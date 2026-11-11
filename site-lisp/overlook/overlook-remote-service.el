;;; overlook-remote-service.el --- Remote application commands -*- lexical-binding: t; -*-

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

;; Application operations return data, independent of HTTP transport.

;;; Code:

(require 'overlook-remote-activity)
(require 'overlook-remote-contract)

(defcustom overlook-remote-receipt-limit 512
  "Maximum successful idempotent requests remembered in this Emacs."
  :type 'natnum :group 'overlook)

(defcustom overlook-remote-receipt-seconds 3600
  "Seconds successful idempotent requests remain replayable."
  :type 'natnum :group 'overlook)

(defvar overlook-remote-service--receipts (make-hash-table :test #'equal)
  "Request IDs mapped to (TIME SIGNATURE RESULT).")

(defun overlook-remote-service--prune-receipts ()
  "Expire old receipts and enforce the configured capacity."
  (let ((cutoff (- (float-time) overlook-remote-receipt-seconds)) entries)
    (maphash (lambda (key value)
               (if (< (car value) cutoff)
                   (remhash key overlook-remote-service--receipts)
                 (push (cons key (car value)) entries))) overlook-remote-service--receipts)
    (dolist (entry (nthcdr (max 0 overlook-remote-receipt-limit)
                           (sort entries (lambda (a b) (> (cdr a) (cdr b))))))
      (remhash (car entry) overlook-remote-service--receipts))))

(defun overlook-remote-service-once (route body send)
  "Call SEND on BODY for ROUTE once per successful request ID.
Reuse with a different payload fails; confirmations and failures are not cached."
  (overlook-remote-service--prune-receipts)
  (let* ((key (alist-get 'requestId body))
         (signature (cons route (sort (copy-tree body)
                                      (lambda (a b) (string< (symbol-name (car a))
                                                            (symbol-name (car b)))))))
         (receipt (and key (gethash key overlook-remote-service--receipts))))
    (when (and key (not (and (stringp key) (<= 1 (length key) 128))))
      (overlook-remote-contract-error 400 "invalid_request_id" "Invalid request ID"))
    (if receipt
        (if (equal signature (nth 1 receipt)) (copy-tree (nth 2 receipt))
          (overlook-remote-contract-error
           409 "request_id_conflict" "Request ID already used for a different operation"))
      (let ((result (funcall send body)))
        (when (and key (eq (plist-get result :ok) t))
          (puthash key (list (float-time) signature (copy-tree result))
                   overlook-remote-service--receipts)
          (overlook-remote-service--prune-receipts))
        result))))

(defvar overlook-remote-service--confirmation-secret
  (secure-hash 'sha256 (format "%s:%s:%s" (emacs-pid) (float-time) (random)))
  "Per-process nonce for binding confirmations to current operation state.")

(defun overlook-remote-service--token (signature state questions)
  "Return the confirmation token for SIGNATURE, STATE and QUESTIONS."
  (secure-hash 'sha256
               (prin1-to-string (list overlook-remote-service--confirmation-secret
                                      signature state questions))))

(defun overlook-remote-service-prompt (body)
  "Submit BODY's text to its conversation, or queue it while busy."
  (let ((text (string-trim (or (alist-get 'text body) ""))))
    (when (string-empty-p text)
      (overlook-remote-contract-error 400 "empty_text" "Nothing to send"))
    (list :ok t :queued
          (if (overlook-remote--prompt
               (overlook-remote-service-agent-buffer (alist-get 'id body)) text) t :false))))

(defun overlook-remote-service-session (body)
  "Run BODY's allowlisted session operation, returning data or a confirmation."
  (let* ((buffer (overlook-remote-service-agent-buffer (alist-get 'id body)))
         (action (alist-get 'action body))
         (text (string-trim (or (alist-get 'text body) "")))
         (run (or (overlook-agent-get buffer 'remote-action)
                  (overlook-remote-contract-error 400 "unsupported_action" "This agent has no session controls")))
         (controls (overlook-remote--controls buffer))
         (signature (list (overlook-remote-service-agent-id buffer) action text))
         (state (cdr (overlook-remote--state buffer)))
         (questions (append (alist-get 'confirmations body) nil))
         (confirmed (and (equal (alist-get 'confirmationToken body)
                                (overlook-remote-service--token signature state questions))
                         questions))
         (question (pcase action
                     ("reload" "Reload this session? Unsent prompts may be lost.")
                     ("restart" "Start a fresh conversation? Unsent prompts may be lost.")))
         (ask (lambda (prompt &rest _)
                (unless (member prompt confirmed) (throw 'confirm prompt)) t)))
    (unless (or (and (equal action "steer") (plist-get controls :steer))
                (member action (plist-get controls :actions)))
      (overlook-remote-contract-error 400 "unsupported_action"
                                       (format "This agent does not support %s" action)))
    (when (and (equal action "steer") (string-empty-p text))
      (overlook-remote-contract-error 400 "empty_text" "Nothing to steer"))
    (let ((result
           (catch 'confirm
             (when question (funcall ask question))
             (cl-letf (((symbol-function 'y-or-n-p) ask)
                       ((symbol-function 'yes-or-no-p) ask))
               (with-current-buffer buffer (funcall run action text))))))
      (if (stringp result)
          (list :confirm result :confirmationToken
                (overlook-remote-service--token signature state
                                               (append confirmed (list result))))
        (list :ok t :agent (overlook-remote-service-agent-id result))))))

(defun overlook-remote-service-command (body)
  "Run BODY's current row command, returning data or a bound confirmation."
  (overlook-remote--dashboard)
  (let* ((row (or (gethash (alist-get 'node body) overlook-remote--rows)
                  (overlook-remote-contract-error 404 "resource_missing" "That resource is gone")))
         (command (or (overlook-row-command row (alist-get 'name body))
                      (overlook-remote-contract-error 404 "action_missing"
                                                     (format "That resource no longer offers %s"
                                                             (alist-get 'name body)))))
         (text (string-trim (or (alist-get 'text body) "")))
         (option (alist-get 'option body))
         (confirm (plist-get command :confirm))
         (question (if (functionp confirm) (funcall confirm) confirm))
         (state (let ((overlook-remote--rows nil))
                  (plist-get (overlook-remote--node row "") :hash)))
         (signature (list (overlook-row-key row) (alist-get 'name body) text option))
         (token (overlook-remote-service--token signature state (list question))))
    (when (and (plist-get command :input) (string-empty-p text))
      (overlook-remote-contract-error 400 "empty_text" "Nothing to send"))
    (when (and (plist-get command :options) (not (member option (plist-get command :options))))
      (overlook-remote-contract-error 400 "invalid_option"
                                       (format "Pick one of %s"
                                               (string-join (plist-get command :options) ", "))))
    (if (and question (not (and (eq (alist-get 'confirmed body) t)
                               (equal token (alist-get 'confirmationToken body)))))
        (list :confirm (overlook-remote--text question) :confirmationToken token)
      (let ((result (apply (plist-get command :run)
                           (append (and (plist-get command :input) (list text))
                                   (and (plist-get command :options) (list option))))))
        (overlook-refresh)
        (pcase-let ((`(,agent . ,draft) (if (bufferp (car-safe result)) result (list result))))
          `(:ok t ,@(and (overlook-agent-p agent)
                         (list :agent (overlook-remote-service-agent-id agent)))
                  ,@(and draft (list :draft (overlook-remote--text draft)))))))))

(defun overlook-remote-service-unqueue (body)
  "Withdraw BODY's queued prompt by identity, accepting legacy text."
  (overlook-remote--unqueue (overlook-remote-service-agent-buffer (alist-get 'id body))
                           (alist-get 'text body) (alist-get 'queueId body))
  '(:ok t))

(defun overlook-remote-service-seen (body)
  "Acknowledge attention for BODY's conversation."
  (overlook-agent-seen (overlook-remote-service-agent-buffer (alist-get 'id body)))
  '(:ok t))

(defun overlook-remote-service-retry (body)
  "Allow BODY's conversation to retry delivery after a queue error."
  (overlook-remote--clear-queue-error
   (overlook-remote-service-agent-buffer (alist-get 'id body)))
  '(:ok t))

(defun overlook-remote-service-choose (body)
  "Answer BODY's currently available conversation choice."
  (overlook-agent-choose (overlook-remote-service-agent-buffer (alist-get 'id body))
                         (alist-get 'key body))
  '(:ok t))

(defun overlook-remote-service-upload (body)
  "Attach BODY's validated image to its conversation and return input text."
  (let* ((buffer (overlook-remote-service-agent-buffer (alist-get 'id body)))
         (mime (alist-get 'mime body))
         (extension (car (rassoc mime overlook-remote--image-types)))
         (encoded (alist-get 'data body))
         (attach (or (overlook-agent-get buffer 'attach)
                     (overlook-remote-contract-error
                      409 "attachment_unsupported" "This conversation cannot take files"))))
    (unless (and extension (stringp encoded))
      (overlook-remote-contract-error 400 "invalid_image" "Send a PNG, JPEG, GIF or WebP image"))
    (when (> (length encoded) (+ 4 (* 4 (ceiling overlook-remote-image-size 3))))
      (overlook-remote-contract-error 413 "image_too_large" "The image exceeds the attachment size limit"))
    (let ((data (condition-case nil (base64-decode-string encoded) (error nil))))
      (unless (and data (overlook-remote--image-data-p data mime))
        (overlook-remote-contract-error 400 "invalid_image" "The image data does not match its MIME type"))
      (when (> (length data) overlook-remote-image-size)
        (overlook-remote-contract-error 413 "image_too_large" "The image exceeds the attachment size limit"))
      (list :text (overlook-remote--text
                   (with-current-buffer buffer
                     (funcall attach (format "phone-%s.%s"
                                             (format-time-string "%Y%m%d-%H%M%S-%3N") extension)
                              data)))))))

(defun overlook-remote-service-diff (node-id)
  "Return the current unified diff for NODE-ID."
  (overlook-remote--dashboard)
  (let* ((row (or (gethash node-id overlook-remote--rows)
                  (overlook-remote-contract-error 404 "resource_missing" "That resource is gone")))
         (diff (or (overlook-row-diff row)
                   (overlook-remote-contract-error 404 "diff_missing" "That resource has no diff"))))
    (list :diff (overlook-remote--cut (funcall diff)))))

(provide 'overlook-remote-service)
;;; overlook-remote-service.el ends here
