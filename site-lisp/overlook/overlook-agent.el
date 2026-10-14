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
;; agent-shell) and lists each under the perspective holding its buffer:
;; its status, how long its turn has run, its context usage and what it
;; is doing.
;;
;; Agents are started with the frontend's own commands.  The frontend
;; describes each agent buffer it sees in `overlook-agent-identity', hands
;; it to `overlook-agent-register', and reports through
;; `overlook-agent-report'.  `overlook-agent-start-function' starts agents
;; for overlook itself: to resume a saved one, or for courier to spawn.

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

(defcustom overlook-agent-saved-file (locate-user-emacs-file "overlook-agents.eld")
  "File keeping the agents to offer for resuming after a restart."
  :type 'file
  :group 'overlook)

(defcustom overlook-agent-status-glyphs
  '((working "◐" warning)
    (waiting "⚠" error)
    (done "●" success)
    (idle "○" shadow))
  "Glyph and face for each `overlook-agent-status'."
  :type '(alist :key-type symbol :value-type (list string face))
  :group 'overlook)

(defcustom overlook-agent-context-warning 70
  "Context usage percentage from which an agent's is highlighted."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-agent-notify 'unfocused
  "When to notify that an agent waits for you or finished unseen.
`unfocused' notifies while no Emacs frame has focus, t always, nil never."
  :type '(choice (const :tag "While Emacs is unfocused" unfocused)
                 (const :tag "Always" t)
                 (const :tag "Never" nil))
  :group 'overlook)

(defcustom overlook-agent-notify-function #'overlook-agent-notify-system
  "Function of TITLE and BODY showing a notification."
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

(defconst overlook-agent--wrap-indent "      "
  "Indent of an agent row's continuation lines, lining up with its name.")

;;; State

(defvar-local overlook-agent-identity nil
  "Alist describing the agent in this buffer, set by its frontend.
Keys: `agent' its name; `root' its directory; `insert' a function
inserting a string into its input; `context' a function returning its
context usage percentage or nil; `brief' a function returning a line on
what it is doing, or nil; `session' a function returning its session id,
or nil; `submit' a function submitting a prompt to it; `ready' a function
telling whether it can take a prompt now; `reply' a function returning
its last reply, or nil; `environment' the entries of
`overlook-agent-make-environment' its process started with, or nil.")
(put 'overlook-agent-identity 'permanent-local t)

(defvar-local overlook-agent-status 'idle
  "One of `working', `waiting', `done' or `idle'.
`waiting' means the agent asked for attention; `done' that it finished
unseen.")
(put 'overlook-agent-status 'permanent-local t)

(defvar-local overlook-agent-turn nil
  "Times the agent's latest turn started and finished, as (START . END).
END is nil while the turn runs.")
(put 'overlook-agent-turn 'permanent-local t)

(defvar-local overlook-agent-context nil
  "Percentage of the agent's context window in use, or nil when unknown.")
(put 'overlook-agent-context 'permanent-local t)

(defvar overlook-agent-row-marks nil
  "Functions of an agent buffer returning a mark after its name, or nil.")

(defvar overlook-agent--last nil
  "Name of the agent most recently started or shown.")

(defvar overlook-agent-saved nil
  "Agents of an earlier Emacs not resumed yet.
Each is an alist with keys `agent', `root', `session' and `perspective'.")

(defvar overlook-agent--saved-loaded nil
  "Non-nil once `overlook-agent-saved-file' has been read.")

(defvar overlook-agent--saved-written nil
  "The agents last written to `overlook-agent-saved-file'.")

(defvar overlook-agent-changed-hook nil
  "Hook run by `overlook-agent-changed' when some agent's state changed.")

(defvar overlook-agent-turn-start-hook nil
  "Hook run in an agent's buffer when it starts a turn.")

(defvar overlook-agent-turn-end-hook nil
  "Hook run in an agent's buffer when it finishes a turn.")

(defvar overlook-agent-environment-functions nil
  "Functions of an agent's NAME and ROOT returning entries for its environment.
Each returns a list of \"VAR=value\" strings, gathered by
`overlook-agent-make-environment'.")

(defun overlook-agent-make-environment (name root)
  "Entries for the environment of agent NAME starting in ROOT.
A frontend calls it once per agent, before starting its process."
  (seq-mapcat (lambda (fn) (funcall fn name root)) overlook-agent-environment-functions))

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

(defun overlook-agent-visit (buffer)
  "Switch to agent BUFFER's perspective and show it there."
  (unless (buffer-live-p buffer) (user-error "Agent buffer is gone"))
  (overlook-show-elsewhere (overlook-buffer-perspective buffer)
                           (lambda () (overlook-agent-show buffer))))

;;; Status

(defun overlook-agent-glyph (buffer)
  "Status glyph of agent BUFFER, in its face from `overlook-agent-status-glyphs'."
  (let ((glyph (alist-get (buffer-local-value 'overlook-agent-status buffer)
                          overlook-agent-status-glyphs)))
    (propertize (car glyph) 'face (cadr glyph))))

(defun overlook-agent--set-status (status)
  "Set this agent's STATUS, telling the views when it changed."
  (unless (eq status overlook-agent-status)
    (setq overlook-agent-status status)
    (when (memq status '(waiting done))
      (overlook-agent--notify (current-buffer)))
    (overlook-agent-changed)))

(defun overlook-agent-notify-system (title body)
  "Show a desktop notification of TITLE and BODY."
  (cond ((eq system-type 'darwin)
         ;; Passed as arguments, so quotes in them need no escaping.
         (call-process "osascript" nil 0 nil
                       "-e" "on run argv"
                       "-e" "display notification (item 2 of argv) with title (item 1 of argv)"
                       "-e" "end run"
                       title body))
        ((and (featurep 'dbusbind) (require 'notifications nil t))
         (notifications-notify :title title :body body))
        (t (message "%s: %s" title body))))

(defun overlook-agent--notify (buffer)
  "Notify that agent BUFFER waits for you or finished, per `overlook-agent-notify'."
  (when (pcase overlook-agent-notify
          ('unfocused (not (seq-some (lambda (frame) (eq (frame-focus-state frame) t))
                                     (frame-list))))
          (option option))
    (let ((perspective (overlook-buffer-perspective buffer))
          (brief (overlook-agent--brief buffer)))
      (funcall overlook-agent-notify-function
               (format "%s %s" (or (overlook-agent-get buffer 'agent) "agent")
                       (if (eq (buffer-local-value 'overlook-agent-status buffer) 'waiting)
                           "needs you" "finished"))
               (string-join (delq nil (list perspective brief)) ": ")))))

(defun overlook-agent--seen-p ()
  "Non-nil when this agent is shown in the selected window."
  (eq (window-buffer (selected-window)) (current-buffer)))

(defun overlook-agent-report (event)
  "Update the current agent buffer's status for EVENT.
EVENT is `working', `finished' or `attention'; what it becomes depends on
whether the agent is shown in the selected window.  `working' after
`finished' starts a turn, which `overlook-agent-turn' times and
`overlook-agent-turn-start-hook' announces."
  ;; Turns follow events, not statuses: glancing at an agent waiting for
  ;; approval resets it to idle, yet approving does not start a new turn.
  (pcase event
    ('working (when (or (null overlook-agent-turn) (cdr overlook-agent-turn))
                (setq overlook-agent-turn (list (float-time)))
                (run-hooks 'overlook-agent-turn-start-hook)))
    ('finished (when (and overlook-agent-turn (null (cdr overlook-agent-turn)))
                 (setcdr overlook-agent-turn (float-time))
                 (run-hooks 'overlook-agent-turn-end-hook))))
  (pcase event
    ('finished (overlook-agent--set-status (if (overlook-agent--seen-p) 'idle 'done)))
    ('working (unless (eq overlook-agent-status 'waiting)
                (overlook-agent--set-status 'working)))
    ('attention (unless (overlook-agent--seen-p)
                  (overlook-agent--set-status 'waiting)))))

(defun overlook-agent--acknowledge (&rest _)
  "Reset `done' and `waiting' once the agent is shown in the selected window."
  (let ((buffer (window-buffer (selected-window))))
    (when (and (overlook-agent-p buffer)
               (memq (buffer-local-value 'overlook-agent-status buffer) '(done waiting)))
      (with-current-buffer buffer (overlook-agent--set-status 'idle)))))

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
    (add-hook 'kill-buffer-hook (lambda () (run-at-time 0 nil #'overlook-agent-changed)) nil t))
  (setq overlook-agent--last name)
  (overlook-agent-changed))

(defun overlook-agent--launch (name root &optional session fresh)
  "Start agent NAME in ROOT and return its buffer.
SESSION resumes that session; FRESH starts a new conversation without
asking."
  (unless overlook-agent-start-function
    (user-error "Set `overlook-agent-start-function' first"))
  (let ((default-directory root))
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
                                  (perspective . ,(overlook-buffer-perspective buffer)))))
                            (overlook-agent-buffers)))
          overlook-agent-saved))

(defun overlook-agent-save ()
  "Write the agents to resume later to `overlook-agent-saved-file', if changed."
  (with-demoted-errors "overlook: saving agents: %S"
    (let ((agents (overlook-agent--to-save)))
      (unless (equal agents overlook-agent--saved-written)
        (make-directory (file-name-directory overlook-agent-saved-file) t)
        (let ((print-length nil)
              (print-level nil))
          (with-temp-file overlook-agent-saved-file
            (prin1 agents (current-buffer))))
        (setq overlook-agent--saved-written agents)))))

(defun overlook-agent--load-saved ()
  "Read `overlook-agent-saved-file' once, skipping sessions already running."
  (unless overlook-agent--saved-loaded
    (setq overlook-agent--saved-loaded t)
    (let ((running (mapcar #'overlook-agent--session (overlook-agent-buffers)))
          (agents (when (file-readable-p overlook-agent-saved-file)
                    (with-temp-buffer
                      (insert-file-contents overlook-agent-saved-file)
                      (ignore-errors (read (current-buffer)))))))
      (setq overlook-agent-saved
            (seq-remove (lambda (saved) (member (alist-get 'session saved) running))
                        (seq-filter #'consp agents))
            overlook-agent--saved-written agents))))

(defun overlook-agent--resume (saved)
  "Resume SAVED agent from `overlook-agent-saved' and return its buffer."
  (setq overlook-agent-saved (delq saved overlook-agent-saved))
  (let ((root (alist-get 'root saved)))
    (unless (file-directory-p root)
      (overlook-agent-changed)
      (user-error "%s is gone; forgot its agent" root))
    (overlook-agent--launch (alist-get 'agent saved) root (alist-get 'session saved))))

(defun overlook-agent--saved-perspective (saved)
  "The perspective SAVED agent was in, when it still exists."
  (car (member (alist-get 'perspective saved) (overlook-perspectives))))

(defun overlook-agent-resume-visit (saved)
  "Resume SAVED agent in its perspective and show it there."
  (overlook-show-elsewhere (overlook-agent--saved-perspective saved)
                           (lambda () (overlook-agent-show (overlook-agent--resume saved)))))

(defun overlook-agent-forget ()
  "Forget the saved agent of the dashboard row at point."
  (interactive)
  (pcase (overlook-item-at-point)
    (`(saved . ,saved)
     (setq overlook-agent-saved (delq saved overlook-agent-saved))
     (overlook-agent-changed))
    (_ (user-error "Not on a saved agent"))))

(defun overlook-agent--annotate (name)
  "Status and perspective of the agent buffer NAME, for completion."
  (let ((buffer (get-buffer name)))
    (concat "  " (overlook-agent-glyph buffer) " "
            (symbol-name (buffer-local-value 'overlook-agent-status buffer))
            (if-let* ((perspective (overlook-buffer-perspective buffer)))
                (propertize (concat "  " perspective) 'face 'shadow)
              ""))))

;;;###autoload
(defun overlook-agent-switch ()
  "Pick any running agent and show it in its perspective."
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

;;;###autoload
(defun overlook-agent-send (&optional beg end)
  "Paste the region, or an @ reference to the file, into this project's agent.
Interactively BEG and END are the region, when active."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (let* ((file (buffer-file-name (buffer-base-buffer)))
         (path (if file (file-relative-name file (overlook-agent--root)) (buffer-name)))
         (text (if beg
                   (format "%s:%d-%d\n```\n%s\n```\n" path
                           (line-number-at-pos beg) (line-number-at-pos (max beg (1- end)))
                           (buffer-substring-no-properties beg end))
                 (if file (format "@%s " path) (user-error "Buffer has no file"))))
         (buffer (or (overlook-agent--current)
                     (user-error "No agent running in this project"))))
    (deactivate-mark)
    (with-current-buffer buffer
      (funcall (or (overlook-agent-get buffer 'insert)
                   (user-error "%s cannot receive text" (buffer-name)))
               text))
    (overlook-agent-show buffer)))

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
Returns (TEXT . COLUMNS), COLUMNS being how far from the edge TEXT starts.
Context takes the last four columns but one, left free for the wrap mark;
the duration ends a column before it, so both line up across agents."
  (let ((turn (overlook-agent--turn-label buffer))
        (context (overlook-agent--context-label buffer)))
    (cons (concat (if turn (overlook-align-right turn 6) "")
                  (if context (overlook-align-right context 1) ""))
          (cond (turn (+ 6 (string-width turn)))
                (context 5)
                (t 0)))))

(defun overlook-agent--project-label (root perspective)
  "Name of the project at ROOT, dimmed, unless it is PERSPECTIVE's."
  (if (and root (not (equal (and perspective (overlook-perspective-root perspective))
                            root)))
      (propertize (concat " " (file-name-nondirectory (directory-file-name root)))
                  'face 'shadow)
    ""))

(defun overlook-agent--brief (buffer)
  "Return what agent BUFFER is doing, on one line, or nil."
  (when-let* ((brief (overlook-agent-get buffer 'brief))
              (text (with-current-buffer buffer (ignore-errors (funcall brief))))
              (text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
              ((not (string-empty-p text))))
    text))

(defun overlook-agent--brief-label (buffer brief head meta)
  "BRIEF fit to the dashboard between HEAD and META columns at the right.
Highlighted while agent BUFFER waits, set apart from its name while it
works, dimmed otherwise."
  (let* ((gap "  ")
         (face (pcase (buffer-local-value 'overlook-agent-status buffer)
                 ('waiting 'warning)
                 ('working 'font-lock-doc-face)
                 (_ 'shadow)))
         (room (- (overlook-window-pixels)
                  (overlook-pixel-width (concat head gap))
                  (* (1+ meta) (frame-char-width))))
         (text (overlook-fit brief room face)))
    (if text (concat gap text) "")))

(defun overlook-agent--row (buffer perspective)
  "Insert the row of agent BUFFER under PERSPECTIVE."
  (let* ((head (concat overlook-indent (overlook-glyph-cell (overlook-agent-glyph buffer))
                       (or (overlook-agent-get buffer 'agent) "agent")
                       (string-join (delq nil (mapcar (lambda (fn) (funcall fn buffer))
                                                      overlook-agent-row-marks)))
                       (overlook-agent--project-label (overlook-agent-get buffer 'root) perspective)))
         (meta (overlook-agent--meta buffer))
         (brief (overlook-agent--brief buffer))
         (status (buffer-local-value 'overlook-agent-status buffer))
         (line (concat head
                       (if brief (overlook-agent--brief-label buffer brief head (cdr meta)) "")
                       (car meta)
                       "\n"))
         (highlight (pcase status
                      ('waiting 'overlook-agent-waiting)
                      ('done 'overlook-agent-done))))
    (when highlight
      (add-face-text-property (length overlook-indent) (length line) highlight t line))
    (insert (propertize line
                        'overlook-item (cons 'agent buffer)
                        'overlook-action (lambda () (overlook-agent-visit buffer))
                        'overlook-attention (memq status '(waiting done))
                        'help-echo (if brief (concat (buffer-name buffer) "\n" brief)
                                     (buffer-name buffer))
                        'wrap-prefix overlook-agent--wrap-indent))))

(defun overlook-agent--saved-row (saved perspective)
  "Insert the row of SAVED agent, dimmed, under PERSPECTIVE."
  (let ((glyph (alist-get 'idle overlook-agent-status-glyphs)))
    (insert (propertize
             (concat overlook-indent
                     (overlook-glyph-cell (propertize (car glyph) 'face 'shadow))
                     (propertize (concat (alist-get 'agent saved) " saved") 'face 'shadow)
                     (overlook-agent--project-label (alist-get 'root saved) perspective)
                     "\n")
             'overlook-item (cons 'saved saved)
             'overlook-action (lambda () (overlook-agent-resume-visit saved))
             'help-echo (concat "Resume session " (alist-get 'session saved))
             'wrap-prefix overlook-agent--wrap-indent))))

(defun overlook-agent--insert (perspective)
  "Insert the agents whose buffers are in PERSPECTIVE, then those saved there."
  (let ((buffers (overlook-perspective-buffers perspective)))
    (dolist (buffer (overlook-agent-buffers (lambda (buffer) (memq buffer buffers))))
      (overlook-agent--row buffer perspective)))
  (dolist (saved overlook-agent-saved)
    (when (equal (overlook-agent--saved-perspective saved) perspective)
      (overlook-agent--saved-row saved perspective))))

(defun overlook-agent--insert-orphans ()
  "Insert the agents in no perspective; non-nil when there were any."
  (let ((orphans (overlook-agent-buffers
                  (lambda (buffer) (null (overlook-buffer-perspective buffer)))))
        (saved (seq-remove #'overlook-agent--saved-perspective overlook-agent-saved)))
    (dolist (buffer orphans)
      (overlook-agent--row buffer nil))
    (dolist (entry saved)
      (overlook-agent--saved-row entry nil))
    (or orphans saved)))

(defun overlook-agent--mode-line ()
  "A count of agents by state, like \"3 agents · 1 working\"."
  (let* ((statuses (mapcar (lambda (buffer) (buffer-local-value 'overlook-agent-status buffer))
                           (overlook-agent-buffers)))
         (working (seq-count (lambda (status) (eq status 'working)) statuses))
         (attention (seq-count (lambda (status) (memq status '(waiting done))) statuses)))
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
  (let ((hooks '((overlook-perspective-functions . overlook-agent--insert)
                 (overlook-orphan-functions . overlook-agent--insert-orphans)
                 (overlook-mode-line-functions . overlook-agent--mode-line)
                 (overlook-tick-hook . overlook-agent--tick)
                 (window-selection-change-functions . overlook-agent--acknowledge)
                 (window-buffer-change-functions . overlook-agent--acknowledge)
                 (overlook-agent-changed-hook . overlook-agent-save)
                 (kill-emacs-hook . overlook-agent-save))))
    (when overlook-agent-mode (overlook-agent--load-saved))
    (pcase-dolist (`(,hook . ,function) hooks)
      (if overlook-agent-mode
          (add-hook hook function)
        (remove-hook hook function))))
  (overlook-refresh))

(overlook-define-key "x" #'overlook-agent-forget)

(provide 'overlook-agent)
;;; overlook-agent.el ends here
