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
;; agent finishes a turn, with its reply; `courier-spawn' starts an agent
;; on a task and monitors it.  Nothing here waits, so Emacs never blocks:
;; an agent sends, ends its turn, and is woken by the reply.
;;
;; Courier knows no agent program.  A frontend registers each agent with
;; functions delivering a prompt, telling whether it is ready and
;; returning its last reply, and reports its turns through
;; `courier-turn-started' and `courier-turn-finished'.  Agents call in
;; through the bin/courier script, which finds them by $COURIER_ID.

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
  "Function of NAME, DIRECTORY and parent ID starting agent NAME, returning its id.
Set by a frontend; the parent ID is nil when no agent asked.")

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
  "Forget agent ID, telling the agents monitoring it that it is gone."
  (when-let* ((agent (courier-agent id)))
    (remhash id courier--agents)
    (courier--notify-monitors agent (format "[courier] %s is gone." id))
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
    (courier--enqueue agent from body (courier--hops from))
    t))

(defun courier-monitor (watcher target)
  "Tell agent WATCHER, with its reply, the next time agent TARGET finishes a turn."
  (let ((agent (or (courier-agent target) (user-error "No agent %s" target))))
    (unless (courier-agent watcher) (user-error "No agent %s" watcher))
    (cl-pushnew watcher (courier-agent-monitors agent) :test #'equal)
    (run-hooks 'courier-changed-hook)
    t))

(defun courier-spawn (name directory prompt &optional from)
  "Start agent NAME in DIRECTORY on PROMPT for agent FROM, which it monitors.
Returns the new agent's id."
  (unless courier-spawn-function (user-error "No frontend can spawn agents"))
  (let ((id (funcall courier-spawn-function name (expand-file-name directory) from)))
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
            (format "  %s started you for the task below and is told your final \
reply when you finish your turn, so end with what it needs to know, and \
call no tools after that reply." from))
          "  Message another agent with `courier send ID MESSAGE`; `courier list` \
shows them."))

(defun courier--notify-monitors (agent text)
  "Send TEXT from AGENT to the agents monitoring it, and stop monitoring."
  (let ((watchers (courier-agent-monitors agent))
        (hops (1+ (courier-agent-hops agent))))
    (setf (courier-agent-monitors agent) nil)
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
      (setf (courier-agent-hops agent) 0))))

(defun courier-turn-finished (id)
  "Note that agent ID finished a turn: tell its monitors and deliver its mail."
  (when-let* ((agent (courier-agent id)))
    (setf (courier-agent-delivered agent) nil)
    (when (courier-agent-monitors agent)
      (let ((reply (courier--reply agent)))
        (courier--notify-monitors
         agent
         (if reply
             (format "[courier] %s finished its turn.  Its reply:\n\n%s" id reply)
           (format "[courier] %s finished its turn." id)))))
    (courier--schedule)))

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
                   (format "[courier] From %s (answer with `courier send %s MESSAGE`):\n\n%s"
                           from from body))))
             messages "\n\n---\n\n"))

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
                (courier-agent-hops agent)
                (apply #'max (mapcar (lambda (m) (plist-get m :hops)) messages)))
          (condition-case err
              (funcall (courier-agent-deliver agent) (courier--format messages))
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
  "Run COMMAND with ARGS for agent FROM, writing what it says to file OUTPUT.
Called by bin/courier, which encodes every argument but OUTPUT with base64."
  (let* ((from (let ((id (courier--decode from))) (and (not (string-empty-p id)) id)))
         (args (mapcar #'courier--decode args))
         (text (condition-case err
                   (pcase (cons (courier--decode command) args)
                     (`("send" ,to ,body)
                      (courier-send to body from)
                      (format "Sent to %s; it arrives when %s is between turns." to to))
                     (`("spawn" ,name ,directory ,prompt)
                      (let ((id (courier-spawn name directory prompt from)))
                        (format "Started %s.%s" id
                                (if (courier-agent from)
                                    "  You will get its reply when it finishes; end your turn now."
                                  ""))))
                     (`("monitor" ,target)
                      (courier-monitor (or from (user-error "No COURIER_ID")) target)
                      (format "You will be told when %s next finishes a turn." target))
                     (`("list")
                      (mapconcat #'courier--describe (courier-agents) "\n"))
                     (`("whoami") (or from "Not a courier agent: COURIER_ID is unset."))
                     (_ (user-error "Usage: courier send ID MESSAGE | spawn AGENT DIR PROMPT \
| monitor ID | list | whoami")))
                 (error (concat "error: " (error-message-string err))))))
    (with-temp-file output
      (set-buffer-file-coding-system 'utf-8)
      (insert text "\n"))
    (not (string-prefix-p "error: " text))))

(provide 'courier)
;;; courier.el ends here
