;;; jgy-worklog.el --- Worklog todos in the agents dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;; 在 agents 看板底部列出当前项目文件夹的 project.md 待办。
;; 待办取 Todo 段的未完成项，加上任意段落里带 #waiting 的未完成项；
;; 不在项目文件夹里时列出所有带 #now 或 #waiting 的待办。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'jgy-project)

(declare-function agents--dashboard-schedule "jgy-agents")
(declare-function agents-dashboard-define-key "jgy-agents")
(declare-function agents-dashboard-heading "jgy-agents")
(declare-function agents-dashboard-insert-section "jgy-agents")
(defvar agents-dashboard-functions)

(defgroup jgy-worklog nil
  "Worklog todos in the agents dashboard."
  :group 'tools)

(defcustom jgy-worklog-directory jgy/workspace-directory
  "Directory containing workspaces, each with a projects/ folder."
  :type 'directory)

(defvar jgy-worklog--cache nil
  "Parsed cards, as (STAMP . CARDS); STAMP lists each card's file and mtime.")

(defvar jgy-worklog--last-root nil
  "Project root the dashboard last showed todos for.")

(defun jgy-worklog--card-files ()
  "Return every project card file."
  (jgy/project-files jgy-worklog-directory))

(defun jgy-worklog--parse (file)
  "Parse card FILE into a plist of :id :status :file :todos.
Each todo is (TEXT . LINE) for an open checkbox under the Todo heading,
or anywhere when tagged #waiting."
  (with-temp-buffer
    (insert-file-contents file)
    (let (id status todos in-todo)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties (point) (line-end-position))))
          (cond
           ((string-match "\\`id: *\\(.+\\)" line) (setq id (string-trim (match-string 1 line))))
           ((string-match "\\`status: *\\([a-z]+\\)" line) (setq status (match-string 1 line)))
           ((string-prefix-p "## " line) (setq in-todo (string= line "## Todo")))
           ((and (string-match "\\`- \\[ \\] \\(.+\\)" line)
                 (or in-todo (string-match-p "#waiting\\>" line)))
            (push (cons (match-string 1 line) (line-number-at-pos)) todos))))
        (forward-line 1))
      (list :id id :status status :file file :todos (nreverse todos)))))

