;;; jgy-agents-follow.el --- Diff windows following an agent's edits -*- lexical-binding: t; -*-

;;; Commentary:
;; 让 agent 所在 tab 开一个 diff 窗口，跟着它最近写的文件刷新，光标落在改动处。
;; 文件和缓存的本轮 diff 取自 agent 的 `files' identity；别的 tab 里的 agent 等切过去再补上。

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

(defun jgy-agents-follow--insert (file)
  "Insert FILE's uncommitted changes, or the whole file when git does not track it."
  ;; git 在文件所在目录里跑；文件可能在项目里嵌套的另一个仓库。
  (let ((default-directory (file-name-directory file))
        (name (file-name-nondirectory file)))
    (erase-buffer)
    (if (eq 0 (process-file "git" nil nil nil "ls-files" "--error-unmatch" "--" name))
        (process-file "git" nil t nil "diff" "--no-color" "HEAD" "--" name)
      (process-file "git" nil t nil "diff" "--no-color" "--no-index" "--" "/dev/null" name))))

(defun jgy-agents-follow--hunk (line)
  "Start of the hunk whose new side holds LINE, else of the first hunk."
  (goto-char (point-min))
  (let (first found)
    (while (and (not found)
                (re-search-forward "^@@ -[0-9,]+ \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@" nil t))
      (let ((start (string-to-number (match-string 1)))
            (count (if (match-string 2) (string-to-number (match-string 2)) 1)))
        (setq first (or first (match-beginning 0)))
        (when (and line (<= start line) (< line (+ start (max count 1))))
          (setq found (match-beginning 0)))))
    (or found first (point-min))))

(defun jgy-agents-follow--show (buffer file)
  "Show FILE's changes for agent BUFFER in a window of the current tab.
FILE is an entry of its `files' identity; point goes to the hunk at its line."
  (let ((diff (get-buffer-create (jgy-agents-follow--buffer-name buffer)))
        (path (alist-get 'file file)))
    (with-current-buffer diff
      (let ((inhibit-read-only t))
        (if (assq 'diff file)
            (progn
              (erase-buffer)
              (insert (or (alist-get 'diff file) ""))
              (when (zerop (buffer-size)) (insert "No net changes this turn.\n")))
          (jgy-agents-follow--insert path))
        (unless (derived-mode-p 'diff-mode) (diff-mode))
        (setq buffer-read-only t
              header-line-format (and (assq 'diff file) "This turn · file changes")
              default-directory (or (alist-get 'directory file) (file-name-directory path)))))
    (let* ((anchor (or (get-buffer-window buffer)
                       (get-mru-window nil nil t)))
           (window (display-buffer
                    diff `((display-buffer-reuse-window display-buffer-in-direction)
                           (direction . right) (window . ,anchor)
                           (inhibit-same-window . t)))))
      (when window
        (with-current-buffer diff
          (let ((pos (jgy-agents-follow--hunk (alist-get 'line file))))
            ;; 从头显示，留着文件名；改动不在第一屏时 redisplay 自己滚过去。
            (set-window-start window (point-min))
            (set-window-point window pos)))))))

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
