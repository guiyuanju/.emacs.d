;;; jgy-perspective.el --- Buffer history per perspective -*- lexical-binding: t; -*-

;;; Commentary:
;; frame 的 buffer-list 是全局的使用顺序，跨 perspective 共享的 buffer 会被别处的使用顶到前面；
;; 所以每个 perspective 自己记录 buffer 的使用顺序，`jgy-last-buffer' 据此切回上一个 buffer。

;;; Code:

(require 'seq)

(declare-function persp-current-name "perspective")
(declare-function persp-current-buffers "perspective")
(declare-function persp-other-buffer "perspective")

(defvar jgy-persp-history (make-hash-table :test #'equal)
  "Perspective name to its buffers, most recently selected first.")

(defvar jgy-persp--renaming nil
  "Name of the perspective being renamed.")

(defun jgy-persp-record (&rest _)
  "Move the selected window's buffer to the front of this perspective's history."
  (when (bound-and-true-p persp-mode)
    (let ((buffer (window-buffer (selected-window)))
          (name (persp-current-name)))
      (unless (or (minibufferp buffer) (string-prefix-p " " (buffer-name buffer)))
        (puthash name (cons buffer (seq-filter (lambda (b) (and (buffer-live-p b) (not (eq b buffer))))
                                               (gethash name jgy-persp-history)))
                 jgy-persp-history)))))

(defun jgy-persp--before-rename ()
  "Remember the name of the perspective about to be renamed."
  (setq jgy-persp--renaming (persp-current-name)))

(defun jgy-persp--after-rename ()
  "Move the history of the renamed perspective to its new name."
  (when jgy-persp--renaming
    (when-let* ((buffers (gethash jgy-persp--renaming jgy-persp-history)))
      (puthash (persp-current-name) buffers jgy-persp-history))
    (remhash jgy-persp--renaming jgy-persp-history)
    (setq jgy-persp--renaming nil)))

(defun jgy-persp--forget ()
  "Drop the history of the perspective being killed."
  (remhash (persp-current-name) jgy-persp-history))

(defun jgy-last-buffer ()
  "Switch to the most recently used other buffer of this perspective.
Without `persp-mode', switch to the other buffer of the frame."
  (interactive)
  (switch-to-buffer
   (if (bound-and-true-p persp-mode)
       (let ((buffers (persp-current-buffers)))
         (or (seq-find (lambda (b) (and (buffer-live-p b) (not (eq b (current-buffer))) (memq b buffers)))
                       (gethash (persp-current-name) jgy-persp-history))
             (persp-other-buffer (current-buffer))))
     (other-buffer (current-buffer) t))))

;;;###autoload
(define-minor-mode jgy-persp-history-mode
  "Record each perspective's buffer history for `jgy-last-buffer'."
  :global t
  :group 'convenience
  (let ((hooks '((window-buffer-change-functions . jgy-persp-record)
                 (window-selection-change-functions . jgy-persp-record)
                 (persp-before-rename-hook . jgy-persp--before-rename)
                 (persp-after-rename-hook . jgy-persp--after-rename)
                 (persp-killed-hook . jgy-persp--forget))))
    (pcase-dolist (`(,hook . ,fn) hooks)
      (if jgy-persp-history-mode (add-hook hook fn) (remove-hook hook fn)))))

(provide 'jgy-perspective)
;;; jgy-perspective.el ends here
