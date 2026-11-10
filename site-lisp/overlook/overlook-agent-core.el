;;; overlook-agent-core.el --- Agent state and frontend capabilities -*- lexical-binding: t; -*-

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

;; Owns agent identity, project association, status and turn lifecycle.
;; Frontends report here; persistence and dashboard rows are separate layers.

;;; Code:

(require 'overlook-model)
(require 'overlook-markers)
(require 'project)

(declare-function notifications-notify "notifications" (&rest params))

(declare-function overlook-agent-at-point "overlook-agent" ())
(declare-function overlook-main-window "overlook" ())
(declare-function overlook-show-elsewhere "overlook" (project show))

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
`persona' the name of the persona it runs without an agent program, or nil;
`remote-controls' a function returning a plist of :slash, a list of
\(:name N :description D), :steer, non-nil when it can be steered, and
:actions, a list of names; `remote-action' a function of ACTION and TEXT
returning the resulting agent buffer;
`attach' a function of a file NAME and its bytes DATA, saving them where
the agent reads them and returning the text naming that file in a prompt.")

(defvar-local overlook-agent-status 'idle
  "One of `working', `waiting', `failed', `done' or `idle'.
`waiting' means the agent asked for attention; `done' that it finished
unseen.  `failed' persists until the next turn starts.")

(defvar-local overlook-agent-error nil
  "Error message from the agent's latest failed request, or nil.")

(defvar-local overlook-agent-turn nil
  "Times the agent's latest turn started and finished, as (START . END).
END is nil while the turn runs.")

(defun overlook-agent-turn-open-p ()
  "Non-nil while the current agent's latest turn runs."
  (and overlook-agent-turn (null (cdr overlook-agent-turn))))

(defvar-local overlook-agent-context nil
  "Percentage of the agent's context window in use, or nil when unknown.")

(defvar overlook-agent--last nil
  "Name of the agent most recently started or shown.")

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

(defun overlook-agent-call (buffer key &rest args)
  "Call agent BUFFER's capability KEY with ARGS in its buffer.
Return nil when the frontend supplies no such capability.  Errors from
an existing capability propagate to the caller."
  (when-let* ((function (overlook-agent-get buffer key)))
    (with-current-buffer buffer (apply function args))))

(defun overlook-agent-ready-p (buffer)
  "Non-nil when agent BUFFER can take a prompt now.
Use its frontend's readiness check when supplied, else its status."
  (with-current-buffer buffer
    (if (overlook-agent-get buffer 'ready)
        (overlook-agent-call buffer 'ready)
      (not (memq overlook-agent-status '(working waiting))))))

(defun overlook-agent-submit (buffer text)
  "Submit TEXT to agent BUFFER through its frontend.
The caller decides when to submit and whether to queue busy agents."
  (unless (overlook-agent-get buffer 'submit)
    (user-error "%s cannot take a prompt" (buffer-name buffer)))
  (overlook-agent-call buffer 'submit text))

(defun overlook-agent-buffers (&optional pred)
  "Live agent buffers, restricted to those satisfying PRED when given."
  (let* ((collect (lambda () (seq-filter #'overlook-agent-p (buffer-list))))
         (buffers (if overlook-model-cache
                      (car (with-memoization
                               (gethash 'overlook-agent-buffers overlook-model-cache)
                             (list (funcall collect))))
                    (funcall collect))))
    (seq-filter (lambda (buffer)
                  (and (buffer-live-p buffer)
                       (or (null pred) (funcall pred buffer))))
                buffers)))

(defun overlook-agent-project-root ()
  "The current project's root, or `default-directory' outside a project."
  (if-let* ((project (project-current))) (project-root project) default-directory))

(defun overlook-agent-resolve-root ()
  "Directory agents of the current buffer run in."
  (expand-file-name (funcall overlook-agent-root-function)))

(defun overlook-agent--project-buffers (&optional name)
  "Agents of the current project, restricted to agent NAME when given."
  (let ((root (overlook-agent-resolve-root)))
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

(defvar overlook-agent-starting-project nil
  "Project the agent being started belongs to.
Nil works it out from the agent's root; `none' puts it in no project.")

(defun overlook-agent-project-holding (directory)
  "The open project whose root holds DIRECTORY most closely, or nil."
  (let ((directory (file-name-as-directory (file-truename directory)))
        (best nil)
        (length 0))
    (dolist (name (overlook-projects))
      (when-let* ((root (overlook-project-root name))
                  (root (file-name-as-directory (file-truename root)))
                  ((string-prefix-p root directory))
                  ((> (length root) length)))
        (setq best name length (length root))))
    best))

(defun overlook-agent-marked-project (directory)
  "Project named after the marked folder holding DIRECTORY, opened if missing.
Nil when no folder marked by `overlook-markers' holds DIRECTORY."
  (when-let* ((project (overlook-markers-try directory))
              (name (file-name-nondirectory (directory-file-name (cdr project)))))
    (overlook-ensure-project name)
    (car (member name (overlook-projects)))))

(defun overlook-agent-project-at (directory)
  "The project an agent working in DIRECTORY belongs to, or nil.
That is the open project whose root holds it, else the project of the
marked folder holding it, opened in the background."
  (and directory
       (or (overlook-agent-project-holding directory)
           (overlook-agent-marked-project directory))))

(defun overlook-agent-project (buffer)
  "The project agent BUFFER belongs to, while it is open; nil when detached."
  (unless (buffer-local-value 'overlook-detached buffer)
    (car (member (overlook-agent-get buffer 'project) (overlook-projects)))))

(defun overlook-agent-set-project (buffer project)
  "Make agent BUFFER belong to PROJECT."
  (with-current-buffer buffer
    (setf (alist-get 'project overlook-agent-identity) project))
  (when project (overlook-add-to-project project buffer))
  (overlook-agent-changed))

(defun overlook-agent-move (buffer project)
  "Move agent BUFFER to PROJECT.
Interactively, the agent at point or the current buffer's, to a project read."
  (interactive
   (let ((buffer (or (overlook-agent-at-point)
                     (and (overlook-agent-p (current-buffer)) (current-buffer))
                     (user-error "No agent here"))))
     (list buffer (completing-read (format "Move %s to project: " (buffer-name buffer))
                                   (overlook-projects) nil t))))
  (overlook-agent-set-project buffer project))

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
          (title (overlook-agent-title buffer))
          (brief (overlook-agent-brief buffer)))
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
                          ((overlook-agent-reply-question (current-buffer)) 'waiting)
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
    (let ((labels (mapcar #'overlook-agent-turn-label (overlook-agent-buffers))))
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
    (unless (assq 'project overlook-agent-identity)
      (setf (alist-get 'project overlook-agent-identity)
            (pcase overlook-agent-starting-project
              ('none nil)
              ('nil (or (overlook-agent-project-at (alist-get 'root overlook-agent-identity))
                        (overlook-current-project)))
              (project project))))
    (when-let* ((project (alist-get 'project overlook-agent-identity)))
      (overlook-add-to-project project buffer))
    (add-hook 'kill-buffer-hook (lambda () (run-at-time 0 nil #'overlook-agent-changed)) nil t))
  (setq overlook-agent--last name)
  (overlook-agent-changed))

(defun overlook-agent-start (name root &optional session fresh effort)
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

;;; Session identity

(defun overlook-agent-session (buffer)
  "Session id of agent BUFFER, or nil."
  (ignore-errors (overlook-agent-call buffer 'session)))

(defun overlook-agent-kill (buffer)
  "Stop agent BUFFER and kill it, so it is not saved to resume either."
  (let ((kill-buffer-query-functions nil))
    (kill-buffer buffer)))

(defun overlook-agent-kill-question (buffer)
  "The question confirming that agent BUFFER is to be killed."
  (format "Kill agent %s%s? " (buffer-name buffer)
          (if (eq (buffer-local-value 'overlook-agent-status buffer) 'working)
              ", still working" "")))

;;; Choices

(defun overlook-agent-choices (buffer)
  "The answers agent BUFFER offers you now, as its frontend says."
  (ignore-errors (overlook-agent-call buffer 'choices)))

(defun overlook-agent-choose (buffer key)
  "Give agent BUFFER the answer it offers under KEY.
Looked up afresh, so an answer given elsewhere meanwhile is not given twice."
  (let ((choice (or (assoc key (overlook-agent-choices buffer))
                    (user-error "%s no longer asks that" (buffer-name buffer)))))
    (with-current-buffer buffer
      (funcall (nth 2 choice))
      ;; Answering here is attending to it, as looking at it would be.
      (when (and (eq overlook-agent-status 'waiting)
                 (not (overlook-agent-choices buffer)))
        (overlook-agent--set-status 'working)))
    (overlook-agent-changed)))

(defun overlook-agent-turn-label (buffer)
  "How long agent BUFFER's latest turn has run, or ran, once past a minute; or nil."
  (pcase (buffer-local-value 'overlook-agent-turn buffer)
    (`(,start . ,end)
     (let ((seconds (- (or end (float-time)) start)))
       (when (>= seconds 60)
         (propertize (overlook-format-duration seconds) 'face 'shadow))))))

(defun overlook-agent-status-face (status)
  "Face of agent STATUS from `overlook-agent-status-glyphs', bold when waiting."
  (let ((face (cadr (alist-get status overlook-agent-status-glyphs))))
    (if (eq status 'waiting) (list 'bold face) face)))

(defun overlook-agent-title (buffer)
  "Agent BUFFER's session title, as its frontend says, on one line, or nil."
  (when-let* ((text (ignore-errors (overlook-agent-call buffer 'title)))
              (text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
              ((not (string-empty-p text))))
    text))

(defun overlook-agent-reply (buffer)
  "Agent BUFFER's last reply, as its frontend says, or nil."
  (ignore-errors (overlook-agent-call buffer 'reply)))

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

(defun overlook-agent-reply-question (buffer)
  "The question agent BUFFER's last reply ends with, or nil."
  (when-let* ((line (car (last (overlook-agent--plain-lines (overlook-agent-reply buffer)))))
              ((string-match "[^.!?。！？:：]*[?？]\\'" line)))
    (string-trim (match-string 0 line))))

(defun overlook-agent--reply-brief (buffer)
  "What agent BUFFER's last reply comes to, on one line, or nil.
The question it ends with after a `? ', else its first line."
  (if-let* ((question (overlook-agent-reply-question buffer)))
      (concat "? " question)
    (car (overlook-agent--plain-lines (overlook-agent-reply buffer)))))

(defun overlook-agent-brief (buffer)
  "Return what agent BUFFER is doing, on one line, or nil.
Once its turn has ended, what its last reply comes to."
  (when-let* ((text (or (buffer-local-value 'overlook-agent-error buffer)
                       (and (cdr (buffer-local-value 'overlook-agent-turn buffer))
                            (overlook-agent--reply-brief buffer))
                       (ignore-errors (overlook-agent-call buffer 'brief))))
              (text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
              ((not (string-empty-p text))))
    text))

(put 'overlook-agent-identity 'permanent-local t)

(put 'overlook-agent-status 'permanent-local t)

(put 'overlook-agent-error 'permanent-local t)

(put 'overlook-agent-turn 'permanent-local t)

(put 'overlook-agent-context 'permanent-local t)

(provide 'overlook-agent-core)
;;; overlook-agent-core.el ends here
