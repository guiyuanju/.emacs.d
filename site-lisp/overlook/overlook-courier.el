;;; overlook-courier.el --- Erlang-style messages between AI agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
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
;; `overlook-courier-send' drops a message in a mailbox and returns at once; the
;; message reaches the agent as a new prompt once it is ready for one,
;; between its turns.  `overlook-courier-monitor' asks to be told the next time an
;; agent finishes a turn, with its reply.  `overlook-courier-spawn' starts an agent
;; on a task; the child reports back with `overlook-courier-send', and courier
;; tells the parent what the child cannot: that it ended a turn on the
;; parent's message without reporting, waits for the user, hit an error,
;; or is gone.  Nothing here waits, so Emacs never blocks: an agent sends,
;; ends its turn, and is woken by the reply.  `overlook-courier-hand-off'
;; starts an agent for the user instead: it gets no parent, and its task
;; waits unsent at its prompt.
;;
;; Courier knows no agent program.  A frontend registers each agent with
;; functions delivering a prompt, telling whether it is ready and
;; returning its last reply, and optionally one inserting a draft, and reports its turns through
;; `overlook-courier-turn-started' and `overlook-courier-turn-finished', and requests for
;; the user through `overlook-courier-blocked'.  Agents call in through the
;; bin/courier script, which finds them by $COURIER_ID.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup overlook-courier nil
  "Messages between AI agents."
  :group 'overlook
  :prefix "overlook-courier-")

(defcustom overlook-courier-max-hops 8
  "Messages one human prompt may set off in a row before courier drops them.
A message an agent sends while handling one is a hop further along."
  :type 'natnum
  :group 'overlook-courier)

(defcustom overlook-courier-retry-interval 2
  "Seconds between delivery attempts while some agent is not ready."
  :type 'number
  :group 'overlook-courier)

(defcustom overlook-courier-delivery-delay 2
  "Seconds courier gathers mail before delivering it.
Messages arriving within this time reach an agent as one prompt, so it
spends one turn on them."
  :type 'number
  :group 'overlook-courier)

(defcustom overlook-courier-delivery-timeout 120
  "Seconds a delivery may go without starting a turn before courier gives up on it.
An agent ready for a prompt that took a delivery without starting a turn
would get no more mail; after this long it gets it again."
  :type 'number
  :group 'overlook-courier)

(defcustom overlook-courier-reply-max 4000
  "Most characters of a reply courier passes on; the rest is cut from its start."
  :type 'natnum
  :group 'overlook-courier)

(defvar overlook-courier-spawn-function nil
  "Function of NAME, DIRECTORY, parent ID, EFFORT and AS starting agent NAME.
It returns the new agent's id.  Set by a frontend; the parent ID is nil
when no agent asked, and EFFORT, a reasoning effort level like
\"high\", is nil unless one was asked for.  AS is the id the agent must
get, or nil for a new one.")

(defvar overlook-courier-offline-functions nil
  "Functions returning ids of agents that are not running but start on demand.")

(defvar overlook-courier-start-functions nil
  "Functions of an id and the id of the agent asking, starting that offline agent.
The first to start it returns its id; the others return nil.")

(autoload 'overlook-courier-worktree-cli "overlook-courier-worktree")
(autoload 'overlook-courier-worktree-spawn "overlook-courier-worktree")
(autoload 'overlook-courier-persona-cli "overlook-courier-persona")

(defvar overlook-courier-changed-hook nil
  "Hook run when an agent's mailbox, monitors or registration changed.")

(defconst overlook-courier-bin-directory
  (expand-file-name "bin" (file-name-directory (or load-file-name buffer-file-name "")))
  "Directory of the courier script agents call.")

(defcustom overlook-courier-skill-directories '("~/.claude/skills/" "~/.codex/skills/")
  "Directories agents load skills from, where courier links its skills.
One whose parent folder is missing is skipped, since that agent is not
installed."
  :type '(repeat directory)
  :group 'overlook-courier)

(defun overlook-courier-link-skills ()
  "Link each of courier's skills into `overlook-courier-skill-directories'.
