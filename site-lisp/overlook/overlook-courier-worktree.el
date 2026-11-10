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

;; Starts agents in project worktrees.  Git operations live in
;; `overlook-worktree'.

;;; Code:

(require 'overlook-courier)
(require 'overlook-worktree)

(defun overlook-courier-worktree-spawn (name dir branch prompt &optional from effort handoff)
  "Start agent NAME in the worktree of project DIR for BRANCH, made if missing.
It works on PROMPT for agent FROM at reasoning EFFORT, as
`overlook-courier-spawn' starts it; with HANDOFF non-nil it is the user's,
as `overlook-courier-hand-off' starts it.
Returns its id."
  (let* ((path (overlook-worktree-add dir branch))
         (note (format "You work in a Git worktree of your own, %s, on branch %s; \
commit your work there, and leave the main checkout alone."
                       (abbreviate-file-name path) branch))
         (prompt (and prompt (concat note "\n\n" prompt))))
    (if handoff
        (overlook-courier-hand-off name path prompt effort)
      (let ((id (overlook-courier-spawn name path prompt from effort)))
        (unless prompt (overlook-courier-note id note))
        id))))

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
