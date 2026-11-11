;;; iuiw-remote.el --- Keep Remote available on macOS -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep the Mac awake while Overlook Remote serves, allowing display sleep.

;;; Code:

(require 'system-sleep)

(defvar iuiw-remote--sleep-token nil
  "Token preventing idle system sleep while Remote is enabled.")

(defun iuiw-remote-stop-awake ()
  "Release Remote's idle sleep assertion."
  (when iuiw-remote--sleep-token
    (system-sleep-unblock-sleep iuiw-remote--sleep-token))
  (setq iuiw-remote--sleep-token nil))

(defun iuiw-remote-sync-awake ()
  "Keep macOS awake only while `overlook-remote-mode' is enabled."
  (if (and (eq system-type 'darwin)
           (bound-and-true-p overlook-remote-mode))
      (unless iuiw-remote--sleep-token
        (setq iuiw-remote--sleep-token
              (system-sleep-block-sleep "Overlook Remote" t)))
    (iuiw-remote-stop-awake)))

(provide 'iuiw-remote)
;;; iuiw-remote.el ends here
