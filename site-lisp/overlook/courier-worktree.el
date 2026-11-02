;;; courier-worktree.el --- Git worktrees for the agents courier spawns -*- lexical-binding: t; -*-

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

;; Gives a spawned agent a checkout of its own, so agents working at once
;; on one project do not edit the same files.  A worktree for branch B of
;; project DIR lies in DIR/.worktrees/B: a Git worktree when DIR is a
;; repo, else a folder holding a worktree of each repo in DIR and a
;; `.overlook' file marking it one project.  The branch is made from the
;; checked out commit unless it exists.  `.worktrees/' goes in the repo's
;; info/exclude, so Git leaves it out of the status.
;; `courier-worktree-spawn' starts an agent in one, following the room
;; named after the branch, where events about it go; removing the
;; worktree closes that room.

;;; Code:

(require 'courier)
(require 'courier-room)

(defcustom courier-worktree-directory ".worktrees"
  "Folder, inside a project, holding the worktrees made for its agents."
  :type 'string
  :group 'courier)

(defcustom courier-worktree-marker ".overlook"
  "File marking a folder of several repos' worktrees as one project."
  :type 'string
  :group 'courier)

(defun courier-worktree-git-program ()
  "The git program to run."
  (or (bound-and-true-p vc-git-program) "git"))

(defun courier-worktree--git (dir &rest args)
  "Run git with ARGS in DIR; return its output, or signal its error."
  (with-temp-buffer
    (let* ((default-directory (file-name-as-directory dir))
           (status (apply #'process-file (courier-worktree-git-program) nil t nil args)))
      (unless (eq status 0)
        (user-error "Git %s in %s: %s" (string-join args " ") (abbreviate-file-name dir)
                    (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun courier-worktree--repo-p (dir)
  "Non-nil when DIR is the top of a Git repo or worktree."
  (file-exists-p (expand-file-name ".git" dir)))

(defun courier-worktree-repos (dir)
  "DIR when it is a Git repo, else the Git repos directly inside it."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (if (courier-worktree--repo-p dir)
        (list dir)
      (seq-filter #'courier-worktree--repo-p
                  (mapcar #'file-name-as-directory
                          (seq-filter #'file-directory-p
                                      (directory-files dir t "\\`[^.]")))))))

(defun courier-worktree-path (dir branch)
  "Where the worktree of project DIR for BRANCH lies."
  (file-name-as-directory
   (expand-file-name (replace-regexp-in-string "/" "-" branch)
                     (expand-file-name courier-worktree-directory dir))))

(defun courier-worktree--exclude (dir)
  "Have the repo holding DIR, if any, leave out `courier-worktree-directory'."
  (when-let* ((common (ignore-errors
                        (courier-worktree--git dir "rev-parse" "--path-format=absolute"
                                               "--git-common-dir"))))
    (let ((file (expand-file-name "info/exclude" common))
          (line (concat courier-worktree-directory "/")))
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

(defun courier-worktree--add-one (repo path branch)
  "Check out BRANCH of REPO at PATH, making the branch when it does not exist."
  (make-directory (file-name-directory (directory-file-name path)) t)
  (if (ignore-errors (courier-worktree--git repo "rev-parse" "--verify" "--quiet"
                                            (concat "refs/heads/" branch)))
      (courier-worktree--git repo "worktree" "add" (directory-file-name path) branch)
    (courier-worktree--git repo "worktree" "add" "-b" branch (directory-file-name path))))

(defun courier-worktree-add (dir branch)
  "Make the worktree of project DIR for BRANCH and return its path.
An existing one is returned as it is."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (path (courier-worktree-path dir branch))
         (repos (or (courier-worktree-repos dir) (user-error "No Git repo in %s" dir))))
    (courier-worktree--git dir "check-ref-format" "--branch" branch)
    (unless (file-exists-p path)
      (courier-worktree--exclude dir)
      (if (equal repos (list dir))
          (courier-worktree--add-one dir path branch)
        (let ((made nil))
          (condition-case err
              (progn
                (make-directory path t)
                (with-temp-file (expand-file-name courier-worktree-marker path))
                (dolist (repo repos)
                  (let ((sub (file-name-as-directory
                              (expand-file-name (file-name-nondirectory (directory-file-name repo))
                                                path))))
                    (courier-worktree--add-one repo sub branch)
                    (push (cons repo sub) made))))
            (error
             (pcase-dolist (`(,repo . ,sub) made)
               (ignore-errors (courier-worktree--git repo "worktree" "remove" "--force"
                                                     (directory-file-name sub))))
             (ignore-errors (delete-directory path t))
             (signal (car err) (cdr err)))))))
    path))

(defun courier-worktree-spawn (name dir branch prompt &optional from effort)
  "Start agent NAME in the worktree of project DIR for BRANCH, made if missing.
It works on PROMPT for agent FROM at reasoning EFFORT, as `courier-spawn'
starts it, and every post in the room named after BRANCH wakes it.
Returns its id."
  (let* ((path (courier-worktree-add dir branch))
         (room (courier-room-name-for branch))
         (note (format "You work in a Git worktree of your own, %s, on branch %s; \
commit your work there, and leave the main checkout alone.  Events about \
the branch, such as CI results, reach you from the room #%s."
                       (abbreviate-file-name path) branch room))
         (id (courier-spawn name path (and prompt (concat note "\n\n" prompt)) from effort)))
    (courier-room-join room id 'all)
    (unless prompt (courier-note id note))
    id))

(defun courier-worktree-remove (dir branch &optional force)
  "Remove the worktree of project DIR for BRANCH, keeping the branch.
Git refuses while a checkout has changes, unless FORCE is non-nil.  The
room named after the branch is closed."
  (let ((path (courier-worktree-path dir branch)))
    (unless (file-directory-p path) (user-error "No worktree %s" (abbreviate-file-name path)))
    (dolist (checkout (courier-worktree-repos path))
      (apply #'courier-worktree--git checkout "worktree" "remove"
             (append (and force '("--force")) (list (directory-file-name checkout)))))
    (when (file-directory-p path) (delete-directory path t))
    (let ((room (courier-room-name-for branch)))
      (when (courier-room room) (courier-room-close room)))
    path))

(defun courier-worktree-list (dir)
  "Branches with a worktree in project DIR."
  (let ((folder (expand-file-name courier-worktree-directory dir)))
    (and (file-directory-p folder)
         (mapcar #'file-name-nondirectory
                 (seq-filter #'file-directory-p (directory-files folder t "\\`[^.]"))))))

(defun courier-worktree-cli (args)
  "Run the worktree command ARGS and return its output."
  (pcase args
    (`("add" ,dir ,branch)
     (format "Worktree for %s at %s." branch (abbreviate-file-name (courier-worktree-add dir branch))))
    ((or `("remove" ,dir ,branch) `("remove" "--force" ,dir ,branch))
     (courier-worktree-remove dir branch (equal (cadr args) "--force"))
     (format "Removed the worktree of %s; the branch is kept." branch))
    (`("list" ,dir)
     (courier-or-empty (mapconcat (lambda (name)
                      (format "%s  %s" name (abbreviate-file-name (courier-worktree-path dir name))))
                    (courier-worktree-list dir) "\n")
         "No worktrees."))
    (_ (user-error "Usage: courier worktree add DIR BRANCH | remove [--force] DIR BRANCH | list DIR"))))

(provide 'courier-worktree)
;;; courier-worktree.el ends here
