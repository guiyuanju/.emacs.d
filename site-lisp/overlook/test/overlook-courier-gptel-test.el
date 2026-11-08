;;; overlook-courier-gptel-test.el --- Tests for gptel personas -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel)
(require 'gptel-openai)
(require 'overlook-courier)
(require 'overlook-courier-persona)
(require 'overlook-courier-gptel)

(defvar overlook-courier-gptel-test--requests nil
  "Each faked `gptel-request' call as (PROMPT . KEYS), newest first.")

(defmacro overlook-courier-gptel-test-with-persona (&rest body)
  "Run BODY with persona jp on gptel, a fake backend and no real requests."
  (declare (indent 0))
  `(let* ((root (make-temp-file "overlook-courier-gptel" t))
          (overlook-courier-persona-directories (list (expand-file-name "personas/" root)))
          (overlook-courier-gptel-history-directory (expand-file-name "history/" root))
          (overlook-courier--agents (make-hash-table :test #'equal))
          (overlook-courier--retry-timer nil)
          (overlook-courier--delivery-timer nil)
          (overlook-courier-spawn-function (lambda (&rest _) (error "No agent should spawn")))
          (overlook-courier-gptel-test--requests nil)
          (overlook-courier-gptel--last nil))
     (make-directory (expand-file-name "personas/jp" root) t)
     (with-temp-file (expand-file-name "personas/jp/persona.md" root)
       (insert "---\nengine: gptel\nbackend: Fake\nmodel: fake-model\ntools: t_echo\n"
               "memory: off\ntone: terse\n---\nExplain Japanese.\n"))
     (gptel-make-openai "Fake" :key "none" :models '(fake-model))
     (gptel-make-tool :name "t_echo" :function #'identity :description "Echo"
                      :args '((:name "text" :type string :description "Text")))
     (unwind-protect
         (cl-letf (((symbol-function 'gptel-request)
                    (lambda (prompt &rest keys)
                      (push (cons prompt keys) overlook-courier-gptel-test--requests)
                      nil)))
           ,@body)
       (when-let* ((buffer (get-buffer "*jp*")))
         (with-current-buffer buffer (set-buffer-modified-p nil))
         (kill-buffer buffer))
       (when (timerp overlook-courier--retry-timer) (cancel-timer overlook-courier--retry-timer))
       (when (timerp overlook-courier--delivery-timer) (cancel-timer overlook-courier--delivery-timer))
       (delete-directory root t))))

(defun overlook-courier-gptel-test--reply (chunks &optional state results)
  "Answer the newest faked request with CHUNKS, then end it in STATE.
RESULTS are tool results (TOOL ARGS RESULT) given after the chunks."
  (let* ((keys (cdar overlook-courier-gptel-test--requests))
         (callback (plist-get keys :callback))
         (fsm (plist-get keys :fsm)))
    (dolist (chunk chunks) (funcall callback chunk nil))
    (when results (funcall callback (cons 'tool-result results) nil))
    (funcall callback t nil)
    (setf (gptel-fsm-info fsm) (list :status (if (eq state 'ERRS) "HTTP 500" "OK")))
    (gptel--fsm-transition fsm (or state 'DONE))))

(defun overlook-courier-gptel-test--history ()
  "Text of jp's history buffer."
  (with-current-buffer "*jp*" (buffer-string)))

(ert-deftest overlook-courier-gptel-starts-without-an-agent ()
  (overlook-courier-gptel-test-with-persona
    (should (equal (overlook-courier-gptel-names) '("jp")))
    (should (equal (overlook-courier-persona-start "jp") "jp"))
    (let ((buffer (overlook-courier-agent-buffer (overlook-courier-agent "jp"))))
      (should (equal (buffer-name buffer) "*jp*"))
      (should (buffer-local-value 'overlook-courier-gptel-mode buffer)))
    (should-not overlook-courier-gptel-test--requests)
    (should-error (overlook-courier-persona-start "jp"))))

(ert-deftest overlook-courier-gptel-sends-each-prompt-alone ()
  (overlook-courier-gptel-test-with-persona
    (save-window-excursion (overlook-courier-gptel-ask "jp" "食べる"))
    (let ((keys (cdar overlook-courier-gptel-test--requests)))
      (should (equal (caar overlook-courier-gptel-test--requests) "食べる"))
      (should (equal (plist-get keys :system) "Explain Japanese.\n\nTone: terse")))
    (should-not (funcall (overlook-courier-agent-ready (overlook-courier-agent "jp"))))
    (should-error (overlook-courier-gptel-ask "jp" "again"))
    (overlook-courier-gptel-test--reply
     '("吃" "。") 'DONE (list (list (gptel-get-tool "t_echo") '(:text "食べる") "entries/1")))
    (let ((history (overlook-courier-gptel-test--history)))
      (should (string-search "食べる\n\n吃。" history))
      (should (string-search "> t_echo (:text \"食べる\") → entries/1" history)))
    (should (equal (funcall (overlook-courier-agent-reply (overlook-courier-agent "jp"))) "吃。"))
    (should (funcall (overlook-courier-agent-ready (overlook-courier-agent "jp"))))
    (should (eq (buffer-local-value 'overlook-agent-status (get-buffer "*jp*")) 'idle))
    (should (file-exists-p (expand-file-name "jp.md" overlook-courier-gptel-history-directory)))
    (save-window-excursion (overlook-courier-gptel-ask "jp" "飲む"))
    (should (equal (caar overlook-courier-gptel-test--requests) "飲む"))
    (should (= (length overlook-courier-gptel-test--requests) 2))))

(ert-deftest overlook-courier-gptel-reports-a-failed-request ()
  (overlook-courier-gptel-test-with-persona
    (save-window-excursion (overlook-courier-gptel-ask "jp" "x"))
    (overlook-courier-gptel-test--reply nil 'ERRS)
    (should (string-search "> Failed: HTTP 500" (overlook-courier-gptel-test--history)))
    (should (eq (buffer-local-value 'overlook-agent-status (get-buffer "*jp*")) 'failed))
    (should (funcall (overlook-courier-agent-ready (overlook-courier-agent "jp"))))))

(ert-deftest overlook-courier-gptel-takes-courier-messages ()
  (overlook-courier-gptel-test-with-persona
    (overlook-courier-register "a@p" :deliver #'ignore :ready #'always)
    (overlook-courier-send "jp" "Translate 猫" "a@p")
    (should (overlook-courier-agent "jp"))
    (overlook-courier-deliver)
    (should (string-search "Translate 猫" (caar overlook-courier-gptel-test--requests)))
    (should (string-search "From agent a@p" (caar overlook-courier-gptel-test--requests)))))

(provide 'overlook-courier-gptel-test)
;;; overlook-courier-gptel-test.el ends here
