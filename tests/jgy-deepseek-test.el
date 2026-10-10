;;; jgy-deepseek-test.el --- DeepSeek dashboard checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'jgy-deepseek)

(ert-deftest jgy-deepseek-balance-validation ()
  (should (equal (jgy-deepseek--parse-balance
                  '((balance_infos . (((currency . "CNY") (total_balance . "0.00"))
                                      ((currency . "USD") (total_balance . "1.234"))))))
                 '(("CNY" . "0.00") ("USD" . "1.234"))))
  (should-error (jgy-deepseek--parse-balance '((error . "Unauthorized"))))
  (should-error (jgy-deepseek--parse-balance
                 '((balance_infos . (((currency . "CNY") (total_balance . "oops"))))))))

(ert-deftest jgy-deepseek-observations-persist-and-roll-over ()
  (let* ((dir (make-temp-file "deepseek-state" t))
         (jgy-deepseek-state-file (expand-file-name "state.json" dir))
         (jgy-deepseek--state nil)
         (jgy-deepseek--loaded-key nil)
         (jgy-deepseek-api-key "test")
         (time (float-time (date-to-time "2026-10-10 12:00:00"))))
    (unwind-protect
        (progn
          (jgy-deepseek--record '(("CNY" . "10.00") ("USD" . "2.00")) time)
          (jgy-deepseek--record '(("CNY" . "9.75") ("USD" . "1.50")) time)
          ;; Reload as after a restart, then recharge and spend again.
          (setq jgy-deepseek--state nil jgy-deepseek--loaded-key nil)
          (jgy-deepseek--record '(("CNY" . "19.75") ("USD" . "1.50")) time)
          (jgy-deepseek--record '(("CNY" . "19.50") ("USD" . "1.50")) time)
          (should (equal '(0.5 0.5)
                         (mapcar (lambda (r) (alist-get 'spent r))
                                 (alist-get 'rows jgy-deepseek--state))))
          ;; The next day starts a fresh observation, excluding the overnight gap.
          (jgy-deepseek--record '(("CNY" . "18.00")) (+ time 86400))
          (should (= 0 (alist-get 'spent (car (alist-get 'rows jgy-deepseek--state)))))
          ;; A changed key must not inherit the prior account's baseline.
          (setq jgy-deepseek-api-key "different")
          (jgy-deepseek--record '(("CNY" . "1.00")) (+ time 86400))
          (should (= 0 (alist-get 'spent (car (alist-get 'rows jgy-deepseek--state)))))
          ;; A broken state file starts a new baseline, never invents spending.
          (with-temp-file jgy-deepseek-state-file (insert "{broken"))
          (setq jgy-deepseek--loaded-key nil)
          (jgy-deepseek--record '(("CNY" . "0.50")) time)
          (should (= 0 (alist-get 'spent (car (alist-get 'rows jgy-deepseek--state))))))
      (delete-directory dir t))))

(ert-deftest jgy-deepseek-stale-and-loading-display ()
  (let ((jgy-deepseek-api-key "test")
        (jgy-deepseek--balance '(("CNY" . "4.34")))
        (jgy-deepseek--updated (float-time))
        (jgy-deepseek--error t)
        (jgy-deepseek--loaded-key (secure-hash 'sha256 "test"))
        (jgy-deepseek--state
         `((day . ,(format-time-string "%F")) (since . ,(float-time))
           (rows . (((currency . "CNY") (last . 4.34) (spent . 0.0123)))))))
    (cl-letf (((symbol-function 'jgy-deepseek--fetch) #'ignore))
      (let ((text (cadr (assoc "balance" (cdr (jgy-deepseek-usage)))) ))
        (should (string-match-p "¥4.34" text))
        (should (string-match-p "stale" text))
        (should (equal "~¥0.0123 stale" (cadr (assoc "today" (cdr (jgy-deepseek-usage)))))))
      (setq jgy-deepseek--balance nil)
      (should (string-match-p "unavailable" (cadr (assoc "balance" (cdr (jgy-deepseek-usage))))))
      (setq jgy-deepseek--error nil)
      (should (string-match-p "loading" (cadr (assoc "balance" (cdr (jgy-deepseek-usage)))))))))

(ert-deftest jgy-deepseek-render-alongside-plan-bars ()
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

(ert-deftest jgy-deepseek-request-throttling ()
  (let ((jgy-deepseek-api-key "test")
        (jgy-deepseek--requested (float-time))
        (jgy-deepseek--process nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "Duplicate balance request"))))
      (jgy-deepseek--fetch))))

;;; jgy-deepseek-test.el ends here
