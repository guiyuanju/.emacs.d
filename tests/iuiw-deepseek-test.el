;;; iuiw-deepseek-test.el --- DeepSeek dashboard checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'iuiw-deepseek)

(ert-deftest iuiw-deepseek-balance-validation ()
  (should (equal (iuiw-deepseek--parse-balance
                  '((balance_infos . (((currency . "CNY") (total_balance . "0.00"))
                                      ((currency . "USD") (total_balance . "1.234"))))))
                 '(("CNY" . "0.00") ("USD" . "1.234"))))
  (should-error (iuiw-deepseek--parse-balance '((error . "Unauthorized"))))
  (should-error (iuiw-deepseek--parse-balance
                 '((balance_infos . (((currency . "CNY") (total_balance . "oops"))))))))

(ert-deftest iuiw-deepseek-observations-persist-and-roll-over ()
  (let* ((dir (make-temp-file "deepseek-state" t))
         (iuiw-deepseek-state-file (expand-file-name "state.json" dir))
         (iuiw-deepseek--state nil)
         (iuiw-deepseek--loaded-key nil)
         (iuiw-deepseek-api-key "test")
         (time (float-time (date-to-time "2026-10-10 12:00:00"))))
    (unwind-protect
        (progn
          (iuiw-deepseek--record '(("CNY" . "10.00") ("USD" . "2.00")) time)
          (iuiw-deepseek--record '(("CNY" . "9.75") ("USD" . "1.50")) time)
          ;; Reload as after a restart, then recharge and spend again.
          (setq iuiw-deepseek--state nil iuiw-deepseek--loaded-key nil)
          (iuiw-deepseek--record '(("CNY" . "19.75") ("USD" . "1.50")) time)
          (iuiw-deepseek--record '(("CNY" . "19.50") ("USD" . "1.50")) time)
          (should (equal '(0.5 0.5)
                         (mapcar (lambda (r) (alist-get 'spent r))
                                 (alist-get 'rows iuiw-deepseek--state))))
          ;; The next day starts a fresh observation, excluding the overnight gap.
          (iuiw-deepseek--record '(("CNY" . "18.00")) (+ time 86400))
          (should (= 0 (alist-get 'spent (car (alist-get 'rows iuiw-deepseek--state)))))
          ;; A changed key must not inherit the prior account's baseline.
          (setq iuiw-deepseek-api-key "different")
          (iuiw-deepseek--record '(("CNY" . "1.00")) (+ time 86400))
          (should (= 0 (alist-get 'spent (car (alist-get 'rows iuiw-deepseek--state)))))
          ;; A broken state file starts a new baseline, never invents spending.
          (with-temp-file iuiw-deepseek-state-file (insert "{broken"))
          (setq iuiw-deepseek--loaded-key nil)
          (iuiw-deepseek--record '(("CNY" . "0.50")) time)
          (should (= 0 (alist-get 'spent (car (alist-get 'rows iuiw-deepseek--state))))))
      (delete-directory dir t))))

(ert-deftest iuiw-deepseek-stale-and-loading-display ()
  (let ((iuiw-deepseek-api-key "test")
        (iuiw-deepseek--balance '(("CNY" . "4.34")))
        (iuiw-deepseek--updated (float-time))
        (iuiw-deepseek--error t)
        (iuiw-deepseek--loaded-key (secure-hash 'sha256 "test"))
        (iuiw-deepseek--state
         `((day . ,(format-time-string "%F")) (since . ,(float-time))
           (rows . (((currency . "CNY") (last . 4.34) (spent . 0.0123)))))))
    (cl-letf (((symbol-function 'iuiw-deepseek--fetch) #'ignore))
      (let ((text (cadr (assoc "balance" (cdr (iuiw-deepseek-usage)))) ))
        (should (string-match-p "¥4.34" text))
        (should (string-match-p "stale" text))
        (should (equal "~¥0.0123 stale" (cadr (assoc "today" (cdr (iuiw-deepseek-usage)))))))
      (setq iuiw-deepseek--balance nil)
      (should (string-match-p "unavailable" (cadr (assoc "balance" (cdr (iuiw-deepseek-usage))))))
      (setq iuiw-deepseek--error nil)
      (should (string-match-p "loading" (cadr (assoc "balance" (cdr (iuiw-deepseek-usage)))))))))

(ert-deftest iuiw-deepseek-render-alongside-plan-bars ()
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

(ert-deftest iuiw-deepseek-request-throttling ()
  (let ((iuiw-deepseek-api-key "test")
        (iuiw-deepseek--requested (float-time))
        (iuiw-deepseek--process nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "Duplicate balance request"))))
      (iuiw-deepseek--fetch))))

;;; iuiw-deepseek-test.el ends here
