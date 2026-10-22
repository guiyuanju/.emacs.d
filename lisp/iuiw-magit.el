;;; iuiw-magit.el --- Magit window layout -*- lexical-binding: t; -*-

;;; Commentary:
;; 在 magit 默认的 fullframe-status-topleft 布局上，把 diff 左边留下的窗口收窄。

;;; Code:

(require 'magit-mode)

(defcustom iuiw-magit-side-window-width 0.35
  "Width of the window left beside a diff, as a fraction of the frame."
  :type 'float
  :group 'magit)

(defun iuiw-magit-display-buffer (buffer)
  "Display BUFFER like `magit-display-buffer-fullframe-status-topleft-v1'.
When a diff splits the frame side by side, the log or status window it
pushes to the right gets `iuiw-magit-side-window-width'."
  (display-buffer
   buffer
   (cond ((eq (buffer-local-value 'major-mode buffer) 'magit-status-mode)
          '(magit--display-buffer-fullframe))
         ((with-current-buffer buffer
            (derived-mode-p 'magit-diff-mode 'magit-process-mode))
          `(magit--display-buffer-topleft
            (window-width . ,iuiw-magit-side-window-width)))
         ('(display-buffer-same-window)))))

(provide 'iuiw-magit)
;;; iuiw-magit.el ends here
