;;; jgy-worklog.el --- Worklog todos on the overlook dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;; 在 overlook 看板底部列出所有进行中项目的 project.md 待办，项目顺序同看板的 perspective。
;; 待办取 Todo 段的未完成项（含缩进的子项），加上任意段落里带 #waiting 的未完成项。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'jgy-project)

(declare-function overlook-refresh "overlook")
(declare-function overlook-insert-section "overlook")
(declare-function overlook-ordered-perspectives "overlook")
(declare-function overlook-current-perspective "overlook")
(defvar overlook-sections)

(defvar jgy-worklog--cache nil
  "Parsed cards, as (STAMP . CARDS); STAMP lists each card's file and mtime.")

(defun jgy-worklog--parse (file)
  "Parse card FILE into a plist of :id :status :file :todos.
Each todo is (TEXT LINE DEPTH) for an open checkbox under the Todo heading,
or anywhere when tagged #waiting; DEPTH is its indent in columns."
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
           ((and (string-match "\\`\\( *\\)- \\[ \\] \\(.+\\)" line)
                 (or in-todo (string-match-p "#waiting\\>" line)))
            (push (list (match-string 2 line) (line-number-at-pos) (length (match-string 1 line)))
                  todos))))
        (forward-line 1))
      (list :id id :status status :file file :todos (nreverse todos)))))

(defun jgy-worklog--cards ()
  "Return parsed active cards, re-reading only when a card file changed."
  (let* ((files (jgy-project-files))
         (stamp (mapcar (lambda (file)
                          (cons file (file-attribute-modification-time (file-attributes file))))
                        files)))
    (unless (equal stamp (car jgy-worklog--cache))
      (setq jgy-worklog--cache (cons stamp (mapcar #'jgy-worklog--parse files))))
    (seq-filter (lambda (card) (member (plist-get card :status) '("active" "waiting")))
                (cdr jgy-worklog--cache))))

(defun jgy-worklog--rank (text)
  "0 for a #now todo TEXT, 1 for #waiting, 2 for the rest.
Tags inside `code' do not count."
  (let ((text (replace-regexp-in-string "`[^`]*`" "" text)))
    (cond ((string-match-p "#now\\>" text) 0)
          ((string-match-p "#waiting\\>" text) 1)
          (t 2))))

(defun jgy-worklog--sort-todos (todos)
  "TODOS with #now first, then #waiting, then the rest, among siblings.
A todo moves with its subitems, ranked by the most urgent of them."
  (let (siblings)
    (while todos
      (let* ((todo (pop todos))
             (children (seq-take-while (lambda (child) (> (nth 2 child) (nth 2 todo))) todos)))
        (setq todos (nthcdr (length children) todos))
        (push (cons todo (jgy-worklog--sort-todos children)) siblings)))
    (mapcan #'copy-sequence
            (seq-sort-by (lambda (group) (apply #'min (mapcar (lambda (todo) (jgy-worklog--rank (car todo))) group)))
                         #'<
                         (nreverse siblings)))))

(defun jgy-worklog--display (text)
  "Return TEXT without inline fields and tags, with its due date appended.
#now shows plain, #waiting italic and the rest dimmed."
  (let ((due (and (string-match "\\[due:: *\\([0-9-]+\\)\\]" text) (match-string 1 text)))
        (face (pcase (jgy-worklog--rank text)
                (0 'default)
                (1 'italic)
                (_ 'shadow)))
        (clean (string-trim
                (replace-regexp-in-string
                 " +" " "
                 (replace-regexp-in-string
                  "\\(`[^`]*`\\)\\|\\[[a-z]+::[^]]*\\]\\|#[[:alnum:]_-]+"
                  (lambda (match) (if (string-prefix-p "`" match) match ""))
                  text t t)))))
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

(defun jgy-worklog--insert-card (card current)
  "Insert a heading for CARD followed by its todos; CURRENT highlights the heading."
  (insert (propertize (plist-get card :id)
                      'face (if current 'overlook-heading-current 'overlook-heading)
                      'overlook-heading t
                      'overlook-action (jgy-worklog--visit (plist-get card :file) 1))
          "\n")
  (pcase-dolist (`(,text ,line ,depth) (jgy-worklog--sort-todos (plist-get card :todos)))
    (let ((indent (make-string (+ 3 depth) ?\s))
          (mark (pcase (jgy-worklog--rank text) (0 "→") (1 "◷") (_ "☐"))))
      ;; →、◷、☐ 在等宽字体里都占两列，折行接在它们后面。
      (insert (propertize (concat indent (propertize mark 'face 'shadow) " "
                                  (jgy-worklog--display text))
                          'overlook-action (jgy-worklog--visit (plist-get card :file) line)
                          'wrap-prefix (concat indent "   "))
              "\n"))))

(defun jgy-worklog--ordered (cards)
  "CARDS with todos, those with a perspective first in the dashboard's order."
  (let ((order (overlook-ordered-perspectives)))
    (seq-sort-by (lambda (card) (or (seq-position order (plist-get card :id)) (length order)))
                 #'<
                 (seq-filter (lambda (card) (plist-get card :todos)) cards))))

(defun jgy-worklog-dashboard-insert ()
  "Insert a Todo section with every ongoing project's open todos."
  (let ((current (overlook-current-perspective)))
    (overlook-insert-section
     "Todo"
     (lambda ()
       (let ((first t))
         (dolist (card (jgy-worklog--ordered (jgy-worklog--cards)))
           (unless first (insert "\n"))
           (setq first nil)
           (jgy-worklog--insert-card card (equal (plist-get card :id) current))))))))

(defun jgy-worklog--after-save ()
  "Re-render the dashboard after saving a worklog file."
  (when (and buffer-file-name
             (fboundp 'overlook-refresh)
             (file-in-directory-p buffer-file-name jgy-workspace-directory))
    (overlook-refresh)))

;;;###autoload
(define-minor-mode jgy-worklog-dashboard-mode
  "Show ongoing projects' worklog todos in the agents dashboard."
  :global t
  :group 'overlook
  (if jgy-worklog-dashboard-mode
      (progn
        (add-hook 'overlook-sections #'jgy-worklog-dashboard-insert 50)
        (add-hook 'after-save-hook #'jgy-worklog--after-save))
    (remove-hook 'overlook-sections #'jgy-worklog-dashboard-insert)
    (remove-hook 'after-save-hook #'jgy-worklog--after-save)))

(provide 'jgy-worklog)
;;; jgy-worklog.el ends here
