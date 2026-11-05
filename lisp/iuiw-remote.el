;;; iuiw-remote.el --- Keep Remote available on macOS -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep the Mac awake while Overlook Remote serves, allowing display sleep.

;;; Code:

(defvar iuiw-remote--awake-process nil
  "Process preventing idle system sleep while Remote is enabled.")

(defun iuiw-remote-stop-awake ()
  "Release Remote's idle sleep assertion."
  (when (process-live-p iuiw-remote--awake-process)
    (delete-process iuiw-remote--awake-process))
  (setq iuiw-remote--awake-process nil))

(defun iuiw-remote-sync-awake ()
  "Keep macOS awake only while `overlook-remote-mode' is enabled."
  (if (and (eq system-type 'darwin)
           (bound-and-true-p overlook-remote-mode))
      (unless (process-live-p iuiw-remote--awake-process)
        (setq iuiw-remote--awake-process
              (make-process
               :name "overlook-remote-awake"
               :command (list "/usr/bin/caffeinate" "-i" "-w"
                              (number-to-string (emacs-pid)))
               :connection-type 'pipe :noquery t)))
    (iuiw-remote-stop-awake)))

(provide 'iuiw-remote)
;;; iuiw-remote.el ends here