A link that is missing or dangling is made anew; anything else of the
same name is left alone.  Returns the links made."
  (let ((skills (directory-files (expand-file-name "../skills" overlook-courier-bin-directory)
                                 t directory-files-no-dot-files-regexp))
        (made nil))
    (dolist (dir overlook-courier-skill-directories)
      (let ((dir (file-name-as-directory (expand-file-name dir))))
        (when (file-directory-p (file-name-directory (directory-file-name dir)))
          (make-directory dir t)
          (dolist (skill skills)
            (let ((link (expand-file-name (file-name-nondirectory skill) dir)))
              (unless (file-exists-p link)
                (when (file-symlink-p link) (delete-file link))
                (make-symbolic-link skill link)
                (push link made)))))))
    (nreverse made)))

;;; Agents

(cl-defstruct (overlook-courier-agent (:constructor overlook-courier-agent--make) (:copier nil))
  "An agent registered with courier."
  id buffer deliver ready reply insert
  (draft nil :documentation "Text to leave unsent at its prompt once it is ready, or nil.")
  (mailbox nil :documentation "Messages not delivered yet, oldest first.")
  (monitors nil :documentation "Ids of agents to tell when this one next stops.")
  (hops 0 :documentation "Hops of the messages this agent's turn handles.")
  (delivered nil :documentation "Time of a delivery that has not started a turn yet, or nil.")
  (askers nil :documentation "Senders of the messages this agent's turn handles.")
  (told nil :documentation "Agents this one sent to in its current turn.")
  (blocked nil :documentation "Non-nil once its parent heard it waits for the user this turn.")
  (owes nil :documentation "Non-nil while it has not reported on a message from its parent.")
  (notes nil :documentation "Notes for its next prompt, oldest first; they wake nobody.")
  transcript parent)

