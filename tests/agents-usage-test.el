;;; agents-usage-test.el --- Claude dashboard usage checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'jgy-agents-usage)

(defun agents-usage-test--set-file (file text)
  "Write TEXT to FILE."
  (write-region text nil file nil 'silent))

(ert-deftest agents-claude-keeps-last-reading-when-file-has-none ()
  (let* ((file (make-temp-file "claude-usage" nil ".json"))
         (agents-usage-file file)
         (agents--claude-usage nil))
    (unwind-protect
        (progn
          (agents-usage-test--set-file
           file
           "{\"five_hour\":{\"used_percentage\":96,\"resets_at\":1791577800},\"seven_day\":{\"used_percentage\":6,\"resets_at\":1791950400}}")
          (should (equal (agents-usage-claude)
                         '("claude" ("5h" 96 1791577800) ("7d" 6 1791950400))))
          ;; A null file must not wipe the row while Claude reconnects.
          (agents-usage-test--set-file file "null")
          (should (equal (agents-usage-claude)
                         '("claude" ("5h" 96 1791577800) ("7d" 6 1791950400))))
          ;; A deleted file keeps it too.
          (delete-file file)
          (should (equal (agents-usage-claude)
                         '("claude" ("5h" 96 1791577800) ("7d" 6 1791950400)))))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest agents-claude-without-any-reading-stays-hidden ()
  (let* ((file (make-temp-file "claude-usage" nil ".json"))
         (agents-usage-file file)
         (agents--claude-usage nil))
    (unwind-protect
        (progn
          (agents-usage-test--set-file file "null")
          (should-not (agents-usage-claude)))
      (delete-file file))))

(ert-deftest agents-claude-row-opens-usage-page ()
  (let* ((file (make-temp-file "claude-usage" nil ".json"))
         (agents-usage-file file)
         (agents--claude-usage nil))
    (unwind-protect
        (progn
          (agents-usage-test--set-file
           file "{\"five_hour\":{\"used_percentage\":96,\"resets_at\":1791577800}}")
          (should (eq (get-text-property 0 'agents-action (car (agents-usage-claude)))
                      #'agents-claude-open-usage)))
      (delete-file file))))

(ert-deftest agents-usage-row-action-reaches-line-start ()
  (with-temp-buffer
    (let ((agents--usage
           (list (cons (propertize "deepseek" 'agents-action #'ignore)
                       (list (list "balance" "¥1.00" nil))))))
      (agents--usage-insert)
      (should (eq (get-text-property (point-min) 'agents-action) #'ignore)))))

(ert-deftest agents-usage-plain-row-has-no-action ()
  (with-temp-buffer
    (let ((agents--usage (list (cons "claude" (list (list "5h" 96 1791577800))))))
      (agents--usage-insert)
      (should-not (get-text-property (point-min) 'agents-action)))))

(provide 'agents-usage-test)
;;; agents-usage-test.el ends here
