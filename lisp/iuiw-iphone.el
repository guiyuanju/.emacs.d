;;; iuiw-iphone.el --- Install Xcode projects on the iPhone -*- lexical-binding: t; -*-

;;; Commentary:
;; Offers "Install on iPhone" on the Overlook heading of every Xcode project,
;; driving iuiw-iphone.py, which agents can also run themselves.

;;; Code:

(require 'overlook)

(defconst iuiw-iphone--script
  (expand-file-name "iuiw-iphone.py" (file-name-directory (or load-file-name buffer-file-name)))
  "The script that builds and installs.")

(defvar iuiw-iphone--status (make-hash-table :test #'equal)
  "Map a perspective name to its install's state: `running' or `failed'.")

(defun iuiw-iphone--project (perspective)
  "The Xcode project in PERSPECTIVE's root or a repository right under it."
  (when-let* ((root (overlook-perspective-root perspective)))
    (car (or (file-expand-wildcards (expand-file-name "*.xcodeproj" root))
             (file-expand-wildcards (expand-file-name "*/*.xcodeproj" root))))))

(defun iuiw-iphone--finish (perspective process)
  "Record how PROCESS, installing PERSPECTIVE's project, ended."
  (when (memq (process-status process) '(exit signal))
    (if (zerop (process-exit-status process))
        (remhash perspective iuiw-iphone--status)
      (puthash perspective 'failed iuiw-iphone--status))
    (message "iPhone install of %s: %s" perspective
             (if (zerop (process-exit-status process)) "done" "failed, see *iphone-install*"))
    (overlook-refresh)))

(defun iuiw-iphone-install (perspective)
  "Build PERSPECTIVE's Xcode project and install it on the iPhone."
  (interactive (list (persp-current-name)))
  (let ((project (or (iuiw-iphone--project perspective)
                     (user-error "No Xcode project in %s" perspective))))
    (when (eq (gethash perspective iuiw-iphone--status) 'running)
      (user-error "Already installing %s" perspective))
    (puthash perspective 'running iuiw-iphone--status)
    (make-process
     :name "iphone-install"
     :buffer (get-buffer-create "*iphone-install*")
     :command (list "python3" "-I" iuiw-iphone--script "deploy" project)
     :noquery t
     :sentinel (lambda (process _event) (iuiw-iphone--finish perspective process)))
    nil))

(defun iuiw-iphone--command (perspective)
  "A command installing PERSPECTIVE's Xcode project, if it has one."
  (when (iuiw-iphone--project perspective)
    (list (list :name "install-iphone" :label "Install on iPhone"
                :run (lambda () (iuiw-iphone-install perspective))))))

(defun iuiw-iphone--mark (perspective)
  "How PERSPECTIVE's install stands, shown beside its heading."
  (pcase (gethash perspective iuiw-iphone--status)
    ('running " installing")
    ('failed " install failed")))

(provide 'iuiw-iphone)
;;; iuiw-iphone.el ends here
