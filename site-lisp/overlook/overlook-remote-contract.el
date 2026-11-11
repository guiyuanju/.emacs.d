;;; overlook-remote-contract.el --- Typed remote API contracts -*- lexical-binding: t; -*-

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

;; Defines the wire types shared by HTTP, model and activity adapters.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst overlook-remote-protocol-version 2
  "Version of the remote API data contract.")

(define-error 'overlook-remote-api-error "Remote API error")

(defun overlook-remote-contract-error (status code detail)
  "Signal an API error with HTTP STATUS, stable CODE and human DETAIL."
  (signal 'overlook-remote-api-error (list status code detail)))

(defun overlook-remote-problem (status code detail)
  "Return problem details with STATUS, CODE and human DETAIL."
  (list :type (concat "urn:overlook:problem:" code)
        :title (or (cdr (assq status '((400 . "Invalid request")
                                      (401 . "Authentication required")
                                      (404 . "Resource not found")
                                      (405 . "Method not allowed")
                                      (409 . "State conflict")
                                      (413 . "Request too large")
                                      (500 . "Internal server error"))))
                   "Request failed")
        :status status :code code :detail detail :error detail
        :protocolVersion overlook-remote-protocol-version))

(defun overlook-remote-contract--type-p (value type)
  "Return whether VALUE satisfies wire TYPE."
  (pcase type
    ('string (stringp value))
    ('nonempty (and (stringp value) (not (string-empty-p (string-trim value)))))
    ('number (numberp value))
    ('integer (and (integerp value) (>= value 0)))
    ('boolean (memq value '(t :false)))
    ('strings (and (vectorp value) (cl-every #'stringp value)))
    ('nullable-string (or (null value) (eq value :null) (stringp value)))
    (_ nil)))

(defun overlook-remote-contract--field (value type name)
  "Encode VALUE as TYPE, naming NAME in contract failures."
  (pcase type
    (`(enum . ,values)
     (unless (member value values)
       (error "Remote contract: invalid %s" name))
     value)
    (`(nullable ,inner)
     (if (or (null value) (eq value :null)) :null
       (overlook-remote-contract--field value inner name)))
    (`(array ,inner)
     (unless (or (null value) (listp value) (vectorp value))
       (error "Remote contract: %s must be an array" name))
     (vconcat (mapcar (lambda (item) (overlook-remote-contract--field item inner name)) value)))
    (`(object ,fields)
     (overlook-remote-contract--object value fields))
    (`(or . ,types)
     (or (cl-loop for candidate in types
                  when (overlook-remote-contract--type-p value candidate)
                  return (overlook-remote-contract--field value candidate name))
         (error "Remote contract: invalid %s" name)))
    (_
     (unless (overlook-remote-contract--type-p value type)
       (error "Remote contract: invalid %s (%s)" name type))
     (if (stringp value) (substring-no-properties value) value))))

(defun overlook-remote-contract--object (data fields)
  "Encode DATA using explicit FIELDS, each (KEY TYPE REQUIRED)."
  (let (result)
    (dolist (field fields)
      (pcase-let ((`(,key ,type . ,required) field))
        (when (or required (plist-member data key))
          (setq result (append result
                               (list key (overlook-remote-contract--field
                                          (plist-get data key) type key)))))))
    result))

(defconst overlook-remote-contract--node-fields
  '((:kind string t) (:title string t)
    (:subtitle (nullable string)) (:provider (nullable string))
    (:status (nullable string)) (:context (nullable number))
    (:duration (nullable (or string number))) (:durationSeconds (nullable number))
    (:resourceId string)
    (:account (nullable string)) (:branch (nullable string))
    (:path (nullable string)) (:from (nullable string))
    (:added (nullable integer)) (:removed (nullable integer))
    (:due (nullable string)) (:projectId (nullable string))
    (:repositoryId (nullable string)) (:conversationId (nullable string))
    (:taskId (nullable string))
    (:windows (array (object ((:label string t)
                             (:value (nullable (or string number)) t)
                             (:reset (nullable (or string number))))))))
  "Allowed semantic node fields and their wire types.")

(defun overlook-remote-contract-node (data)
  "Encode semantic node DATA without presentation properties."
  (overlook-remote-contract--object data overlook-remote-contract--node-fields))

