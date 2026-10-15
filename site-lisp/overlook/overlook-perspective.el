;;; overlook-perspective.el --- Perspective.el backend for overlook -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
;; URL: https://github.com/guiyuanju/overlook
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
  "Name of the current perspective, or nil without `persp-mode'."
  (and (bound-and-true-p persp-mode) (persp-current-name)))

(defun overlook-perspective--names ()
  "Names of all perspectives, or nil without `persp-mode'."
  (and (bound-and-true-p persp-mode) (persp-names)))

(defun overlook-perspective--root (name)
  "Project root of perspective NAME, per `overlook-perspective-root'."
  (funcall overlook-perspective-root name))

(defun overlook-perspective--add-buffer (name buffer)
  "Add BUFFER to perspective NAME."
  (if (equal name (persp-current-name))
      (persp-add-buffer buffer)
    (with-perspective name (persp-add-buffer buffer))))

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
  (pcase-dolist (`(,variable . ,function)
                 '((overlook-perspectives-function . overlook-perspective--names)
                   (overlook-current-perspective-function . overlook-perspective--current)
                   (overlook-switch-perspective-function . persp-switch)
                   (overlook-perspective-buffers-function . persp-get-buffers)
                   (overlook-add-to-perspective-function . overlook-perspective--add-buffer)
                   (overlook-perspective-root-function . overlook-perspective--root)))
    (set variable (if overlook-perspective-mode function #'ignore)))
  (overlook-toggle-hooks
   overlook-perspective-mode
   '((persp-switch-hook overlook-perspective-switched)
     (persp-created-hook overlook-refresh)
     (persp-killed-hook overlook-refresh)
     (persp-after-rename-hook overlook-refresh))))

(provide 'overlook-perspective)
;;; overlook-perspective.el ends here
