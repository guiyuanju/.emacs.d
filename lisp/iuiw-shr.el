;;; iuiw-shr.el --- shr rendering tweaks -*- lexical-binding: t; -*-

;;; Commentary:
;; shr 默认按窗口宽度缩放图片；这里改成按正文宽度（`shr-max-width'），宽窗口里图片
;; 不会比文字宽出一截。

;;; Code:

(require 'shr)

(defun iuiw-shr-text-pixel-width ()
  "Return the pixel width shr fills text to in the selected window."
  (let ((window (window-body-width nil t)))
    (if shr-max-width
        (min window (* shr-max-width (frame-char-width)))
      window)))

(defun iuiw-shr-fit-image-to-text (args)
  "Default the max width in ARGS of `shr-rescale-image' to the text width."
  (pcase-let ((`(,data ,type ,width ,height ,max-width ,max-height) args))
    (list data type width height
          (or max-width
              (and (get-buffer-window (current-buffer) t)
                   (with-selected-window (get-buffer-window (current-buffer) t)
                     ;; shr multiplies the limit by this proportion.
                     (truncate (/ (iuiw-shr-text-pixel-width)
                                  shr-max-image-proportion)))))
          max-height)))

(provide 'iuiw-shr)
;;; iuiw-shr.el ends here
