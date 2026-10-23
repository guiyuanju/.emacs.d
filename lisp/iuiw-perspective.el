;;; iuiw-perspective.el --- Buffer history per perspective -*- lexical-binding: t; -*-

;;; Commentary:
;; frame 的 buffer-list 是全局的使用顺序，跨 perspective 共享的 buffer 会被别处的使用顶到前面；
;; 所以每个 perspective 自己记录 buffer 的使用顺序，`iuiw-last-buffer' 据此切回上一个 buffer。

;;; Code:

(require 'perspective)

(defvar iuiw-persp-history (make-hash-table :test #'equal)
  "Perspective name to its buffers, most recently selected first.")

(defvar iuiw-persp--renaming nil
  "Name of the perspective being renamed.")

(defun iuiw-persp-record (&rest _)
  "Move the selected window's buffer to the front of this perspective's history."
  (when (bound-and-true-p persp-mode)
    (let ((buffer (window-buffer (selected-window)))
          (name (persp-current-name)))
      (unless (or (minibufferp buffer) (string-prefix-p " " (buffer-name buffer)))
        (puthash name (cons buffer (seq-filter (lambda (b) (and (buffer-live-p b) (not (eq b buffer))))
                                               (gethash name iuiw-persp-history)))
                 iuiw-persp-history)))))

(defun iuiw-persp--before-rename ()
  "Remember the name of the perspective about to be renamed."
  (setq iuiw-persp--renaming (persp-current-name)))

(defun iuiw-persp--after-rename ()
  "Move the history of the renamed perspective to its new name."
  (when iuiw-persp--renaming
    (when-let* ((buffers (gethash iuiw-persp--renaming iuiw-persp-history)))
      (puthash (persp-current-name) buffers iuiw-persp-history))
    (remhash iuiw-persp--renaming iuiw-persp-history)
    (setq iuiw-persp--renaming nil)))

(defun iuiw-persp--forget ()
  "Drop the history of the perspective being killed."
  (remhash (persp-current-name) iuiw-persp-history))

(defun iuiw-last-buffer ()
  "Switch to the most recently used other buffer of this perspective.
Without `persp-mode', switch to the other buffer of the frame."
  (interactive)
  (switch-to-buffer
   (if (bound-and-true-p persp-mode)
       (let ((buffers (persp-current-buffers)))
         (or (seq-find (lambda (b) (and (buffer-live-p b) (not (eq b (current-buffer))) (memq b buffers)))
                       (gethash (persp-current-name) iuiw-persp-history))
             (persp-other-buffer (current-buffer))))
     (other-buffer (current-buffer) t))))

;; 恢复 magit-status 要对每个仓库跑一遍 git，拖慢启动。
(defun iuiw-persp-kill-magit-status ()
  "Kill magit-status buffers so `persp-state-save' does not record them."
  (dolist (buffer (buffer-list))
    (when (eq (buffer-local-value 'major-mode buffer) 'magit-status-mode)
      (kill-buffer buffer))))

;; `persp-state-load' 为保存的每个额外 frame 新建一个 frame，屏幕外的 frame 会因此代代相传，
;; perspective 可能恢复进去；多 frame 时它的临时 perspective 也删不掉。所以只存当前 frame。
(defun iuiw-persp-save-selected-frame (save &rest args)
  "Call SAVE with ARGS, saving only the selected frame's perspectives."
  (let ((frame (selected-frame)))
    (cl-letf (((symbol-function 'frame-list) (lambda () (list frame))))
      (apply save args))))

;; `persp-state-load' 依次恢复各 perspective，看板的 side window 会在之后的布局里
;; 变成普通窗口，显示 *scratch*。
(defun iuiw-persp-delete-stray-side-windows ()
  "Delete windows dedicated as side windows that are not side windows."
  (dolist (name (persp-names))
    (with-perspective name
      (dolist (window (window-list nil 'nomini))
        (when (and (eq (window-dedicated-p window) 'side)
                   (not (window-parameter window 'window-side)))
          (if (window-parent window)
              (delete-window window)
            (set-window-dedicated-p window nil)))))))

;;;###autoload
(define-minor-mode iuiw-persp-history-mode
  "Record each perspective's buffer history for `iuiw-last-buffer'."
  :global t
  :group 'convenience
  (let ((hooks '((window-buffer-change-functions . iuiw-persp-record)
                 (window-selection-change-functions . iuiw-persp-record)
                 (persp-before-rename-hook . iuiw-persp--before-rename)
                 (persp-after-rename-hook . iuiw-persp--after-rename)
                 (persp-killed-hook . iuiw-persp--forget))))
    (pcase-dolist (`(,hook . ,fn) hooks)
      (if iuiw-persp-history-mode (add-hook hook fn) (remove-hook hook fn)))))

(provide 'iuiw-perspective)
;;; iuiw-perspective.el ends here
