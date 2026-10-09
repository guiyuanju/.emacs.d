;;; jgy-agents-deepseek-test.el --- DeepSeek dashboard checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'jgy-agents-deepseek)

(ert-deftest jgy-agents-deepseek-balance-validation ()
  (should (equal (jgy-agents-deepseek--parse-balance
                  '((balance_infos . (((currency . "CNY") (total_balance . "0.00"))
                                      ((currency . "USD") (total_balance . "1.234"))))))
                 '(("CNY" . "0.00") ("USD" . "1.234"))))
  (should-error (jgy-agents-deepseek--parse-balance '((error . "Unauthorized"))))
  (should-error (jgy-agents-deepseek--parse-balance
                 '((balance_infos . (((currency . "CNY") (total_balance . "oops"))))))))

(ert-deftest jgy-agents-deepseek-observations-persist-and-roll-over ()
  (let* ((dir (make-temp-file "deepseek-state" t))
         (jgy-agents-deepseek-state-file (expand-file-name "state.json" dir))
         (jgy-agents-deepseek--state nil)
         (jgy-agents-deepseek--loaded-key nil)
         (jgy-deepseek-api-key "test")
         (time (float-time (date-to-time "2026-10-10 12:00:00"))))
    (unwind-protect
        (progn
          (jgy-agents-deepseek--record '(("CNY" . "10.00") ("USD" . "2.00")) time)
          (jgy-agents-deepseek--record '(("CNY" . "9.75") ("USD" . "1.50")) time)
          ;; Reload as after a restart, then recharge and spend again.
          (setq jgy-agents-deepseek--state nil jgy-agents-deepseek--loaded-key nil)
          (jgy-agents-deepseek--record '(("CNY" . "19.75") ("USD" . "1.50")) time)
          (jgy-agents-deepseek--record '(("CNY" . "19.50") ("USD" . "1.50")) time)
          (should (equal '(0.5 0.5)
                         (mapcar (lambda (r) (alist-get 'spent r))
                                 (alist-get 'rows jgy-agents-deepseek--state))))
          ;; The next day starts a fresh observation, excluding the overnight gap.
          (jgy-agents-deepseek--record '(("CNY" . "18.00")) (+ time 86400))
          (should (= 0 (alist-get 'spent (car (alist-get 'rows jgy-agents-deepseek--state)))))
          ;; A changed key must not inherit the prior account's baseline.
          (setq jgy-deepseek-api-key "different")
          (jgy-agents-deepseek--record '(("CNY" . "1.00")) (+ time 86400))
          (should (= 0 (alist-get 'spent (car (alist-get 'rows jgy-agents-deepseek--state)))))
          ;; A broken state file starts a new baseline, never invents spending.
          (with-temp-file jgy-agents-deepseek-state-file (insert "{broken"))
          (setq jgy-agents-deepseek--loaded-key nil)
          (jgy-agents-deepseek--record '(("CNY" . "0.50")) time)
          (should (= 0 (alist-get 'spent (car (alist-get 'rows jgy-agents-deepseek--state))))))
      (delete-directory dir t))))

(ert-deftest jgy-agents-deepseek-stale-and-loading-display ()
  (let ((jgy-deepseek-api-key "test")
        (jgy-agents-deepseek--balance '(("CNY" . "4.34")))
        (jgy-agents-deepseek--updated (float-time))
        (jgy-agents-deepseek--error t)
        (jgy-agents-deepseek--loaded-key (secure-hash 'sha256 "test"))
        (jgy-agents-deepseek--state
         `((day . ,(format-time-string "%F")) (since . ,(float-time))
           (rows . (((currency . "CNY") (last . 4.34) (spent . 0.0123)))))))
    (cl-letf (((symbol-function 'jgy-agents-deepseek--fetch) #'ignore))
      (let ((text (cadr (assoc "balance" (cdr (jgy-agents-deepseek-usage)))) ))
        (should (string-match-p "¥4.34" text))
        (should (string-match-p "stale" text))
        (should (equal "~¥0.0123 stale" (cadr (assoc "today" (cdr (jgy-agents-deepseek-usage)))))))
      (setq jgy-agents-deepseek--balance nil)
      (should (string-match-p "unavailable" (cadr (assoc "balance" (cdr (jgy-agents-deepseek-usage))))))
      (setq jgy-agents-deepseek--error nil)
      (should (string-match-p "loading" (cadr (assoc "balance" (cdr (jgy-agents-deepseek-usage)))))))))

(ert-deftest jgy-agents-deepseek-render-alongside-plan-bars ()
  (dolist (width '(55 65 90))
    (let ((jgy-agents-usage--rows '(("claude" ("5h" 50 nil) ("7d" 10 nil))
                          ("deepseek" ("balance" "¥4.34" nil) ("today" "~¥0.0123" nil))))
          (jgy-agents-dashboard-width width))
      (with-temp-buffer
        (jgy-agents-usage--insert)
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

(ert-deftest jgy-agents-deepseek-request-throttling ()
  (let ((jgy-deepseek-api-key "test")
        (jgy-agents-deepseek--requested (float-time))
        (jgy-agents-deepseek--process nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "Duplicate balance request"))))
      (jgy-agents-deepseek--fetch))))

;;; jgy-agents-deepseek-test.el ends here
