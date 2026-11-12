;;; overlook-courier-gptel-test.el --- Tests for gptel personas -*- lexical-binding: t; -*-

(require 'ert)
(require 'gptel)
(require 'gptel-openai)
(require 'overlook-courier)
(require 'overlook-courier-persona)
(require 'overlook-courier-gptel)
(require 'overlook-agent)
(require 'overlook-agent-courier)

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
      (should (with-current-buffer buffer (derived-mode-p 'overlook-courier-gptel-mode)))
      (should (string-suffix-p "jp> " (with-current-buffer buffer (buffer-string)))))
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
    ;; Finished unseen.
    (should (eq (buffer-local-value 'overlook-agent-status (get-buffer "*jp*")) 'done))
    (should (file-exists-p (expand-file-name "jp.md" overlook-courier-gptel-history-directory)))
    (save-window-excursion (overlook-courier-gptel-ask "jp" "飲む"))
    (should (equal (caar overlook-courier-gptel-test--requests) "飲む"))
    (should (= (length overlook-courier-gptel-test--requests) 2))))

(ert-deftest overlook-courier-gptel-asks-what-is-typed-at-its-prompt ()
  (overlook-courier-gptel-test-with-persona
    (overlook-courier-persona-start "jp")
    (with-current-buffer "*jp*"
      (should-error (overlook-courier-gptel-submit))
      (goto-char (point-max))
      (insert "猫")
      (overlook-courier-gptel-submit)
      (should (equal (caar overlook-courier-gptel-test--requests) "猫"))
      (should (overlay-buffer overlook-courier-gptel--spinner))
      (insert "犬")
      (should-error (overlook-courier-gptel-submit))
      (overlook-courier-gptel-test--reply '("cat"))
      ;; The draft typed while it answered waits at the new prompt.
      (should (string-suffix-p "jp> 猫\n\ncat\n\njp> 犬" (buffer-string)))
      (should-not overlook-courier-gptel--spinner)
      (should-not (seq-some (lambda (o) (overlay-get o 'after-string))
                            (overlays-in (point-min) (point-max)))))
    (should (string-search "猫\n\ncat"
                           (with-temp-buffer
                             (insert-file-contents
                              (expand-file-name "jp.md" overlook-courier-gptel-history-directory))
                             (buffer-string))))))

(ert-deftest overlook-courier-gptel-archives-its-history-when-it-starts ()
  (overlook-courier-gptel-test-with-persona
    (make-directory overlook-courier-gptel-history-directory t)
    (with-temp-file (expand-file-name "jp.md" overlook-courier-gptel-history-directory)
      (insert "\n## 2026-01-01 00:00\n\n猫\n\ncat\n"))
    (overlook-courier-persona-start "jp")
    (should (equal (overlook-courier-gptel-test--history) "jp> "))
    (should-not (file-exists-p (expand-file-name "jp.md" overlook-courier-gptel-history-directory)))
    (should (= (length (directory-files (expand-file-name "archive/" overlook-courier-gptel-history-directory)
                                        nil "\\`jp-.*\\.md\\'"))
               1))))

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

(ert-deftest overlook-courier-gptel-tells-courier-its-turns-without-the-bridge ()
  (overlook-courier-gptel-test-with-persona
    (let ((told nil))
      (overlook-courier-register "a@p" :deliver (lambda (text) (push text told)) :ready #'always)
      (overlook-courier-persona-start "jp" :from "a@p")
      (should (buffer-local-value 'overlook-courier-gptel--own-turns (get-buffer "*jp*")))
      (overlook-courier-monitor "a@p" "jp")
      (save-window-excursion (overlook-courier-gptel-ask "jp" "猫"))
      (overlook-courier-gptel-test--reply '("cat"))
      (overlook-courier-deliver)
      (should (string-search "cat" (car told))))))

(ert-deftest overlook-courier-gptel-runs-as-an-agent ()
  (overlook-courier-gptel-test-with-persona
    (let ((events nil)
          (told nil)
          (overlook-agent-event-functions nil))
      (add-hook 'overlook-agent-event-functions
                (lambda (_buffer event) (push (plist-get event :type) events)))
      (unwind-protect
          (progn
            (overlook-agent-courier-mode 1)
            (overlook-courier-register "a@p" :deliver (lambda (text) (push text told)) :ready #'always)
            (overlook-courier-persona-start "jp" :from "a@p")
            (let ((buffer (get-buffer "*jp*")))
              (should (overlook-agent-p buffer))
              (should (member buffer (overlook-agent-buffers)))
              (should (equal (overlook-agent-get buffer 'agent) "fake"))
              ;; The bridge registered it with courier under the persona's name.
              (should (equal (buffer-local-value 'overlook-agent-courier-id buffer) "jp"))
              (should-not (buffer-local-value 'overlook-courier-gptel--own-turns buffer))
              (should (eq (overlook-courier-agent-buffer (overlook-courier-agent "jp")) buffer))
              (should (equal (overlook-courier-agent-parent (overlook-courier-agent "jp")) "a@p"))
              (should (equal (hash-table-count overlook-courier--agents) 2))
              ;; Listed with the personas, standing for the agent, and kept out of projects.
              (should (overlook-agent-courier--persona-item-p (cons 'agent buffer)))
              (should (equal (overlook-row-id (overlook-agent-courier--persona-row "jp"))
                             (cons 'agent buffer)))
              (overlook-courier-monitor "a@p" "jp")
              ;; A view prompts it the way it prompts any agent.
              (with-current-buffer buffer (funcall (overlook-agent-get buffer 'submit) "猫"))
              (should (equal (caar overlook-courier-gptel-test--requests) "猫"))
              (should (eq (buffer-local-value 'overlook-agent-status buffer) 'working))
              (should-not (with-current-buffer buffer (funcall (overlook-agent-get buffer 'ready))))
              (overlook-courier-gptel-test--reply
               '("cat") 'DONE (list (list (gptel-get-tool "t_echo") '(:text "猫") "entries/2")))
              (should (equal (reverse events) '(prompt text tool end)))
              (should (equal (with-current-buffer buffer (funcall (overlook-agent-get buffer 'reply))) "cat"))
              (should (cdr (buffer-local-value 'overlook-agent-turn buffer)))
              (should (eq (buffer-local-value 'overlook-agent-status buffer) 'done))
              (should (equal (overlook-agent-brief buffer) "cat"))
              ;; Courier heard the turn end through overlook's hooks.
              (overlook-courier-deliver)
              (should (string-search "cat" (car told)))
              ;; A failed turn reaches courier with its error.
              (with-current-buffer buffer (funcall (overlook-agent-get buffer 'submit) "犬"))
              (overlook-courier-gptel-test--reply nil 'ERRS)
              (should (eq (buffer-local-value 'overlook-agent-status buffer) 'failed))
              (should (string-search "HTTP 500" (buffer-local-value 'overlook-agent-error buffer)))))
        (overlook-agent-courier-mode -1)))))

(ert-deftest overlook-courier-gptel-restarts-with-its-history-archived ()
  (overlook-courier-gptel-test-with-persona
    (save-window-excursion (overlook-courier-gptel-ask "jp" "猫"))
    (let ((old (get-buffer "*jp*")))
      (should (member "restart" (plist-get (with-current-buffer old
                                             (funcall (overlook-agent-get old 'remote-controls)))
                                           :actions)))
      ;; Not while it answers.
      (should-error (with-current-buffer old
                      (funcall (overlook-agent-get old 'remote-action) "restart" "")))
      (overlook-courier-gptel-test--reply '("cat"))
      (let ((new (with-current-buffer old
                   (funcall (overlook-agent-get old 'remote-action) "restart" ""))))
        (should-not (buffer-live-p old))
        (should (equal (buffer-name new) "*jp*"))
        (should (overlook-agent-p new))
        (should (equal (with-current-buffer new (buffer-string)) "jp> "))
        (should (eq (overlook-courier-agent-buffer (overlook-courier-agent "jp")) new))
        (let ((archived (directory-files (expand-file-name "archive/" overlook-courier-gptel-history-directory)
                                         t "\\`jp-.*\\.md\\'")))
          (should (= (length archived) 1))
          (should (string-search "猫\n\ncat" (with-temp-buffer (insert-file-contents (car archived))
                                                               (buffer-string)))))))))

(provide 'overlook-courier-gptel-test)
;;; overlook-courier-gptel-test.el ends here
