;;; overlook-data.el --- Shared semantic business queries -*- lexical-binding: t; -*-

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

;; Queries use business identities, independent of display rows and HTTP.

;;; Code:

(require 'overlook-agent-core)

(defvar overlook-data-functions nil
  "Functions of a business key returning a semantic plist, or nil.
Keys identify domain objects, such as (repo . DIRECTORY).  Providers
return values without faces, glyphs, alignment or formatted numbers.")

(defvar-local overlook-data--agent-id nil
  "Opaque identity of this live conversation, independent of its buffer name.")
(put 'overlook-data--agent-id 'permanent-local t)

(defun overlook-data-agent-id (buffer)
  "Stable opaque identity for live conversation BUFFER."
  (with-current-buffer buffer
    (or overlook-data--agent-id
        (setq overlook-data--agent-id
              (concat "conversation-"
                      (secure-hash 'sha256
                                   (format "%s:%s:%s" (emacs-pid) (float-time) (random))))))))

(defun overlook-data-id (key)
  "Opaque identity for business KEY, stable across display changes."
  (if (and (eq (car-safe key) 'agent) (buffer-live-p (cdr key)))
      (overlook-data-agent-id (cdr key))
    (let ((identity (pcase key
                      (`(closed-project ,name) (cons 'project name))
                      (`(saved . ,saved)
                       (list 'saved (alist-get 'agent saved)
                             (alist-get 'root saved) (alist-get 'session saved)))
                      (_ key))))
      (secure-hash 'sha256 (let ((print-length nil) (print-level nil))
                            (prin1-to-string identity))))))

(defun overlook-agent-data (buffer)
  "Current semantic conversation data of agent BUFFER."
  (when (overlook-agent-p buffer)
    (let ((turn (buffer-local-value 'overlook-agent-turn buffer)))
      (list :kind "agent" :title (or (overlook-agent-title buffer) "")
            :provider (or (overlook-agent-get buffer 'agent) "agent")
            :status (symbol-name (buffer-local-value 'overlook-agent-status buffer))
            :subtitle (or (overlook-agent-brief buffer) "")
            :context (buffer-local-value 'overlook-agent-context buffer)
            :durationSeconds (and turn (max 0 (- (or (cdr turn) (float-time)) (car turn))))))))

(defun overlook-data (key)
  "Semantic business data identified by KEY, or nil if unsupported."
  (let ((data
         (or (run-hook-with-args-until-success 'overlook-data-functions key)
             (pcase key
               (`(agent . ,buffer) (overlook-agent-data buffer))
               (`(saved . ,saved)
                (list :kind "saved" :title (or (alist-get 'title saved) "Saved conversation")
                      :provider (alist-get 'agent saved) :status "saved"
                      :subtitle "Saved conversation"))
               (`(project . ,name) (list :kind "project" :title name :projectId name))
               (`(closed-project ,name) (list :kind "project" :title name :projectId name))
               (`(section ,name) (list :kind "group" :title name))
               (`(project-status ,status) (list :kind "group" :title status))))))
    (when data
      (unless (plist-get data :resourceId)
        (setq data (plist-put data :resourceId (overlook-data-id key))))
      data)))

(provide 'overlook-data)
;;; overlook-data.el ends here
