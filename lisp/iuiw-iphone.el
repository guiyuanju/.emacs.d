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
  "Map a project name to its install's state: `running' or `failed'.")

(defun iuiw-iphone--xcodeproj (project)
  "The Xcode project in PROJECT's root or a repository right under it."
  (when-let* ((root (overlook-project-root project)))
    (car (or (file-expand-wildcards (expand-file-name "*.xcodeproj" root))
             (file-expand-wildcards (expand-file-name "*/*.xcodeproj" root))))))

(defun iuiw-iphone--finish (project process)
  "Record how PROCESS, installing PROJECT's Xcode project, ended."
  (when (memq (process-status process) '(exit signal))
    (if (zerop (process-exit-status process))
        (remhash project iuiw-iphone--status)
      (puthash project 'failed iuiw-iphone--status))
    (message "iPhone install of %s: %s" project
             (if (zerop (process-exit-status process)) "done" "failed, see *iphone-install*"))
    (overlook-refresh)))

(defun iuiw-iphone-install (project)
  "Build PROJECT's Xcode project and install it on the iPhone."
  (interactive (list (overlook-current-project)))
  (let ((xcodeproj (or (iuiw-iphone--xcodeproj project)
                       (user-error "No Xcode project in %s" project))))
    (when (eq (gethash project iuiw-iphone--status) 'running)
      (user-error "Already installing %s" project))
    (puthash project 'running iuiw-iphone--status)
    (make-process
     :name "iphone-install"
     :buffer (get-buffer-create "*iphone-install*")
     :command (list "python3" "-I" iuiw-iphone--script "deploy" xcodeproj)
     :noquery t
     :sentinel (lambda (process _event) (iuiw-iphone--finish project process)))
    nil))

(defun iuiw-iphone--command (project)
  "A command installing PROJECT's Xcode project, if it has one."
  (when (iuiw-iphone--xcodeproj project)
    (list (list :name "install-iphone" :label "Install on iPhone"
                :run (lambda () (iuiw-iphone-install project))))))

(defun iuiw-iphone--mark (project)
  "How PROJECT's install stands, shown beside its heading."
  (pcase (gethash project iuiw-iphone--status)
    ('running " installing")
    ('failed " install failed")))

(provide 'iuiw-iphone)
;;; iuiw-iphone.el ends here