(defconst overlook-remote-contract--conversation-fields
  '((:id string t) (:bufferName string) (:agent string t) (:status (enum "idle" "working" "waiting" "done" "failed") t)
    (:title string t) (:project string) (:folder string) (:brief string)
    (:context (nullable number)) (:queueError (nullable string))
    (:reply string) (:transcript string)
    (:choices (array (object ((:key string t) (:label string t)))))
    (:queued (array string))
    (:queueItems (array (object ((:id string t) (:text string t)))))
    (:controls (object ((:slash (array (object ((:name string t) (:description string)))))
                        (:steer boolean) (:actions (array string))))))
  "Conversation fields and their wire types.")

(defun overlook-remote-contract-conversation (data)
  "Encode conversation DATA with explicit arrays, booleans and nullable fields."
  (overlook-remote-contract--object data overlook-remote-contract--conversation-fields))

(defun overlook-remote-contract-response (data)
  "Add protocol metadata to response object DATA."
  (cons :protocolVersion (cons overlook-remote-protocol-version data)))

(defconst overlook-remote-contract--requests
  '(("/api/prompt" (id nonempty t) (text nonempty t))
    ("/api/session" (id nonempty t) (action nonempty t) (text string)
     (confirmations strings) (confirmationToken nonempty))
    ("/api/unqueue" (id nonempty t) (text string) (queueId nonempty))
    ("/api/seen" (id nonempty t))
    ("/api/retry" (id nonempty t))
    ("/api/choose" (id nonempty t) (key nonempty t))
    ("/api/command" (node nonempty t) (name nonempty t) (text string)
     (option string) (confirmed boolean) (version nonempty) (confirmationToken nonempty))
    ("/api/upload" (id nonempty t) (mime nonempty t) (data nonempty t)))
  "Known request bodies as (ROUTE (FIELD TYPE REQUIRED)...).")

(defun overlook-remote-contract-request (route body)
  "Validate ROUTE's parsed JSON BODY alist and return it."
  (unless (and (listp body)
               (cl-every (lambda (pair) (and (consp pair) (symbolp (car pair)))) body))
    (overlook-remote-contract-error 400 "invalid_body" "The body must be a JSON object"))
  (dolist (field (append (cdr (assoc route overlook-remote-contract--requests))
                         '((requestId nonempty) (protocolVersion integer))))
    (pcase-let ((`(,key ,type . ,required) field))
      (when (or required (assq key body))
        (unless (overlook-remote-contract--type-p (alist-get key body) type)
          (overlook-remote-contract-error
           400 "invalid_field" (format "Invalid or missing field: %s" key))))))
  (when-let* ((key (alist-get 'requestId body)))
    (when (> (length key) 128)
      (overlook-remote-contract-error 400 "invalid_field" "Request ID exceeds 128 characters")))
  (when-let* ((version (alist-get 'protocolVersion body)))
    (unless (= version overlook-remote-protocol-version)
      (overlook-remote-contract-error 409 "protocol_mismatch" "Refresh the page to update the API client")))
  (when (and (equal route "/api/unqueue")
             (not (or (alist-get 'queueId body) (alist-get 'text body))))
    (overlook-remote-contract-error 400 "invalid_field" "A queue item ID is required"))
  body)

(defun overlook-remote-contract-query (route query)
  "Validate parsed QUERY for ROUTE and return it."
  (dolist (key (pcase route
                ((or "/api/agent" "/api/events") '("id"))
                ("/api/diff" '("node"))
                ("/api/image" '("n"))))
    (let ((value (cadr (assoc key query))))
      (unless (and (stringp value) (not (string-empty-p value)))
        (overlook-remote-contract-error 400 "invalid_query" (concat "Missing query: " key)))))
  (dolist (key '("after" "n" "protocolVersion"))
    (when-let* ((pair (assoc key query)))
      (unless (and (stringp (cadr pair)) (string-match-p "\\`[0-9]+\\'" (cadr pair)))
        (overlook-remote-contract-error 400 "invalid_query" (concat "Invalid integer query: " key)))))
  (when-let* ((version (cadr (assoc "protocolVersion" query))))
    (unless (= (string-to-number version) overlook-remote-protocol-version)
      (overlook-remote-contract-error 409 "protocol_mismatch" "Refresh the page to update the API client")))
  query)

(provide 'overlook-remote-contract)
;;; overlook-remote-contract.el ends here
