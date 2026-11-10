;;; overlook-agent.el --- AI agents on the overlook dashboard -*- lexical-binding: t; -*-

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

;; Composes agent state, saved sessions and dashboard rows.
;; Provides interactive commands and the tracking mode.

;;; Code:

(require 'overlook)
(require 'overlook-agent-core)
(require 'overlook-agent-session)
(require 'overlook-agent-view)

(defun overlook-agent--delete (item)
  "Kill the agent ITEM stands for, once confirmed, or forget the saved one."
  (pcase item
    (`(agent . ,buffer)
     (when (yes-or-no-p (overlook-agent-kill-question buffer))
       (overlook-agent-kill buffer))
     t)
    (`(saved . ,saved) (overlook-agent-forget saved) t)))

(defun overlook-agent--in-folder (dir)
  "The agents working in folder DIR, as `overlook-folder-contents-functions' wants."
  (let ((in (lambda (root) (and root (file-in-directory-p root dir)))))
    (append (mapcar (lambda (buffer)
                      (cons (format "agent %s" (buffer-name buffer))
                            (lambda () (overlook-agent-kill buffer))))
                    (overlook-agent-buffers
                     (lambda (buffer) (funcall in (overlook-agent-get buffer 'root)))))
            (mapcar (lambda (saved)
                      (cons (format "saved agent %s" (or (alist-get 'title saved)
                                                         (alist-get 'agent saved)))
                            (lambda () (overlook-agent-forget saved))))
                    (seq-filter (lambda (saved) (funcall in (alist-get 'root saved)))
                                overlook-agent-saved)))))

(defun overlook-agent--annotate (name)
  "Status and project of the agent buffer NAME, for completion."
  (let ((buffer (get-buffer name)))
    (concat "  " (overlook-agent-glyph buffer) " "
            (symbol-name (buffer-local-value 'overlook-agent-status buffer))
            (if-let* ((project (overlook-agent-project buffer)))
                (propertize (concat "  " project) 'face 'shadow)
              ""))))

;;;###autoload
(defun overlook-agent-switch ()
  "Pick any running agent and show it in its project."
  (interactive)
  (let* ((names (or (mapcar #'buffer-name (overlook-agent-buffers))
                    (user-error "No agent running")))
         (name (completing-read
                "Agent: "
                (lambda (string pred action)
                  (if (eq action 'metadata)
                      '(metadata (category . buffer)
                                 (annotation-function . overlook-agent--annotate))
                    (complete-with-action action names string pred)))
                nil t)))
    (overlook-agent-visit (get-buffer name))))

(defun overlook-agent-reference (path beg end)
  "The current buffer from BEG to END quoted as lines of PATH, for an agent."
  (format "%s:%d-%d\n```\n%s\n```\n" path
          (line-number-at-pos beg) (line-number-at-pos (max beg (1- end)))
          (buffer-substring-no-properties beg end)))

;;;###autoload
(defun overlook-agent-send (&optional beg end)
  "Paste the region, or an @ reference to the file, into this project's agent.
Interactively BEG and END are the region, when active."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (let* ((file (buffer-file-name (buffer-base-buffer)))
         (path (if file (file-relative-name file (overlook-agent-resolve-root)) (buffer-name)))
         (text (if beg
                   (overlook-agent-reference path beg end)
                 (if file (format "@%s " path) (user-error "Buffer has no file"))))
         (buffer (or (overlook-agent--current)
                     (user-error "No agent running in this project"))))
    (deactivate-mark)
    (with-current-buffer buffer
      (funcall (or (overlook-agent-get buffer 'insert)
                   (user-error "%s cannot receive text" (buffer-name)))
               text))
    (overlook-agent-show buffer)))

(defun overlook-agent-draft-command (project)
  "Return a function making commands that draft a prompt for an agent of PROJECT.
The function takes a function of the agent's root giving the prompt, and
makes a command offering PROJECT's agents and starting a new one, or
nil when there is neither.  The prompt is left unsent, as \\[overlook-agent-send] does."
  (let* ((agents (mapcar #'buffer-name
                         (overlook-agent-buffers
                          (lambda (buffer) (equal (overlook-agent-project buffer) project)))))
         (start (seq-find (lambda (command) (equal (plist-get command :name) "new-agent"))
                          (seq-mapcat (lambda (function) (funcall function project))
                                      overlook-project-command-functions)))
         (new (mapcar (lambda (engine) (concat "New " engine)) (plist-get start :options)))
         (options (append agents new)))
    (lambda (prompt)
      (when options
        (list :name "draft" :label "Agent" :options options
              :run (lambda (option)
                     (let ((buffer (if (member option agents)
                                       (or (get-buffer option)
                                           (user-error "%s is gone" option))
                                     (funcall (plist-get start :run)
                                              (string-remove-prefix "New " option)))))
                       (cons buffer (funcall prompt (overlook-agent-get buffer 'root))))))))))

(define-obsolete-function-alias 'overlook-agent-label #'overlook-icon "0.2.0")

;;; Dashboard commands

(defun overlook-agent-at-point ()
  "The agent of the dashboard row at point, or nil."
  (pcase (overlook-item-at-point)
    (`(agent . ,buffer) buffer)))

;;;###autoload
(define-minor-mode overlook-agent-mode
  "Track agents and list them on the dashboard."
  :global t
  :group 'overlook
  (when overlook-agent-mode (overlook-agent-load-saved))
  (if overlook-agent-mode
      (add-function :after after-focus-change-function #'overlook-agent--acknowledge)
    (remove-function after-focus-change-function #'overlook-agent--acknowledge))
  (overlook-toggle-hooks
   overlook-agent-mode
   '((overlook-worktree-functions overlook-agent--rows)
     (overlook-delete-functions overlook-agent--delete)
     (overlook-folder-contents-functions overlook-agent--in-folder)
     (overlook-mode-line-functions overlook-agent--mode-line)
     (overlook-tick-hook overlook-agent--tick)
     (window-selection-change-functions overlook-agent--acknowledge)
     (window-buffer-change-functions overlook-agent--acknowledge)
     (overlook-agent-changed-hook overlook-agent-save)
     (kill-emacs-hook overlook-agent-save)))
  (overlook-refresh))

(provide 'overlook-agent)
;;; overlook-agent.el ends here
