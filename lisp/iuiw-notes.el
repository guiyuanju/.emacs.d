;;; iuiw-notes.el --- Commands over the notes directory -*- lexical-binding: t; -*-

;;; Commentary:
;; 在笔记目录里查找、搜索、新建笔记和打开当天日记。

;;; Code:

(declare-function consult-find "consult")
(declare-function consult-ripgrep "consult")

(defvar iuiw-notes-directory "~/Documents/Garden/"
  "Root directory for notes.")

(defun iuiw-notes-find ()
  "Find a file below `iuiw-notes-directory'."
  (interactive)
  (consult-find (expand-file-name iuiw-notes-directory)))

(defun iuiw-notes-search ()
  "Search `iuiw-notes-directory' with ripgrep."
  (interactive)
  (consult-ripgrep (expand-file-name iuiw-notes-directory)))

(defun iuiw-notes-new ()
  "Create or open a note in the notes inbox."
  (interactive)
  (let ((directory (expand-file-name "notes/" iuiw-notes-directory)))
    (make-directory directory t)
    (find-file (read-file-name "Note: " directory nil nil nil))))

(defun iuiw-notes-daily ()
  "Open today's journal note."
  (interactive)
  (let ((directory (expand-file-name "journals/" iuiw-notes-directory)))
    (make-directory directory t)
    (find-file (expand-file-name (format-time-string "%Y-%m-%d.md") directory))))

(provide 'iuiw-notes)
;;; iuiw-notes.el ends here
