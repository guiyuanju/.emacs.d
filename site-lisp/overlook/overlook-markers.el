;;; overlook-markers.el --- A folder of repos as one project -*- lexical-binding: t; -*-

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

;; A folder holding a file named in `overlook-markers', `.overlook' by
;; default, is one project.el project with every Git repo inside it, so
;; a file in one of its repos belongs to the whole folder rather than to
;; that repo alone.  Turn on `overlook-markers-mode' at startup, as it
;; needs nothing else of overlook.

;;; Code:

(require 'cl-lib)
(require 'project)
(require 'seq)

;; Added in Emacs 30; declare it special for the binding below on Emacs 29.
(defvar project-files-relative-names)

(defcustom overlook-markers '(".overlook")
  "Files marking a folder whose repos together form one project.
The marked folder wins over the repo nearer to a file.  A project of a
single repo needs no marker."
  :type '(repeat string)
  :group 'overlook)

(defun overlook-project-repos (root)
  "ROOT when it is a Git repo, then the Git repos directly inside it."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (append
     (and (file-exists-p (expand-file-name ".git" root)) (list root))
     (seq-filter (lambda (dir) (file-exists-p (expand-file-name ".git" dir)))
                 (mapcar #'file-name-as-directory
                         (seq-filter #'file-directory-p
                                     (directory-files root t "\\`[^.]")))))))

(defvar eglot-lsp-context)

(defun overlook-markers-try (directory)
  "The folder marked by `overlook-markers' above DIRECTORY, as a project.
Symlinks in DIRECTORY are resolved first, so a link into a marked folder
belongs to it.  Eglot is left to the repo, as language servers expect."
  (when-let* (((not (bound-and-true-p eglot-lsp-context)))
              (root (locate-dominating-file
                     (file-truename directory)
                     (lambda (dir)
                       (seq-some (lambda (marker) (file-exists-p (expand-file-name marker dir)))
                                 overlook-markers)))))
    (cons 'overlook (file-name-as-directory (expand-file-name root)))))

(cl-defmethod project-root ((project (head overlook)))
  "The marked folder of PROJECT."
  (cdr project))

(cl-defmethod project-files ((project (head overlook)) &optional dirs)
  "Files of PROJECT, or under DIRS in it.
Each repo's files are those Git lists, then come the files outside repos."
  ;; Relative names from a repo would be relative to that repo, not to PROJECT.
  (let ((project-files-relative-names nil))
    (mapcan (lambda (dir)
              (let ((repos (overlook-project-repos dir)))
                (append
                 (mapcan (lambda (repo) (project-files (project-try-vc repo))) repos)
                 (unless (member (file-name-as-directory (expand-file-name dir)) repos)
                   (directory-files-recursively
                    dir "" nil
                    (lambda (sub) (not (or (member (file-name-as-directory sub) repos)
                                           (equal (file-name-nondirectory sub) ".git")))))))))
            (or dirs (list (project-root project))))))

;;;###autoload
(define-minor-mode overlook-markers-mode
  "Make folders marked by `overlook-markers' project.el projects."
  :global t
  :group 'overlook
  (if overlook-markers-mode
      (add-hook 'project-find-functions #'overlook-markers-try -50)
    (remove-hook 'project-find-functions #'overlook-markers-try)))

(provide 'overlook-markers)
;;; overlook-markers.el ends here
