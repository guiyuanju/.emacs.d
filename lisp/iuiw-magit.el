;;; iuiw-magit.el --- Magit window layout and synchronous push -*- lexical-binding: t; -*-

;;; Commentary:
;; 在 magit 默认的 fullframe-status-topleft 布局上，把 diff 左边留下的窗口收窄。
;; `iuiw-magit-push' 让 agent 经 emacsclient 推送：提示照常在 Emacs 里处理，结果看退出码。

;;; Code:

(require 'magit-mode)
(require 'magit-process)

(defcustom iuiw-magit-side-window-width 0.25
  "Width of the window left beside a diff, as a fraction of the frame."
  :type 'float
  :group 'magit)

(defcustom iuiw-magit-push-timeout 300
  "Seconds `iuiw-magit-push' waits before giving up."
  :type 'natnum
  :group 'magit)

(defun iuiw-magit--display-buffer-topleft (buffer alist)
  "Like `magit--display-buffer-topleft', narrowing the window pushed right.
Only a fresh split is resized; `window-width' in ALIST would also resize
the diff window each time it is reused."
  (let* ((windows (count-windows))
         (window (magit--display-buffer-topleft buffer alist)))
    (when (and window (> (count-windows) windows))
      (let ((side (selected-window)))
        (window-resize side (- (round (* iuiw-magit-side-window-width
                                         (frame-width (window-frame side))))
                               (window-total-width side))
                       t t)))
    window))

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
          '(iuiw-magit--display-buffer-topleft))
         ('(display-buffer-same-window)))))

(defun iuiw-magit--process-output (process)
  "Return the output Magit logged for PROCESS."
  (let ((section (process-get process 'section)))
    (with-current-buffer (process-buffer process)
      (string-trim (buffer-substring-no-properties (oref section content)
                                                   (oref section end))))))

(defun iuiw-magit-push (directory &rest args)
  "Run git push ARGS in DIRECTORY through Magit and wait until it ends.
Prompts are answered as in an interactive push.  Return git's output;
signal an error with it if the push fails or exceeds
`iuiw-magit-push-timeout', so `emacsclient --eval' exits non-zero."
  (let* ((default-directory (file-name-as-directory (expand-file-name directory)))
         (process (apply #'magit-run-git-async "push" args))
         (deadline (+ (float-time) iuiw-magit-push-timeout)))
    (while (and (process-live-p process) (< (float-time) deadline))
      (accept-process-output process 0.1))
    (when (process-live-p process)
      (delete-process process)
      (error "git push timed out after %ds" iuiw-magit-push-timeout))
    (let ((output (iuiw-magit--process-output process)))
      (unless (zerop (process-exit-status process))
        (error "git push failed:\n%s" output))
      output)))

(provide 'iuiw-magit)
;;; iuiw-magit.el ends here
