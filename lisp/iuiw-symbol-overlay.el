;;; iuiw-symbol-overlay.el --- Project-wide symbol-overlay highlights -*- lexical-binding: t; -*-

;;; Commentary:
;; symbol-overlay 只高亮当前 buffer；这里让同一项目的文件 buffer 共用一组高亮，
;; 之后打开的文件也会带上。

;;; Code:

(require 'project)
(require 'seq)
(require 'symbol-overlay)

(defun iuiw-symbol-overlay--project-buffers ()
  "Live file buffers of the current project other than this one."
  (when-let* ((project (project-current)))
    (seq-filter (lambda (buffer)
                  (and (buffer-file-name buffer) (not (eq buffer (current-buffer)))))
                (project-buffers project))))

(defun iuiw-symbol-overlay--apply (keywords)
  "Make the current buffer highlight exactly KEYWORDS, keeping their faces."
  (symbol-overlay-remove-all)
  (dolist (keyword (reverse keywords))
    (symbol-overlay-put-all (car keyword) nil keyword)))

;;;###autoload
(defun iuiw-symbol-overlay-put ()
  "Toggle the highlight of the symbol at point in every file of the project."
  (interactive)
  (symbol-overlay-put)
  (let ((keywords symbol-overlay-keywords-alist))
    (dolist (buffer (iuiw-symbol-overlay--project-buffers))
      (with-current-buffer buffer
        (iuiw-symbol-overlay--apply keywords)))))

(defun iuiw-symbol-overlay-inherit ()
  "Highlight the symbols the project's other buffers already highlight."
  (when-let* ((source (seq-find (lambda (buffer)
                                  (buffer-local-value 'symbol-overlay-keywords-alist buffer))
                                (iuiw-symbol-overlay--project-buffers))))
    (iuiw-symbol-overlay--apply
     (buffer-local-value 'symbol-overlay-keywords-alist source))))

(provide 'iuiw-symbol-overlay)
;;; iuiw-symbol-overlay.el ends here
