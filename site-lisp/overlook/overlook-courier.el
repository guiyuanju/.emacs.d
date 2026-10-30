;;; overlook-courier.el --- Agents on the overlook dashboard messaging each other -*- lexical-binding: t; -*-

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

;; Registers each agent overlook runs with courier, so agents can message,
;; spawn and monitor each other.  An agent started while the mode is on
;; learns its courier id from $COURIER_ID and finds the courier script on
;; its PATH.  Its errors and requests for the user reach the agent that
;; spawned it.  A spawned agent opens in its parent's perspective; the
;; dashboard marks who spawned it, and the messages waiting for it.
;; Above the perspectives, a Rooms section lists courier's chat rooms with
;; the posts the user has not read; RET opens one.

;;; Code:

(require 'overlook-agent)
(require 'courier)
(require 'courier-room)

(declare-function overlook-room-open "overlook-room")

(defvar-local overlook-courier-id nil
  "This agent's courier id.")
(put 'overlook-courier-id 'permanent-local t)

(defvar overlook-courier--parent nil
  "Courier id of the agent spawning the agent being started, or nil.")

(defun overlook-courier--environment (name root)
  "Environment telling agent NAME starting in ROOT its new courier id."
  (courier-environment (courier-new-id name root)))

(defun overlook-courier--register (buffer)
  "Register agent BUFFER with courier once its frontend is ready."
  (with-current-buffer buffer
    (when-let* (((not (and overlook-courier-id (courier-agent overlook-courier-id))))
                (submit (overlook-agent-get buffer 'submit)))
      (let* ((environment (overlook-agent-get buffer 'environment))
             (id (or (seq-some (lambda (entry)
                                 (and (string-prefix-p "COURIER_ID=" entry)
                                      (substring entry (length "COURIER_ID="))))
                               environment)
                     (courier-new-id (or (overlook-agent-get buffer 'agent) "agent")
                                     (or (overlook-agent-get buffer 'root) default-directory))))
            (ready (overlook-agent-get buffer 'ready))
            (reply (overlook-agent-get buffer 'reply))
            (transcript (overlook-agent-get buffer 'transcript)))
        (setq overlook-courier-id id)
        (courier-register
         id
         :buffer buffer
         :parent overlook-courier--parent
         :deliver (lambda (text) (with-current-buffer buffer (funcall submit text)))
         :ready (lambda ()
                  (with-current-buffer buffer
                    (if ready (funcall ready)
                      (not (memq overlook-agent-status '(working waiting))))))
         :reply (and reply (lambda () (with-current-buffer buffer (funcall reply))))
         :transcript (and transcript
                          (lambda () (with-current-buffer buffer (funcall transcript)))))))))

(defun overlook-courier--sync ()
  "Register the agents courier does not know yet."
  (mapc #'overlook-courier--register (overlook-agent-buffers)))

(defun overlook-courier--turn-started ()
  "Tell courier this agent started a turn."
  (courier-turn-started overlook-courier-id))

(defun overlook-courier--turn-finished ()
  "Tell courier this agent finished a turn, and the error it failed with."
  (courier-turn-finished overlook-courier-id overlook-agent-error))

(defun overlook-courier--blocked ()
  "Tell courier this agent waits for the user, and on what."
  (courier-blocked overlook-courier-id
                   (or (overlook-agent--brief (current-buffer)) "a request")))

(defun overlook-courier--spawn (name directory parent &optional effort)
  "Start agent NAME in DIRECTORY for agent PARENT and return its id.
It opens in PARENT's perspective, at reasoning EFFORT if non-nil."
  (let* ((parent-buffer (when-let* ((agent (courier-agent parent))) (courier-agent-buffer agent)))
         (perspective (and (buffer-live-p parent-buffer) (overlook-agent-perspective parent-buffer)))
         (buffer (let ((overlook-courier--parent parent))
                   (overlook-agent--launch name directory nil t effort))))
    (when perspective (overlook-add-to-perspective perspective buffer))
    (let ((overlook-courier--parent parent)) (overlook-courier--register buffer))
    (buffer-local-value 'overlook-courier-id buffer)))

(defun overlook-courier--mark (buffer)
  "Who spawned agent BUFFER and how many messages wait for it, dimmed; or nil."
  (when-let* ((agent (courier-agent (buffer-local-value 'overlook-courier-id buffer))))
    (let ((parent (courier-agent-parent agent))
          (pending (length (courier-agent-mailbox agent))))
      (concat (if parent (propertize (concat " ← " parent) 'face 'shadow) "")
              (if (> pending 0) (propertize (format " ✉%d" pending) 'face 'warning) "")))))

(defun overlook-courier--room-row (name)
  "Insert the row of room NAME: its unread posts, and whether one names the user."
  (let* ((room (courier-room name))
         (read (plist-get (courier-room-member room courier-room-user) :read))
         (unread (if read
                     (cl-loop for post in (courier-room-posts room)
                              while (> (plist-get post :n) read)
                              collect post)
                   '()))
         (named (seq-some (lambda (post)
                            (and (not (equal (plist-get post :from) courier-room-user))
                                 (courier-room-mentions-p (plist-get post :body) courier-room-user)))
                          unread))
         (members (length (courier-room-members room)))
         (last (car (courier-room-posts room)))
         (meta (propertize (format "%d member%s" members (if (= members 1) "" "s"))
                           'face 'shadow))
         (line (concat overlook-indent "#" name
                       (if unread (propertize (format " ✉%d" (length unread)) 'face 'warning) "")
                       (overlook-align-right meta 1)
                       "\n")))
    (when named
      (add-face-text-property (length overlook-indent) (length line) 'overlook-agent-waiting t line))
    (add-text-properties 0 (length line)
                         `( overlook-item (room . ,name)
                            overlook-action ,(lambda () (overlook-room-open name))
                            overlook-attention ,named
                            help-echo ,(if last (courier-room-format last) "No posts yet"))
                         line)
    (overlook-insert-row line)))

(defun overlook-courier--rooms-section ()
  "Insert the Rooms section: a row per courier room."
  (overlook-insert-section
   (propertize "Rooms" 'overlook-action (lambda () (call-interactively #'overlook-room-open)))
   (lambda () (mapc #'overlook-courier--room-row (courier-room-names)))))

;;;###autoload
(define-minor-mode overlook-courier-mode
  "Let overlook's agents message, spawn and monitor each other through courier."
  :global t
  :group 'overlook
  (overlook-toggle-hooks
   overlook-courier-mode
   '((overlook-agent-environment-functions overlook-courier--environment)
     (overlook-agent-changed-hook overlook-courier--sync)
     (overlook-agent-turn-start-hook overlook-courier--turn-started)
     (overlook-agent-turn-end-hook overlook-courier--turn-finished)
     (overlook-agent-attention-hook overlook-courier--blocked)
     (overlook-agent-row-marks overlook-courier--mark)
     (overlook-sections overlook-courier--rooms-section -10)
     (courier-changed-hook overlook-refresh)))
  (setq courier-spawn-function (and overlook-courier-mode #'overlook-courier--spawn))
  (when overlook-courier-mode (overlook-courier--sync))
  (overlook-refresh))

(provide 'overlook-courier)
;;; overlook-courier.el ends here
