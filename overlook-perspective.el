;;; overlook-perspective.el --- Perspective.el backend for overlook -*- lexical-binding: t; -*-

;;; Commentary:

;; Makes each perspective.el perspective an overlook perspective.  Its
;; project root is guessed from the projects of its buffers, unless
;; `overlook-perspective-root' says otherwise.
;; `overlook-perspective-open-project' opens a project.el project in a
;; perspective named after it.

;;; Code:

(require 'overlook)
(require 'perspective)
(require 'project)

(defcustom overlook-perspective-root #'overlook-perspective-guess-root
  "Function of a perspective NAME returning its project root, or nil."
  :type 'function
  :group 'overlook)

(defun overlook-perspective-guess-root (name)
  "Root of the project of the first file or Dired buffer in perspective NAME."
  (seq-some (lambda (buffer)
              (when (or (buffer-file-name buffer)
                        (eq (buffer-local-value 'major-mode buffer) 'dired-mode))
                (when-let* ((project (project-current
                                      nil (buffer-local-value 'default-directory buffer))))
                  (project-root project))))
            (overlook-perspective-buffers name)))

(defun overlook-perspective--current ()
  (and (bound-and-true-p persp-mode) (persp-current-name)))

(defun overlook-perspective--names ()
  (and (bound-and-true-p persp-mode) (persp-names)))

;;;###autoload
(defun overlook-perspective-open-project (directory)
  "Switch to the perspective of the project in DIRECTORY, named after it.
A new perspective opens the project's root in Dired."
  (interactive (list (project-prompt-project-dir)))
  (let* ((project (project-current nil directory))
         (name (if project (project-name project)
                 (file-name-nondirectory (directory-file-name directory))))
         (new (not (member name (persp-names)))))
    (overlook-switch-perspective name)
    (when new (dired (if project (project-root project) directory)))))

;;;###autoload
(define-minor-mode overlook-perspective-mode
  "Let overlook show perspective.el's perspectives."
  :global t
  :group 'overlook
  (if overlook-perspective-mode
      (progn
        (setq overlook-perspectives-function #'overlook-perspective--names
              overlook-current-perspective-function #'overlook-perspective--current
              overlook-switch-perspective-function #'persp-switch
              overlook-perspective-buffers-function #'persp-get-buffers
              overlook-perspective-root-function
              (lambda (name) (funcall overlook-perspective-root name)))
        (add-hook 'persp-switch-hook #'overlook-perspective-switched)
        (dolist (hook '(persp-created-hook persp-killed-hook persp-after-rename-hook))
          (add-hook hook #'overlook-refresh)))
    (setq overlook-perspectives-function #'ignore
          overlook-current-perspective-function #'ignore
          overlook-switch-perspective-function #'ignore
          overlook-perspective-buffers-function #'ignore
          overlook-perspective-root-function #'ignore)
    (remove-hook 'persp-switch-hook #'overlook-perspective-switched)
    (dolist (hook '(persp-created-hook persp-killed-hook persp-after-rename-hook))
      (remove-hook hook #'overlook-refresh))))

(provide 'overlook-perspective)
;;; overlook-perspective.el ends here
