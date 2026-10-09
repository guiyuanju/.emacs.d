;;; jgy-agents-usage-test.el --- Claude dashboard usage checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'jgy-agents-usage)

(defun jgy-agents-usage-test--set-file (file text)
  "Write TEXT to FILE."
  (write-region text nil file nil 'silent))

(ert-deftest jgy-agents-claude-keeps-last-reading-when-file-has-none ()
  (let* ((file (make-temp-file "claude-usage" nil ".json"))
         (jgy-agents-usage-file file)
         (jgy-agents--claude-usage nil))
    (unwind-protect
        (progn
          (jgy-agents-usage-test--set-file
           file
           "{\"five_hour\":{\"used_percentage\":96,\"resets_at\":1791577800},\"seven_day\":{\"used_percentage\":6,\"resets_at\":1791950400}}")
          (should (equal (jgy-agents-usage-claude)
                         '("claude" ("5h" 96 1791577800) ("7d" 6 1791950400))))
          ;; A null file must not wipe the row while Claude reconnects.
          (jgy-agents-usage-test--set-file file "null")
          (should (equal (jgy-agents-usage-claude)
                         '("claude" ("5h" 96 1791577800) ("7d" 6 1791950400))))
          ;; A deleted file keeps it too.
          (delete-file file)
          (should (equal (jgy-agents-usage-claude)
                         '("claude" ("5h" 96 1791577800) ("7d" 6 1791950400)))))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest jgy-agents-claude-without-any-reading-stays-hidden ()
  (let* ((file (make-temp-file "claude-usage" nil ".json"))
         (jgy-agents-usage-file file)
         (jgy-agents--claude-usage nil))
    (unwind-protect
        (progn
          (jgy-agents-usage-test--set-file file "null")
          (should-not (jgy-agents-usage-claude)))
      (delete-file file))))

(ert-deftest jgy-agents-claude-row-opens-usage-page ()
  (let* ((file (make-temp-file "claude-usage" nil ".json"))
         (jgy-agents-usage-file file)
         (jgy-agents--claude-usage nil))
    (unwind-protect
        (progn
          (jgy-agents-usage-test--set-file
           file "{\"five_hour\":{\"used_percentage\":96,\"resets_at\":1791577800}}")
          (should (eq (get-text-property 0 'jgy-agents-action (car (jgy-agents-usage-claude)))
                      #'jgy-agents-claude-open-usage)))
      (delete-file file))))

(ert-deftest jgy-agents-usage-row-action-reaches-line-start ()
  (with-temp-buffer
    (let ((jgy-agents--usage
           (list (cons (propertize "deepseek" 'jgy-agents-action #'ignore)
                       (list (list "balance" "¥1.00" nil))))))
      (jgy-agents--usage-insert)
      (should (eq (get-text-property (point-min) 'jgy-agents-action) #'ignore)))))

(ert-deftest jgy-agents-usage-plain-row-has-no-action ()
  (with-temp-buffer
    (let ((jgy-agents--usage (list (cons "claude" (list (list "5h" 96 1791577800))))))
      (jgy-agents--usage-insert)
      (should-not (get-text-property (point-min) 'jgy-agents-action)))))

(provide 'jgy-agents-usage-test)
;;; jgy-agents-usage-test.el ends here
