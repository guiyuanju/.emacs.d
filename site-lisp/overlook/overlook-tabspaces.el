;;; overlook-tabspaces.el --- Tabspaces backend for overlook -*- lexical-binding: t; -*-

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

;; Makes each tab of the selected frame an overlook project, its
;; buffers kept apart by tabspaces.  A hidden tab's buffers are read from
;; what `tab-bar' saved of its frame parameters, so listing them does not
;; switch tabs.  A buffer of no file and no project, such as *scratch*,
;; belongs to the project of its tab.

;;; Code:

(require 'overlook)
(require 'tab-bar)
(require 'tabspaces)

(defun overlook-tabspaces--tabs (&optional frame)
  "Tabs of FRAME, or nil without `tabspaces-mode'."
  (and (bound-and-true-p tabspaces-mode) (funcall tab-bar-tabs-function frame)))

(defun overlook-tabspaces--tab (name)
  "The tab named NAME in the selected frame, or nil."
  (seq-find (lambda (tab) (equal (alist-get 'name tab) name)) (overlook-tabspaces--tabs)))

(defun overlook-tabspaces--names ()
  "Names of the tabs of the selected frame."
  (mapcar (lambda (tab) (alist-get 'name tab)) (overlook-tabspaces--tabs)))

(defun overlook-tabspaces--current ()
  "Name of the current tab, or nil without `tabspaces-mode'."
  (and (bound-and-true-p tabspaces-mode) (alist-get 'name (tab-bar--current-tab))))

(defun overlook-tabspaces--switch (name)
  "Switch to the tab named NAME, creating it when missing."
  (tabspaces-switch-or-create-workspace name))

;; Buffers such as *scratch* are shared by every tab and sit in no project.
(defvar overlook-tabspaces--roots (make-hash-table :test #'equal)
  "Project roots of tabs by name, cleared when tabs are switched or changed.")

(defun overlook-tabspaces--root (name)
  "Project root of the tab named NAME, or nil."
  (or (gethash name overlook-tabspaces--roots)
      (when-let* ((root (overlook-project-root name)))
        (puthash name root overlook-tabspaces--roots))))

(defun overlook-tabspaces--forget-roots (&rest _)
  "Forget the cached project roots of tabs."
  (clrhash overlook-tabspaces--roots))

(defun overlook-tabspaces--project-current (project-current &optional maybe-prompt directory)
  "Call PROJECT-CURRENT with MAYBE-PROMPT and DIRECTORY, falling back to the tab.
A buffer visiting no file and in no project belongs to the project of
its tab, unless that is `overlook-orphan-project'."
  (or (funcall project-current nil directory)
      (and (not directory)
           (not project-current-directory-override)
           (not (buffer-file-name (buffer-base-buffer)))
           (not (derived-mode-p 'dired-mode))
           (when-let* ((name (overlook-tabspaces--current))
                       ((not (equal name overlook-orphan-project)))
                       (root (overlook-tabspaces--root name)))
             (funcall project-current nil root)))
      (and maybe-prompt (funcall project-current maybe-prompt directory))))

;; The current tab also holds what its windows show, as tabspaces counts
;; it, but not a detached buffer.
(defun overlook-tabspaces--buffers (name)
  "Buffers of the tab named NAME."
  (when-let* ((tab (overlook-tabspaces--tab name)))
    (delete-dups
     (if (eq (car tab) 'current-tab)
         (append (frame-parameter nil 'buffer-list)
                 (frame-parameter nil 'buried-buffer-list)
                 (seq-remove (lambda (buffer) (buffer-local-value 'overlook-detached buffer))
                             (mapcar #'window-buffer (window-list nil 'nomini))))
       (append (alist-get 'wc-bl tab) (alist-get 'wc-bbl tab))))))

(defun overlook-tabspaces--add-buffer (name buffer)
  "Add BUFFER to the tab named NAME, last in its buffer list."
  (when-let* ((tab (overlook-tabspaces--tab name)))
    (if (eq (car tab) 'current-tab)
        (unless (memq buffer (frame-parameter nil 'buffer-list))
          (set-frame-parameter nil 'buffer-list
                               (append (frame-parameter nil 'buffer-list) (list buffer))))
      (unless (memq buffer (alist-get 'wc-bl tab))
        (setf (alist-get 'wc-bl (cdr tab))
              (append (alist-get 'wc-bl tab) (list buffer)))))))

;; Showing a buffer adds it to the tab, so a detached one is taken out
;; each time it is shown.
(defun overlook-tabspaces--detach (buffer)
  "Remove BUFFER from every tab of every frame, without switching."
  (dolist (frame (frame-list))
    (dolist (parameter '(buffer-list buried-buffer-list))
      (when (memq buffer (frame-parameter frame parameter))
        (set-frame-parameter frame parameter (remq buffer (frame-parameter frame parameter)))))
    (dolist (tab (overlook-tabspaces--tabs frame))
      (dolist (key '(wc-bl wc-bbl))
        (when (memq buffer (alist-get key tab))
          (setf (alist-get key (cdr tab)) (remq buffer (alist-get key tab))))))))

(defun overlook-tabspaces--close (name)
  "Close the tab named NAME and kill the buffers no other tab holds.
Buffers in `tabspaces-include-buffers' are kept.  The sole tab stays."
  (let ((buffers (overlook-tabspaces--buffers name))
        (others (mapcan (lambda (other) (copy-sequence (overlook-tabspaces--buffers other)))
                        (remove name (overlook-tabspaces--names)))))
    (tab-bar-close-tab-by-name name)
    (dolist (buffer buffers)
      (unless (or (memq buffer others)
                  (not (buffer-live-p buffer))
                  (member (buffer-name buffer) tabspaces-include-buffers))
        (kill-buffer buffer)))))

(defun overlook-tabspaces--changed (&rest _)
  "Redraw the dashboard after a tab is opened, closed or renamed."
  (overlook-tabspaces--forget-roots)
  (overlook-refresh))

;;;###autoload
(define-minor-mode overlook-tabspaces-mode
  "Let overlook show the tabs of tabspaces as projects."
  :global t
  :group 'overlook
  (pcase-dolist (`(,variable . ,function)
                 '((overlook-projects-function . overlook-tabspaces--names)
                   (overlook-current-project-function . overlook-tabspaces--current)
                   (overlook-switch-project-function . overlook-tabspaces--switch)
                   (overlook-project-buffers-function . overlook-tabspaces--buffers)
                   (overlook-add-to-project-function . overlook-tabspaces--add-buffer)
                   (overlook-detach-function . overlook-tabspaces--detach)
                   (overlook-close-project-function . overlook-tabspaces--close)))
    (set variable (if overlook-tabspaces-mode function #'ignore)))
  (overlook-toggle-hooks
   overlook-tabspaces-mode
   '((tab-bar-tab-post-select-functions overlook-tabspaces--forget-roots)
     (tab-bar-tab-post-select-functions overlook-project-switched)
     (tab-bar-tab-post-open-functions overlook-tabspaces--changed)
     (tab-bar-tab-pre-close-functions overlook-tabspaces--changed)))
  (if overlook-tabspaces-mode
      (progn
        (advice-add 'tab-bar-rename-tab :after #'overlook-tabspaces--changed)
        (advice-add 'project-current :around #'overlook-tabspaces--project-current))
    (advice-remove 'tab-bar-rename-tab #'overlook-tabspaces--changed)
    (advice-remove 'project-current #'overlook-tabspaces--project-current)))

(provide 'overlook-tabspaces)
;;; overlook-tabspaces.el ends here
