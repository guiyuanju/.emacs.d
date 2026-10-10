;;; overlook-follow.el --- Diff windows following an agent's edits -*- lexical-binding: t; -*-

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

;; \\<overlook-mode-map>\\[overlook-follow-toggle] on an agent's row opens a window in its
;; perspective showing the diff of the file it last edited, refreshed as it
;; edits more, with point on the latest change.  An agent following its
;; edits carries a green ± after its name.  Agents in other perspectives
;; catch up when you switch to theirs.

;;; Code:

(require 'overlook-agent)
(require 'diff-mode)

(defvar-local overlook-follow--state nil
  "Non-nil while this agent's diff window follows its edits.
A plist: :files the `files' identity last seen, :file the file shown,
:pending non-nil when that file changed while its perspective was not
current.")

(defvar overlook-follow--timer nil)

(defun overlook-follow--buffer-name (buffer)
  "Name of the diff window buffer following agent BUFFER."
  (format "*overlook diff: %s*" (buffer-name buffer)))

(defun overlook-follow--schedule ()
  "Update the diff windows soon, coalescing bursts of edits."
  (unless (timerp overlook-follow--timer)
    (setq overlook-follow--timer
          (run-with-timer 0.3 nil (lambda ()
                                    (setq overlook-follow--timer nil)
                                    (overlook-follow--update))))))

(defun overlook-follow--latest (old new &optional current)
  "The entry of NEW, a `files' identity, changed since OLD, or nil.
Of several, prefer the active file or CURRENT; keep an unchanged CURRENT."
  (let ((changed
         (seq-remove
          (lambda (file)
            (let ((previous (seq-find (lambda (entry)
                                        (equal (alist-get 'file entry) (alist-get 'file file)))
                                      old)))
              ;; Clearing a stale focus marker is not a content change.
              (equal (assq-delete-all 'active (copy-sequence file))
                     (assq-delete-all 'active (copy-sequence previous)))))
          new)))
    (or (seq-find (lambda (file) (alist-get 'active file)) changed)
        (seq-find (lambda (file) (equal (alist-get 'file file) current)) changed)
        (unless (and (> (length changed) 1)
                     (seq-find (lambda (file) (equal (alist-get 'file file) current)) new))
          (car (last changed))))))

(defun overlook-follow--show (buffer file)
  "Show FILE's diffs for agent BUFFER in a window, point on the latest hunk.
FILE is an entry of its `files' identity, rendered by its `diff' identity."
  (let* ((name (overlook-follow--buffer-name buffer))
         (old (get-buffer name))
         (window (and old (get-buffer-window old)))
         (diff (overlook-agent-diff buffer (list file))))
    (when diff
      (when window (set-window-buffer window diff))
      (when old (kill-buffer old))
      (with-current-buffer diff (rename-buffer name))
      (when-let* ((window (or window
                              (display-buffer
                               diff `((display-buffer-reuse-window display-buffer-in-direction)
                                      (direction . right)
                                      (window . ,(or (get-buffer-window buffer)
                                                     (get-mru-window nil nil t)))
                                      (inhibit-same-window . t))))))
        (with-current-buffer diff
          (goto-char (point-max))
          (ignore-errors (diff-hunk-prev))
          (set-window-point window (point)))))))

(defun overlook-follow--here-p (buffer)
  "Non-nil when agent BUFFER's perspective is the current one, or it has none."
  (let ((perspective (overlook-buffer-perspective buffer)))
    (or (null perspective) (equal perspective (overlook-current-perspective)))))

(defun overlook-follow--update (&rest _)
  "Show the latest edit of each agent following its diffs.
Agents in other perspectives catch up when theirs is selected."
  (dolist (buffer (overlook-agent-buffers))
    (when-let* ((state (buffer-local-value 'overlook-follow--state buffer)))
      (let* ((files (overlook-agent-files buffer))
             (latest (overlook-follow--latest (plist-get state :files) files
                                              (plist-get state :file)))
             (file (or latest
                       (and (plist-get state :pending)
                            (seq-find (lambda (file)
                                        (equal (alist-get 'file file) (plist-get state :file)))
                                      files)))))
        (with-current-buffer buffer
          (setq overlook-follow--state
                (list :files files
                      :file (if file (alist-get 'file file) (plist-get state :file))
                      :pending (and file t))))
        (when (and file (overlook-follow--here-p buffer))
          (overlook-follow--show buffer file)
          (with-current-buffer buffer
            (setq overlook-follow--state (plist-put overlook-follow--state :pending nil))))))))

(defun overlook-follow-p (buffer)
  "Non-nil when agent BUFFER's diff window follows its edits."
  (and (buffer-local-value 'overlook-follow--state buffer) t))

(defun overlook-follow--latest-file (buffer)
  "The file agent BUFFER is writing, or else the one it wrote last."
  (let ((files (overlook-agent-files buffer)))
    (or (seq-find (lambda (file) (alist-get 'active file)) files)
        (car (last files)))))

(defun overlook-follow-start (buffer)
  "Follow agent BUFFER's edits, showing its latest file in a window."
  (let ((file (overlook-follow--latest-file buffer)))
    (with-current-buffer buffer
      (setq overlook-follow--state
            (list :files (overlook-agent-files buffer) :file (alist-get 'file file))))
    (when file (overlook-follow--show buffer file))
    (overlook-agent-changed)))

(defun overlook-follow-stop (buffer)
  "Stop following agent BUFFER's edits and close its diff window."
  (with-current-buffer buffer (setq overlook-follow--state nil))
  (when-let* ((diff (get-buffer (overlook-follow--buffer-name buffer))))
    (dolist (window (get-buffer-window-list diff nil t))
      (ignore-errors (delete-window window)))
    (kill-buffer diff))
  (overlook-agent-changed))

(defun overlook-follow-toggle ()
  "Toggle a window following the edits of the agent at point."
  (interactive)
  (let ((buffer (or (overlook-agent-at-point) (user-error "No agent on this line"))))
    (cond ((overlook-follow-p buffer)
           (overlook-follow-stop buffer)
           (message "Stopped following %s's edits" (buffer-name buffer)))
          ((overlook-follow--latest-file buffer)
           (overlook-show-elsewhere (overlook-buffer-perspective buffer)
                                    (lambda () (overlook-follow-start buffer))))
          (t (overlook-follow-start buffer)
             (message "Following %s's edits from its next one" (buffer-name buffer))))))

(defun overlook-follow--turn-start ()
  "Let the diff window wait for this new turn's edits."
  (when overlook-follow--state
    (setq overlook-follow--state (plist-put overlook-follow--state :files nil)))
  (when-let* ((diff (get-buffer (overlook-follow--buffer-name (current-buffer)))))
    (with-current-buffer diff
      (setq header-line-format "Previous turn · waiting for changes"))))

(defun overlook-follow--mark (buffer)
  "A green ± when agent BUFFER's diff window follows its edits."
  (when (overlook-follow-p buffer)
    (propertize " ±" 'face `(:foreground ,(face-foreground 'diff-indicator-added nil t))
                'help-echo "Its diff window follows its edits")))

(add-hook 'overlook-agent-changed-hook #'overlook-follow--schedule)
(add-hook 'overlook-agent-turn-start-hook #'overlook-follow--turn-start)
(add-hook 'overlook-perspective-switch-hook #'overlook-follow--update)
(add-hook 'overlook-agent-row-marks #'overlook-follow--mark)
(overlook-define-key "D" #'overlook-follow-toggle)

(provide 'overlook-follow)
;;; overlook-follow.el ends here