(defvar overlook-courier--agents (make-hash-table :test #'equal)
  "Registered agents by id.")

(defvar overlook-courier--retry-timer nil)

(defvar overlook-courier--delivery-timer nil)

(defun overlook-courier-agent (id)
  "The agent registered as ID, or nil."
  (and id (gethash id overlook-courier--agents)))

(defun overlook-courier-agents ()
  "All registered agents, sorted by id."
  (sort (hash-table-values overlook-courier--agents)
        (lambda (a b) (string< (overlook-courier-agent-id a) (overlook-courier-agent-id b)))))

(defun overlook-courier-offline ()
  "Ids of the agents `overlook-courier-reach' would start, sorted."
  (sort (seq-remove #'overlook-courier-agent
                    (delete-dups (apply #'append (mapcar #'funcall overlook-courier-offline-functions))))
        #'string<))

(defun overlook-courier-reach (id &optional from)
  "The agent ID, started for agent FROM if it is offline, or nil."
  (or (overlook-courier-agent id)
      (and (member id (overlook-courier-offline))
           (overlook-courier-agent (run-hook-with-args-until-success 'overlook-courier-start-functions id from)))))

(defun overlook-courier-new-id (name directory)
  "A free id for agent NAME in DIRECTORY, like \"claude@shop\"."
  (let* ((base (format "%s@%s" name (file-name-nondirectory (directory-file-name directory))))
         (id base)
         (n 1))
    (while (gethash id overlook-courier--agents)
      (setq id (format "%s-%d" base (cl-incf n))))
    id))

(defun overlook-courier-environment (id)
  "Environment entries telling the agent of ID who it is and how to call courier."
  (delq nil
        (list (concat "COURIER_ID=" id)
              (concat "PATH=" overlook-courier-bin-directory path-separator (or (getenv "PATH") ""))
              (when (bound-and-true-p server-process)
                (concat "COURIER_SOCKET="
                        (expand-file-name (bound-and-true-p server-name)
                                          (bound-and-true-p server-socket-dir)))))))

(cl-defun overlook-courier-register (id &key buffer deliver ready reply insert transcript parent)
  "Register agent ID and return it.
BUFFER is the agent's buffer, unregistered when killed.  DELIVER is a
function of a prompt submitting it to the agent; READY a function telling
whether it can take one now; REPLY a function returning its last reply,
or nil; INSERT a function of a text putting it at the agent's prompt
unsent, or nil; TRANSCRIPT a function returning the file of its whole
session, or nil.  PARENT is the id of the agent that spawned it."
  (let ((agent (overlook-courier-agent--make :id id :buffer buffer :deliver deliver
                                    :ready ready :reply reply :insert insert
                                    :transcript transcript :parent parent)))
    (puthash id agent overlook-courier--agents)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook (lambda () (overlook-courier-unregister id)) nil t)))
    (run-hooks 'overlook-courier-changed-hook)
    agent))

(defun overlook-courier-unregister (id)
  "Forget agent ID, telling its parent and monitors that it is gone.
A parent it already reported to only finds that in its next prompt."
  (when-let* ((agent (overlook-courier-agent id)))
    (remhash id overlook-courier--agents)
    (let ((text (format "[courier] %s is gone." id))
          (parent (overlook-courier-agent-parent agent)))
      (overlook-courier--tell agent (if (overlook-courier-agent-owes agent)
                               (overlook-courier--watchers agent t)
                             (remove parent (overlook-courier-agent-monitors agent)))
                     text)
      (unless (overlook-courier-agent-owes agent)
        (overlook-courier-note parent text)))
    (setf (overlook-courier-agent-monitors agent) nil)
    (run-hooks 'overlook-courier-changed-hook)))

;;; Messages

(defun overlook-courier--enqueue (to from body hops)
  "Put BODY from FROM in TO's mailbox, HOPS from a human prompt."
  (if (> hops overlook-courier-max-hops)
      (message "courier: dropped a message from %s to %s after %d hops"
               (or from "?") (overlook-courier-agent-id to) overlook-courier-max-hops)
    (setf (overlook-courier-agent-mailbox to)
          (append (overlook-courier-agent-mailbox to)
                  (list (list :from from :body body :hops hops :time (float-time)))))
    (run-hooks 'overlook-courier-changed-hook)
    (overlook-courier--schedule)))

(defun overlook-courier--hops (from)
  "Hops of a message sent by agent FROM."
  (if-let* ((sender (overlook-courier-agent from))) (1+ (overlook-courier-agent-hops sender)) 0))

(defun overlook-courier-send (to body &optional from)
  "Send BODY to agent TO from agent FROM, delivered once TO is ready.
An offline TO is started first."
  (let ((agent (or (overlook-courier-reach to from) (user-error "No agent %s" to))))
    (when-let* ((sender (overlook-courier-agent from)))
      (cl-pushnew to (overlook-courier-agent-told sender) :test #'equal)
      (when (equal to (overlook-courier-agent-parent sender))
        (setf (overlook-courier-agent-owes sender) nil)))
    (overlook-courier--enqueue agent from body (overlook-courier--hops from))
    t))

(defun overlook-courier-note (id text)
  "Add TEXT to the next prompt agent ID gets, without waking it."
  (when-let* ((agent (overlook-courier-agent id)))
    (setf (overlook-courier-agent-notes agent) (append (overlook-courier-agent-notes agent) (list text)))
    (run-hooks 'overlook-courier-changed-hook)))

(defun overlook-courier-monitor (watcher target)
  "Tell agent WATCHER, with its reply, the next time agent TARGET finishes a turn."
  (let ((agent (or (overlook-courier-agent target) (user-error "No agent %s" target))))
    (unless (overlook-courier-agent watcher) (user-error "No agent %s" watcher))
    (cl-pushnew watcher (overlook-courier-agent-monitors agent) :test #'equal)
    (run-hooks 'overlook-courier-changed-hook)
    t))

(defun overlook-courier-spawn (name directory prompt &optional from effort as unbriefed)
  "Start agent NAME in DIRECTORY on PROMPT for agent FROM, its parent.
EFFORT is the reasoning effort level to start it with, or nil for its
default; AS the id to give it, or nil for a new one.  With PROMPT nil the
agent idles, and its briefing comes with the first message it gets.
With UNBRIEFED non-nil it is told nothing about courier.
Returns the new agent's id."
  (unless overlook-courier-spawn-function (user-error "No frontend can spawn agents"))
  (when (and as (overlook-courier-agent as)) (user-error "%s is running already" as))
  (let ((id (funcall overlook-courier-spawn-function name (expand-file-name directory) from effort as)))
    (when-let* ((agent (overlook-courier-agent id)))
      (setf (overlook-courier-agent-parent agent) from))
    (cond (prompt
           (overlook-courier--enqueue (overlook-courier-agent id) from
                             (if unbriefed
                                 prompt
                               (concat (overlook-courier--briefing id from t) "\n\n" prompt))
                             (overlook-courier--hops from)))
          ((not unbriefed) (overlook-courier-note id (overlook-courier--briefing id from nil))))
    id))

(defun overlook-courier-hand-off (name directory prompt &optional effort)
  "Start agent NAME in DIRECTORY for the user, with PROMPT left at its prompt.
The agent has no parent and is told nothing about courier; the user
reads PROMPT and sends it.  EFFORT is as for `overlook-courier-spawn'.
Returns the new agent's id."
  (let* ((id (overlook-courier-spawn name directory nil nil effort nil t))
         (agent (overlook-courier-agent id)))
    (when prompt
      (unless (and agent (overlook-courier-agent-insert agent))
        (user-error "%s cannot take a draft" id))
      (setf (overlook-courier-agent-draft agent) prompt)
      (overlook-courier--schedule))
    id))

(defun overlook-courier-or-empty (text default)
  "TEXT, or DEFAULT when TEXT is empty."
  (if (string-empty-p text) default text))

(defun overlook-courier-options (args names &optional flags)
  "Split ARGS into the options NAMES and FLAGS leading it and the rest.
Returns (OPTIONS . REST), OPTIONS an alist of each option given to its
value, and of each flag given to t."
  (let ((options nil))
    (while (or (member (car args) names) (member (car args) flags))
      (let ((name (pop args)))
        (push (cons name (or (and (member name flags) t)
                             (pop args)
                             (user-error "No value after %s" name)))
              options)))
    (cons options args)))

(defun overlook-courier-option (name options)
  "The value of option NAME in OPTIONS from `overlook-courier-options', or nil."
  (cdr (assoc name options)))

(defun overlook-courier--briefing (id from task)
  "What agent ID is told when spawned for agent FROM, with a TASK or not."
  (concat (format "You are %s, an agent reachable through courier." id)
          (when from
            (format "  %s started you%s.  When you finish what it asks or get \
stuck, report to %s with `courier send %s MESSAGE`; put a long result in a \
file and send its path.  If you end a turn on its message without \
reporting, your final reply is sent to it instead."
                    from (if task " for the task below" "") from from))
          "  Message another agent with `courier send ID MESSAGE`; `courier list` \
shows them."))

(defun overlook-courier--watchers (agent &optional parent)
  "Ids of the agents monitoring AGENT, and its parent too if PARENT is non-nil."
  (let ((watchers (overlook-courier-agent-monitors agent))
        (parent (and parent (overlook-courier-agent-parent agent))))
    (if parent (cl-adjoin parent watchers :test #'equal) watchers)))

(defun overlook-courier--cut (text agent)
  "TEXT of AGENT's, cut from its start to `overlook-courier-reply-max' characters."
  (if (<= (length text) overlook-courier-reply-max)
      text
    (concat (format "[… %d characters cut%s]\n"
                    (- (length text) overlook-courier-reply-max)
                    (if-let* ((transcript (overlook-courier-agent-transcript agent))
                              (file (ignore-errors (funcall transcript))))
                        (format "; all of it is in %s" file)
                      ""))
            (substring text (- overlook-courier-reply-max)))))

(defun overlook-courier--tell (agent watchers text)
  "Send TEXT from AGENT to the agents of ids WATCHERS."
  (let ((hops (1+ (overlook-courier-agent-hops agent))))
    (dolist (watcher watchers)
      (when-let* ((to (overlook-courier-agent watcher)))
        (overlook-courier--enqueue to (overlook-courier-agent-id agent) text hops)))))

;;; Turns

(defun overlook-courier-turn-started (id)
  "Note that agent ID started a turn.
A turn courier did not deliver comes from a human, so its hops restart."
  (when-let* ((agent (overlook-courier-agent id)))
    (if (overlook-courier-agent-delivered agent)
        (setf (overlook-courier-agent-delivered agent) nil)
      (setf (overlook-courier-agent-hops agent) 0
            (overlook-courier-agent-askers agent) nil))
    (setf (overlook-courier-agent-told agent) nil
          (overlook-courier-agent-blocked agent) nil)))

(defun overlook-courier-turn-finished (id &optional error)
  "Note that agent ID finished a turn, failing with message ERROR if non-nil.
Tell its monitors, and its parent if the turn failed or handled a message
from it, then deliver the mail.  An agent hears no more of a turn that
reported to it, unless the turn failed."
  (when-let* ((agent (overlook-courier-agent id)))
    (let ((watchers (overlook-courier--watchers
                     agent (or error (member (overlook-courier-agent-parent agent)
                                             (overlook-courier-agent-askers agent))))))
      (unless error
        (setq watchers (cl-set-difference watchers (overlook-courier-agent-told agent) :test #'equal)))
      (setf (overlook-courier-agent-delivered agent) nil
            (overlook-courier-agent-askers agent) nil
            (overlook-courier-agent-monitors agent) nil)
      (when (member (overlook-courier-agent-parent agent) watchers)
        (setf (overlook-courier-agent-owes agent) nil))
      (when watchers
        (let ((reply (overlook-courier--reply agent)))
          (overlook-courier--tell agent watchers
                         (concat (if error
                                     (format "[courier] %s hit an error: %s" id error)
                                   (format "[courier] %s finished its turn" id))
                                 (if reply
                                     (format ".  Its reply:\n\n%s" (overlook-courier--cut reply agent))
                                   "."))))))
    (overlook-courier--schedule)))

(defun overlook-courier-blocked (id what)
  "Note for agent ID's parent and monitors that it waits for the user on WHAT.
Only the user can answer, so they are not woken; they find it in their
next prompt, once per turn."
  (when-let* ((agent (overlook-courier-agent id))
              ((not (overlook-courier-agent-blocked agent))))
    (setf (overlook-courier-agent-blocked agent) t)
    (dolist (watcher (overlook-courier--watchers agent t))
      (overlook-courier-note watcher (format "[courier] %s is waiting for the user: %s.  \
It goes on once they answer in its buffer." id what)))))

(defun overlook-courier--reply (agent)
  "AGENT's last reply, or nil."
  (when-let* ((reply (overlook-courier-agent-reply agent))
              (text (ignore-errors (funcall reply)))
              (text (string-trim text))
              ((not (string-empty-p text))))
    text))

;;; Delivery

(defun overlook-courier--format (messages)
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

(defun overlook-courier--prompt (agent messages)
  "The prompt delivering MESSAGES to AGENT, with the notes for it."
  (string-join (append (overlook-courier-agent-notes agent)
                       (list (overlook-courier--format messages)))
               "\n\n---\n\n"))

(defun overlook-courier--frontend-ready-p (agent)
  "Non-nil when AGENT's frontend says it can take a prompt."
  (if-let* ((ready (overlook-courier-agent-ready agent)))
      (ignore-errors (funcall ready))
    t))

(defun overlook-courier--ready-p (agent)
  "Non-nil when AGENT can take a prompt now."
  (and (or (null (overlook-courier-agent-buffer agent)) (buffer-live-p (overlook-courier-agent-buffer agent)))
       (not (overlook-courier-agent-delivered agent))
       (overlook-courier--frontend-ready-p agent)))

(defun overlook-courier--give-up (agent)
  "Forget AGENT's delivery if it started no turn in time.
The time is `overlook-courier-delivery-timeout'."
  (when-let* ((delivered (overlook-courier-agent-delivered agent))
              ((> (- (float-time) delivered) overlook-courier-delivery-timeout))
              ((overlook-courier--frontend-ready-p agent)))
    (setf (overlook-courier-agent-delivered agent) nil)))

(defun overlook-courier--draft (agent)
  "Leave AGENT's draft at its prompt if it is ready; non-nil while it is not."
  (when-let* ((draft (overlook-courier-agent-draft agent)))
    (if (not (overlook-courier--ready-p agent))
        t
      (setf (overlook-courier-agent-draft agent) nil)
      (condition-case err
          (funcall (overlook-courier-agent-insert agent) draft)
        (error (message "courier: drafting for %s failed: %S" (overlook-courier-agent-id agent) err)))
      nil)))

(defun overlook-courier-deliver ()
  "Deliver the mail and drafts of every ready agent, and retry the rest later."
  (let ((waiting nil))
    (dolist (agent (overlook-courier-agents))
      (when (overlook-courier--draft agent) (setq waiting t))
      (when-let* ((messages (overlook-courier-agent-mailbox agent)))
        (overlook-courier--give-up agent)
        (if (not (overlook-courier--ready-p agent))
            (setq waiting t)
          (setf (overlook-courier-agent-mailbox agent) nil
                (overlook-courier-agent-delivered agent) (float-time)
                (overlook-courier-agent-askers agent)
                (delete-dups (delq nil (mapcar (lambda (m) (plist-get m :from)) messages)))
                (overlook-courier-agent-owes agent)
                (or (overlook-courier-agent-owes agent)
                    (and (member (overlook-courier-agent-parent agent) (overlook-courier-agent-askers agent)) t))
                (overlook-courier-agent-hops agent)
                (apply #'max (mapcar (lambda (m) (plist-get m :hops)) messages)))
          (condition-case err
              (progn
                (funcall (overlook-courier-agent-deliver agent) (overlook-courier--prompt agent messages))
                (setf (overlook-courier-agent-notes agent) nil))
            (error
             (setf (overlook-courier-agent-mailbox agent) messages
                   (overlook-courier-agent-delivered agent) nil
                   waiting t)
             (message "courier: delivering to %s failed: %S" (overlook-courier-agent-id agent) err)))
          (run-hooks 'overlook-courier-changed-hook))))
    (when (timerp overlook-courier--retry-timer) (cancel-timer overlook-courier--retry-timer))
    (setq overlook-courier--retry-timer
          (and waiting (run-at-time overlook-courier-retry-interval nil #'overlook-courier-deliver)))))

(defun overlook-courier--schedule ()
  "Deliver after `overlook-courier-delivery-delay'.
The mail that comes meanwhile goes in the same delivery."
  (unless (timerp overlook-courier--delivery-timer)
    (setq overlook-courier--delivery-timer
          (run-at-time overlook-courier-delivery-delay nil
                       (lambda ()
                         (setq overlook-courier--delivery-timer nil)
                         (overlook-courier-deliver))))))

;;; Calls from agents

(defun overlook-courier--describe (agent)
  "A line describing AGENT for `courier list'."
  (let ((pending (length (overlook-courier-agent-mailbox agent))))
    (concat (overlook-courier-agent-id agent)
            (when-let* ((parent (overlook-courier-agent-parent agent))) (format "  (spawned by %s)" parent))
            (when (> pending 0) (format "  %d unread" pending))
            (when-let* ((buffer (overlook-courier-agent-buffer agent))
                        ((buffer-live-p buffer)))
              (format "  %s" (abbreviate-file-name
                              (buffer-local-value 'default-directory buffer)))))))

(defun overlook-courier--decode (arg)
  "ARG as sent by bin/courier: base64 of UTF-8 text."
  (decode-coding-string (base64-decode-string arg) 'utf-8))

(defun overlook-courier-cli (output from command &rest args)
  "Run COMMAND with ARGS for agent FROM and write the result to file OUTPUT.
Called by bin/courier, which encodes every argument but OUTPUT with base64,
in the agent's working directory."
  (let* ((from (let ((id (overlook-courier--decode from))) (and (not (string-empty-p id)) id)))
         (args (mapcar #'overlook-courier--decode args))
         (text (condition-case err
                   (pcase (cons (overlook-courier--decode command) args)
                     (`("send" ,to ,body)
                      (let ((offline (not (overlook-courier-agent to))))
                        (overlook-courier-send to body from)
                        (format "Sent to %s; it arrives when %s is between turns.%s" to to
                                (if offline (format "  %s was offline, so it was started." to) ""))))
                     ((and `("spawn" . ,rest)
                           (let `(,options ,name ,directory ,prompt)
                             (overlook-courier-options rest '("--effort" "--worktree") '("--handoff"))))
                      (let* ((effort (overlook-courier-option "--effort" options))
                             (branch (overlook-courier-option "--worktree" options))
                             (handoff (overlook-courier-option "--handoff" options))
                             (id (cond (branch (overlook-courier-worktree-spawn name directory branch prompt
                                                                       from effort handoff))
                                       (handoff (overlook-courier-hand-off name directory prompt effort))
                                       (t (overlook-courier-spawn name directory prompt from effort)))))
                        (format "Started %s.%s" id
                                (cond
                                 (handoff "  It is your user's now, told nothing of you or \
courier; the task waits unsent at its prompt for your user to check and \
send.  Do not wait for it or message it.")
                                 ((overlook-courier-agent from)
                                  "  It reports when done or stuck, and courier tells you \
if it stops without reporting, waits for the user, hits an error or is \
gone.  End your turn now.")
                                 (t "")))))
                     (`("monitor" ,target)
                      (overlook-courier-monitor (or from (user-error "No COURIER_ID")) target)
                      (format "You will be told when %s next finishes a turn." target))
                     (`("list")
                      (concat (mapconcat #'overlook-courier--describe (overlook-courier-agents) "\n")
                              (when-let* ((offline (overlook-courier-offline)))
                                (format "\nOffline, started by a message: %s"
                                        (string-join offline ", ")))))
                     (`("whoami") (or from "Not a courier agent: COURIER_ID is unset."))
                     (`("worktree" . ,rest) (overlook-courier-worktree-cli rest))
                     (`("persona" . ,rest) (overlook-courier-persona-cli from rest))
                     (_ (user-error "Usage: courier send ID MESSAGE \
| spawn [--effort LEVEL] [--worktree BRANCH] [--handoff] AGENT DIR PROMPT | monitor ID \
| list | whoami | persona COMMAND | worktree COMMAND")))
                 (error (concat "error: " (error-message-string err))))))
    (with-temp-file output
      (set-buffer-file-coding-system 'utf-8)
      (insert text "\n"))
    (not (string-prefix-p "error: " text))))

(provide 'overlook-courier)
;;; overlook-courier.el ends here
