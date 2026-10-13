;;; jgy-notes.el --- Commands over the notes directory -*- lexical-binding: t; -*-

;;; Commentary:
;; 在笔记目录里查找、搜索、新建笔记和打开当天日记。

;;; Code:

(declare-function consult-find "consult")
(declare-function consult-ripgrep "consult")

(defvar jgy-notes-directory "~/Documents/Garden/"
  "Root directory for notes.")

(defun jgy-notes-find ()
  "Find a file below `jgy-notes-directory'."
  (interactive)
  (consult-find (expand-file-name jgy-notes-directory)))

(defun jgy-notes-search ()
  "Search `jgy-notes-directory' with ripgrep."
  (interactive)
  (consult-ripgrep (expand-file-name jgy-notes-directory)))

(defun jgy-notes-new ()
  "Create or open a note in the notes inbox."
  (interactive)
  (let ((directory (expand-file-name "notes/" jgy-notes-directory)))
    (make-directory directory t)
    (find-file (read-file-name "Note: " directory nil nil nil))))

(defun jgy-notes-daily ()
  "Open today's journal note."
  (interactive)
  (let ((directory (expand-file-name "journals/" jgy-notes-directory)))
    (make-directory directory t)
    (find-file (expand-file-name (format-time-string "%Y-%m-%d.md") directory))))

(provide 'jgy-notes)
;;; jgy-notes.el ends here
