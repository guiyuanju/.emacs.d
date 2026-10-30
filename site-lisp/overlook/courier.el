;;; courier.el --- Erlang-style messages between AI agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes
;; URL: https://github.com/guiyuanju/overlook
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Lets AI agents running in Emacs message each other, the way Erlang
;; processes do.  Each agent registered here has an id and a mailbox.
;; `courier-send' drops a message in a mailbox and returns at once; the
;; message reaches the agent as a new prompt once it is ready for one,
;; between its turns.  `courier-monitor' asks to be told the next time an
;; agent finishes a turn, with its reply.  `courier-spawn' starts an agent
;; on a task; the child reports back with `courier-send', and courier
;; tells the parent what the child cannot: that it ended a turn on the
;; parent's message without reporting, waits for the user, hit an error,
;; or is gone.  Nothing here waits, so Emacs never blocks: an agent sends,
;; ends its turn, and is woken by the reply.
;;
;; Courier knows no agent program.  A frontend registers each agent with
;; functions delivering a prompt, telling whether it is ready and
;; returning its last reply, and reports its turns through
;; `courier-turn-started' and `courier-turn-finished', and requests for
;; the user through `courier-blocked'.  Agents call in through the
;; bin/courier script, which finds them by $COURIER_ID.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup courier nil
  "Messages between AI agents."
  :group 'tools
  :prefix "courier-")

(defcustom courier-max-hops 8
  "Messages one human prompt may set off in a row before courier drops them.
A message an agent sends while handling one is a hop further along."
  :type 'natnum
  :group 'courier)

(defcustom courier-retry-interval 2
  "Seconds between delivery attempts while some agent is not ready."
  :type 'number
  :group 'courier)

(defvar courier-spawn-function nil
  "Function of NAME, DIRECTORY, parent ID and EFFORT starting agent NAME.
It returns the new agent's id.  Set by a frontend; the parent ID is nil
when no agent asked, and EFFORT, a reasoning effort level like
\"high\", is nil unless one was asked for.")

(defvar courier-prompt-functions nil
  "Functions of an agent's id returning a note for the prompt delivered to it.
A function returns nil to add nothing.")

(autoload 'courier-room-cli "courier-room")

(defvar courier-changed-hook nil
  "Hook run when an agent's mailbox, monitors or registration changed.")

(defconst courier-bin-directory
  (expand-file-name "bin" (file-name-directory (or load-file-name buffer-file-name "")))
  "Directory of the courier script agents call.")

;;; Agents

(cl-defstruct (courier-agent (:constructor courier-agent--make) (:copier nil))
  "An agent registered with courier."
  id buffer deliver ready reply
  (mailbox nil :documentation "Messages not delivered yet, oldest first.")
  (monitors nil :documentation "Ids of agents to tell when this one next stops.")
  (hops 0 :documentation "Hops of the messages this agent's turn handles.")
  (delivered nil :documentation "Non-nil while a delivery has not started a turn yet.")
  (askers nil :documentation "Senders of the messages this agent's turn handles.")
  (told nil :documentation "Agents this one sent to in its current turn.")
  (blocked nil :documentation "Non-nil once its parent heard it waits for the user this turn.")
  parent)

(defvar courier--agents (make-hash-table :test #'equal)
  "Registered agents by id.")

(defvar courier--retry-timer nil)

(defun courier-agent (id)
  "The agent registered as ID, or nil."
  (and id (gethash id courier--agents)))

(defun courier-agents ()
  "All registered agents, sorted by id."
  (sort (hash-table-values courier--agents)
        (lambda (a b) (string< (courier-agent-id a) (courier-agent-id b)))))

(defun courier-new-id (name directory)
  "A free id for agent NAME in DIRECTORY, like \"claude@shop\"."
  (let* ((base (format "%s@%s" name (file-name-nondirectory (directory-file-name directory))))
         (id base)
         (n 1))
    (while (gethash id courier--agents)
      (setq id (format "%s-%d" base (cl-incf n))))
    id))

(defun courier-environment (id)
  "Environment entries telling the agent of ID who it is and how to call courier."
  (delq nil
        (list (concat "COURIER_ID=" id)
              (concat "PATH=" courier-bin-directory path-separator (or (getenv "PATH") ""))
              (when (bound-and-true-p server-process)
                (concat "COURIER_SOCKET="
                        (expand-file-name (bound-and-true-p server-name)
                                          (bound-and-true-p server-socket-dir)))))))

(cl-defun courier-register (id &key buffer deliver ready reply parent)
  "Register agent ID and return it.
BUFFER is the agent's buffer, unregistered when killed.  DELIVER is a
function of a prompt submitting it to the agent; READY a function telling
whether it can take one now; REPLY a function returning its last reply,
or nil.  PARENT is the id of the agent that spawned it."
  (let ((agent (courier-agent--make :id id :buffer buffer :deliver deliver
                                    :ready ready :reply reply :parent parent)))
    (puthash id agent courier--agents)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook (lambda () (courier-unregister id)) nil t)))
    (run-hooks 'courier-changed-hook)
    agent))

(defun courier-unregister (id)
  "Forget agent ID, telling its parent and monitors that it is gone."
  (when-let* ((agent (courier-agent id)))
    (remhash id courier--agents)
    (courier--tell agent (courier--watchers agent t) (format "[courier] %s is gone." id))
    (setf (courier-agent-monitors agent) nil)
    (run-hooks 'courier-changed-hook)))

;;; Messages

(defun courier--enqueue (to from body hops)
  "Put BODY from FROM in TO's mailbox, HOPS from a human prompt."
  (if (> hops courier-max-hops)
      (message "courier: dropped a message from %s to %s after %d hops"
               (or from "?") (courier-agent-id to) courier-max-hops)
    (setf (courier-agent-mailbox to)
          (append (courier-agent-mailbox to)
                  (list (list :from from :body body :hops hops :time (float-time)))))
    (run-hooks 'courier-changed-hook)
    (courier--schedule)))

(defun courier--hops (from)
  "Hops of a message sent by agent FROM."
  (if-let* ((sender (courier-agent from))) (1+ (courier-agent-hops sender)) 0))

(defun courier-send (to body &optional from)
  "Send BODY to agent TO from agent FROM, delivered once TO is ready."
  (let ((agent (or (courier-agent to) (user-error "No agent %s" to))))
    (when-let* ((sender (courier-agent from)))
      (cl-pushnew to (courier-agent-told sender) :test #'equal))
    (courier--enqueue agent from body (courier--hops from))
    t))

(defun courier-monitor (watcher target)
  "Tell agent WATCHER, with its reply, the next time agent TARGET finishes a turn."
  (let ((agent (or (courier-agent target) (user-error "No agent %s" target))))
    (unless (courier-agent watcher) (user-error "No agent %s" watcher))
    (cl-pushnew watcher (courier-agent-monitors agent) :test #'equal)
    (run-hooks 'courier-changed-hook)
    t))

(defun courier-spawn (name directory prompt &optional from effort)
  "Start agent NAME in DIRECTORY on PROMPT for agent FROM, which it monitors.
EFFORT is the reasoning effort level to start it with, or nil for its
default.  Returns the new agent's id."
  (unless courier-spawn-function (user-error "No frontend can spawn agents"))
  (let ((id (funcall courier-spawn-function name (expand-file-name directory) from effort)))
    (when-let* ((agent (courier-agent id)))
      (setf (courier-agent-parent agent) from))
    (when (courier-agent from)
      (courier-monitor from id))
    (courier--enqueue (courier-agent id) from
                      (concat (courier--briefing id from) "\n\n" prompt)
                      (courier--hops from))
    id))

(defun courier--briefing (id from)
  "What agent ID is told when spawned for agent FROM."
  (concat (format "You are %s, an agent reachable through courier." id)
          (when from
            (format "  %s started you for the task below.  When you finish it \
or get stuck, report to %s with `courier send %s MESSAGE`; put a long \
result in a file and send its path.  If you end a turn on its task without \
reporting, your final reply is sent to it instead." from from from))
          "  Message another agent with `courier send ID MESSAGE`; `courier list` \
shows them."))

(defun courier--watchers (agent &optional parent)
  "Ids of the agents monitoring AGENT, and its parent too if PARENT is non-nil."
  (let ((watchers (courier-agent-monitors agent))
        (parent (and parent (courier-agent-parent agent))))
    (if parent (cl-adjoin parent watchers :test #'equal) watchers)))

(defun courier--tell (agent watchers text)
  "Send TEXT from AGENT to the agents of ids WATCHERS."
  (let ((hops (1+ (courier-agent-hops agent))))
    (dolist (watcher watchers)
      (when-let* ((to (courier-agent watcher)))
        (courier--enqueue to (courier-agent-id agent) text hops)))))

;;; Turns

(defun courier-turn-started (id)
  "Note that agent ID started a turn.
A turn courier did not deliver comes from a human, so its hops restart."
  (when-let* ((agent (courier-agent id)))
    (if (courier-agent-delivered agent)
        (setf (courier-agent-delivered agent) nil)
      (setf (courier-agent-hops agent) 0
            (courier-agent-askers agent) nil))
    (setf (courier-agent-told agent) nil
          (courier-agent-blocked agent) nil)))

(defun courier-turn-finished (id &optional error)
  "Note that agent ID finished a turn, failing with message ERROR if non-nil.
Tell its monitors, and its parent if the turn failed or handled a message
from it, then deliver the mail.  An agent hears no more of a turn that
reported to it, unless the turn failed."
  (when-let* ((agent (courier-agent id)))
    (let ((watchers (courier--watchers
                     agent (or error (member (courier-agent-parent agent)
                                             (courier-agent-askers agent))))))
      (unless error
        (setq watchers (cl-set-difference watchers (courier-agent-told agent) :test #'equal)))
      (setf (courier-agent-delivered agent) nil
            (courier-agent-askers agent) nil
            (courier-agent-monitors agent) nil)
      (when watchers
        (let ((reply (courier--reply agent)))
          (courier--tell agent watchers
                         (concat (if error
                                     (format "[courier] %s hit an error: %s" id error)
                                   (format "[courier] %s finished its turn" id))
                                 (if reply (format ".  Its reply:\n\n%s" reply) "."))))))
    (courier--schedule)))

(defun courier-blocked (id what)
  "Tell agent ID's parent and monitors that it waits for the user on WHAT.
They hear it once per turn."
  (when-let* ((agent (courier-agent id))
              ((not (courier-agent-blocked agent)))
              (watchers (courier--watchers agent t)))
    (setf (courier-agent-blocked agent) t)
    (courier--tell agent watchers
                   (format "[courier] %s is waiting for the user: %s.  It goes on \
once they answer in its buffer." id what))))

(defun courier--reply (agent)
  "AGENT's last reply, or nil."
  (when-let* ((reply (courier-agent-reply agent))
              (text (ignore-errors (funcall reply)))
              (text (string-trim text))
              ((not (string-empty-p text))))
    text))

;;; Delivery

(defun courier--format (messages)
  "One prompt carrying MESSAGES."
  (mapconcat (lambda (message)
               (let ((from (plist-get message :from))
                     (body (plist-get message :body)))
                 (if (or (null from) (string-prefix-p "[courier]" body))
                     body
                   (format "[courier] From agent %s, not from your user \
(answer with `courier send %s MESSAGE`):\n\n%s"
                           from from body))))
             messages "\n\n---\n\n"))

(defun courier--prompt (agent messages)
  "The prompt delivering MESSAGES to AGENT, with the notes for it."
  (string-join (cons (courier--format messages)
                     (delq nil (mapcar (lambda (fn) (funcall fn (courier-agent-id agent)))
                                       courier-prompt-functions)))
               "\n\n---\n\n"))

(defun courier--ready-p (agent)
  "Non-nil when AGENT can take a prompt now."
  (and (or (null (courier-agent-buffer agent)) (buffer-live-p (courier-agent-buffer agent)))
       (not (courier-agent-delivered agent))
       (if-let* ((ready (courier-agent-ready agent)))
           (ignore-errors (funcall ready))
         t)))

(defun courier-deliver ()
  "Deliver the mail of every agent that is ready, and retry the rest later."
  (let ((waiting nil))
    (dolist (agent (courier-agents))
      (when-let* ((messages (courier-agent-mailbox agent)))
        (if (not (courier--ready-p agent))
            (setq waiting t)
          (setf (courier-agent-mailbox agent) nil
                (courier-agent-delivered agent) t
                (courier-agent-askers agent)
                (delete-dups (delq nil (mapcar (lambda (m) (plist-get m :from)) messages)))
                (courier-agent-hops agent)
                (apply #'max (mapcar (lambda (m) (plist-get m :hops)) messages)))
          (condition-case err
              (funcall (courier-agent-deliver agent) (courier--prompt agent messages))
            (error
             (setf (courier-agent-mailbox agent) messages
                   (courier-agent-delivered agent) nil
                   waiting t)
             (message "courier: delivering to %s failed: %S" (courier-agent-id agent) err)))
          (run-hooks 'courier-changed-hook))))
    (when (timerp courier--retry-timer) (cancel-timer courier--retry-timer))
    (setq courier--retry-timer
          (and waiting (run-at-time courier-retry-interval nil #'courier-deliver)))))

(defun courier--schedule ()
  "Deliver soon, outside whatever process filter or hook is running."
  (run-at-time 0 nil #'courier-deliver))

;;; Calls from agents

(defun courier--describe (agent)
  "A line describing AGENT for `courier list'."
  (let ((pending (length (courier-agent-mailbox agent))))
    (concat (courier-agent-id agent)
            (when-let* ((parent (courier-agent-parent agent))) (format "  (spawned by %s)" parent))
            (when (> pending 0) (format "  %d unread" pending))
            (when-let* ((buffer (courier-agent-buffer agent))
                        ((buffer-live-p buffer)))
              (format "  %s" (abbreviate-file-name
                              (buffer-local-value 'default-directory buffer)))))))

(defun courier--decode (arg)
  "ARG as sent by bin/courier: base64 of UTF-8 text."
  (decode-coding-string (base64-decode-string arg) 'utf-8))

(defun courier-cli (output from command &rest args)
  "Run COMMAND with ARGS for agent FROM and write the result to file OUTPUT.
Called by bin/courier, which encodes every argument but OUTPUT with base64."
  (let* ((from (let ((id (courier--decode from))) (and (not (string-empty-p id)) id)))
         (args (mapcar #'courier--decode args))
         (text (condition-case err
                   (pcase (cons (courier--decode command) args)
                     (`("send" ,to ,body)
                      (courier-send to body from)
                      (format "Sent to %s; it arrives when %s is between turns." to to))
                     ((or `("spawn" ,name ,directory ,prompt)
                          `("spawn" "--effort" ,effort ,name ,directory ,prompt))
                      (let ((id (courier-spawn name directory prompt from effort)))
                        (format "Started %s.%s" id
                                (if (courier-agent from)
                                    "  It reports when done or stuck, and courier tells you \
if it stops without reporting, waits for the user, hits an error or is \
gone.  End your turn now."
                                  ""))))
                     (`("monitor" ,target)
                      (courier-monitor (or from (user-error "No COURIER_ID")) target)
                      (format "You will be told when %s next finishes a turn." target))
                     (`("list")
                      (mapconcat #'courier--describe (courier-agents) "\n"))
                     (`("whoami") (or from "Not a courier agent: COURIER_ID is unset."))
                     (`("room" . ,rest) (courier-room-cli from rest))
                     (_ (user-error "Usage: courier send ID MESSAGE \
| spawn [--effort LEVEL] AGENT DIR PROMPT | monitor ID | list | whoami \
| room COMMAND")))
                 (error (concat "error: " (error-message-string err))))))
    (with-temp-file output
      (set-buffer-file-coding-system 'utf-8)
      (insert text "\n"))
    (not (string-prefix-p "error: " text))))

(provide 'courier)
;;; courier.el ends here
