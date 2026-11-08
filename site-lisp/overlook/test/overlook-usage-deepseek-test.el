;;; overlook-usage-deepseek-test.el --- DeepSeek dashboard checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-usage-deepseek)

(ert-deftest overlook-usage-deepseek-balance-validation ()
  (should (equal (overlook-usage-deepseek--parse-balance
                  '((balance_infos . (((currency . "CNY") (total_balance . "0.00"))
                                      ((currency . "USD") (total_balance . "1.234"))))))
                 '(("CNY" . "0.00") ("USD" . "1.234"))))
  (should-error (overlook-usage-deepseek--parse-balance '((error . "Unauthorized"))))
  (should-error (overlook-usage-deepseek--parse-balance
                 '((balance_infos . (((currency . "CNY") (total_balance . "oops"))))))))

(ert-deftest overlook-usage-deepseek-peak-survives-restarts-and-key-changes ()
  (let* ((dir (make-temp-file "deepseek-state" t))
         (overlook-usage-deepseek-state-file (expand-file-name "state.json" dir))
         (overlook-usage-deepseek--state nil)
         (overlook-usage-deepseek--loaded-key nil)
         (overlook-usage-deepseek-api-key "test")
         (peak (lambda () (alist-get 'peak (overlook-usage-deepseek--top "CNY")))))
    (unwind-protect
        (progn
          (overlook-usage-deepseek--record '(("CNY" . "10.00")))
          (overlook-usage-deepseek--record '(("CNY" . "9.75")))
          (setq overlook-usage-deepseek--state nil overlook-usage-deepseek--loaded-key nil)
          (overlook-usage-deepseek--load-state)
          (should (= 10 (funcall peak)))
          ;; A changed key must not inherit the prior account's peak.
          (setq overlook-usage-deepseek-api-key "different")
          (overlook-usage-deepseek--record '(("CNY" . "1.00")))
          (should (= 1 (funcall peak)))
          ;; A broken state file starts afresh.
          (with-temp-file overlook-usage-deepseek-state-file (insert "{broken"))
          (setq overlook-usage-deepseek--loaded-key nil)
          (overlook-usage-deepseek--record '(("CNY" . "0.50")))
          (should (= 0.5 (funcall peak))))
      (delete-directory dir t))))

(ert-deftest overlook-usage-deepseek-stale-and-loading-display ()
  (let ((overlook-usage-deepseek-api-key "test")
        (overlook-usage-deepseek--balance '(("CNY" . "4.34")))
        (overlook-usage-deepseek--error t)
        (overlook-usage-deepseek--loaded-key (secure-hash 'sha256 "test"))
        (overlook-usage-deepseek--state nil))
    (should (equal (mapcar #'car (cdr (overlook-usage-deepseek-usage))) '("¥")))
    (should (equal "4.34 stale" (nth 2 (assoc "¥" (cdr (overlook-usage-deepseek-usage))))))
    (setq overlook-usage-deepseek--balance nil)
    (should (string-match-p "unavailable" (cadr (assoc "balance" (cdr (overlook-usage-deepseek-usage))))))
    (setq overlook-usage-deepseek--error nil)
    (should (string-match-p "loading" (cadr (assoc "balance" (cdr (overlook-usage-deepseek-usage))))))))

(ert-deftest overlook-usage-deepseek-loading-text-lines-up-with-plan-bars ()
  (dolist (width '(55 65 90))
    (let ((overlook-usage--rows '(("claude" ("5h" 50 nil) ("7d" 10 nil))
                                  ("deepseek" ("balance" "loading" nil))))
          (overlook-width width))
      (with-temp-buffer
        (overlook-insert-rows (overlook-usage--dashboard-rows))
        (should (string-match-p "balance +loading" (buffer-string)))
        (goto-char (point-min))
        (while (not (eobp))
          (should (<= (string-width (buffer-substring (point) (line-end-position))) width))
          (forward-line 1))))))

(ert-deftest overlook-usage-deepseek-bar-spends-down-from-the-last-top-up ()
  (let* ((dir (make-temp-file "deepseek-state" t))
         (overlook-usage-deepseek-state-file (expand-file-name "state.json" dir))
         (overlook-usage-deepseek--state nil)
         (overlook-usage-deepseek--loaded-key nil)
         (overlook-usage-deepseek--error nil)
         (overlook-usage-deepseek-api-key "test")
         (percent (lambda (balance)
                    (setq overlook-usage-deepseek--balance balance)
                    (cadr (assoc "¥" (cdr (overlook-usage-deepseek-usage))))))
         (overlook-usage-deepseek--balance nil))
    (unwind-protect
        (progn
          (overlook-usage-deepseek--record '(("CNY" . "20.00")))
          (should (= 0 (funcall percent '(("CNY" . "20.00")))))
          (overlook-usage-deepseek--record '(("CNY" . "15.00")))
          (should (= 25 (funcall percent '(("CNY" . "15.00")))))
          ;; The peak outlives a restart.
          (setq overlook-usage-deepseek--state nil overlook-usage-deepseek--loaded-key nil)
          (overlook-usage-deepseek--record '(("CNY" . "10.00")))
          (should (= 50 (funcall percent '(("CNY" . "10.00")))))
          ;; A top-up starts a full bar again.
          (overlook-usage-deepseek--record '(("CNY" . "40.00")))
          (should (= 0 (funcall percent '(("CNY" . "40.00")))))
          (should (equal "40.00" (nth 2 (assoc "¥" (cdr (overlook-usage-deepseek-usage)))))))
      (delete-directory dir t))))

(ert-deftest overlook-usage-deepseek-balance-bar-shows-its-amount ()
  (let ((overlook-usage--rows '(("claude" ("5h" 50 nil) ("7d" 10 nil))
                                ("deepseek" ("¥" 25 "15.00"))))
        (overlook-width 90))
    (with-temp-buffer
      (overlook-insert-rows (overlook-usage--dashboard-rows))
      (should (string-match-p "¥  ━+  25% 15.00" (buffer-string))))))

(ert-deftest overlook-usage-deepseek-request-throttling ()
  (let ((overlook-usage-deepseek-api-key "test")
        (overlook-usage-deepseek--requested (float-time))
        (overlook-usage-deepseek--process nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "Duplicate balance request"))))
      (overlook-usage-deepseek--fetch))))

;;; overlook-usage-deepseek-test.el ends here
