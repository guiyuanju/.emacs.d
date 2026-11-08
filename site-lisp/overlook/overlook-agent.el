;;; overlook-agent.el --- AI agents on the overlook dashboard -*- lexical-binding: t; -*-

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

;; Tracks AI agents run by a frontend (overlook-agent-shell.el drives
;; agent-shell) and lists each under the project holding its buffer,
;; the one whose root it runs at when several hold it: its status, how long
;; its turn has run, its context usage and what it is doing.
;;
;; Agents are started with the frontend's own commands.  The frontend
;; describes each agent buffer it sees in `overlook-agent-identity', hands
;; it to `overlook-agent-register', and reports through
;; `overlook-agent-report'.  `overlook-agent-start-function' starts agents
;; for overlook itself: to resume a saved one, or for courier to spawn.
;;
;; Overlook remembers which session each forked agent came from, in
;; `overlook-agent-forks-file', and lists forks under their parent.

;;; Code:

(require 'overlook)
(require 'project)

(declare-function notifications-notify "notifications" (&rest params))

(defcustom overlook-agent-root-function #'overlook-agent-project-root
  "Function returning the directory agents of the current buffer run in."
  :type 'function
  :group 'overlook)

(defcustom overlook-agent-start-function nil
  "Function starting agent NAME in ROOT and returning its buffer.
Called with NAME and ROOT, and to resume a saved session also with nil
and the SESSION id, or to start a new conversation with t.  The buffer
it returns has been registered with `overlook-agent-register'."
  :type 'function
  :group 'overlook)

