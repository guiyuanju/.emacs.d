;;; overlook-agent-worktree.el --- Agents in project worktrees -*- lexical-binding: t; -*-

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

;; Starts agents in worktrees of a project.  `overlook-agent-worktree'
;; makes the worktree from the keyboard; on the dashboard `w' does so for
;; the row's project, or for the task of a row that
;; `overlook-agent-worktree-task-functions' knows, and `a' starts another
;; agent in the row's checkout.

;;; Code:

(require 'magit-section)
(require 'overlook)
(require 'overlook-agent)
(require 'overlook-worktree)

(defvar overlook-agent-worktree-task-functions nil
  "Functions telling the task a dashboard row stands for.
Each is called with the row's id and returns nil or a plist:
  :project  the project the task belongs to, else the row's;
  :branch   a branch name to offer;
  :prompt   a function of the agent's root giving its prompt, left unsent;
  :started  a function called with the branch once the agent started.")

(defun overlook-agent-worktree-read-branch (dir &optional initial)
  "Read a branch of project DIR for an agent, starting with INITIAL.
Offered are those of its main checkout and those a worktree can check out."
  (let* ((repo (car (or (overlook-worktree-repos dir) (user-error "No Git repo in %s" dir))))
         (main (seq-filter (lambda (branch) (overlook-worktree-main-checkout-p dir branch))
                           (overlook-worktree--refs repo "refs/heads")))
         (branch (string-trim (completing-read "Branch: "
                                               (delete-dups
                                                (append main (overlook-worktree-free-branches dir)))
                                               nil nil initial))))
    (when (string-empty-p branch) (user-error "No branch given"))
    branch))

(defun overlook-agent-worktree--start-in (project root name)
  "Start agent NAME in ROOT as one of PROJECT, and return its buffer.
Its frontend may offer to resume a past session there."
  (when project (overlook-ensure-project project))
  (let ((overlook-agent-starting-project project))
    (overlook-agent-start name root)))

(defun overlook-agent-worktree-start (project dir branch name &optional prompt)
  "Start agent NAME in the worktree of project DIR for BRANCH, made if missing.
A new branch starts at the remote's default branch.  A branch of DIR's
main checkout has the agent start there instead.  The agent belongs to
PROJECT; PROMPT, a function of its root, gives text left unsent at its
prompt.  Shows the agent and returns its buffer."
  (let* ((path (if (overlook-worktree-main-checkout-p dir branch)
                   (file-name-as-directory (expand-file-name dir))
                 (overlook-worktree-add dir branch 'default)))
         (buffer (overlook-agent-worktree--start-in project path name)))
    (when prompt (overlook-agent-call buffer 'insert (funcall prompt path)))
    (overlook-show-elsewhere project (lambda () (overlook-agent-show buffer)))
    buffer))

(defun overlook-agent-worktree--current ()
  "(PROJECT . DIR) of the current project, DIR its main checkout."
  (let ((project (overlook-current-project)))
    (cons project (or (and project (overlook-project-root project))
                      (overlook-worktree--project)))))

;;;###autoload
(defun overlook-agent-worktree (name branch)
  "Start agent NAME in the current project's worktree for BRANCH, made if missing."
  (interactive
   (list (overlook-agent-read-name)
         (overlook-agent-worktree-read-branch (cdr (overlook-agent-worktree--current)))))
  (pcase-let ((`(,project . ,dir) (overlook-agent-worktree--current)))
    (overlook-agent-worktree-start project dir branch name)))

(defun overlook-agent-worktree--items ()
  "Ids of the dashboard row at point and the rows it lies under, nearest first."
  (let ((section (magit-current-section)) items)
    (while section
      (when-let* ((item (get-text-property (oref section start) 'overlook-item)))
        (push item items))
      (setq section (oref section parent)))
    (nreverse items)))

(defun overlook-agent-worktree--row-project ()
  "The project of the dashboard row at point, or nil."
  (seq-some (lambda (item) (pcase item (`(project . ,name) name)))
            (overlook-agent-worktree--items)))

(defun overlook-agent-worktree--row-checkout ()
  "The worktree of the dashboard row at point, or nil."
  (seq-some (lambda (item)
              (let ((dir (pcase item
                           (`(,(or 'worktree 'repo) . ,dir) dir)
                           (`(agent . ,buffer) (and (buffer-live-p buffer)
                                                    (overlook-agent-get buffer 'root))))))
                (and dir (overlook-worktree-at dir) dir)))
            (overlook-agent-worktree--items)))

(defun overlook-agent-worktree-at-point ()
  "Start an agent in a new worktree of the row's project, on the row's task if any."
  (interactive)
  (let* ((task (run-hook-with-args-until-success 'overlook-agent-worktree-task-functions
                                                 (overlook-item-at-point)))
         (project (or (plist-get task :project) (overlook-agent-worktree--row-project)
                      (user-error "No project here")))
         (dir (or (overlook-project-root project) (user-error "No folder for %s" project)))
         (name (overlook-agent-read-name))
         (branch (overlook-agent-worktree-read-branch dir (plist-get task :branch))))
    (prog1 (overlook-agent-worktree-start project dir branch name (plist-get task :prompt))
      (when-let* ((started (plist-get task :started)))
        (with-demoted-errors "After starting the agent: %S" (funcall started branch))))))

(defun overlook-agent-worktree-agent-at-point ()
  "Start another agent in the row's worktree, else in its project's root."
  (interactive)
  (let* ((project (or (overlook-agent-worktree--row-project) (user-error "No project here")))
         (root (or (overlook-agent-worktree--row-checkout)
                   (overlook-project-root project)
                   (user-error "No folder for %s" project)))
         (buffer (overlook-agent-worktree--start-in project root (overlook-agent-read-name))))
    (overlook-show-elsewhere project (lambda () (overlook-agent-show buffer)))
    buffer))

(overlook-define-key "w" #'overlook-agent-worktree-at-point)
(overlook-define-key "a" #'overlook-agent-worktree-agent-at-point)
(overlook-add-hint "w" "agent in a new worktree (main's branch: in main), for the row's task")
(overlook-add-hint "a" "another agent in the row's worktree")

(provide 'overlook-agent-worktree)
;;; overlook-agent-worktree.el ends here
