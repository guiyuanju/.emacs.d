;;; overlook-usage-subscription-test.el --- Quota polling tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-usage-subscription)

(ert-deftest overlook-subscription-parses-service-responses ()
  (should (equal
           (overlook-usage-subscription--parse
            'claude '((five_hour (utilization . 0) (resets_at . "2026-11-12T00:00:00Z"))
                      (seven_day (utilization . 100) (resets_at . 200))))
           (list (list "5h" 0 (float-time (date-to-time "2026-11-12T00:00:00Z")))
                 '("7d" 100 200))))
  (should (equal
           (overlook-usage-subscription--parse
            'codex '((rate_limit (primary_window (used_percent . 25) (reset_at . 100)))))
           '(("5h" 25 100))))
  (should-error (overlook-usage-subscription--parse 'codex '((rate_limit))))
  (should-error (overlook-usage-subscription--parse
                 'claude '((five_hour (utilization . 0))))))

(ert-deftest overlook-subscription-failure-backs-off-and-preserves-reading ()
  (let ((overlook-usage-subscription--state (make-hash-table :test #'equal))
        (overlook-usage-subscription-interval 300))
    (puthash "claude" '(:windows (("5h" 100 200))) overlook-usage-subscription--state)
    (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 100)))
      (overlook-usage-subscription--failed "claude")
      (should (= 400 (plist-get (gethash "claude" overlook-usage-subscription--state) :next)))
      (overlook-usage-subscription--failed "claude")
      (should (= 700 (plist-get (gethash "claude" overlook-usage-subscription--state) :next)))
      (should (equal '(("5h" 100 200))
                     (plist-get (gethash "claude" overlook-usage-subscription--state) :windows)))
      (should-not (overlook-usage-subscription--due-p "claude")))))

(ert-deftest overlook-subscription-recovery-reaches-publisher-without-a-turn ()
  (let ((overlook-usage-subscription--state (make-hash-table :test #'equal))
        (overlook-usage--states (make-hash-table :test #'equal))
        (overlook-usage--rows '(("claude" ("5h" 100 9999999999))))
        events)
    (let ((overlook-usage-state-change-hook
           (list (lambda (name state) (push (list name state) events)))))
      (overlook-usage--publish)
      (puthash "claude" '(:windows (("5h" 0 9999999999)) :local (("5h" 100 9999999999)))
               overlook-usage-subscription--state)
      (setq overlook-usage--rows
            (overlook-usage-subscription--merge (copy-tree overlook-usage--rows)))
      (overlook-usage--publish)
      (should (equal events '(("claude" available) ("claude" exhausted)))))))

(ert-deftest overlook-subscription-rejects-previous-codex-account ()
  (let ((overlook-usage-subscription--state (make-hash-table :test #'equal)))
    (puthash "codex" '(:login "old" :windows (("5h" 0 200)))
             overlook-usage-subscription--state)
    (cl-letf (((symbol-function 'overlook-usage-codex-login) (lambda () "new")))
      (should-not (overlook-usage-subscription--merge nil)))))

(ert-deftest overlook-subscription-new-local-reading-wins-over-older-server-cache ()
  (let ((overlook-usage-subscription--state (make-hash-table :test #'equal))
        (rows '(("claude" ("5h" 100 200)))))
    (puthash "claude" '(:windows (("5h" 0 200)) :local (("5h" 50 200)))
             overlook-usage-subscription--state)
    (should (equal rows (overlook-usage-subscription--merge (copy-tree rows))))))

(ert-deftest overlook-subscription-token-only-goes-through-stdin ()
  (let ((overlook-usage-subscription--state (make-hash-table :test #'equal))
        command input buffer)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq command (plist-get args :command)
                       buffer (plist-get args :buffer))
                 'request))
              ((symbol-function 'process-send-string)
               (lambda (_ text) (setq input text)))
              ((symbol-function 'process-send-eof) #'ignore))
      (unwind-protect
          (progn
            (overlook-usage-subscription--request "codex" 'codex "test-secret" "account")
            (should-not (string-match-p "test-secret" (prin1-to-string command)))
            (should (string-match-p "Authorization: Bearer test-secret" input))
            (should (string-match-p "ChatGPT-Account-Id: account" input)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest overlook-subscription-deduplicates-the-local-login-identity ()
  (let ((overlook-agent-shell-claude-accounts '(("login") ("las" . "test-token")))
        (overlook-usage-subscription--state (make-hash-table :test #'equal))
        (overlook-usage-mode t)
        rows)
    (cl-letf (((symbol-function 'overlook-usage-claude-login) (lambda () "las"))
              ((symbol-function 'overlook-usage-subscription--claude-login)
               (lambda (row)
                 (push row rows)
                 (puthash row '(:next 9999999999) overlook-usage-subscription--state)))
              ((symbol-function 'overlook-usage-subscription--request)
               (lambda (row &rest _) (push row rows))))
      (overlook-usage-subscription--poll)
      (should (equal (sort rows #'string-lessp) '("claude" "codex")))
      (should (equal (overlook-agent-shell-claude-account-identity "login") "las"))
      (should-not (overlook-agent-shell--other-account "las")))))

(ert-deftest overlook-subscription-hides-removed-machine-accounts ()
  (let ((overlook-agent-shell-claude-accounts '(("login")))
        (overlook-usage-subscription--state (make-hash-table :test #'equal)))
    (puthash "claude @personal" '(:windows (("5h" 0 200)))
             overlook-usage-subscription--state)
    (should (equal (overlook-usage-subscription--merge
                    '(("claude" ("5h" 10 200)) ("claude @personal" ("5h" 20 200))))
                   '(("claude" ("5h" 10 200)))))))

(provide 'overlook-usage-subscription-test)
;;; overlook-usage-subscription-test.el ends here
