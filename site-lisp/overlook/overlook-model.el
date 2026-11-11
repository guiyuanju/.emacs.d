;;; overlook-model.el --- Project model and background updates -*- lexical-binding: t; -*-

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

;; Collects project rows and invalidates the shared model.
;; Views independently subscribe to background updates.

;;; Code:

(require 'overlook-row)
(require 'project)

(declare-function overlook-show-elsewhere "overlook" (project show))

(defcustom overlook-project-order 'recent
  "Order of the projects on the dashboard.
`recent' puts the current one first, then the rest by how recently they
were switched to; `backend' keeps the backend's order."
  :type '(choice (const recent) (const backend))
  :group 'overlook)

(defconst overlook-buffer-name " *overlook*"
  "The dashboard buffer.  A leading space keeps it out of buffer lists.")

(defcustom overlook-project-priority-function nil
  "Function of a project name returning its numeric priority, lower first.
With `recent' ordering, priority precedes last switch time, after current."
  :type '(choice (const nil) function)
  :group 'overlook)

(defvar overlook--project-order-snapshots nil
  "Project orders held while the dashboard window is selected.")

(defun overlook-stable-project-order (names key)
  "Hold NAMES in their first order under KEY while browsing the dashboard.
Removed names disappear and new names are appended."
  (if (not (eq (window-buffer (selected-window)) (get-buffer overlook-buffer-name)))
      names
    (let* ((old (alist-get key overlook--project-order-snapshots))
           (order (append (seq-filter (lambda (name) (member name names)) old)
                          (seq-remove (lambda (name) (member name old)) names))))
      (setf (alist-get key overlook--project-order-snapshots) order)
      order)))

(defcustom overlook-project-annotation nil
  "Function of a project NAME returning a tag shown after its heading, or nil."
  :type '(choice (const :tag "None" nil) function)
  :group 'overlook)

(defcustom overlook-project-filter nil
  "Function of a project NAME returning nil to hide it, or nil to show all.
The current project, and one with a row needing your attention, are
shown regardless."
  :type '(choice (const :tag "Show all" nil) function)
  :group 'overlook)

(defcustom overlook-show-empty-projects nil
  "Non-nil to list a project with no rows and no mark after its heading.
A function of the project's name decides per project.  The current one
is listed either way."
  :type '(choice boolean function)
  :group 'overlook)

(defcustom overlook-orphan-project nil
  "Project listing the rows that belong to no project, or nil.
Rows opened from there open in it.  Without it, they are listed under
the current project."
  :type '(choice (const :tag "The current project" nil) string)
  :group 'overlook)

(defcustom overlook-section-order nil
  "Functions of `overlook-sections' in the order the dashboard shows them.
Sections not listed follow, by hook depth."
  :type '(repeat function)
  :group 'overlook)

(defcustom overlook-account-labels nil
  "Short labels drawn in place of account names, keyed by name.
Like ((\"work\" . \"W\") (\"home\" . \"H\")).  An account with a label
shows it wherever the dashboard names the account, the first one too."
  :type '(alist :key-type string :value-type string)
  :group 'overlook)

(defun overlook-account-label (account)
  "The label `overlook-account-labels' gives ACCOUNT, or nil."
  (and account (alist-get account overlook-account-labels nil nil #'equal)))

(defcustom overlook-account-width 3
  "Characters of an account's name shown after @ on the dashboard; nil for all."
  :type '(choice (const :tag "All" nil) natnum)
  :group 'overlook)

(defun overlook-account-name (account)
  "ACCOUNT as the dashboard draws it: its label, else @ACCOUNT, dimmed.
The name is cut to `overlook-account-width' characters."
  (or (overlook-account-label account)
      (propertize (concat "@" (if overlook-account-width
                                  (truncate-string-to-width account overlook-account-width)
                                account))
                  'face 'shadow)))

(defcustom overlook-tick-interval 5
  "Seconds between runs of `overlook-tick-hook' while any view needs updates."
  :type 'number
  :group 'overlook)

;;; Project backend

(defvar overlook-projects-function #'ignore
  "Function returning the names of all projects, in display order.")

(defvar overlook-current-project-function #'ignore
  "Function returning the name of the current project, or nil.")

(defvar overlook-switch-project-function #'ignore
  "Function of a NAME switching to that project.")

(defvar overlook-project-buffers-function #'ignore
  "Function of a NAME returning that project's buffers.")

(defvar overlook-project-root-function #'overlook-project--root
  "Function of a NAME returning that project's root, or nil.")

(defvar overlook-add-to-project-function #'ignore
  "Function of a NAME and a BUFFER adding BUFFER to that project.")

(defvar overlook-detach-function #'ignore
  "Function of a BUFFER removing it from every project.")

(defvar overlook-close-project-function #'ignore
  "Function of a NAME closing that project and killing its own buffers.")

(defcustom overlook-project-root #'overlook-project-guess-root
  "Function of a project NAME returning its project root, or nil."
  :type 'function
  :group 'overlook)

(defun overlook-projects ()
  "Names of all projects."
  (funcall overlook-projects-function))

(defun overlook-current-project ()
  "Name of the current project, or nil."
  (funcall overlook-current-project-function))

(defvar overlook--buffers-cache nil
  "Project buffers looked up during one render, keyed by name.")

(defun overlook-project-buffers (name)
  "Live buffers of project NAME."
  (let ((lookup (lambda ()
                  (seq-filter #'buffer-live-p
                              (funcall overlook-project-buffers-function name)))))
    (if overlook--buffers-cache
        (with-memoization (gethash name overlook--buffers-cache) (funcall lookup))
      (funcall lookup))))

(defvar overlook--roots-cache nil
  "Project roots looked up during one render, keyed by name, each in a list.")

(defvar overlook--generation 0
  "Count of calls to `overlook-refresh', telling when a model is stale.")

(defvar overlook--roots (cons nil (make-hash-table :test #'equal))
  "((GENERATION . FUNCTION) . TABLE) of the roots FUNCTION found since a refresh.
FUNCTION is `overlook-project-root-function'.")

;; A missing root may be guessed once the project visits a file, which
;; does not refresh, so only a render remembers that there is none.
(defun overlook-project-root (name)
  "Project root of project NAME, or nil."
  (let ((key (cons overlook--generation overlook-project-root-function)))
    (unless (equal (car overlook--roots) key)
      (setq overlook--roots (cons key (make-hash-table :test #'equal)))))
  (or (gethash name (cdr overlook--roots))
      (when-let* ((root (if overlook--roots-cache
                            (car (with-memoization (gethash name overlook--roots-cache)
                                   (list (funcall overlook-project-root-function name))))
                          (funcall overlook-project-root-function name))))
        (puthash name root (cdr overlook--roots)))))

(defun overlook-project-guess-root (name)
  "Root of the project of the first file or Dired buffer in project NAME."
  (seq-some (lambda (buffer)
              (when (or (buffer-file-name buffer)
                        (eq (buffer-local-value 'major-mode buffer) 'dired-mode))
                (when-let* ((project (project-current
                                      nil (buffer-local-value 'default-directory buffer))))
                  (project-root project))))
            (overlook-project-buffers name)))

(defun overlook-project--root (name)
  "Project root of project NAME, per `overlook-project-root'."
  (funcall overlook-project-root name))

(defun overlook-orphan-project ()
  "Name of `overlook-orphan-project' when it exists, else nil."
  (car (member overlook-orphan-project (overlook-projects))))

(defun overlook-orphans-project ()
  "Name of the project rows of no project go under.
That is `overlook-orphan-project', or else the current one."
  (or (overlook-orphan-project) (overlook-current-project)))

(defun overlook-add-to-project (name buffer)
  "Add BUFFER to project NAME."
  (funcall overlook-add-to-project-function name buffer))

(defvar-local overlook-detached nil
  "Non-nil in a buffer `overlook-detach' keeps out of every project.")

(defun overlook-detach (buffer)
  "Keep BUFFER out of every project, even once shown in one.
Opening it from the dashboard shows it in the current project."
  (with-current-buffer buffer
    (setq overlook-detached t)
    (add-hook 'window-buffer-change-functions #'overlook--detach-shown nil t))
  (funcall overlook-detach-function buffer))

(defun overlook--detach-shown (window)
  "Take the buffer WINDOW now shows back out of the projects."
  (funcall overlook-detach-function (window-buffer window)))

(defun overlook-buffer-project (buffer)
  "The project BUFFER belongs to, preferring the current one; or nil."
  (let ((current (overlook-current-project)))
    (if (and current (memq buffer (overlook-project-buffers current)))
        current
      (seq-find (lambda (name) (memq buffer (overlook-project-buffers name)))
                (overlook-projects)))))

(defun overlook-switch-project (name)
  "Switch to project NAME, keeping the dashboard shown if it was."
  (unless (equal name (overlook-current-project))
    (funcall overlook-switch-project-function name)
    (overlook-project-switched)))

(defun overlook-ensure-project (name)
  "Create project NAME if missing, staying in the current project."
  (unless (member name (overlook-projects))
    (let ((current (overlook-current-project)))
      (overlook-switch-project name)
      (when current (overlook-switch-project current)))))

(defun overlook-close-project (name)
  "Close project NAME, killing the buffers no other project holds."
  (interactive
   (let ((current (overlook-current-project)))
     (list (completing-read (format-prompt "Close project" current)
                            (overlook-projects) nil t nil nil current))))
  (funcall overlook-close-project-function name)
  (overlook-refresh))

(defvar overlook-project-switch-hook nil
  "Hook run after switching projects, in the new one.")

(defvar overlook-project-switch-times nil
  "Alist of project name to the time it was last switched to.
Add it to `savehist-additional-variables' to keep it across sessions.")

(defun overlook--record-switch ()
  "Record the time of a switch to the current project."
  (when-let* ((name (overlook-current-project)))
    (setf (alist-get name overlook-project-switch-times nil nil #'equal)
          (float-time))))

(defun overlook-sort-projects (names &optional current)
  "Sort NAMES by priority, last switch time, then name, with CURRENT first."
  (let ((keys (mapcar (lambda (name)
                        (list name
                              (if overlook-project-priority-function
                                  (funcall overlook-project-priority-function name) 0)
                              (alist-get name overlook-project-switch-times 0 nil #'equal)))
                      (remove current names))))
    (append (and (member current names) (list current))
            (mapcar #'car
                    (sort keys
                          (lambda (a b)
                            (cond ((/= (nth 1 a) (nth 1 b)) (< (nth 1 a) (nth 1 b)))
                                  ((/= (nth 2 a) (nth 2 b)) (> (nth 2 a) (nth 2 b)))
                                  (t (string< (car a) (car b))))))))))

(defun overlook-ordered-projects ()
  "Names of all projects, in the order of `overlook-project-order'."
  (let ((names (overlook-projects)))
    (if (eq overlook-project-order 'recent)
        (overlook-sort-projects names (overlook-current-project))
      names)))

(defun overlook-project-switched (&rest _)
  "Record a project switch and notify views in the new project."
  (setq overlook--project-order-snapshots nil)
  (overlook--record-switch)
  (run-hooks 'overlook-project-switch-hook)
  (overlook-refresh))

;;; Hooks

(defvar overlook-sections nil
  "Functions giving the dashboard's top level sections, by hook depth.
Each is called with no arguments and returns a section, as made by
`overlook-section-row', or nil.  The projects section sits at
depth 0.")

(defvar overlook-project-functions nil
  "Functions giving the rows under a project's heading, by hook depth.
Each is called with the project's NAME and returns a list of rows,
as made by `overlook-row'.  The rows of what lies in a checkout come
from `overlook-worktree-functions' instead, at depth 0 when the project
lists no worktrees.  Under
`overlook-orphans-project' a function also gives its rows that
belong to no project.")

(defvar overlook-closed-projects-functions nil
  "Functions giving rows after the projects' headings, by hook depth.
Each is called with no arguments and returns a list of rows, for what
`overlook-projects' does not list, like projects that are not open.")

(defvar overlook-worktrees-functions nil
  "Functions of a project NAME returning the worktrees listed under it.
Each returns a list of folders, each ending in a slash.")

(defvar overlook-worktree-functions nil
  "Functions giving the rows of what lies in a checkout, by hook depth.
Each is called with the project's NAME and the worktree's folder
DIR, or nil for what lies in none of its worktrees, and returns a list
of rows.  Agents sit at depth 0 and changed repos at 50.  With DIR nil
they go right under the project's heading while it lists no
worktrees, else under the row of its main checkout, which a function of
`overlook-project-functions' gives with those of its worktrees.")

(defvar overlook--worktrees-cache nil
  "Worktrees looked up during one render, keyed by project name.")

(defun overlook-worktrees (name)
  "Folders of the worktrees listed under project NAME."
  (let ((lookup (lambda () (seq-mapcat (lambda (fn) (funcall fn name))
                                       overlook-worktrees-functions))))
    (if overlook--worktrees-cache
        (car (with-memoization (gethash name overlook--worktrees-cache)
               (list (funcall lookup))))
      (funcall lookup))))

(defun overlook-worktree-of (dir worktrees)
  "The folder among WORKTREES holding DIR, or nil."
  (when dir
    (let ((dir (file-name-as-directory (expand-file-name dir))))
      (seq-find (lambda (tree) (string-prefix-p tree dir)) worktrees))))

(defvar overlook-folder-contents-functions nil
  "Functions of a folder DIR returning what lies in it, before DIR goes.
Each returns a list of (DESCRIPTION . DELETE), DESCRIPTION naming one
thing, like \"agent claude\", and DELETE a function letting it go.")

(defun overlook-folder-contents (dir)
  "What lies in folder DIR, as `overlook-folder-contents-functions' tell."
  (seq-mapcat (lambda (fn) (funcall fn dir)) overlook-folder-contents-functions))

(defvar overlook-delete-functions nil
  "Functions of a row's id, as `overlook-item-at-point' gives, deleting it.
Each deletes what the row stands for.
Each returns non-nil when it handled the item.")

(defvar overlook-project-contents-functions nil
  "Functions of a project NAME returning what goes when it closes.
Each returns a list of (LABEL . DELETE), DELETE a function letting it go.")

(defvar overlook-project-close-blockers nil
  "Functions of a project NAME returning why it cannot close, or nil.")

(defun overlook-delete-project (name)
  "Close project NAME with what lies in it, such as its agents, once confirmed.
Refused while `overlook-project-close-blockers' give a reason."
  (when-let* ((reasons (delq nil (mapcar (lambda (blocker) (funcall blocker name))
                                         overlook-project-close-blockers))))
    (user-error "Cannot close project %s: %s" name (string-join reasons "; ")))
  (let ((contents (seq-mapcat (lambda (function) (funcall function name))
                              overlook-project-contents-functions)))
    (when (yes-or-no-p (format "Close project %s%s? " name
                               (if contents
                                   (format " and %s" (mapconcat #'car contents ", "))
                                 "")))
      (pcase-dolist (`(,_ . ,delete) contents) (funcall delete))
      (overlook-close-project name)
      (message "Closed project %s" name))))

(defun overlook--delete-project (item)
  "Close the project ITEM stands for, if it is an open one."
  (pcase item
    (`(project . ,name)
     (overlook-delete-project name)
     t)))

(add-hook 'overlook-delete-functions #'overlook--delete-project)

(defvar overlook-project-command-functions nil
  "Functions of a project NAME returning commands for its heading.
Each returns a list of commands, as `overlook-row' describes.")

(defvar overlook-heading-mark-functions nil
  "Functions of a project NAME returning a mark put right after its heading.
Each returns a string, such as \"*\", or nil.")

(defvar overlook-projects-mark-functions nil
  "Functions returning a mark put right after the Projects section's title.
Each returns a string, such as \"*\", or nil.")

(defvar overlook-mode-line-functions nil
  "Functions returning strings joined into the dashboard's mode line.")

(defvar overlook-before-render-hook nil
  "Hook run before `overlook-model' gathers the dashboard's rows.")

(defvar overlook-after-model-hook nil
  "Hook run once `overlook-model' has gathered the dashboard's rows afresh.
For views drawing the model `overlook-latest-model' gives.")

(defvar overlook-tick-hook nil
  "Hook run every `overlook-tick-interval' seconds while any view needs updates.")

(defun overlook-toggle-hooks (on hooks)
  "Add HOOKS when ON is non-nil, else remove them; for modules' modes.
Each of HOOKS is (HOOK FUNCTION) or (HOOK FUNCTION DEPTH)."
  (pcase-dolist (`(,hook ,function ,depth) hooks)
    (if on (add-hook hook function depth) (remove-hook hook function))))

(defvar overlook--tick-timer nil)

(defun overlook-live-p ()
  "Non-nil when the dashboard buffer exists."
  (and (get-buffer overlook-buffer-name) t))

(defvar overlook-refresh-hook nil
  "Hook run by `overlook-refresh', whether or not the dashboard is live.
For other views of the dashboard; see `overlook-latest-model'.")

(defun overlook-refresh ()
  "Invalidate the shared model and notify its views."
  (setq overlook--generation (1+ overlook--generation))
  (run-hooks 'overlook-refresh-hook))

(defun overlook-format-duration (seconds)
  "Format SECONDS compactly with its two largest units, like 2h10m or 3d4h."
  (let ((m (/ (max 0 (floor seconds)) 60)))
    (cond ((< m 60) (format "%dm" m))
          ((< m 1440) (format "%dh%dm" (/ m 60) (% m 60)))
          (t (format "%dd%dh" (/ m 1440) (% (/ m 60) 24))))))

;;; Projects section

(defun overlook--sections ()
  "Functions of `overlook-sections', sorted by `overlook-section-order'."
  (let (functions)
    (run-hook-wrapped 'overlook-sections (lambda (f) (push f functions) nil))
    (seq-sort-by (lambda (f) (or (seq-position overlook-section-order f)
                                 (length overlook-section-order)))
                 #'< (nreverse functions))))

(defun overlook--heading-marks (name)
  "The marks `overlook-heading-mark-functions' put after project NAME."
  (mapconcat (lambda (function) (or (funcall function name) ""))
             overlook-heading-mark-functions))

(defun overlook-project-heading (name face marks &rest slots)
  "The heading row of project NAME in FACE, with the string MARKS after it.
SLOTS are further keyword arguments of `overlook-row'."
  (apply #'overlook-row
         :content (list (propertize (concat name marks) 'face face)
                        (when-let* ((tag (and overlook-project-annotation
                                              (funcall overlook-project-annotation name))))
                          (propertize (concat " " tag) 'face 'shadow)))
         :heading t
         :action (lambda () (overlook-show-elsewhere name #'ignore))
         :commands (seq-mapcat (lambda (function) (funcall function name))
                               overlook-project-command-functions)
         slots))

(defun overlook--checkout-rows (name)
  "The rows of what lies in project NAME's only checkout, if it lists no worktrees."
  (unless (overlook-worktrees name)
    (overlook-rows 'overlook-worktree-functions name nil)))

(add-hook 'overlook-project-functions #'overlook--checkout-rows)

(defun overlook--project-row (name current)
  "The heading of project NAME over its rows, or nil when left out.
CURRENT is the current project's name.  See `overlook--projects'."
  (let* ((marks (overlook--heading-marks name))
         (rows (overlook-rows 'overlook-project-functions name))
         (row (overlook-project-heading name
                                        (if (equal name current)
                                            'overlook-heading-current
                                          'overlook-heading)
                                        marks
                                        :id (cons 'project name)
                                        :children rows)))
    (when (and (or rows (equal name current)
                   (if (functionp overlook-show-empty-projects)
                       (funcall overlook-show-empty-projects name)
                     overlook-show-empty-projects)
                   (not (string-empty-p marks)))
               (or (equal name current)
                   (null overlook-project-filter)
                   (funcall overlook-project-filter name)
                   (overlook-row-attention-p row)))
      row)))

(defun overlook--projects (&optional unordered)
  "Each project's heading over its rows.
One with no rows and no mark after its heading is left out unless
current or `overlook-show-empty-projects' is set.  Those
`overlook-project-filter' hides are left out unless current or
needing attention.  UNORDERED leaves sorting to the containing section."
  (let ((current (overlook-current-project)))
    (overlook-gaps (seq-keep (lambda (name) (overlook--project-row name current))
                             (if unordered (overlook-projects)
                               (overlook-stable-project-order (overlook-ordered-projects) 'open))))))

(defun overlook--projects-section ()
  "The Projects section, merging open and closed projects by priority."
  (let* ((rows (overlook--projects overlook-project-priority-function))
         (closed (overlook-rows 'overlook-closed-projects-functions))
         (all (append rows closed)))
    (if overlook-project-priority-function
        (let (projects others)
          (dolist (row all)
            (let ((name (pcase (overlook-row-id row)
                          (`(project . ,name) name)
                          (`(closed-project ,name) name))))
              (if name (push (cons name row) projects) (push row others))))
          (setq all
                (append
                 (mapcar (lambda (name) (cdr (assoc name projects)))
                         (overlook-stable-project-order
                          (overlook-sort-projects (mapcar #'car projects)
                                                  (overlook-current-project))
                          'projects))
                 (nreverse others)))))
    (let ((final (car (last all))))
      (dolist (row all)
        (setf (overlook-row-gap row) (not (eq row final)))))
    (overlook-section-row
     (concat "Projects"
             (mapconcat (lambda (function) (or (funcall function) ""))
                        overlook-projects-mark-functions))
     all)))

(add-hook 'overlook-sections #'overlook--projects-section)

;;; Model

(defvar overlook--model nil
  "The model `overlook-model' last gathered, as (GENERATION . SECTIONS).")

(defvar overlook-model-cache nil
  "Hash table for lookups shared within one `overlook-model' call.
Nil outside model gathering.  Modules should use distinct keys and wrap
possibly nil values in a list.")

(defun overlook-model ()
  "The dashboard as data, gathered afresh: a list of sections.
Each is a row, as `overlook-row' describes, its children the rows of
the section.  Views keep it as `overlook-latest-model' gives it."
  (let* ((generation overlook--generation)
         (overlook-model-cache (make-hash-table :test #'equal))
         (overlook--buffers-cache (make-hash-table :test #'equal))
         (overlook--roots-cache (make-hash-table :test #'equal))
         (overlook--worktrees-cache (make-hash-table :test #'equal))
         (sections (progn
                     (run-hooks 'overlook-before-render-hook)
                     (seq-mapcat (lambda (function) (ensure-list (funcall function)))
                                 (overlook--sections)))))
    (setq overlook--model (cons generation sections))
    (run-hooks 'overlook-after-model-hook)
    sections))

(defun overlook-model-fresh-p ()
  "Non-nil when no `overlook-refresh' came since the last model was gathered."
  (and overlook--model (= (car overlook--model) overlook--generation)))

(defun overlook-latest-model ()
  "The dashboard's model: the last one gathered while fresh, else a new one.
The dashboard gathers one each redraw, so other views of it share that
one; see `overlook-after-model-hook'."
  (if (overlook-model-fresh-p)
      (cdr overlook--model)
    (overlook-model)))

(defvar overlook--update-consumers nil
  "Views currently using the background update timer.")

(defun overlook-updating-p ()
  "Non-nil when some view needs background updates."
  (and overlook--update-consumers t))

(defun overlook-start-updates (consumer)
  "Keep background updates running for CONSUMER, a view's unique symbol.
Repeated starts by the same consumer share its existing subscription."
  (cl-pushnew consumer overlook--update-consumers)
  (unless (timerp overlook--tick-timer)
    (setq overlook--tick-timer
          (run-with-timer 0 overlook-tick-interval #'overlook--tick))))

(defun overlook-stop-updates (consumer)
  "Release CONSUMER's updates, stopping the timer once no views need it."
  (setq overlook--update-consumers (delq consumer overlook--update-consumers))
  (unless overlook--update-consumers
    (when (timerp overlook--tick-timer) (cancel-timer overlook--tick-timer))
    (setq overlook--tick-timer nil)))

(defun overlook--tick ()
  "Run the update hooks while a view needs them."
  (when (overlook-updating-p) (run-hooks 'overlook-tick-hook)))

(provide 'overlook-model)
;;; overlook-model.el ends here
