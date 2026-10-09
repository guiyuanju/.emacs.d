;;; agents-deepseek-test.el --- DeepSeek dashboard checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'agents-deepseek)

(ert-deftest agents-deepseek-balance-validation ()
  (should (equal (agents-deepseek--parse-balance
                  '((balance_infos . (((currency . "CNY") (total_balance . "0.00"))
                                      ((currency . "USD") (total_balance . "1.234"))))))
                 '(("CNY" . "0.00") ("USD" . "1.234"))))
  (should-error (agents-deepseek--parse-balance '((error . "Unauthorized"))))
  (should-error (agents-deepseek--parse-balance
                 '((balance_infos . (((currency . "CNY") (total_balance . "oops"))))))))

(ert-deftest agents-deepseek-local-day-provider-and-cache ()
  (let ((file (make-temp-file "pi-usage"))
        (agents-deepseek--files (make-hash-table :test #'equal))
        (day "2026-10-10"))
    (unwind-protect
        (cl-labels ((entry (provider date tokens)
                      (let ((stamp (* 1000 (float-time
                                            (date-to-time (concat date " 12:00:00"))))))
                        (concat
                         (json-encode
                          `((message (role . "assistant") (provider . ,provider)
                                     (timestamp . ,stamp)
                                     (usage (totalTokens . ,tokens)))))
                         "\n"))))
          (with-temp-file file
            (insert (entry "deepseek" day 100)
                    (entry "openai-codex" day 500)
                    (entry "deepseek" "2026-10-09" 200)
                    "{partial"))
          (should (= 100 (agents-deepseek--file-tokens file day)))
          (should (= 100 (agents-deepseek--file-tokens file day)))
          (with-temp-buffer
            (insert "\n" (entry "deepseek" day 50))
            (write-region (point-min) (point-max) file t 'silent))
          (should (= 150 (agents-deepseek--file-tokens file day)))
          (should (= 200 (agents-deepseek--file-tokens file "2026-10-09"))))
      (delete-file file))))

(ert-deftest agents-deepseek-stale-and-loading-display ()
  (let ((jgy/deepseek-api-key "test")
        (agents-deepseek--balance '(("CNY" . "4.34")))
        (agents-deepseek--updated (float-time))
        (agents-deepseek--error t)
        (agents-deepseek--tokens 123))
    (cl-letf (((symbol-function 'agents-deepseek--fetch) #'ignore)
              ((symbol-function 'agents-deepseek--scan) #'ignore))
      (let ((text (cdr (agents-usage-deepseek))))
        (should (string-match-p "CNY 4.34" text))
        (should (string-match-p "stale" text))
        (should (string-match-p "Pi today 123 tok" text)))
      (setq agents-deepseek--balance nil)
      (should (string-match-p "balance unavailable" (cdr (agents-usage-deepseek))))
      (setq agents-deepseek--error nil)
      (should (string-match-p "balance loading" (cdr (agents-usage-deepseek)))))))

(ert-deftest agents-deepseek-render-alongside-plan-bars ()
  (let ((agents--usage '(("claude" ("5h" 50 nil))
                         ("deepseek" . "CNY 4.34 · Pi today 123 tok")))
        (agents-dashboard-width 45))
    (with-temp-buffer
      (agents--usage-insert)
      (should (string-match-p "50%" (buffer-string)))
      (should (string-match-p "deepseek  CNY 4.34" (buffer-string)))
      (goto-char (point-min))
      (while (not (eobp))
        (should (<= (string-width (buffer-substring (point) (line-end-position))) 45))
        (forward-line 1)))))

(ert-deftest agents-deepseek-request-throttling ()
  (let ((jgy/deepseek-api-key "test")
        (agents-deepseek--requested (float-time))
        (agents-deepseek--process nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "Duplicate balance request"))))
      (agents-deepseek--fetch))))

;;; agents-deepseek-test.el ends here
