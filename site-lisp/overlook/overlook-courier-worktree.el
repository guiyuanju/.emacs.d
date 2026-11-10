;;; overlook-courier-worktree.el --- Git worktrees for the agents courier spawns -*- lexical-binding: t; -*-

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

;; Starts agents in project worktrees and subscribes them to branch rooms.
;; Removing a worktree closes its room.  Git operations live in
;; `overlook-worktree'.

;;; Code:

(require 'overlook-courier)
(require 'overlook-courier-room)
(require 'overlook-worktree)

(defalias 'overlook-courier-worktree-git-program #'overlook-worktree-git-program)
(defalias 'overlook-courier-worktree-repos #'overlook-worktree-repos)
(defalias 'overlook-courier-worktree-path #'overlook-worktree-path)
(defalias 'overlook-courier-worktree-at #'overlook-worktree-at)
(defalias 'overlook-courier-worktree-add #'overlook-worktree-add)
(defalias 'overlook-courier-worktree-remove #'overlook-worktree-remove)
(defalias 'overlook-courier-worktree-list #'overlook-worktree-list)

(defun overlook-courier-worktree-room (branch)
  "Name of the room events about BRANCH go to.
The name of BRANCH's worktree folder names the same room."
  (overlook-courier-room-name-for branch))

(defun overlook-courier-worktree-spawn (name dir branch prompt &optional from effort)
  "Start agent NAME in the worktree of project DIR for BRANCH, made if missing.
It works on PROMPT for agent FROM at reasoning EFFORT, as
`overlook-courier-spawn' starts it, and every post in the room named after
BRANCH wakes it.
Returns its id."
  (let* ((path (overlook-worktree-add dir branch))
         (room (overlook-courier-worktree-room branch))
         (note (format "You work in a Git worktree of your own, %s, on branch %s; \
commit your work there, and leave the main checkout alone.  Events about \
the branch, such as CI results, reach you from the room #%s."
                       (abbreviate-file-name path) branch room))
         (id (overlook-courier-spawn name path (and prompt (concat note "\n\n" prompt)) from effort)))
    (overlook-courier-room-join room id 'all)
    (unless prompt (overlook-courier-note id note))
    id))

(defun overlook-courier-worktree--removed (_dir branch)
  "Close the room of the removed worktree's BRANCH."
  (let ((room (overlook-courier-worktree-room branch)))
    (when (overlook-courier-room room) (overlook-courier-room-close room))))

(add-hook 'overlook-worktree-removed-functions #'overlook-courier-worktree--removed)

(defun overlook-courier-worktree-cli (args)
  "Run the worktree command ARGS and return its output."
  (pcase args
    (`("add" ,dir ,branch)
     (format "Worktree for %s at %s." branch (abbreviate-file-name (overlook-worktree-add dir branch))))
    ((or `("remove" ,dir ,branch) `("remove" "--force" ,dir ,branch))
     (overlook-worktree-remove dir branch (equal (cadr args) "--force"))
     (format "Removed the worktree of %s; the branch is kept." branch))
    (`("list" ,dir)
     (overlook-courier-or-empty (mapconcat (lambda (name)
                      (format "%s  %s" name (abbreviate-file-name (overlook-worktree-path dir name))))
                    (overlook-worktree-list dir) "\n")
         "No worktrees."))
    (_ (user-error "Usage: courier worktree add DIR BRANCH | remove [--force] DIR BRANCH | list DIR"))))

(provide 'overlook-courier-worktree)
;;; overlook-courier-worktree.el ends here
