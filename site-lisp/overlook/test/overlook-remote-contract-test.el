;;; overlook-remote-contract-test.el --- API contract tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-remote-contract)
(require 'overlook-remote)

(defconst overlook-remote-contract-test--schema-file
  (expand-file-name "../docs/remote-api.schema.json"
                    (file-name-directory (or load-file-name buffer-file-name))))

(defun overlook-remote-contract-test--schema-p (value schema root)
  "Validate VALUE against SCHEMA and ROOT using the contract's schema keywords."
  (cl-labels ((get (key) (gethash key schema))
              (valid (item subschema)
                (overlook-remote-contract-test--schema-p item subschema root))
              (type-p (name)
                (pcase name
                  ("null" (eq value :null))
                  ("boolean" (memq value '(t :false)))
                  ("string" (stringp value))
                  ("integer" (integerp value))
                  ("number" (numberp value))
                  ("array" (and (vectorp value) (not (stringp value))))
                  ("object" (hash-table-p value)))))
    (cond
     ((get "$ref")
      (valid value (gethash (substring (get "$ref") 8) (gethash "$defs" root))))
     ((get "anyOf") (cl-some (lambda (sub) (valid value sub)) (get "anyOf")))
     ((get "oneOf") (= 1 (cl-count-if (lambda (sub) (valid value sub)) (get "oneOf"))))
     (t
      (and
       (or (not (get "type"))
           (if (stringp (get "type")) (type-p (get "type"))
             (cl-some #'type-p (get "type"))))
       (or (eq (gethash "const" schema 'missing) 'missing)
           (equal value (get "const")))
       (or (not (get "enum")) (member value (append (get "enum") nil)))
       (or (not (numberp value))
           (and (or (not (get "minimum")) (>= value (get "minimum")))
                (or (not (get "maximum")) (<= value (get "maximum")))))
       (or (not (stringp value))
           (and (or (not (get "minLength")) (>= (length value) (get "minLength")))
                (or (not (get "maxLength")) (<= (length value) (get "maxLength")))))
       (or (not (hash-table-p value))
           (and (cl-every (lambda (key) (not (eq (gethash key value 'missing) 'missing)))
                          (get "required"))
                (let ((valid t))
                  (maphash (lambda (key item)
                             (let ((sub (and (get "properties")
                                             (gethash key (get "properties")))))
                               (unless (if sub (valid item sub)
                                         (not (eq (get "additionalProperties") :false)))
                                 (setq valid nil)))) value)
                  valid)))
       (or (not (and (vectorp value) (not (stringp value))))
           (not (get "items"))
           (cl-every (lambda (item) (valid item (get "items"))) value)))))))

(defun overlook-remote-contract-test--valid (data definition)
  "Validate serialized DATA against schema DEFINITION."
  (let ((schema (with-temp-buffer
                  (insert-file-contents overlook-remote-contract-test--schema-file)
                  (json-parse-buffer))))
    (overlook-remote-contract-test--schema-p
     (json-parse-string (json-serialize data))
     (gethash definition (gethash "$defs" schema)) schema)))

(ert-deftest overlook-remote-contract-distinguishes-wire-types ()
  (let* ((node (overlook-remote-contract-node
                '(:kind "usage" :title "Claude" :account nil :context 0
                  :windows [(:label "5h" :value 0 :reset nil)]
                  :face error :spans [(:text "bad")])))
         (json (json-serialize node)))
    (should (string-search "\"account\":null" json))
    (should (string-search "\"reset\":null" json))
    (should (string-search "\"value\":0" json))
    (should-not (plist-member node :face))
    (should-not (plist-member node :spans))
    (should-not (plist-member node :subtitle))
    (should-error (overlook-remote-contract-node '(:kind "todo" :title (:text "bad"))))))

(ert-deftest overlook-remote-contract-conversation-encodes-empty-arrays-and-false ()
  (let ((conversation
         (overlook-remote-contract-conversation
          '(:id "c1" :agent "claude" :status "idle" :title "Task"
            :context nil :queued nil :queueItems nil :choices nil
            :controls (:slash [] :steer :false :actions [])))))
    (should (eq (plist-get conversation :context) :null))
    (should (equal (plist-get conversation :queued) []))
    (should (overlook-remote-contract-test--valid conversation "Conversation"))))

(ert-deftest overlook-remote-contract-schemas-cover-full-and-delta-responses ()
  (should (overlook-remote-contract-test--valid
           (overlook-remote-contract-response '(:ok t :closed t)) "Result"))
  (let* ((node (append '(:id "n1" :hash "h1" :children [])
                       (overlook-remote-contract-node
                        '(:kind "todo" :title "Task" :subtitle nil :due nil)))))
    (should (overlook-remote-contract-test--valid
             (overlook-remote-contract-response (list :sections (vector node) :known "v1"))
             "Dashboard"))
    (should (overlook-remote-contract-test--valid
             (overlook-remote-contract-response '(:sections [(:same "h1")] :known "v1"))
             "Dashboard"))
    (should-not (overlook-remote-contract-test--valid
                 (overlook-remote-contract-response
                  (list :sections (vector (plist-put (copy-sequence node) :subtitle '(:bad t)))
                        :known "v1")) "Dashboard"))
    (should (overlook-remote-contract-test--valid
             (overlook-remote-problem 409 "state_changed" "Reload and try again") "Problem"))))

(ert-deftest overlook-remote-contract-rejects-malformed-requests-before-dispatch ()
  (dolist (body '("text" 2 :null [1] ((id . "c1") (text . 42))
                        ((id . "c1")) ((id . "c1") (text . "   "))))
    (should-error (overlook-remote-contract-request "/api/prompt" body)
                  :type 'overlook-remote-api-error))
  (should (overlook-remote-contract-request
           "/api/prompt" '((id . "c1") (text . "Hello") (requestId . "r1"))))
  (should-error (overlook-remote-contract-request
                 "/api/session" '((id . "c1") (action . "restart") (confirmations . "yes")))
                :type 'overlook-remote-api-error)
  (should-error (overlook-remote-contract-request
                 "/api/prompt" '((id . "c1") (text . "Hello") (protocolVersion . 1)))
                :type 'overlook-remote-api-error))

(ert-deftest overlook-remote-contract-rejects-invalid-query-integers ()
  (dolist (value '("12oops" "-1" "" "1.5" "1e3"))
    (should-error (overlook-remote-contract-query "/api/events" `(("id" "c1") ("after" ,value)))
                  :type 'overlook-remote-api-error))
  (should (overlook-remote-contract-query "/api/events" '(("id" "c1") ("after" "0")))))


(ert-deftest overlook-remote-contract-validates-real-http-responses ()
  (let ((agent (generate-new-buffer " *remote-contract-agent*"))
        (overlook-remote--dashboard nil)
        (overlook-remote--versions nil)
        (overlook-remote--rows nil))
    (unwind-protect
        (progn
          (with-current-buffer agent
            (setq overlook-agent-identity
                  '((agent . "claude") (root . "/work/project/")
                    (title . "Contract fixture")))
            (setq overlook-agent-status 'idle
                  overlook-agent-context nil))
          (cl-letf (((symbol-function 'overlook-remote--authorized-p) #'always)
                    ((symbol-function 'overlook-agent-buffers) (lambda () (list agent)))
                    ((symbol-function 'overlook-remote--model)
                     (lambda () (list (overlook-row :id '(project . "Demo")
                                                   :content "Demo")))))
            (dolist (case '(("/api/agents" nil "Conversations")
                            ("/api/agent" t "Conversation")
                            ("/api/events" t "Events")
                            ("/api/dashboard" nil "Dashboard")))
              (pcase-let* ((`(,route ,agent-query ,definition) case)
                           (`(,status ,_mime ,json)
                            (overlook-remote--respond
                             "GET" (concat "/overlook" route)
                             (when agent-query
                               (list (list "id" (overlook-remote-service-agent-id agent))))
                             nil)))
                (should (= status 200))
                (should (overlook-remote-contract-test--valid
                         (json-parse-string json) definition))))
            (pcase-let ((`(,status ,mime ,json)
                         (overlook-remote--respond
                          "GET" "/overlook/api/events" '(("after" "1oops")) nil)))
              (should (= status 400))
              (should (equal mime "application/problem+json"))
              (should (overlook-remote-contract-test--valid
                       (json-parse-string json) "Problem")))))
      (kill-buffer agent))))

(provide 'overlook-remote-contract-test)
;;; overlook-remote-contract-test.el ends here
