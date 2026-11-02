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

(ert-deftest overlook-usage-deepseek-observations-persist-and-roll-over ()
  (let* ((dir (make-temp-file "deepseek-state" t))
         (overlook-usage-deepseek-state-file (expand-file-name "state.json" dir))
         (overlook-usage-deepseek--state nil)
         (overlook-usage-deepseek--loaded-key nil)
         (overlook-usage-deepseek-api-key "test")
         (time (float-time (date-to-time "2026-10-10 12:00:00"))))
    (unwind-protect
        (progn
          (overlook-usage-deepseek--record '(("CNY" . "10.00") ("USD" . "2.00")) time)
          (overlook-usage-deepseek--record '(("CNY" . "9.75") ("USD" . "1.50")) time)
          ;; Reload as after a restart, then recharge and spend again.
          (setq overlook-usage-deepseek--state nil overlook-usage-deepseek--loaded-key nil)
          (overlook-usage-deepseek--record '(("CNY" . "19.75") ("USD" . "1.50")) time)
          (overlook-usage-deepseek--record '(("CNY" . "19.50") ("USD" . "1.50")) time)
          (should (equal '(0.5 0.5)
                         (mapcar (lambda (r) (alist-get 'spent r))
                                 (alist-get 'rows overlook-usage-deepseek--state))))
          ;; The next day starts a fresh observation, excluding the overnight gap.
          (overlook-usage-deepseek--record '(("CNY" . "18.00")) (+ time 86400))
          (should (= 0 (alist-get 'spent (car (alist-get 'rows overlook-usage-deepseek--state)))))
          ;; A changed key must not inherit the prior account's baseline.
          (setq overlook-usage-deepseek-api-key "different")
          (overlook-usage-deepseek--record '(("CNY" . "1.00")) (+ time 86400))
          (should (= 0 (alist-get 'spent (car (alist-get 'rows overlook-usage-deepseek--state)))))
          ;; A broken state file starts a new baseline, never invents spending.
          (with-temp-file overlook-usage-deepseek-state-file (insert "{broken"))
          (setq overlook-usage-deepseek--loaded-key nil)
          (overlook-usage-deepseek--record '(("CNY" . "0.50")) time)
          (should (= 0 (alist-get 'spent (car (alist-get 'rows overlook-usage-deepseek--state))))))
      (delete-directory dir t))))

(ert-deftest overlook-usage-deepseek-stale-and-loading-display ()
  (let ((overlook-usage-deepseek-api-key "test")
        (overlook-usage-deepseek--balance '(("CNY" . "4.34")))
        (overlook-usage-deepseek--updated (float-time))
        (overlook-usage-deepseek--error t)
        (overlook-usage-deepseek--loaded-key (secure-hash 'sha256 "test"))
        (overlook-usage-deepseek--state
         `((day . ,(format-time-string "%F")) (since . ,(float-time))
           (rows . (((currency . "CNY") (last . 4.34) (spent . 0.0123)))))))
    (cl-letf (((symbol-function 'overlook-usage-deepseek--fetch) #'ignore))
      (let ((text (cadr (assoc "balance" (cdr (overlook-usage-deepseek-usage)))) ))
        (should (string-match-p "¥4.34" text))
        (should (string-match-p "stale" text))
        (should (equal "~¥0.0123 stale" (cadr (assoc "today" (cdr (overlook-usage-deepseek-usage)))))))
      (setq overlook-usage-deepseek--balance nil)
      (should (string-match-p "unavailable" (cadr (assoc "balance" (cdr (overlook-usage-deepseek-usage))))))
      (setq overlook-usage-deepseek--error nil)
      (should (string-match-p "loading" (cadr (assoc "balance" (cdr (overlook-usage-deepseek-usage)))))))))

(ert-deftest overlook-usage-deepseek-render-alongside-plan-bars ()
  (dolist (width '(55 65 90))
    (let ((overlook-usage--rows '(("claude" ("5h" 50 nil) ("7d" 10 nil))
                          ("deepseek" ("balance" "¥4.34" nil) ("today" "~¥0.0123" nil))))
          (overlook-width width))
      (with-temp-buffer
        (overlook-usage--insert)
        (goto-char (point-min))
        (search-forward "7d")
        (let ((second-column (- (current-column) 2)))
          (search-forward "today")
          (should (= second-column (- (current-column) 5))))
        (should (string-match-p "balance +¥4.34" (buffer-string)))
        (should (string-match-p "today +~¥0.0123" (buffer-string)))
        (goto-char (point-min))
        (while (not (eobp))
          (should (<= (string-width (buffer-substring (point) (line-end-position))) width))
          (forward-line 1))))))

(ert-deftest overlook-usage-deepseek-request-throttling ()
  (let ((overlook-usage-deepseek-api-key "test")
        (overlook-usage-deepseek--requested (float-time))
        (overlook-usage-deepseek--process nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "Duplicate balance request"))))
      (overlook-usage-deepseek--fetch))))

;;; overlook-usage-deepseek-test.el ends here
