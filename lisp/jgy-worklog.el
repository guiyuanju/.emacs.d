;;; jgy-worklog.el --- Worklog todos in the agents dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;; 在 agents 看板底部列出当前项目对应的 worklog 待办。
;; 项目卡 frontmatter 的 `repos' 含当前项目根目录（worktree 按主仓库算）即视为对应；
;; 待办取 Todo 段的未完成项，加上任意段落里带 #waiting 的未完成项；
;; 没有对应的卡时列出所有带 #now 或 #waiting 的待办。

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)
(require 'subr-x)

(declare-function ghostel-agents--dashboard-schedule "ghostel-agents")
(declare-function ghostel-agents-dashboard-insert-section "ghostel-agents")
(defvar ghostel-agents-dashboard-functions)

(defgroup jgy-worklog nil
  "Worklog todos in the agents dashboard."
  :group 'tools)

(defcustom jgy-worklog-directory "~/Documents/Garden/worklog/"
  "Root of the worklog repository."
  :type 'directory)

(defvar jgy-worklog--cache nil
  "Parsed cards, as (STAMP . CARDS); STAMP lists each card's file and mtime.")

(defvar jgy-worklog--last-root nil
  "Project root the dashboard last showed todos for.")

(defun jgy-worklog--card-files ()
  "Return every project card file."
  (file-expand-wildcards
   (expand-file-name "projects/*/README.md" jgy-worklog-directory)))

(defun jgy-worklog--repo-list (value)
  "Parse a frontmatter list VALUE such as \"[~/a, ~/b]\" into true names."
  (thread-last (split-string (string-trim value "\\[" "\\]") "," t "[ \t\"']+")
               (mapcar (lambda (path) (file-name-as-directory (file-truename path))))))

(defun jgy-worklog--parse (file)
  "Parse card FILE into a plist of :id :status :repos :file :todos.
Each todo is (TEXT . LINE) for an open checkbox under the Todo heading,
or anywhere when tagged #waiting."
  (with-temp-buffer
    (insert-file-contents file)
    (let (id status repos todos in-todo)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties (point) (line-end-position))))
          (cond
           ((string-match "\\`id: *\\(.+\\)" line) (setq id (string-trim (match-string 1 line))))
           ((string-match "\\`status: *\\([a-z]+\\)" line) (setq status (match-string 1 line)))
           ((string-match "\\`repos: *\\(.+\\)" line)
            (setq repos (jgy-worklog--repo-list (match-string 1 line))))
           ((string-prefix-p "## " line) (setq in-todo (string= line "## Todo")))
           ((and (string-match "\\`- \\[ \\] \\(.+\\)" line)
                 (or in-todo (string-match-p "#waiting\\>" line)))
            (push (cons (match-string 1 line) (line-number-at-pos)) todos))))
        (forward-line 1))
      (list :id id :status status :repos repos :file file :todos (nreverse todos)))))

(defun jgy-worklog--cards ()
  "Return parsed active cards, re-reading only when a card file changed."
  (let* ((files (jgy-worklog--card-files))
         (stamp (mapcar (lambda (file)
                          (cons file (file-attribute-modification-time (file-attributes file))))
                        files)))
    (unless (equal stamp (car jgy-worklog--cache))
      (setq jgy-worklog--cache (cons stamp (mapcar #'jgy-worklog--parse files))))
    (seq-filter (lambda (card) (equal (plist-get card :status) "active"))
                (cdr jgy-worklog--cache))))

(defun jgy-worklog--main-repo (root)
  "Return ROOT, or the main repository when ROOT is a git worktree."
  (let ((dotgit (expand-file-name ".git" root)))
    (or (and (file-regular-p dotgit)
             (with-temp-buffer
               (insert-file-contents dotgit)
               (and (re-search-forward "^gitdir: *\\(.+\\)/\\.git/worktrees/" nil t)
                    (file-name-as-directory (file-truename (match-string 1))))))
        (file-name-as-directory (file-truename root)))))

(defun jgy-worklog--current-root (frame)
  "Return the project root of the main window in FRAME's current tab."
  (let* ((selected (frame-selected-window frame))
         (window (if (window-parameter selected 'window-side)
                     (get-mru-window frame nil t)
                   selected)))
    (when-let* ((window)
                (project (with-current-buffer (window-buffer window)
                           (project-current nil))))
      (project-root project))))

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

(defun jgy-worklog--insert-card (card todos first)
  "Insert a heading for CARD followed by TODOS.
FIRST omits the blank line before the heading."
  (unless first (insert "\n"))
  (insert (propertize (format "[%s]" (plist-get card :id)) 'face 'bold
                      'ghostel-agents-tab t
                      'ghostel-agents-action (jgy-worklog--visit (plist-get card :file) 1))
          "\n")
  (cl-loop for ((text . line) . rest) on todos
           do (insert (propertize (concat "  " (if rest "├─ " "└─ ") (jgy-worklog--display text))
                                  'ghostel-agents-action
                                  (jgy-worklog--visit (plist-get card :file) line)
                                  'wrap-prefix (if rest "  │  " "     "))
                      "\n")))

(defun jgy-worklog-dashboard-insert (frame)
  "Insert a Todo section for the worklog cards matching FRAME's current project.
Without a matching card, list every #now or #waiting todo instead."
  (let* ((root (jgy-worklog--current-root frame))
         (repo (and root (jgy-worklog--main-repo root)))
         (cards (jgy-worklog--cards))
         (matched (and repo (seq-filter (lambda (card) (member repo (plist-get card :repos)))
                                        cards))))
    (setq jgy-worklog--last-root root)
    (ghostel-agents-dashboard-insert-section
     (concat "Todo · " (if matched (file-name-nondirectory (directory-file-name repo)) "#now"))
     (lambda ()
       (let ((first t))
         (dolist (card (or matched cards))
           (when-let* ((todos (if matched
                                  (plist-get card :todos)
                                (seq-filter (lambda (todo) (string-match-p "#\\(?:now\\|waiting\\)\\>" (car todo)))
                                            (plist-get card :todos)))))
             (jgy-worklog--insert-card card todos first)
             (setq first nil))))))))

(defun jgy-worklog--refresh (frame)
  "Re-render the dashboard when FRAME's current project changed."
  (when (and (fboundp 'ghostel-agents--dashboard-schedule)
             (not (equal (jgy-worklog--current-root frame) jgy-worklog--last-root)))
    (ghostel-agents--dashboard-schedule)))

(defun jgy-worklog--after-save ()
  "Re-render the dashboard after saving a worklog file."
  (when (and buffer-file-name
             (fboundp 'ghostel-agents--dashboard-schedule)
             (file-in-directory-p buffer-file-name jgy-worklog-directory))
    (ghostel-agents--dashboard-schedule)))

;;;###autoload
(define-minor-mode jgy-worklog-dashboard-mode
  "Show worklog todos for the current project in the agents dashboard."
  :global t
  (if jgy-worklog-dashboard-mode
      (progn
        (add-hook 'ghostel-agents-dashboard-functions #'jgy-worklog-dashboard-insert)
        (add-hook 'window-buffer-change-functions #'jgy-worklog--refresh)
        (add-hook 'after-save-hook #'jgy-worklog--after-save))
    (remove-hook 'ghostel-agents-dashboard-functions #'jgy-worklog-dashboard-insert)
    (remove-hook 'window-buffer-change-functions #'jgy-worklog--refresh)
    (remove-hook 'after-save-hook #'jgy-worklog--after-save)))

(provide 'jgy-worklog)
;;; jgy-worklog.el ends here