(defun jgy-worklog--cards ()
  "Return parsed active cards, re-reading only when a card file changed."
  (let* ((files (jgy-worklog--card-files))
         (stamp (mapcar (lambda (file)
                          (cons file (file-attribute-modification-time (file-attributes file))))
                        files)))
    (unless (equal stamp (car jgy-worklog--cache))
      (setq jgy-worklog--cache (cons stamp (mapcar #'jgy-worklog--parse files))))
    (seq-filter (lambda (card) (member (plist-get card :status) '("active" "waiting")))
                (cdr jgy-worklog--cache))))

(defun jgy-worklog--current-root (frame)
  "Return the project folder of the main window in FRAME's current tab."
  (let* ((selected (frame-selected-window frame))
         (window (if (window-parameter selected 'window-side)
                     (get-mru-window frame nil t)
                   selected)))
    (when window
      (jgy/project-root (buffer-local-value 'default-directory (window-buffer window))))))

(defun jgy-worklog--display (text)
  "Return TEXT without inline fields and tags, with its due date appended.
#now shows bold and #waiting dimmed."
  (let ((due (and (string-match "\\[due:: *\\([0-9-]+\\)\\]" text) (match-string 1 text)))
        (face (cond ((string-match-p "#now\\>" text) 'bold)
                    ((string-match-p "#waiting\\>" text) '(:inherit shadow :slant italic))
                    (t 'default)))
        (clean (string-trim
                (replace-regexp-in-string
                 " +" " " (replace-regexp-in-string "\\[[a-z]+::[^]]*\\]\\|#[[:alnum:]_-]+" "" text)))))
    (concat (propertize clean 'face face)
            (if due (propertize (concat " " due) 'face 'shadow) ""))))

(defun jgy-worklog--visit (file line)
  "Return a command that opens FILE at LINE in the main window."
  (lambda ()
    (when (window-parameter (selected-window) 'window-side)
      (select-window (get-mru-window nil nil t)))
    (find-file file)
    (goto-char (point-min))
    (forward-line (1- line))))

(defun jgy-worklog--insert-card (card todos first &optional bare)
  "Insert a heading for CARD followed by TODOS.
FIRST omits the blank line before the heading; BARE omits the heading."
  (unless (or first bare) (insert "\n"))
  (unless bare
    (insert (propertize (agents-dashboard-heading (plist-get card :id))
                        'agents-tab t
                        'agents-action (jgy-worklog--visit (plist-get card :file) 1))
            "\n"))
  (pcase-dolist (`(,text . ,line) todos)
    ;; ☐ 在等宽字体里占两列，折行接在它后面。
    (insert (propertize (concat "   " (propertize "☐" 'face 'shadow) " "
                                (jgy-worklog--display text))
                        'agents-action (jgy-worklog--visit (plist-get card :file) line)
                        'wrap-prefix "      ")
            "\n")))

(defun jgy-worklog-dashboard-insert (frame)
  "Insert a Todo section for the project folder shown in FRAME's current tab.
Outside a project folder, list every #now or #waiting todo instead."
  (let* ((root (jgy-worklog--current-root frame))
         (cards (jgy-worklog--cards))
         (matched (and root (seq-filter (lambda (card)
                                          (file-equal-p (file-name-directory (plist-get card :file))
                                                        root))
                                        cards))))
    (setq jgy-worklog--last-root root)
    (agents-dashboard-insert-section
     ;; 只有当前项目一张卡时，标题就是它的标题：RET 打开它，下面不再重复。
     (if (and matched (null (cdr matched)))
         (propertize (concat "Todo · " (plist-get (car matched) :id))
                     'agents-tab t
                     'agents-action (jgy-worklog--visit (plist-get (car matched) :file) 1))
       (concat "Todo · " (if matched (plist-get (car matched) :id) "#now")))
     (lambda ()
       (let ((first t)
             (bare (and matched (null (cdr matched)))))
         (dolist (card (or matched cards))
           (when-let* ((todos (if matched
                                  (plist-get card :todos)
                                (seq-filter (lambda (todo) (string-match-p "#\\(?:now\\|waiting\\)\\>" (car todo)))
                                            (plist-get card :todos)))))
             (jgy-worklog--insert-card card todos first bare)
             (setq first nil))))))))

(defun jgy-worklog--refresh (frame)
  "Re-render the dashboard when FRAME's current project changed."
  (when (and (fboundp 'agents--dashboard-schedule)
             (not (equal (jgy-worklog--current-root frame) jgy-worklog--last-root)))
    (agents--dashboard-schedule)))

(defun jgy-worklog--after-save ()
  "Re-render the dashboard after saving a worklog file."
  (when (and buffer-file-name
             (fboundp 'agents--dashboard-schedule)
             (file-in-directory-p buffer-file-name jgy-worklog-directory))
    (agents--dashboard-schedule)))

;;;###autoload
(define-minor-mode jgy-worklog-dashboard-mode
  "Show worklog todos for the current project in the agents dashboard."
  :global t
  (if jgy-worklog-dashboard-mode
      (progn
        (add-hook 'agents-dashboard-functions #'jgy-worklog-dashboard-insert)
        (add-hook 'window-buffer-change-functions #'jgy-worklog--refresh)
        (add-hook 'after-save-hook #'jgy-worklog--after-save))
    (remove-hook 'agents-dashboard-functions #'jgy-worklog-dashboard-insert)
    (remove-hook 'window-buffer-change-functions #'jgy-worklog--refresh)
    (remove-hook 'after-save-hook #'jgy-worklog--after-save)))

(provide 'jgy-worklog)
;;; jgy-worklog.el ends here