(defvar overlook-agent-effort nil
  "Reasoning effort level, like \"high\", for the agent being started, or nil.
Bound around `overlook-agent-start-function', which applies it if its
frontend can.")

(defcustom overlook-agent-saved-file (locate-user-emacs-file "overlook-agents.eld")
  "File keeping the agents to offer for resuming after a restart."
  :type 'file
  :group 'overlook)

(defcustom overlook-agent-forks-file (locate-user-emacs-file "overlook-forks.eld")
  "File keeping the session each forked session was forked from."
  :type 'file
  :group 'overlook)

(defcustom overlook-agent-status-glyphs
  '((working "◐" warning)
    (waiting "▲" error)
    (failed "✖" error)
    (done "●" success)
    (idle "○" shadow))
  "Glyph and face for each `overlook-agent-status'.
The dashboard draws an agent's icon in the face; completion shows the glyph."
  :type '(alist :key-type symbol :value-type (list string face))
  :group 'overlook)

(defcustom overlook-agent-context-warning 70
  "Context usage percentage from which an agent's is highlighted."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-agent-title-width 30
  "Columns an agent's session title takes at most on its row."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-agent-notify 'unfocused
  "When to notify that an agent waits, fails or finishes unseen.
`unfocused' notifies while no Emacs frame has focus, t always, nil never."
  :type '(choice (const :tag "While Emacs is unfocused" unfocused)
                 (const :tag "Always" t)
                 (const :tag "Never" nil))
  :group 'overlook)

(defcustom overlook-agent-notify-function #'overlook-agent-notify-system
  "Function of TITLE, BODY and the agent BUFFER showing a notification."
  :type 'function
  :group 'overlook)

(defface overlook-agent-waiting
  '((((background dark)) :background "#3d1c20" :extend t)
    (t :background "#fbe4e4" :extend t))
  "Face added to the row of an agent waiting for you."
  :group 'overlook)

(defface overlook-agent-done
  '((((background dark)) :background "#1b3324" :extend t)
    (t :background "#e2f5e6" :extend t))
  "Face added to the row of an agent that finished unseen."
  :group 'overlook)

(defconst overlook-agent--wrap-indent "   "
  "Indent of an agent row's continuation lines, lining up with its name.")

;;; State

(defvar-local overlook-agent-identity nil
  "Alist describing the agent in this buffer, set by its frontend.
Keys: `agent' its name; `root' its directory; `insert' a function
inserting a string into its input; `context' a function returning its
context usage percentage or nil; `brief' a function returning a line on
what it is doing, or nil; `title' a function returning its session's
title, or nil; `session' a function returning its session id,
or nil; `submit' a function submitting a prompt to it; `ready' a function
telling whether it can take a prompt now; `reply' a function returning
its last reply, or nil; `transcript' a function returning the file
recording its session, or nil; `choices' a function returning the answers it
offers you now, each (KEY LABEL FUNCTION) with FUNCTION giving that answer
in its buffer, or nil; `forked-from' a function returning the session id
its session was forked from, or nil; `environment' the entries of
`overlook-agent-make-environment' its process started with, or nil;
`remote-controls' a function returning a plist of :slash, a list of
\(:name N :description D), :steer, non-nil when it can be steered, and
:actions, a list of names; `remote-action' a function of ACTION and TEXT
returning the resulting agent buffer;
`attach' a function of a file NAME and its bytes DATA, saving them where
the agent reads them and returning the text naming that file in a prompt.")
(put 'overlook-agent-identity 'permanent-local t)

(defvar-local overlook-agent-status 'idle
  "One of `working', `waiting', `failed', `done' or `idle'.
`waiting' means the agent asked for attention; `done' that it finished
unseen.  `failed' persists until the next turn starts.")
(put 'overlook-agent-status 'permanent-local t)

(defvar-local overlook-agent-error nil
  "Error message from the agent's latest failed request, or nil.")
(put 'overlook-agent-error 'permanent-local t)

(defvar-local overlook-agent-turn nil
  "Times the agent's latest turn started and finished, as (START . END).
END is nil while the turn runs.")
(put 'overlook-agent-turn 'permanent-local t)

(defun overlook-agent-turn-open-p ()
  "Non-nil while the current agent's latest turn runs."
  (and overlook-agent-turn (null (cdr overlook-agent-turn))))

(defvar-local overlook-agent-context nil
  "Percentage of the agent's context window in use, or nil when unknown.")
(put 'overlook-agent-context 'permanent-local t)

(defvar overlook-agent-row-marks nil
  "Functions of an agent buffer returning a mark after its name, or nil.")

(defvar overlook-agent-hide-functions nil
  "Functions of a dashboard item returning non-nil to hide it.
The item is (agent . BUFFER) or (saved . SAVED); a hidden one is not
listed under any project.")

(defvar overlook-agent--last nil
  "Name of the agent most recently started or shown.")

(defvar overlook-agent-saved nil
  "Agents of an earlier Emacs not resumed yet.
Each is an alist with keys `agent', `root', `session' and `project',
and `title' and `active', the time of its last turn, when known.")

(defvar overlook-agent--saved-loaded nil
  "Non-nil once `overlook-agent-saved-file' has been read.")

(defvar overlook-agent--saved-written nil
  "The agents last written to `overlook-agent-saved-file'.")

(defvar overlook-agent-forks nil
  "Alist of each forked session id to the session id it was forked from.")

(defvar overlook-agent--forks-written nil
  "The forks last written to `overlook-agent-forks-file'.")

(defvar overlook-agent-changed-hook nil
  "Hook run by `overlook-agent-changed' when some agent's state changed.")

(defvar overlook-agent-turn-start-hook nil
  "Hook run in an agent's buffer when it starts a turn.")

(defvar overlook-agent-turn-end-hook nil
  "Hook run in an agent's buffer when it finishes a turn.")

(defvar overlook-agent-attention-hook nil
  "Hook run in an agent's buffer when it asks the user for permission or an answer.")

(defvar overlook-agent-event-functions nil
  "Functions of an agent buffer and an EVENT in it, for views following it live.
EVENT is a plist whose :type is one of
  `prompt': a prompt was submitted, :text;
  `text': the next piece of the agent's reply, :text, and :images as
    for `tool';
  `tool': a tool call started or changed, :id, :title, :status as the
    agent says it, :kind, :diffs, each (:file F :old OLD :new NEW),
    :output its text so far, and :images, each (:file F) or (:data
    BASE64 :mime TYPE);
  `end': the turn ended;
  `error': the turn failed, :text.
Frontends send them with `overlook-agent-event'.")

(defvar overlook-agent-save-functions nil
  "Functions of an agent buffer returning entries to keep in its saved alist.")

(defvar overlook-agent-resume-functions nil
  "Functions of a saved alist called before it is resumed.
One may refuse by signaling an error.")

(defvar overlook-agent-resuming nil
  "The saved alist of the agent being resumed, while it starts.")

(defvar overlook-agent-environment-functions nil
  "Functions of an agent's NAME and ROOT returning entries for its environment.
Each returns a list of \"VAR=value\" strings, gathered by
`overlook-agent-make-environment'.")

(defun overlook-agent-make-environment (name root)
  "Entries for the environment of agent NAME starting in ROOT.
A frontend calls it once per agent, before starting its process."
  (seq-mapcat (lambda (fn) (funcall fn name root)) overlook-agent-environment-functions))

(defun overlook-agent-event (type &rest properties)
  "Tell the views following the current agent buffer of event TYPE.
PROPERTIES are the event's other entries; see `overlook-agent-event-functions'."
  (run-hook-with-args 'overlook-agent-event-functions (current-buffer)
                      (cons :type (cons type properties))))

(defun overlook-agent-changed ()
  "Tell the views that some agent's state changed."
  (run-hooks 'overlook-agent-changed-hook)
  (overlook-refresh))

(defun overlook-agent-p (buffer)
  "Return non-nil when BUFFER is an agent's buffer."
  (and (buffer-live-p buffer)
       (buffer-local-value 'overlook-agent-identity buffer)
       t))

(defun overlook-agent-get (buffer key)
  "Value of KEY in agent BUFFER's `overlook-agent-identity'."
  (alist-get key (buffer-local-value 'overlook-agent-identity buffer)))

(defun overlook-agent-buffers (&optional pred)
  "Live agent buffers, restricted to those satisfying PRED when given."
  (seq-filter (lambda (buffer)
                (and (overlook-agent-p buffer)
                     (or (null pred) (funcall pred buffer))))
              (buffer-list)))

(defun overlook-agent-project-root ()
  "The current project's root, or `default-directory' outside a project."
  (if-let* ((project (project-current))) (project-root project) default-directory))

(defun overlook-agent--root ()
  "Directory agents of the current buffer run in."
  (expand-file-name (funcall overlook-agent-root-function)))

(defun overlook-agent--project-buffers (&optional name)
  "Agents of the current project, restricted to agent NAME when given."
  (let ((root (overlook-agent--root)))
    (overlook-agent-buffers
     (lambda (buffer)
       (and (equal (overlook-agent-get buffer 'root) root)
            (or (null name) (equal (overlook-agent-get buffer 'agent) name)))))))

(defun overlook-agent--current ()
  "This project's agent, preferring the last used one."
  (or (car (overlook-agent--project-buffers overlook-agent--last))
      (car (overlook-agent--project-buffers))))

(defun overlook-agent-show (buffer)
  "Select agent BUFFER in its window, or in the selected window."
  (setq overlook-agent--last (overlook-agent-get buffer 'agent))
  (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-same-window))))

(defun overlook-agent-project (buffer)
  "The project agent BUFFER is listed under, or nil.
A buffer shown in several projects belongs to the one whose root it runs at."
  (let ((root (overlook-agent-get buffer 'root)))
    (or (and root (seq-find (lambda (name)
                              (and (equal (overlook-project-root name) root)
                                   (memq buffer (overlook-project-buffers name))))
                            (overlook-projects)))
        (overlook-buffer-project buffer))))

(defun overlook-agent-visit (buffer)
  "Switch to agent BUFFER's project and show it there.
A detached agent shows in the current project."
  (unless (buffer-live-p buffer) (user-error "Agent buffer is gone"))
  (overlook-show-elsewhere (unless (buffer-local-value 'overlook-detached buffer)
                             (or (overlook-agent-project buffer)
                                 (overlook-orphan-project)))
                           (lambda () (overlook-agent-show buffer))))

;;; Status

(defun overlook-agent-glyph (buffer)
  "Status glyph of agent BUFFER, in its face from `overlook-agent-status-glyphs'."
  (let ((glyph (alist-get (buffer-local-value 'overlook-agent-status buffer)
                          overlook-agent-status-glyphs)))
    (propertize (car glyph) 'face (cadr glyph))))

(defun overlook-agent-idle-glyph ()
  "The idle glyph of `overlook-agent-status-glyphs', dimmed.
For an agent that is not running."
  (propertize (car (alist-get 'idle overlook-agent-status-glyphs)) 'face 'shadow))

(defun overlook-agent--set-status (status)
  "Set this agent's STATUS, telling the views when it changed."
  (unless (eq status overlook-agent-status)
    (setq overlook-agent-status status)
    (when (memq status '(waiting failed done))
      (overlook-agent--notify (current-buffer)))
    (overlook-agent-changed)))

(defun overlook-agent--notify-click (buffer)
  "Arguments for terminal-notifier making a click visit agent BUFFER.
Nil unless this Emacs runs a server on a local socket.  terminal-notifier
runs only one click action, so the command raises Emacs itself."
  (when-let* ((process (bound-and-true-p server-process))
              ((process-live-p process))
              (socket (process-contact process :local))
              ((stringp socket))
              (client (executable-find "emacsclient")))
    (list "-group" (concat "overlook:" (buffer-name buffer))
          "-execute" (concat "/usr/bin/open -b org.gnu.Emacs; "
                             (mapconcat #'shell-quote-argument
                                        (list client "--socket-name" socket "--eval"
                                              (format "(overlook-agent-visit (get-buffer %S))"
                                                      (buffer-name buffer)))
                                        " ")))))

(defun overlook-agent-notify-system (title body &optional buffer)
  "Show a desktop notification of TITLE and BODY about agent BUFFER.
On macOS, terminal-notifier makes clicking it raise Emacs and visit BUFFER;
without terminal-notifier it falls back to osascript."
  (cond ((and (eq system-type 'darwin) (executable-find "terminal-notifier"))
         (apply #'call-process "terminal-notifier" nil 0 nil
                "-title" title
                ;; A leading bracket would be read as an option.
                "-message" (if (string-empty-p body) " " (string-replace "[" "\\[" body))
                (or (and buffer (overlook-agent--notify-click buffer))
                    '("-activate" "org.gnu.Emacs"))))
        ((eq system-type 'darwin)
         ;; Passed as arguments, so quotes in them need no escaping.
         (call-process "osascript" nil 0 nil
                       "-e" "on run argv"
                       "-e" "display notification (item 2 of argv) with title (item 1 of argv)"
                       "-e" "end run"
                       title body))
        ((and (featurep 'dbusbind) (require 'notifications nil t))
         (notifications-notify :title title :body body))
        (t (message "%s: %s" title body))))

(defvar overlook-agent--focused-function
  (lambda () (seq-some (lambda (frame) (eq (frame-focus-state frame) t)) (frame-list)))
  "Function returning non-nil while an Emacs frame has focus.")

(defun overlook-agent--notify (buffer)
  "Notify about agent BUFFER, per `overlook-agent-notify'."
  (when (pcase overlook-agent-notify
          ('unfocused (not (funcall overlook-agent--focused-function)))
          (option option))
    (let ((project (overlook-agent-project buffer))
          (title (overlook-agent--title buffer))
          (brief (overlook-agent--brief buffer)))
      (funcall overlook-agent-notify-function
               (format "%s %s" (or (overlook-agent-get buffer 'agent) "agent")
                       (pcase (buffer-local-value 'overlook-agent-status buffer)
                         ('waiting "needs you")
                         ('failed "failed")
                         (_ "finished")))
               (string-join (delq nil (list project title brief)) ": ")
               buffer))))

(defun overlook-agent--seen-p ()
  "Non-nil when this agent is shown in the selected window of a focused Emacs."
  (and (eq (window-buffer (selected-window)) (current-buffer))
       (funcall overlook-agent--focused-function)))

(defun overlook-agent-report (event)
  "Update the current agent buffer's status for EVENT.
EVENT is `working', `finished', `failed', `attention' or `restored'.
Completion and attention depend on whether the agent is shown in the
selected window, and a turn whose reply ends with a question waits for an
answer; failure stays visible until work starts again.  `working' after a
turn ends starts another, which `overlook-agent-turn' times and
`overlook-agent-turn-start-hook' announces.  `restored' follows the replay
of a resumed session's history, which reads as work but was none."
  ;; Turns follow events, not statuses: glancing at an agent waiting for
  ;; approval resets it to idle, yet approving does not start a new turn.
  (let ((started (and (eq event 'working) (not (overlook-agent-turn-open-p)))))
    (when started
      (setq overlook-agent-turn (list (float-time)))
      (run-hooks 'overlook-agent-turn-start-hook))
    (when (and (memq event '(finished failed restored)) (overlook-agent-turn-open-p))
      (setcdr overlook-agent-turn (float-time))
      (run-hooks 'overlook-agent-turn-end-hook))
    (pcase event
      ('restored
       (setq overlook-agent-turn nil)
       (overlook-agent--set-status 'idle))
      ('finished (unless (eq overlook-agent-status 'failed)
                   (overlook-agent--set-status
                    (cond ((overlook-agent--seen-p) 'idle)
                          ((overlook-agent--reply-question (current-buffer)) 'waiting)
                          (t 'done)))))
      ('failed (overlook-agent--set-status 'failed))
      ('working
       (setq overlook-agent-error nil)
       ;; A question the last turn ended on is answered by the next one.
       (unless (and (eq overlook-agent-status 'waiting) (not started))
         (overlook-agent--set-status 'working)))
      ('attention (run-hooks 'overlook-agent-attention-hook)
                  (unless (overlook-agent--seen-p)
                    ;; Each new request notifies, even while one is still waiting.
                    (if (eq overlook-agent-status 'waiting)
                        (overlook-agent--notify (current-buffer))
                      (overlook-agent--set-status 'waiting)))))))

(defun overlook-agent--acknowledge (&rest _)
  "Reset `done' and `waiting' once the agent is shown in the selected window."
  (let ((buffer (window-buffer (selected-window))))
    (when (and (overlook-agent-p buffer)
               (funcall overlook-agent--focused-function)
               (memq (buffer-local-value 'overlook-agent-status buffer) '(done waiting)))
      (with-current-buffer buffer (overlook-agent--set-status 'idle)))))

(defun overlook-agent-seen (buffer)
  "Reset `done' in agent BUFFER, shown somewhere other than its window."
  (when (eq (buffer-local-value 'overlook-agent-status buffer) 'done)
    (with-current-buffer buffer (overlook-agent--set-status 'idle))))

(defvar overlook-agent--turn-labels nil
  "Turn durations as last drawn, to redraw when one ticks over.")

(defun overlook-agent--tick ()
  "Update each agent's context usage, and redraw when it or a duration changed.
An unknown context value keeps the last one."
  (let ((changed nil))
    (dolist (buffer (overlook-agent-buffers))
      (with-current-buffer buffer
        (let ((used (when-let* ((context (overlook-agent-get buffer 'context)))
                      (ignore-errors (funcall context)))))
          (when (and used (not (equal used overlook-agent-context)))
            (setq overlook-agent-context used changed t)))))
    (let ((labels (mapcar #'overlook-agent--turn-label (overlook-agent-buffers))))
      (unless (equal labels overlook-agent--turn-labels)
        (setq overlook-agent--turn-labels labels changed t)))
    (when changed (overlook-agent-changed))))

;;; Commands

(defun overlook-agent-register (buffer name)
  "Track BUFFER as agent NAME.  Its frontend has set its identity already."
  (with-current-buffer buffer
    (when-let* ((root (alist-get 'root overlook-agent-identity)))
      (setf (alist-get 'root overlook-agent-identity)
            (file-name-as-directory (expand-file-name root))))
    (add-hook 'kill-buffer-hook (lambda () (run-at-time 0 nil #'overlook-agent-changed)) nil t))
  (setq overlook-agent--last name)
  (overlook-agent-changed))

(defun overlook-agent--launch (name root &optional session fresh effort)
  "Start agent NAME in ROOT and return its buffer.
SESSION resumes that session; FRESH starts a new conversation without
asking.  EFFORT is its reasoning effort level, or nil for its default."
  (unless overlook-agent-start-function
    (user-error "Set `overlook-agent-start-function' first"))
  (let ((default-directory root)
        (overlook-agent-effort effort))
    (apply overlook-agent-start-function name root
           (cond (session (list nil session))
                 (fresh (list t))))))

;;; Saved agents

(defun overlook-agent--session (buffer)
  "Session id of agent BUFFER, or nil."
  (when-let* ((session (overlook-agent-get buffer 'session)))
    (with-current-buffer buffer (ignore-errors (funcall session)))))

(defun overlook-agent--to-save ()
  "Running agents with a session, then the saved ones not resumed."
  (append (delq nil (mapcar (lambda (buffer)
                              (when-let* ((session (overlook-agent--session buffer)))
                                `((agent . ,(overlook-agent-get buffer 'agent))
                                  (root . ,(overlook-agent-get buffer 'root))
                                  (session . ,session)
                                  (project . ,(overlook-agent-project buffer))
                                  (title . ,(overlook-agent--title buffer))
                                  (active . ,(when-let* ((turn (buffer-local-value
                                                                'overlook-agent-turn buffer)))
                                               (or (cdr turn) (car turn))))
                                  ,@(seq-mapcat (lambda (fn) (funcall fn buffer))
                                                overlook-agent-save-functions))))
                            (overlook-agent-buffers)))
          overlook-agent-saved))

(defun overlook-agent--forked-from (buffer)
  "Session id agent BUFFER's session was forked from, as its frontend says, or nil."
  (when-let* ((forked-from (overlook-agent-get buffer 'forked-from)))
    (with-current-buffer buffer (ignore-errors (funcall forked-from)))))

(defun overlook-agent--parent (session)
  "Session id SESSION was forked from, or nil."
  (and session (alist-get session overlook-agent-forks nil nil #'equal)))

(defun overlook-agent--note-forks ()
  "Add the forks among running agents to `overlook-agent-forks'."
  (dolist (buffer (overlook-agent-buffers))
    (let ((session (overlook-agent--session buffer))
          (parent (overlook-agent--forked-from buffer)))
      (when (and session parent (not (equal session parent))
                 (not (overlook-agent--parent session)))
        (push (cons session parent) overlook-agent-forks)))))

(defun overlook-agent--write (file data)
  "Print DATA to FILE."
  (make-directory (file-name-directory file) t)
  (let ((print-length nil)
        (print-level nil))
    (with-temp-file file
      (prin1 data (current-buffer)))))

(defun overlook-agent--read (file)
  "The data in FILE, or nil when it is missing or unreadable."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (ignore-errors (read (current-buffer))))))

(defun overlook-agent-save ()
  "Write the agents to resume later and the forks, each to its file, if changed."
  (with-demoted-errors "overlook: saving agents: %S"
    (let ((agents (overlook-agent--to-save)))
      (unless (equal agents overlook-agent--saved-written)
        (overlook-agent--write overlook-agent-saved-file agents)
        (setq overlook-agent--saved-written agents)))
    (overlook-agent--note-forks)
    (unless (equal overlook-agent-forks overlook-agent--forks-written)
      (overlook-agent--write overlook-agent-forks-file overlook-agent-forks)
      (setq overlook-agent--forks-written overlook-agent-forks))))

(defun overlook-agent--load-saved ()
  "Read the saved agents and the forks once, skipping sessions already running."
  (unless overlook-agent--saved-loaded
    (setq overlook-agent--saved-loaded t)
    (let ((running (mapcar #'overlook-agent--session (overlook-agent-buffers)))
          (agents (overlook-agent--read overlook-agent-saved-file))
          (forks (seq-filter (lambda (fork) (and (stringp (car-safe fork)) (stringp (cdr fork))))
                             (overlook-agent--read overlook-agent-forks-file))))
      (setq overlook-agent-saved
            (seq-remove (lambda (saved) (member (alist-get 'session saved) running))
                        (seq-filter #'consp agents))
            overlook-agent--saved-written agents
            overlook-agent-forks (append overlook-agent-forks forks)
            overlook-agent--forks-written forks))))

(defun overlook-agent--resume (saved)
  "Resume SAVED agent from `overlook-agent-saved' and return its buffer."
  (run-hook-with-args 'overlook-agent-resume-functions saved)
  (setq overlook-agent-saved (delq saved overlook-agent-saved))
  (let ((root (alist-get 'root saved)))
    (unless (file-directory-p root)
      (overlook-agent-changed)
      (user-error "%s is gone; forgot its agent" root))
    (let ((overlook-agent-resuming saved))
      (overlook-agent--launch (alist-get 'agent saved) root (alist-get 'session saved)))))

(defun overlook-agent--saved-project (saved)
  "The project SAVED agent was in, when it still exists."
  (car (member (alist-get 'project saved) (overlook-projects))))

(defun overlook-agent-resume-visit (saved)
  "Resume SAVED agent in its project and show it there."
  (overlook-show-elsewhere (or (overlook-agent--saved-project saved)
                               (overlook-orphan-project))
                           (lambda () (overlook-agent-show (overlook-agent--resume saved)))))

(defun overlook-agent-resume (saved)
  "Resume SAVED agent in its project, without showing it; return its buffer."
  (let ((project (or (overlook-agent--saved-project saved)
                         (overlook-orphan-project)
                         (overlook-current-project)))
        (buffer (overlook-agent--resume saved)))
    (when project (overlook-add-to-project project buffer))
    buffer))

(defun overlook-agent-forget (saved)
  "Forget SAVED agent."
  (setq overlook-agent-saved (delq saved overlook-agent-saved))
  (overlook-agent-changed))

(defun overlook-agent-forget-project (name)
  "Forget the saved agents of project NAME."
  (setq overlook-agent-saved
        (seq-remove (lambda (saved) (equal (alist-get 'project saved) name))
                    overlook-agent-saved))
  (overlook-agent-changed))

(defun overlook-agent-kill (buffer)
  "Stop agent BUFFER and kill it, so it is not saved to resume either."
  (let ((kill-buffer-query-functions nil))
    (kill-buffer buffer)))

(defun overlook-agent--kill-question (buffer)
  "The question confirming that agent BUFFER is to be killed."
  (format "Kill agent %s%s? " (buffer-name buffer)
          (if (eq (buffer-local-value 'overlook-agent-status buffer) 'working)
              ", still working" "")))

(defun overlook-agent--delete (item)
  "Kill the agent ITEM stands for, once confirmed, or forget the saved one."
  (pcase item
    (`(agent . ,buffer)
     (when (yes-or-no-p (overlook-agent--kill-question buffer))
       (overlook-agent-kill buffer))
     t)
    (`(saved . ,saved) (overlook-agent-forget saved) t)))

(defun overlook-agent--in-folder (dir)
  "The agents working in folder DIR, as `overlook-folder-contents-functions' wants."
  (let ((in (lambda (root) (and root (file-in-directory-p root dir)))))
    (append (mapcar (lambda (buffer)
                      (cons (format "agent %s" (buffer-name buffer))
                            (lambda () (overlook-agent-kill buffer))))
                    (overlook-agent-buffers
                     (lambda (buffer) (funcall in (overlook-agent-get buffer 'root)))))
            (mapcar (lambda (saved)
                      (cons (format "saved agent %s" (or (alist-get 'title saved)
                                                         (alist-get 'agent saved)))
                            (lambda () (overlook-agent-forget saved))))
                    (seq-filter (lambda (saved) (funcall in (alist-get 'root saved)))
                                overlook-agent-saved)))))

(defun overlook-agent--annotate (name)
  "Status and project of the agent buffer NAME, for completion."
  (let ((buffer (get-buffer name)))
    (concat "  " (overlook-agent-glyph buffer) " "
            (symbol-name (buffer-local-value 'overlook-agent-status buffer))
            (if-let* ((project (overlook-agent-project buffer)))
                (propertize (concat "  " project) 'face 'shadow)
              ""))))

;;;###autoload
(defun overlook-agent-switch ()
  "Pick any running agent and show it in its project."
  (interactive)
  (let* ((names (or (mapcar #'buffer-name (overlook-agent-buffers))
                    (user-error "No agent running")))
         (name (completing-read
                "Agent: "
                (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (category . buffer)
                                 (annotation-function . overlook-agent--annotate))
                    (complete-with-action action names string pred)))
                nil t)))
    (overlook-agent-visit (get-buffer name))))

(defun overlook-agent-reference (path beg end)
  "The current buffer from BEG to END quoted as lines of PATH, for an agent."
  (format "%s:%d-%d\n```\n%s\n```\n" path
          (line-number-at-pos beg) (line-number-at-pos (max beg (1- end)))
          (buffer-substring-no-properties beg end)))

;;;###autoload
(defun overlook-agent-send (&optional beg end)
  "Paste the region, or an @ reference to the file, into this project's agent.
Interactively BEG and END are the region, when active."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (let* ((file (buffer-file-name (buffer-base-buffer)))
         (path (if file (file-relative-name file (overlook-agent--root)) (buffer-name)))
         (text (if beg
                   (overlook-agent-reference path beg end)
                 (if file (format "@%s " path) (user-error "Buffer has no file"))))
         (buffer (or (overlook-agent--current)
                     (user-error "No agent running in this project"))))
    (deactivate-mark)
    (with-current-buffer buffer
      (funcall (or (overlook-agent-get buffer 'insert)
                   (user-error "%s cannot receive text" (buffer-name)))
               text))
    (overlook-agent-show buffer)))

(defun overlook-agent-draft-command (project)
  "Return a function making commands that draft a prompt for an agent of PROJECT.
The function takes a function of the agent's root giving the prompt, and
makes a command offering PROJECT's agents and starting a new one, or
nil when there is neither.  The prompt is left unsent, as \\[overlook-agent-send] does."
  (let* ((agents (mapcar #'buffer-name
                         (overlook-agent-buffers
                          (lambda (buffer) (equal (overlook-agent-project buffer) project)))))
         (start (seq-find (lambda (command) (equal (plist-get command :name) "new-agent"))
                          (seq-mapcat (lambda (function) (funcall function project))
                                      overlook-project-command-functions)))
         (new (mapcar (lambda (engine) (concat "New " engine)) (plist-get start :options)))
         (options (append agents new)))
    (lambda (prompt)
      (when options
        (list :name "draft" :label "Agent" :options options
              :run (lambda (option)
                     (let ((buffer (if (member option agents)
                                       (or (get-buffer option)
                                           (user-error "%s is gone" option))
                                     (funcall (plist-get start :run)
                                              (string-remove-prefix "New " option)))))
                       (cons buffer (funcall prompt (overlook-agent-get buffer 'root))))))))))

;;; Choices

(defun overlook-agent--choices (buffer)
  "The answers agent BUFFER offers you now, as its frontend says."
  (when-let* ((choices (overlook-agent-get buffer 'choices)))
    (with-current-buffer buffer (ignore-errors (funcall choices)))))

(defun overlook-agent-choose (buffer key)
  "Give agent BUFFER the answer it offers under KEY.
Looked up afresh, so an answer given elsewhere meanwhile is not given twice."
  (let ((choice (or (assoc key (overlook-agent--choices buffer))
                    (user-error "%s no longer asks that" (buffer-name buffer)))))
    (with-current-buffer buffer
      (funcall (nth 2 choice))
      ;; Answering here is attending to it, as looking at it would be.
      (when (and (eq overlook-agent-status 'waiting)
                 (not (overlook-agent--choices buffer)))
        (overlook-agent--set-status 'working)))
    (overlook-agent-changed)))

(defun overlook-agent--wrap-prefix (depth)
  "What starts an agent row's continuation lines, DEPTH forks deep."
  (concat overlook-agent--wrap-indent (make-string (* 2 depth) ?\s)))

;;; Rows

(defun overlook-agent--context-label (buffer)
  "Context usage of agent BUFFER, or nil."
  (when-let* ((used (buffer-local-value 'overlook-agent-context buffer)))
    (propertize (format "%3d%%" used)
                'face (if (>= used overlook-agent-context-warning) 'warning 'shadow))))

(defun overlook-agent--turn-label (buffer)
  "How long agent BUFFER's latest turn has run, or ran, once past a minute; or nil."
  (pcase (buffer-local-value 'overlook-agent-turn buffer)
    (`(,start . ,end)
     (let ((seconds (- (or end (float-time)) start)))
       (when (>= seconds 60)
         (propertize (overlook-format-duration seconds) 'face 'shadow))))))

(defun overlook-agent--meta (buffer)
  "Turn duration and context usage of agent BUFFER, aligned to the right edge.
Returns (SEGMENTS . COLUMNS), COLUMNS being how far from the edge they start.
Context takes the last four columns but one, left free for the wrap mark;
the duration ends a column before it, so both line up across agents."
  (let ((turn (overlook-agent--turn-label buffer))
        (context (overlook-agent--context-label buffer)))
    (cons (list (and turn (overlook-align-right turn 6))
                (and context (overlook-align-right context 1)))
          (cond (turn (+ 6 (string-width turn)))
                (context 5)
                (t 0)))))

(define-obsolete-function-alias 'overlook-agent-label #'overlook-icon "0.2.0")

(defun overlook-agent-status-face (status)
  "Face of agent STATUS from `overlook-agent-status-glyphs', bold when waiting."
  (let ((face (cadr (alist-get status overlook-agent-status-glyphs))))
    (if (eq status 'waiting) (list 'bold face) face)))

(defun overlook-agent--name-label (buffer)
  "Agent BUFFER's icon from `overlook-agent-icons', else its name.
It is drawn in the face of the agent's status, which it stands for."
  (overlook-icon (propertize (or (overlook-agent-get buffer 'agent) "agent")
                             'face (overlook-agent-status-face
                                    (buffer-local-value 'overlook-agent-status buffer)))))

(defun overlook-agent--failed-label (status)
  "A mark naming a failed STATUS, which shares its color with waiting."
  (if (eq status 'failed) (propertize " failed" 'face 'error) ""))

(defun overlook-agent--title (buffer)
  "Agent BUFFER's session title, as its frontend says, on one line, or nil."
  (when-let* ((title (overlook-agent-get buffer 'title))
              (text (with-current-buffer buffer (ignore-errors (funcall title))))
              (text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
              ((not (string-empty-p text))))
    text))

(defun overlook-agent--title-label (title)
  "TITLE cut to `overlook-agent-title-width', or an empty string."
  (if title
      (concat " " (overlook-truncate title overlook-agent-title-width))
    ""))

(defun overlook-agent--project-label (root project)
  "Name of the project at ROOT, dimmed, unless it is PROJECT's."
  (if (and root (not (equal (and project (overlook-project-root project))
                            root)))
      (propertize (concat " " (file-name-nondirectory (directory-file-name root)))
                  'face 'shadow)
    ""))

(defun overlook-agent--reply (buffer)
  "Agent BUFFER's last reply, as its frontend says, or nil."
  (when-let* ((reply (overlook-agent-get buffer 'reply)))
    (with-current-buffer buffer (ignore-errors (funcall reply)))))

(defun overlook-agent--plain (line)
  "LINE of markdown without its markup, trimmed."
  (thread-last line
               (replace-regexp-in-string "\\`[ \t]*\\(?:#+\\|>\\|[-*+]\\|[0-9]+[.)]\\)[ \t]+" "")
               (replace-regexp-in-string "\\[\\([^]\n]*\\)\\]([^)\n]*)" "\\1")
               (replace-regexp-in-string "\\*\\*\\|__\\|`" "")
               (string-trim)))

(defun overlook-agent--plain-lines (text)
  "The lines of markdown TEXT that are prose, without their markup.
Blank lines, code blocks, tables and rules are left out."
  (let (lines fenced)
    (dolist (line (split-string (or text "") "\n"))
      (cond ((string-match-p "\\`[ \t]*\\(?:```\\|~~~\\)" line) (setq fenced (not fenced)))
            ((or fenced (string-match-p "\\`[ \t]*\\(?:|\\|[-*_=]+[ \t]*\\'\\)" line)))
            (t (let ((plain (overlook-agent--plain line)))
                 (unless (string-empty-p plain) (push plain lines))))))
    (nreverse lines)))

(defun overlook-agent--reply-question (buffer)
  "The question agent BUFFER's last reply ends with, or nil."
  (when-let* ((line (car (last (overlook-agent--plain-lines (overlook-agent--reply buffer)))))
              ((string-match "[^.!?。！？:：]*[?？]\\'" line)))
    (string-trim (match-string 0 line))))

(defun overlook-agent--reply-brief (buffer)
  "What agent BUFFER's last reply comes to, on one line, or nil.
The question it ends with after a `? ', else its first line."
  (if-let* ((question (overlook-agent--reply-question buffer)))
      (concat "? " question)
    (car (overlook-agent--plain-lines (overlook-agent--reply buffer)))))

(defun overlook-agent--brief (buffer)
  "Return what agent BUFFER is doing, on one line, or nil.
Once its turn has ended, what its last reply comes to."
  (when-let* ((text (or (buffer-local-value 'overlook-agent-error buffer)
                       (and (cdr (buffer-local-value 'overlook-agent-turn buffer))
                            (overlook-agent--reply-brief buffer))
                       (when-let* ((brief (overlook-agent-get buffer 'brief)))
                         (with-current-buffer buffer (ignore-errors (funcall brief))))))
              (text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
              ((not (string-empty-p text))))
    text))

(defun overlook-agent--brief-segment (buffer brief meta)
  "BRIEF, a segment fit to the dashboard before META columns at the right.
Highlighted while agent BUFFER waits, set apart from its name while it
works, dimmed otherwise."
  (list :fit brief
        :face (pcase (buffer-local-value 'overlook-agent-status buffer)
                ('waiting 'warning)
                ('failed 'error)
                ('working 'font-lock-doc-face)
                (_ 'shadow))
        :before "  "
        :reserve (1+ meta)))

(defun overlook-agent--tree-prefix (depth)
  "What starts a row DEPTH forks below a row listed under a project."
  (if (> depth 0)
      (concat (make-string (* 2 (1- depth)) ?\s) (propertize "└ " 'face 'shadow))
    ""))

(defun overlook-agent--fork-label (session depth)
  "A dimmed mark for a fork SESSION listed apart from its parent, at DEPTH 0."
  (if (and (= depth 0) (overlook-agent--parent session))
      (propertize " fork" 'face 'shadow)
    ""))

(defun overlook-agent--fork-echo (session)
  "Help text naming the session SESSION was forked from, or an empty string."
  (if-let* ((parent (overlook-agent--parent session)))
      (concat "\nForked from " parent)
    ""))

(defun overlook-agent--row (buffer project &optional depth children)
  "The row of agent BUFFER under PROJECT, DEPTH forks deep.
CHILDREN are the rows of its forks.  What it is doing shows unless it
is idle with no question for you; the answers it offers you sit on a
line of their own under it."
  (let* ((depth (or depth 0))
         (session (overlook-agent--session buffer))
         (title (overlook-agent--title buffer))
         (meta (overlook-agent--meta buffer))
         (brief (overlook-agent--brief buffer))
         (status (buffer-local-value 'overlook-agent-status buffer)))
    (overlook-row
     :id (cons 'agent buffer)
     :content (list (overlook-agent--tree-prefix depth)
                    (overlook-agent--name-label buffer)
                    (overlook-agent--failed-label status)
                    (string-join (delq nil (mapcar (lambda (fn) (funcall fn buffer))
                                                   overlook-agent-row-marks)))
                    (overlook-agent--title-label title)
                    (overlook-agent--fork-label session depth)
                    (overlook-agent--project-label (overlook-agent-get buffer 'root) project)
                    (and brief (or (not (eq status 'idle))
                                   (overlook-agent--reply-question buffer))
                         (overlook-agent--brief-segment buffer brief (cdr meta)))
                    (car meta))
     :attention (and (memq status '(waiting failed done)) t)
     :face (pcase status
             ((or 'waiting 'failed) 'overlook-agent-waiting)
             ('done 'overlook-agent-done))
     :action (lambda () (overlook-agent-visit buffer))
     :help (concat (buffer-name buffer)
                   (if title (concat "\n" title) "")
                   (if brief (concat "\n" brief) "")
                   (overlook-agent--fork-echo session))
     :wrap (overlook-agent--wrap-prefix depth)
     :choices (overlook-agent--choices buffer)
     :choose (lambda (key) (overlook-agent-choose buffer key))
     :commands (list (list :name "kill" :label "Kill"
                           :confirm (lambda () (overlook-agent--kill-question buffer))
                           :run (lambda () (overlook-agent-kill buffer))))
     :children children)))

(defun overlook-agent--saved-row (saved project &optional depth children)
  "The row of SAVED agent, dimmed, under PROJECT, DEPTH forks deep.
It shows the agent's title and how long ago its last turn was.
CHILDREN are the rows of its forks."
  (let ((depth (or depth 0))
        (session (alist-get 'session saved))
        (title (alist-get 'title saved))
        (active (alist-get 'active saved)))
    (overlook-row
     :id (cons 'saved saved)
     :content (list (overlook-agent--tree-prefix depth)
                    (overlook-icon (propertize (alist-get 'agent saved) 'face 'shadow))
                    (propertize (concat " saved" (overlook-agent--title-label title))
                                'face 'shadow)
                    (overlook-agent--fork-label session depth)
                    (overlook-agent--project-label (alist-get 'root saved) project)
                    (and active
                         (overlook-align-right
                          (propertize (overlook-format-duration (- (float-time) active))
                                      'face 'shadow)
                          6)))
     :action (lambda () (overlook-agent-resume-visit saved))
     :help (concat "Resume session " session
                   (if title (concat "\n" title) "")
                   (overlook-agent--fork-echo session))
     :wrap (overlook-agent--wrap-prefix depth)
     :commands (list (list :name "resume" :label "Resume"
                           :run (lambda () (overlook-agent-resume saved)))
                     (list :name "forget" :label "Forget"
                           :confirm (format "Forget saved agent %s%s? " (alist-get 'agent saved)
                                            (overlook-agent--title-label title))
                           :run (lambda () (overlook-agent-forget saved))))
     :children children)))

(defun overlook-agent--item-session (item)
  "Session id of ITEM, an (agent . BUFFER) or (saved . SAVED), or nil."
  (pcase item
    (`(agent . ,buffer) (overlook-agent--session buffer))
    (`(saved . ,saved) (alist-get 'session saved))))

(defun overlook-agent--tree (item items project depth drawn)
  "The row of ITEM under PROJECT, DEPTH forks deep, over its forks among ITEMS.
DRAWN, a list in a cons, collects the items given rows, so none is twice."
  (setcar drawn (cons item (car drawn)))
  (let* ((session (overlook-agent--item-session item))
         (forks (and session
                     (seq-filter (lambda (other)
                                   (and (not (memq other (car drawn)))
                                        (equal (overlook-agent--parent
                                                (overlook-agent--item-session other))
                                               session)))
                                 items)))
         (children (seq-keep (lambda (fork)
                               (unless (memq fork (car drawn))
                                 (overlook-agent--tree fork items project (1+ depth) drawn)))
                             forks)))
    (pcase item
      (`(agent . ,buffer) (overlook-agent--row buffer project depth children))
      (`(saved . ,saved) (overlook-agent--saved-row saved project depth children)))))

(defun overlook-agent--item-root (item)
  "Folder ITEM, an (agent . BUFFER) or (saved . SAVED), works in."
  (pcase item
    (`(agent . ,buffer) (overlook-agent-get buffer 'root))
    (`(saved . ,saved) (alist-get 'root saved))))

(defun overlook-agent--rows (project &optional dir)
  "Rows of the agents listed under PROJECT, then of those saved there.
Forks sit under the agent they were forked from when it is listed there
too.  Under `overlook-orphans-project', those in none follow.  With
DIR, a worktree, only those working in it; else those in none of
PROJECT's worktrees."
  (overlook-agent--note-forks)
  (let* ((projects (if (equal project (overlook-orphans-project))
                           (list project nil)
                         (list project)))
         (worktrees (if dir (list dir) (overlook-worktrees project)))
         (items (seq-filter
                 (lambda (item)
                   (and (equal (overlook-worktree-of (overlook-agent--item-root item) worktrees)
                               dir)
                        (not (run-hook-with-args-until-success 'overlook-agent-hide-functions item))))
                 (append (mapcar (lambda (buffer) (cons 'agent buffer))
                                 (overlook-agent-buffers
                                  (lambda (buffer)
                                    (member (overlook-agent-project buffer) projects))))
                         (mapcar (lambda (saved) (cons 'saved saved))
                                 (seq-filter (lambda (saved)
                                               (member (overlook-agent--saved-project saved)
                                                       projects))
                                             overlook-agent-saved)))))
         (sessions (delq nil (mapcar #'overlook-agent--item-session items)))
         (drawn (list nil))
         (rows (seq-keep (lambda (item)
                           (unless (or (memq item (car drawn))
                                       (member (overlook-agent--parent
                                                (overlook-agent--item-session item))
                                               sessions))
                             (overlook-agent--tree item items project 0 drawn)))
                         items)))
    (append rows
            ;; Left over only when the forks recorded form a loop.
            (seq-keep (lambda (item)
                        (unless (memq item (car drawn))
                          (overlook-agent--tree item items project 0 drawn)))
                      items))))

(defun overlook-agent--mode-line ()
  "A count of agents by state, like \"3 agents · 1 working\"."
  (let* ((statuses (mapcar (lambda (buffer) (buffer-local-value 'overlook-agent-status buffer))
                           (overlook-agent-buffers)))
         (working (seq-count (lambda (status) (eq status 'working)) statuses))
         (attention (seq-count (lambda (status) (memq status '(waiting failed done))) statuses)))
    (when statuses
      (string-join
       (delq nil (list (format "%d agent%s" (length statuses) (if (cdr statuses) "s" ""))
                       (and (> working 0) (format "%d working" working))
                       (and (> attention 0)
                            (propertize (format "%d need you" attention) 'face 'error))))
       " · "))))

;;; Dashboard commands

(defun overlook-agent-at-point ()
  "The agent of the dashboard row at point, or nil."
  (pcase (overlook-item-at-point)
    (`(agent . ,buffer) buffer)))

;;;###autoload
(define-minor-mode overlook-agent-mode
  "Track agents and list them on the dashboard."
  :global t
  :group 'overlook
  (when overlook-agent-mode (overlook-agent--load-saved))
  (if overlook-agent-mode
      (add-function :after after-focus-change-function #'overlook-agent--acknowledge)
    (remove-function after-focus-change-function #'overlook-agent--acknowledge))
  (overlook-toggle-hooks
   overlook-agent-mode
   '((overlook-worktree-functions overlook-agent--rows)
     (overlook-delete-functions overlook-agent--delete)
     (overlook-folder-contents-functions overlook-agent--in-folder)
     (overlook-mode-line-functions overlook-agent--mode-line)
     (overlook-tick-hook overlook-agent--tick)
     (window-selection-change-functions overlook-agent--acknowledge)
     (window-buffer-change-functions overlook-agent--acknowledge)
     (overlook-agent-changed-hook overlook-agent-save)
     (kill-emacs-hook overlook-agent-save)))
  (overlook-refresh))


(provide 'overlook-agent)
;;; overlook-agent.el ends here
