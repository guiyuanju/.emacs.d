;;; overlook-watchdog.el --- Report agents that seem stuck -*- lexical-binding: t; -*-

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

;; While `overlook-watchdog-mode' is on, agents are checked every
;; `overlook-watchdog-interval' seconds by fixed rules, with no model:
;;
;; - an agent another agent spawned has run one turn longer than
;;   `overlook-watchdog-turn-limit', or waited for the user longer than
;;   `overlook-watchdog-waiting-limit';
;; - a courier delivery to any agent has started no turn within
;;   `overlook-watchdog-delivery-limit' though the agent is ready; the
;;   agent then gets no more mail, so it is let take mail again.
;;
;; Each finding is a courier event, emitted once, from `watchdog' in the
;; thread `overlook-watchdog-room'.  When no agent follows that room, it
;; goes to the stuck agent's parent, else to
;; `courier-room-publish-fallback'.

;;; Code:

(require 'overlook-agent)
(require 'overlook-courier)
(require 'courier-event)

(defcustom overlook-watchdog-interval 60
  "Seconds between checks of the agents."
  :type 'number
  :group 'overlook)

(defcustom overlook-watchdog-turn-limit (* 30 60)
  "Seconds a spawned agent's turn may run before it is reported."
  :type 'number
  :group 'overlook)

(defcustom overlook-watchdog-waiting-limit (* 15 60)
  "Seconds a spawned agent may wait for the user before it is reported."
  :type 'number
  :group 'overlook)

(defcustom overlook-watchdog-delivery-limit 120
  "Seconds a courier delivery may go without starting a turn."
  :type 'number
  :group 'overlook)

(defcustom overlook-watchdog-room "watchdog"
  "Room the findings are published in."
  :type 'string
  :group 'overlook)

(defvar overlook-watchdog--waiting (make-hash-table :test #'eq)
  "Each agent buffer seen waiting, to when it was first seen so.")

(defun overlook-watchdog--report (id kind since text)
  "Emit TEXT about agent ID once for finding KIND that began at SINCE."
  (courier-event-emit
   (list :source "watchdog" :thread overlook-watchdog-room :text text
         :key (format "%s %s %s" id kind since)
         :fallback (when-let* ((agent (courier-agent id))) (courier-agent-parent agent)))))

(defun overlook-watchdog--minutes (seconds)
  "SECONDS as whole minutes."
  (format "%d min" (round seconds 60)))

(defun overlook-watchdog--check-agent (buffer now)
  "Check agent BUFFER, spawned by another agent, at time NOW."
  (let* ((id (buffer-local-value 'overlook-courier-id buffer))
         (brief (or (overlook-agent--brief buffer) "no activity shown")))
    (with-current-buffer buffer
      (when-let* (((overlook-agent-turn-open-p))
                  (start (car overlook-agent-turn))
                  ((> (- now start) overlook-watchdog-turn-limit)))
        (overlook-watchdog--report
         id 'turn start
         (format "%s has run one turn for %s; now: %s.  If it loops or drifts from \
its task, tell your user; a message reaches it only after the turn."
                 id (overlook-watchdog--minutes (- now start)) brief))))
    (if (not (eq (buffer-local-value 'overlook-agent-status buffer) 'waiting))
        (remhash buffer overlook-watchdog--waiting)
      (let ((since (or (gethash buffer overlook-watchdog--waiting)
                       (puthash buffer now overlook-watchdog--waiting))))
        (when (> (- now since) overlook-watchdog-waiting-limit)
          (overlook-watchdog--report
           id 'waiting since
           (format "%s has waited for the user for %s: %s.  Remind your user; \
only they can answer in its buffer."
                   id (overlook-watchdog--minutes (- now since)) brief)))))))

(defun overlook-watchdog-check ()
  "Check every agent against the watchdog's rules, publishing what is new."
  (interactive)
  (let ((now (float-time)))
    (dolist (agent (courier-stalled overlook-watchdog-delivery-limit))
      (let ((id (courier-agent-id agent))
            (since (courier-agent-delivered agent)))
        (courier-unstall id)
        (overlook-watchdog--report
         id 'delivery since
         (format "A message delivered to %s %s ago started no turn, so it got no \
more mail; it takes mail again now.  The message may be lost: ask %s \
whether it has it."
                 id (overlook-watchdog--minutes (- now since)) id))))
    (dolist (buffer (overlook-agent-buffers))
      (when-let* ((id (buffer-local-value 'overlook-courier-id buffer))
                  (agent (courier-agent id))
                  ((courier-agent-parent agent)))
        (overlook-watchdog--check-agent buffer now)))
    (dolist (buffer (hash-table-keys overlook-watchdog--waiting))
      (unless (buffer-live-p buffer) (remhash buffer overlook-watchdog--waiting)))))

;;;###autoload
(define-minor-mode overlook-watchdog-mode
  "Report agents that seem stuck, by fixed rules, as courier events."
  :global t
  :group 'overlook
  (if overlook-watchdog-mode
      (courier-event-add-source 'watchdog :interval overlook-watchdog-interval
                                :poll #'overlook-watchdog-check)
    (courier-event-remove-source 'watchdog)))

(provide 'overlook-watchdog)
;;; overlook-watchdog.el ends here
