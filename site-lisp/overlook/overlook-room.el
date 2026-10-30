;;; overlook-room.el --- Chat in courier's rooms -*- lexical-binding: t; -*-

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

;; `overlook-room-open' shows a room in a lui buffer, where the user reads
;; the room as it goes and posts as `courier-room-user'.  A post naming
;; the user while its room is not shown is announced in the echo area.

;;; Code:

(require 'lui)
(require 'circe-color-nicks)
(require 'courier-room)
(require 'courier-persona)

(defcustom overlook-room-history 200
  "How many earlier posts a room's buffer shows when opened."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-room-group-seconds 300
  "Posts by one author this many seconds apart or less share one header."
  :type 'natnum
  :group 'overlook)

(defface overlook-room-user '((t :inherit font-lock-keyword-face :weight bold))
  "Face of the user's name in a room."
  :group 'overlook)

(defface overlook-room-agent '((t :weight bold))
  "Face of an agent's name in a room, under a color of its own."
  :group 'overlook)

(defface overlook-room-mention '((t :inherit warning))
  "Face of the bar beside a post that names the user."
  :group 'overlook)

(defvar-local overlook-room--name nil
  "Name of the room this buffer shows.")

(defvar-local overlook-room--last nil
  "Author and time of the last post shown, as (FROM . TIME).")

(defvar-keymap overlook-room-mode-map
  "C-c C-i" #'overlook-room-invite
  "C-c C-n" #'overlook-room-spawn
  "C-c C-k" #'overlook-room-close)

(define-derived-mode overlook-room-mode lui-mode "Room"
  "Chat in a courier room; RET posts the input.

\\{overlook-room-mode-map}"
  (setq-local lui-input-function #'overlook-room--input)
  ;; Wrap to the window as it resizes, instead of lui's fill at insertion.
  (setq-local lui-fill-type nil
              lui-time-stamp-only-when-changed-p nil
              lui-time-stamp-position 'right-margin
              right-margin-width (string-width (format-time-string lui-time-stamp-format)))
  (visual-line-mode 1)
  (add-hook 'completion-at-point-functions #'overlook-room--complete-mention nil t)
  (lui-set-prompt (propertize "> " 'face 'minibuffer-prompt)))

(defun overlook-room--buffer (name)
  "The live buffer showing room NAME, or nil."
  (get-buffer (format "#%s" name)))

(defun overlook-room--face (id)
  "Face of ID: the user's, or a color of its own for each agent."
  (cond ((equal id courier-room-user) 'overlook-room-user)
        ((equal id "all") 'bold)
        (t `(:foreground ,(circe-nick-color-for-nick id) :inherit overlook-room-agent))))

(defun overlook-room--highlight (body)
  "BODY with each @ID in the face of ID."
  (let ((body (copy-sequence body))
        (start 0))
    (while (string-match "@\\([[:alnum:]_@.-]*[[:alnum:]_]\\)" body start)
      (put-text-property (match-beginning 0) (match-end 0)
                         'face (overlook-room--face (match-string 1 body)) body)
      (setq start (match-end 0)))
    body))

(defun overlook-room--insert (post)
  "Insert POST into the current room buffer.
A post opens with its author and time unless it follows the same
author's within `overlook-room-group-seconds'."
  (let* ((from (plist-get post :from))
         (time (plist-get post :time))
         (body (plist-get post :body))
         (prefix (if (and (not (equal from courier-room-user))
                          (courier-room-mentions-p body courier-room-user))
                     (propertize "▎ " 'face 'overlook-room-mention)
                   "  "))
         (lui-time-stamp-time (seconds-to-time time)))
    (unless (and (equal from (car overlook-room--last))
                 (<= (- time (cdr overlook-room--last)) overlook-room-group-seconds))
      (when (> lui-output-marker (point-min))
        (let ((lui-time-stamp-position nil))
          (lui-insert "" t)))
      (lui-insert (concat (when-let* ((avatar (plist-get (courier-persona from) :avatar)))
                            (concat avatar " "))
                          (propertize from 'face (overlook-room--face from)))
                  t))
    (setq overlook-room--last (cons from time))
    (let ((lui-time-stamp-position nil))
      (lui-insert (propertize (overlook-room--highlight body)
                              'line-prefix prefix 'wrap-prefix prefix)))))

(defun overlook-room--complete-mention ()
  "Complete the id after @ in the input: the room's members, then the other agents."
  (when-let* (((>= (point) lui-input-marker))
              (start (save-excursion
                       (skip-chars-backward "^[:space:]" lui-input-marker)
                       (and (eq (char-after) ?@) (1+ (point))))))
    (let* ((room (courier-room overlook-room--name))
           (members (and room (mapcar #'car (courier-room-members room))))
           (agents (append (mapcar #'courier-agent-id (courier-agents)) (courier-offline)))
           (ids (delete-dups (append (remove courier-room-user members) agents
                                     (list "all" courier-room-user)))))
      (list start (point)
            (lambda (string predicate action)
              (if (eq action 'metadata)
                  '(metadata (display-sort-function . identity))
                (complete-with-action action ids string predicate)))
            :exclusive 'no
            :company-prefix-length t
            :annotation-function
            (lambda (id)
              (cond ((equal id "all") " every member")
                    ((equal id courier-room-user) " you")
                    ((not (courier-room-present-p id)) " gone")
                    ((not (courier-agent id)) " offline persona; naming starts it")
                    ((member id members) " member")
                    (t " joins when named")))))))

(defun overlook-room--input (text)
  "Post TEXT to this buffer's room as the user."
  (courier-room-post overlook-room--name courier-room-user text)
  (when-let* ((missed (courier-room-missed overlook-room--name text)))
    (message "%s" missed)))

(defun overlook-room--on-post (name post)
  "Show POST in room NAME's buffer, and tell the user of posts naming them."
  (let ((buffer (overlook-room--buffer name)))
    (when buffer
      (with-current-buffer buffer (overlook-room--insert post)))
    (if (and buffer (get-buffer-window buffer 'visible))
        (courier-room-mark-read name courier-room-user)
      (when (and (not (equal (plist-get post :from) courier-room-user))
                 (courier-room-mentions-p (plist-get post :body) courier-room-user))
        (message "#%s: %s mentioned you; M-x overlook-room-open" name (plist-get post :from))))))

(add-hook 'courier-room-post-functions #'overlook-room--on-post)

;;;###autoload
(defun overlook-room-open (name)
  "Show room NAME, made if missing, and join it as the user."
  (interactive (list (completing-read "Room: " (courier-room-names))))
  (let* ((room (courier-room-join name courier-room-user))
         (name (courier-room-name room))
         (buffer (or (overlook-room--buffer name) (generate-new-buffer (format "#%s" name)))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'overlook-room-mode)
        (overlook-room-mode)
        (setq overlook-room--name name)
        (mapc #'overlook-room--insert (courier-room-history name overlook-room-history))))
    (courier-room-mark-read name courier-room-user)
    (pop-to-buffer buffer)))

(defun overlook-room-invite (id)
  "Add agent ID to this buffer's room, and tell it so."
  (interactive
   (list (completing-read
          "Invite agent: "
          (seq-remove (lambda (id) (courier-room-member (courier-room overlook-room--name) id))
                      (append (mapcar #'courier-agent-id (courier-agents)) (courier-offline)))
          nil t))
   overlook-room-mode)
  (courier-room-invite overlook-room--name id courier-room-user)
  (message "Added %s to #%s" id overlook-room--name))

(defvar overlook-agent-shell-configs)

(defun overlook-room-spawn (agent directory task &optional effort)
  "Start AGENT in DIRECTORY as a member of this buffer's room.
It works on TASK, or waits for posts when TASK is empty.  With a prefix
argument, ask for its reasoning EFFORT."
  (interactive
   (list (completing-read "Start agent: "
                          (and (boundp 'overlook-agent-shell-configs)
                               (mapcar #'car overlook-agent-shell-configs)))
         (read-directory-name "In directory: ")
         (read-string "Task (empty to wait for posts): ")
         (and current-prefix-arg (read-string "Effort: ")))
   overlook-room-mode)
  (let ((id (courier-room-spawn overlook-room--name agent directory courier-room-user
                                (and (not (string-empty-p (or effort ""))) effort)
                                (and (not (string-empty-p task)) task))))
    (message "Started %s in #%s" id overlook-room--name)))

(defun overlook-room-close ()
  "Close this buffer's room, archiving its posts."
  (interactive nil overlook-room-mode)
  (when (yes-or-no-p (format "Close #%s? " overlook-room--name))
    (courier-room-close overlook-room--name)))

(defun overlook-room--on-close (name)
  "Kill room NAME's buffer."
  (when-let* ((buffer (overlook-room--buffer name)))
    (kill-buffer buffer)))

(add-hook 'courier-room-close-functions #'overlook-room--on-close)

(provide 'overlook-room)
;;; overlook-room.el ends here
