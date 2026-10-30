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
(require 'courier-room)

(defcustom overlook-room-history 200
  "How many earlier posts a room's buffer shows when opened."
  :type 'natnum
  :group 'overlook)

(defface overlook-room-user '((t :inherit font-lock-keyword-face :weight bold))
  "Face of the user's name in a room."
  :group 'overlook)

(defface overlook-room-agent '((t :inherit font-lock-function-name-face))
  "Face of an agent's name in a room."
  :group 'overlook)

(defface overlook-room-mention '((t :inherit warning))
  "Face of a post that names the user."
  :group 'overlook)

(defvar-local overlook-room--name nil
  "Name of the room this buffer shows.")

(defvar-keymap overlook-room-mode-map
  "C-c C-i" #'overlook-room-invite)

(define-derived-mode overlook-room-mode lui-mode "Room"
  "Chat in a courier room; RET posts the input.

\\{overlook-room-mode-map}"
  (setq-local lui-input-function #'overlook-room--input)
  (lui-set-prompt (propertize "> " 'face 'minibuffer-prompt)))

(defun overlook-room--buffer (name)
  "The live buffer showing room NAME, or nil."
  (get-buffer (format "#%s" name)))

(defun overlook-room--insert (post)
  "Insert POST into the current room buffer, stamped with its time."
  (let* ((from (plist-get post :from))
         (body (plist-get post :body))
         (user (equal from courier-room-user))
         (lui-time-stamp-time (seconds-to-time (plist-get post :time))))
    (lui-insert (concat (propertize from 'face (if user 'overlook-room-user 'overlook-room-agent))
                        ": "
                        (if (and (not user) (courier-room-mentions-p body courier-room-user))
                            (propertize body 'face 'overlook-room-mention)
                          body)))))

(defun overlook-room--input (text)
  "Post TEXT to this buffer's room as the user."
  (courier-room-post overlook-room--name courier-room-user text))

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
                      (mapcar #'courier-agent-id (courier-agents)))
          nil t))
   overlook-room-mode)
  (courier-room-invite overlook-room--name id courier-room-user)
  (message "Added %s to #%s" id overlook-room--name))

(provide 'overlook-room)
;;; overlook-room.el ends here
