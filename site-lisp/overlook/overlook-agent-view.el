;;; overlook-agent-view.el --- Agent rows for the shared dashboard -*- lexical-binding: t; -*-

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

;; Builds live and saved agent rows, including fork trees and status labels.

;;; Code:

(require 'overlook-data)
(require 'overlook-agent-session)

(defcustom overlook-agent-context-warning 70
  "Context usage percentage from which an agent's is highlighted."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-agent-title-width 30
  "Columns an agent's session title takes at most on its row."
  :type 'natnum
  :group 'overlook)

(defvar overlook-agent-command-functions nil
  "Functions of an agent buffer returning additional row commands.")

(defvar overlook-agent-row-marks nil
  "Functions of an agent buffer returning a mark after its name, or nil.")

(defvar overlook-agent-hide-functions nil
  "Functions of a dashboard item returning non-nil to hide it.
The item is (agent . BUFFER) or (saved . SAVED); a hidden one is not
listed under any project.")

(defun overlook-agent--wrap-prefix (depth)
  "What starts an agent row's continuation lines, DEPTH forks deep."
  (concat overlook-agent--wrap-indent (make-string (* 2 depth) ?\s)))

;;; Rows

(defun overlook-agent--context-label (buffer)
  "Context usage of agent BUFFER, or nil."
  (when-let* ((used (buffer-local-value 'overlook-agent-context buffer)))
    (propertize (format "%3d%%" used)
                'face (if (>= used overlook-agent-context-warning) 'warning 'shadow))))

(defun overlook-agent--meta (buffer)
  "Turn duration and context usage of agent BUFFER, aligned to the right edge.
Returns (SEGMENTS . COLUMNS), COLUMNS being how far from the edge they start.
Context takes the last four columns but one, left free for the wrap mark;
the duration ends a column before it, so both line up across agents."
  (let ((turn (overlook-agent-turn-label buffer))
        (context (overlook-agent--context-label buffer)))
    (cons (list (and turn (overlook-align-right turn 6))
                (and context (overlook-align-right context 1)))
          (cond (turn (+ 6 (string-width turn)))
                (context 5)
                (t 0)))))

(defun overlook-agent--name-label (buffer)
  "Agent BUFFER's icon from `overlook-agent-icons', else its name.
It is drawn in the face of the agent's status, which it stands for."
  (overlook-icon (propertize (or (overlook-agent-get buffer 'agent) "agent")
                             'face (overlook-agent-status-face
                                    (buffer-local-value 'overlook-agent-status buffer)))))

(defun overlook-agent--failed-label (status)
  "A mark naming a failed STATUS, which shares its color with waiting."
  (if (eq status 'failed) (propertize " failed" 'face 'error) ""))

(defun overlook-agent--title-label (title)
  "TITLE cut to `overlook-agent-title-width', or an empty string."
  (if title
      (concat " " (overlook-truncate title overlook-agent-title-width))
    ""))

(defun overlook-agent--project-label (root project)
  "Name of the project at ROOT, dimmed, unless it is PROJECT's."
  (if (and root (not (equal (and project (overlook-project-root project))
                            root)))
      (propertize (concat " " (file-name-nondirectory (directory-file-name root)))
                  'face 'shadow)
    ""))

(defun overlook-agent-brief-segment (buffer brief meta)
  "BRIEF, a segment fit to the dashboard before META columns at the right.
Highlighted while agent BUFFER waits, set apart from its name while it
works, dimmed otherwise."
  (list :fit brief
        :face (pcase (buffer-local-value 'overlook-agent-status buffer)
                ('waiting 'warning)
                ('failed 'error)
                ('working 'font-lock-doc-face)
                (_ 'shadow))
        :before "  "
        :reserve (1+ meta)))

(defun overlook-agent--tree-prefix (depth)
  "What starts a row DEPTH forks below a row listed under a project."
  (if (> depth 0)
      (concat (make-string (* 2 (1- depth)) ?\s) (propertize "└ " 'face 'shadow))
    ""))

(defun overlook-agent--fork-label (session depth)
  "A dimmed mark for a fork SESSION listed apart from its parent, at DEPTH 0."
  (if (and (= depth 0) (overlook-agent-fork-parent session))
      (propertize " fork" 'face 'shadow)
    ""))

(defun overlook-agent--fork-echo (session)
  "Help text naming the session SESSION was forked from, or an empty string."
  (if-let* ((parent (overlook-agent-fork-parent session)))
      (concat "\nForked from " parent)
    ""))

(defun overlook-agent--row (buffer project &optional depth children)
  "The row of agent BUFFER under PROJECT, DEPTH forks deep.
CHILDREN are the rows of its forks.  What it is doing shows unless it
is idle with no question for you; the answers it offers you sit on a
line of their own under it."
  (let* ((depth (or depth 0))
         (session (overlook-agent-session buffer))
         (data (overlook-agent-data buffer))
         (title (unless (string-empty-p (plist-get data :title))
                  (plist-get data :title)))
         (meta (overlook-agent--meta buffer))
         (brief (plist-get data :subtitle))
         (status (buffer-local-value 'overlook-agent-status buffer)))
    (overlook-row
     :id (cons 'agent buffer)
     :content (list (overlook-agent--tree-prefix depth)
                    (overlook-agent--name-label buffer)
                    (overlook-agent--failed-label status)
                    (string-join (delq nil (mapcar (lambda (fn) (funcall fn buffer))
                                                   overlook-agent-row-marks)))
                    (overlook-agent--title-label title)
                    (overlook-agent--fork-label session depth)
                    (overlook-agent--project-label (overlook-agent-get buffer 'root) project)
                    (and brief (or (not (eq status 'idle))
                                   (overlook-agent-reply-question buffer))
                         (overlook-agent-brief-segment buffer brief (cdr meta)))
                    (car meta))
     :attention (and (memq status '(waiting failed done)) t)
     :face (pcase status
             ((or 'waiting 'failed) 'overlook-agent-waiting)
             ('done 'overlook-agent-done))
     :action (lambda () (overlook-agent-visit buffer))
     :help (concat (buffer-name buffer)
                   (if title (concat "\n" title) "")
                   (if brief (concat "\n" brief) "")
                   (overlook-agent--fork-echo session))
     :wrap (overlook-agent--wrap-prefix depth)
     :choices (overlook-agent-choices buffer)
     :choose (lambda (key) (overlook-agent-choose buffer key))
     :commands (append (seq-mapcat (lambda (fn) (funcall fn buffer))
                                    overlook-agent-command-functions)
                       (list (list :name "kill" :label "Kill"
                           :confirm (lambda () (overlook-agent-kill-question buffer))
                           :run (lambda () (overlook-agent-kill buffer)))))
     :children children)))

(defun overlook-agent--saved-row (saved project &optional depth children)
  "The row of SAVED agent, dimmed, under PROJECT, DEPTH forks deep.
It shows the agent's title and how long ago its last turn was.
CHILDREN are the rows of its forks."
  (let ((depth (or depth 0))
        (session (alist-get 'session saved))
        (title (alist-get 'title saved))
        (active (alist-get 'active saved)))
    (overlook-row
     :id (cons 'saved saved)
     :content (list (overlook-agent--tree-prefix depth)
                    (overlook-icon (propertize (alist-get 'agent saved) 'face 'shadow))
                    (propertize (concat " saved" (overlook-agent--title-label title))
                                'face 'shadow)
                    (overlook-agent--fork-label session depth)
                    (overlook-agent--project-label (alist-get 'root saved) project)
                    (and active
                         (overlook-align-right
                          (propertize (overlook-format-duration (- (float-time) active))
                                      'face 'shadow)
                          6)))
     :action (lambda () (overlook-agent-resume-visit saved))
     :help (concat "Resume session " session
                   (if title (concat "\n" title) "")
                   (overlook-agent--fork-echo session))
     :wrap (overlook-agent--wrap-prefix depth)
     :commands (list (list :name "resume" :label "Resume"
                           :run (lambda () (overlook-agent-resume saved)))
                     (list :name "forget" :label "Forget"
                           :confirm (format "Forget saved agent %s%s? " (alist-get 'agent saved)
                                            (overlook-agent--title-label title))
                           :run (lambda () (overlook-agent-forget saved))))
     :children children)))

(defun overlook-agent--item-session (item)
  "Session id of ITEM, an (agent . BUFFER) or (saved . SAVED), or nil."
  (pcase item
    (`(agent . ,buffer) (overlook-agent-session buffer))
    (`(saved . ,saved) (alist-get 'session saved))))

(defun overlook-agent--tree (item items project depth drawn)
  "The row of ITEM under PROJECT, DEPTH forks deep, over its forks among ITEMS.
DRAWN, a list in a cons, collects the items given rows, so none is twice."
  (setcar drawn (cons item (car drawn)))
  (let* ((session (overlook-agent--item-session item))
         (forks (and session
                     (seq-filter (lambda (other)
                                   (and (not (memq other (car drawn)))
                                        (equal (overlook-agent-fork-parent
                                                (overlook-agent--item-session other))
                                               session)))
                                 items)))
         (children (seq-keep (lambda (fork)
                               (unless (memq fork (car drawn))
                                 (overlook-agent--tree fork items project (1+ depth) drawn)))
                             forks)))
    (pcase item
      (`(agent . ,buffer) (overlook-agent--row buffer project depth children))
      (`(saved . ,saved) (overlook-agent--saved-row saved project depth children)))))

(defun overlook-agent--item-root (item)
  "Folder ITEM, an (agent . BUFFER) or (saved . SAVED), works in."
  (pcase item
    (`(agent . ,buffer) (overlook-agent-get buffer 'root))
    (`(saved . ,saved) (alist-get 'root saved))))

(defun overlook-agent--rows (project &optional dir)
  "Rows of the agents listed under PROJECT, then of those saved there.
Forks sit under the agent they were forked from when it is listed there
too.  Under `overlook-orphans-project', those in none follow.  With
DIR, a worktree, only those working in it; else those in none of
PROJECT's worktrees."
  (overlook-agent-note-forks)
  (let* ((projects (if (equal project (overlook-orphans-project))
                           (list project nil)
                         (list project)))
         (worktrees (if dir (list dir) (overlook-worktrees project)))
         (items (seq-filter
                 (lambda (item)
                   (and (equal (overlook-worktree-of (overlook-agent--item-root item) worktrees)
                               dir)
                        (not (run-hook-with-args-until-success 'overlook-agent-hide-functions item))))
                 (append (mapcar (lambda (buffer) (cons 'agent buffer))
                                 (overlook-agent-buffers
                                  (lambda (buffer)
                                    (member (overlook-agent-project buffer) projects))))
                         (mapcar (lambda (saved) (cons 'saved saved))
                                 (seq-filter (lambda (saved)
                                               (member (overlook-agent-saved-project saved)
                                                       projects))
                                             overlook-agent-saved)))))
         (sessions (delq nil (mapcar #'overlook-agent--item-session items)))
         (drawn (list nil))
         (rows (seq-keep (lambda (item)
                           (unless (or (memq item (car drawn))
                                       (member (overlook-agent-fork-parent
                                                (overlook-agent--item-session item))
                                               sessions))
                             (overlook-agent--tree item items project 0 drawn)))
                         items)))
    (append rows
            ;; Left over only when the forks recorded form a loop.
            (seq-keep (lambda (item)
                        (unless (memq item (car drawn))
                          (overlook-agent--tree item items project 0 drawn)))
                      items))))

(defun overlook-agent--mode-line ()
  "Agent counts with icons for total, working and needing attention."
  (let* ((statuses (mapcar (lambda (buffer) (buffer-local-value 'overlook-agent-status buffer))
                           (overlook-agent-buffers)))
         (working (seq-count (lambda (status) (eq status 'working)) statuses))
         (attention (seq-count (lambda (status) (memq status '(waiting failed done))) statuses)))
    (when statuses
      (string-join
       (delq nil
             (list
              (propertize
               (format "%s %d" (overlook-mode-line-icon "nf-cod-hubot" "agents") (length statuses))
               'help-echo "Total agents")
              (and (> working 0)
                   (propertize
                    (format "%s %d" (overlook-mode-line-icon "nf-cod-play" "working" 'warning) working)
                    'help-echo "Working agents"))
              (and (> attention 0)
                   (propertize
                    (concat (overlook-mode-line-icon "nf-cod-bell" "attention" 'error)
                            (propertize (format " %d" attention) 'face 'error))
                    'help-echo "Agents needing you: waiting, failed or done"))))
       "  "))))


(defun overlook-agent--row-data (row)
  "Compatibility adapter for agent ROW's business data."
  (overlook-data (overlook-row-id row)))

(provide 'overlook-agent-view)
;;; overlook-agent-view.el ends here
