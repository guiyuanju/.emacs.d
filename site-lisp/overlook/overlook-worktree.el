;;; overlook-worktree.el --- Git worktrees for projects -*- lexical-binding: t; -*-

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

;; Manages a project's checkouts without depending on agents or messaging.
;; A repository gets one Git worktree; a folder of repositories gets a
;; marked folder containing a worktree of each repository.

;;; Code:

(require 'seq)
(require 'subr-x)

(defgroup overlook-worktree nil
  "Git worktrees for projects."
  :group 'overlook
  :prefix "overlook-worktree-")

(defcustom overlook-worktree-directory ".worktrees"
  "Folder, inside a project, holding its worktrees."
  :type 'string
  :group 'overlook-worktree)

(defcustom overlook-worktree-marker ".overlook"
  "File marking a folder of several repos' worktrees as one project."
  :type 'string
  :group 'overlook-worktree)

(defun overlook-worktree-git-program ()
  "The git program to run."
  (or (bound-and-true-p vc-git-program) "git"))

(defun overlook-worktree-git (dir &rest args)
  "Run git with ARGS in DIR; return its output, or signal its error."
  (with-temp-buffer
    (let* ((default-directory (file-name-as-directory dir))
           (status (apply #'process-file (overlook-worktree-git-program) nil t nil args)))
      (unless (eq status 0)
        (user-error "Git %s in %s: %s" (string-join args " ") (abbreviate-file-name dir)
                    (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun overlook-worktree--repo-p (dir)
  "Non-nil when DIR is the top of a Git repo or worktree."
  (file-exists-p (expand-file-name ".git" dir)))

(defun overlook-worktree-repos (dir)
  "DIR when it is a Git repo, else the Git repos directly inside it."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (if (overlook-worktree--repo-p dir)
        (list dir)
      (seq-filter #'overlook-worktree--repo-p
                  (mapcar #'file-name-as-directory
                          (seq-filter #'file-directory-p
                                      (directory-files dir t "\\`[^.]")))))))

(defun overlook-worktree-path (dir branch)
  "Where the worktree of project DIR for BRANCH lies."
  (file-name-as-directory
   (expand-file-name (replace-regexp-in-string "/" "-" branch)
                     (expand-file-name overlook-worktree-directory dir))))

(defun overlook-worktree-at (path)
  "(DIR . NAME) when PATH is a worktree folder of project DIR, else nil.
NAME is as `overlook-worktree-list' gives it."
  (let* ((path (file-name-as-directory (expand-file-name path)))
         (folder (file-name-parent-directory path))
         (inside (file-name-as-directory overlook-worktree-directory))
         (name (file-name-nondirectory (directory-file-name path))))
    (when (and folder (string-suffix-p inside folder))
      (let ((dir (substring folder 0 (- (length inside)))))
        (and (member name (overlook-worktree-list dir))
             (cons dir name))))))

(defun overlook-worktree--exclude (dir)
  "Have the repo holding DIR, if any, leave out the worktrees.
They live in `overlook-worktree-directory'."
  (when-let* ((common (ignore-errors
                        (overlook-worktree-git dir "rev-parse" "--path-format=absolute"
                                               "--git-common-dir"))))
    (let ((file (expand-file-name "info/exclude" common))
          (line (concat overlook-worktree-directory "/")))
      (unless (and (file-exists-p file)
                   (with-temp-buffer
                     (insert-file-contents file)
                     (re-search-forward (concat "^" (regexp-quote line) "$") nil t)))
        (make-directory (file-name-directory file) t)
        (with-temp-buffer
          (when (file-exists-p file) (insert-file-contents file))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert line "\n")
          (write-region nil nil file nil 'silent))))))

(defun overlook-worktree--add-one (repo path branch)
  "Check out BRANCH of REPO at PATH, making the branch when it does not exist."
  (make-directory (file-name-directory (directory-file-name path)) t)
  (if (ignore-errors (overlook-worktree-git repo "rev-parse" "--verify" "--quiet"
                                            (concat "refs/heads/" branch)))
      (overlook-worktree-git repo "worktree" "add" (directory-file-name path) branch)
    (overlook-worktree-git repo "worktree" "add" "-b" branch (directory-file-name path))))

(defun overlook-worktree-add (dir branch)
  "Make the worktree of project DIR for BRANCH and return its path.
An existing one is returned as it is."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (path (overlook-worktree-path dir branch))
         (repos (or (overlook-worktree-repos dir) (user-error "No Git repo in %s" dir))))
    (overlook-worktree-git dir "check-ref-format" "--branch" branch)
    (unless (file-exists-p path)
      (overlook-worktree--exclude dir)
      (if (equal repos (list dir))
          (overlook-worktree--add-one dir path branch)
        (let ((made nil))
          (condition-case err
              (progn
                (make-directory path t)
                (with-temp-file (expand-file-name overlook-worktree-marker path))
                (dolist (repo repos)
                  (let ((sub (file-name-as-directory
                              (expand-file-name (file-name-nondirectory (directory-file-name repo))
                                                path))))
                    (overlook-worktree--add-one repo sub branch)
                    (push (cons repo sub) made))))
            (error
             (pcase-dolist (`(,repo . ,sub) made)
               (ignore-errors (overlook-worktree-git repo "worktree" "remove" "--force"
                                                     (directory-file-name sub))))
             (ignore-errors (delete-directory path t))
             (signal (car err) (cdr err)))))))
    path))

(defun overlook-worktree-remove (dir branch &optional force)
  "Remove the worktree of project DIR for BRANCH, keeping the branch.
Git refuses while a checkout has changes, unless FORCE is non-nil."
  (let ((path (overlook-worktree-path dir branch)))
    (unless (file-directory-p path) (user-error "No worktree %s" (abbreviate-file-name path)))
    (dolist (checkout (overlook-worktree-repos path))
      (apply #'overlook-worktree-git checkout "worktree" "remove"
             (append (and force '("--force")) (list (directory-file-name checkout)))))
    (when (file-directory-p path) (delete-directory path t))
    path))

(defun overlook-worktree-list (dir)
  "Branches with a worktree in project DIR."
  (let ((folder (expand-file-name overlook-worktree-directory dir)))
    (and (file-directory-p folder)
         (mapcar #'file-name-nondirectory
                 (seq-filter #'file-directory-p (directory-files folder t "\\`[^.]"))))))

(provide 'overlook-worktree)
;;; overlook-worktree.el ends here
