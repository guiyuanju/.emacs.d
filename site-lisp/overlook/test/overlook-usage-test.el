;;; overlook-usage-test.el --- Claude dashboard usage checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-usage)

(defun overlook-usage-test--set-file (file text)
  "Write TEXT to FILE."
  (write-region text nil file nil 'silent))

(ert-deftest overlook-usage-claude-keeps-last-reading-when-file-has-none ()
  (let* ((file (make-temp-file "claude-usage" nil ".json"))
         (overlook-usage-file file)
         (overlook-usage--claude nil))
    (unwind-protect
        (progn
          (overlook-usage-test--set-file
           file
           "{\"five_hour\":{\"used_percentage\":96,\"resets_at\":1791577800},\"seven_day\":{\"used_percentage\":6,\"resets_at\":1791950400}}")
          (should (equal (overlook-usage-claude)
                         '("claude" ("5h" 96 1791577800) ("7d" 6 1791950400))))
          ;; A null file must not wipe the row while Claude reconnects.
          (overlook-usage-test--set-file file "null")
          (should (equal (overlook-usage-claude)
                         '("claude" ("5h" 96 1791577800) ("7d" 6 1791950400))))
          ;; A deleted file keeps it too.
          (delete-file file)
          (should (equal (overlook-usage-claude)
                         '("claude" ("5h" 96 1791577800) ("7d" 6 1791950400)))))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest overlook-usage-claude-without-any-reading-stays-hidden ()
  (let* ((file (make-temp-file "claude-usage" nil ".json"))
         (overlook-usage-file file)
         (overlook-usage--claude nil))
    (unwind-protect
        (progn
          (overlook-usage-test--set-file file "null")
          (should-not (overlook-usage-claude)))
      (delete-file file))))

(ert-deftest overlook-usage-claude-row-opens-usage-page ()
  (let* ((file (make-temp-file "claude-usage" nil ".json"))
         (overlook-usage-file file)
         (overlook-usage--claude nil))
    (unwind-protect
        (progn
          (overlook-usage-test--set-file
           file "{\"five_hour\":{\"used_percentage\":96,\"resets_at\":1791577800}}")
          (should (eq (get-text-property 0 'overlook-action (car (overlook-usage-claude)))
                      #'overlook-usage-open-claude)))
      (delete-file file))))

(ert-deftest overlook-usage-row-action-reaches-line-start ()
  (with-temp-buffer
    (let ((overlook-usage--rows
           (list (cons (propertize "deepseek" 'overlook-action #'ignore)
                       (list (list "balance" "¥1.00" nil))))))
      (overlook-usage--insert)
      (should (eq (get-text-property (point-min) 'overlook-action) #'ignore)))))

(ert-deftest overlook-usage-plain-row-has-no-action ()
  (with-temp-buffer
    (let ((overlook-usage--rows (list (cons "claude" (list (list "5h" 96 1791577800))))))
      (overlook-usage--insert)
      (should-not (get-text-property (point-min) 'overlook-action)))))

(ert-deftest overlook-usage-rows-fit-the-window ()
  (dolist (columns '(55 69 100))
    (with-temp-buffer
      (let ((overlook-usage--rows
             (list (list "antigravity" (list "5h" 43 (+ (float-time) 66000)) (list "7d" 50 (+ (float-time) 902000)))
                   (list "deepseek" (list "balance" "¥14.15" nil) (list "today" "~¥0.1600" nil)))))
        (cl-letf (((symbol-function 'overlook-columns) (lambda () columns)))
          (overlook-usage--insert))
        (dolist (line (split-string (buffer-string) "\n" t))
          (should (< (string-width line) columns)))))))

(provide 'overlook-usage-test)
;;; overlook-usage-test.el ends here
