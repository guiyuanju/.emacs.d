;;; jgy-agents-follow.el --- Diff windows following an agent's edits -*- lexical-binding: t; -*-

;;; Commentary:
;; 让 agent 所在 tab 开一个 diff 窗口，跟着它最近写的文件刷新，光标落在改动处。
;; 文件取自 agent 的 `files' identity，diff 由它的 `diff' identity 渲染；别的 tab 里的 agent 等切过去再补上。

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'seq)
(require 'jgy-agents)

(defvar-local jgy-agents-follow--state nil
  "Non-nil while this agent's diff window follows its edits.
It is a plist: :files the `files' identity last seen, :file the file shown,
:pending non-nil when that file changed while the agent's tab was not current.")

(defvar jgy-agents-follow--timer nil)

(defun jgy-agents-follow--buffer-name (buffer)
  (format "*agent diff: %s*" (buffer-name buffer)))

(defun jgy-agents-follow--schedule ()
  "Update the diff windows soon, coalescing bursts of edits."
  (unless (timerp jgy-agents-follow--timer)
    (setq jgy-agents-follow--timer
          (run-with-timer 0.3 nil
                          (lambda ()
                            (setq jgy-agents-follow--timer nil)
                            (jgy-agents-follow--update))))))

(defun jgy-agents-follow--latest (old new &optional current)
  "The entry of NEW, a `files' identity, changed since OLD, or nil.
Of several, prefer the active file or CURRENT; keep an unchanged CURRENT."
  (let ((changed
         (seq-remove
          (lambda (file)
            (let ((previous (seq-find (lambda (entry)
                                        (equal (alist-get 'file entry) (alist-get 'file file))) old)))
              ;; Clearing a stale focus marker is not a content change.
              (equal (assq-delete-all 'active (copy-sequence file))
                     (assq-delete-all 'active (copy-sequence previous))))) new)))
    (or (seq-find (lambda (file) (alist-get 'active file)) changed)
        (seq-find (lambda (file) (equal (alist-get 'file file) current)) changed)
        (unless (and (> (length changed) 1)
                     (seq-find (lambda (file) (equal (alist-get 'file file) current)) new))
          (car (last changed))))))

(defun jgy-agents-follow--show (buffer file)
  "Show FILE's diffs for agent BUFFER in a window of the current tab.
FILE is an entry of its `files' identity, rendered by its `diff' identity;
point goes to the latest hunk."
  (let* ((name (jgy-agents-follow--buffer-name buffer))
         (old (get-buffer name))
         (window (and old (get-buffer-window old)))
         (diff (jgy-agents-diff buffer (list file))))
    (when window (set-window-buffer window diff))
    (when old (kill-buffer old))
    (with-current-buffer diff (rename-buffer name))
    (when-let* ((window (or window
                            (display-buffer
                             diff `((display-buffer-reuse-window display-buffer-in-direction)
                                    (direction . right)
                                    (window . ,(or (get-buffer-window buffer)
                                                   (get-mru-window nil nil t)))
                                    (inhibit-same-window . t))))))
      (with-current-buffer diff
        (goto-char (point-max))
        (ignore-errors (diff-hunk-prev))
        (set-window-point window (point))))))

(defun jgy-agents-follow--current-tab-p (buffer)
  "Non-nil when agent BUFFER's tab is the current one, or is gone."
  (let ((index (jgy-agents-tab-index buffer)))
    (or (null index) (= index (tab-bar--current-tab-index)))))

(defun jgy-agents-follow--update (&rest _)
  "Show the latest edit of each agent following its diffs.
Agents in other tabs catch up when their tab is selected."
  (dolist (buffer (jgy-agents-buffers))
    (when-let* ((state (buffer-local-value 'jgy-agents-follow--state buffer)))
      (let* ((files (jgy-agents-files buffer))
             (latest (jgy-agents-follow--latest (plist-get state :files) files (plist-get state :file)))
             (file (or latest
                       (and (plist-get state :pending)
                            (seq-find (lambda (file)
                                        (equal (alist-get 'file file) (plist-get state :file)))
                                      files)))))
        (with-current-buffer buffer
          (setq jgy-agents-follow--state (list :files files
                                          :file (if file (alist-get 'file file) (plist-get state :file))
                                          :pending (and file t))))
        (when (and file (jgy-agents-follow--current-tab-p buffer))
          (jgy-agents-follow--show buffer file)
          (with-current-buffer buffer
            (setq jgy-agents-follow--state (plist-put jgy-agents-follow--state :pending nil))))))))

(defun jgy-agents-follow-p (buffer)
  "Non-nil when agent BUFFER's diff window follows its edits."
  (and (buffer-local-value 'jgy-agents-follow--state buffer) t))

(defun jgy-agents-follow-latest (buffer)
  "The file agent BUFFER is writing, or else the one it wrote last."
  (let ((files (jgy-agents-files buffer)))
    (or (seq-find (lambda (file) (alist-get 'active file)) files)
        (car (last files)))))

(defun jgy-agents-follow-start (buffer)
  "Follow agent BUFFER's edits, showing its latest file in the current tab."
  (let ((file (jgy-agents-follow-latest buffer)))
    (with-current-buffer buffer
      (setq jgy-agents-follow--state
            (list :files (jgy-agents-files buffer) :file (alist-get 'file file))))
    (when file (jgy-agents-follow--show buffer file))
    (jgy-agents-refresh)))

(defun jgy-agents-follow-stop (buffer)
  "Stop following agent BUFFER's edits and close its diff window."
  (with-current-buffer buffer (setq jgy-agents-follow--state nil))
  (when-let* ((diff (get-buffer (jgy-agents-follow--buffer-name buffer))))
    (dolist (window (get-buffer-window-list diff nil t))
      (ignore-errors (delete-window window)))
    (kill-buffer diff))
  (jgy-agents-refresh))

(defun jgy-agents-follow--turn-start ()
  "Let the diff window wait for this new turn's edits."
  (when jgy-agents-follow--state
    (setq jgy-agents-follow--state (plist-put jgy-agents-follow--state :files nil)))
  (when-let* ((diff (get-buffer (jgy-agents-follow--buffer-name (current-buffer)))))
    (with-current-buffer diff
      (setq header-line-format "Previous turn · waiting for changes"))))

(add-hook 'jgy-agents-changed-hook #'jgy-agents-follow--schedule)
(add-hook 'jgy-agents-turn-start-hook #'jgy-agents-follow--turn-start)
(add-hook 'tab-bar-tab-post-select-functions #'jgy-agents-follow--update)

(provide 'jgy-agents-follow)
;;; jgy-agents-follow.el ends here
