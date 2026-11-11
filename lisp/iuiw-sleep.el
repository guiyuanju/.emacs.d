;;; iuiw-sleep.el --- Sleep controls and Emacs status -*- lexical-binding: t; -*-

;;; Commentary:
;; Use system-sleep tokens for independent requests; display only Emacs-owned requests.

;;; Code:

(require 'system-sleep)
(require 'subr-x)
(require 'nerd-icons)

(declare-function overlook-mode-line-icon "overlook-row" (name fallback &optional face))

(defvar iuiw-sleep--token nil "Manual sleep block token.")

(define-minor-mode iuiw-sleep-mode
  "Prevent idle system sleep while allowing the display to sleep."
  :global t :group 'system-sleep
  (if iuiw-sleep-mode
      (unless iuiw-sleep--token
        (setq iuiw-sleep--token (system-sleep-block-sleep "Emacs manual" t))
        (unless iuiw-sleep--token
          (setq iuiw-sleep-mode nil)
          (user-error "System sleep blocking unavailable")))
    (when iuiw-sleep--token
      (system-sleep-unblock-sleep iuiw-sleep--token)
      (setq iuiw-sleep--token nil)))
  (iuiw-sleep-refresh))

(defun iuiw-sleep-refresh ()
  "Refresh the display after an Emacs sleep request changes."
  (force-mode-line-update t))

(defun iuiw-sleep--changed (&rest _)
  "Refresh after an Emacs sleep request changes."
  (iuiw-sleep-refresh))

(defun iuiw-sleep--owners ()
  "Return the reasons for Emacs-owned sleep requests."
  (let ((owners
         (mapcar
          (lambda (token)
            (let ((why (plist-get token :why)))
              (or (cdr (assoc why '(("Emacs manual" . "Manual")
                                    ("Overlook Remote" . "Remote")
                                    ("Overlook continuation" . "Agent continuation")
                                    ("agent-shell (agent busy)" . "Agent"))))
                  why "Emacs")))
          system-sleep--sleep-block-tokens)))
    (dolist (entry '((iuiw-remote--awake-process . "Remote")
                     (overlook-agent-resume--awake . "Agent continuation")))
      (when (and (boundp (car entry))
                 (processp (symbol-value (car entry)))
                 (process-live-p (symbol-value (car entry))))
        (push (cdr entry) owners)))
    (delete-dups owners)))

(defun iuiw-sleep-mode-line ()
  "Return Emacs sleep status for the Overlook mode line."
  (when (eq system-type 'darwin)
    (let* ((owners (iuiw-sleep--owners))
           (active (and owners t)))
      (propertize (overlook-mode-line-icon "nf-cod-coffee" "awake"
                                           (if active 'warning 'shadow))
                  'help-echo (if active
                                 (concat "Emacs awake: " (string-join owners ", "))
                               "Emacs is not preventing sleep.")))))

(advice-add 'system-sleep-block-sleep :after #'iuiw-sleep--changed)
(advice-add 'system-sleep-unblock-sleep :after #'iuiw-sleep--changed)

(iuiw-sleep-refresh)

(provide 'iuiw-sleep)
;;; iuiw-sleep.el ends here
