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
                         '(("claude" ("5h" 96 1791577800) ("7d" 6 1791950400)))))
          ;; A null file must not wipe the row while Claude reconnects.
          (overlook-usage-test--set-file file "null")
          (should (equal (overlook-usage-claude)
                         '(("claude" ("5h" 96 1791577800) ("7d" 6 1791950400)))))
          ;; A deleted file keeps it too.
          (delete-file file)
          (should (equal (overlook-usage-claude)
                         '(("claude" ("5h" 96 1791577800) ("7d" 6 1791950400))))))
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
          (should (eq (get-text-property 0 'overlook-action (caar (overlook-usage-claude)))
                      #'overlook-usage-open-claude)))
      (delete-file file))))

;; Another account's usage goes to a file of its own beside, and shows as a row of its own after.
(ert-deftest overlook-usage-claude-keeps-a-row-per-account ()
  (let* ((dir (make-temp-file "overlook-usage" t))
         (overlook-usage-file (expand-file-name "claude-usage.json" dir))
         (overlook-usage--claude nil))
    (unwind-protect
        (progn
          (overlook-usage-save-claude '((five_hour (used_percentage . 100) (resets_at . 1791577800)))
                                      "home")
          (overlook-usage-save-claude '((five_hour (used_percentage . 40) (resets_at . 1791577800))))
          (should (file-exists-p (expand-file-name "claude-usage-home.json" dir)))
          (should (equal (overlook-usage-claude)
                         '(("claude" ("5h" 40 1791577800))
                           ("claude @home" ("5h" 100 1791577800)))))
          (let ((overlook-agent-icons '(("claude" . "C"))))
            (should (equal (overlook-usage--label "claude @home") "C @hom"))
            (let ((overlook-account-labels '(("home" . "H") ("work" . "W")))
                  (overlook-usage-accounts '(("claude" . "work"))))
              (should (equal (overlook-usage--label "claude @home") "C H"))
              (should (equal (overlook-usage--label "claude") "C W"))
              (should (equal (overlook-usage--label "codex") "codex")))
            (let ((overlook-usage-accounts '(("claude" . "work"))))
              (should (equal (overlook-usage--label "claude") "C @wor")))))
      (delete-directory dir t))))

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

(ert-deftest overlook-usage-text-ends-with-percentages ()
  (with-temp-buffer
    (let ((overlook-usage--rows
           (list (list "claude" (list "5h" 43 (+ (float-time) 66000)))
                 (list "deepseek" (list "balance" "¥14.15" nil)))))
      (cl-letf (((symbol-function 'overlook-columns) (lambda () 69)))
        (overlook-usage--insert))
      (pcase-let ((`(,meter ,text) (split-string (buffer-string) "\n" t)))
        (should (= (+ (string-search "%" meter) 1)
                   (+ (string-search "¥14.15" text) (length "¥14.15"))))))))

(ert-deftest overlook-usage-row-shows-agent-icon ()
  (with-temp-buffer
    (let ((overlook-agent-icons '(("claude" . "C")))
          (overlook-usage--rows
           (list (cons (propertize "claude" 'overlook-action #'ignore)
                       (list (list "5h" 43 nil))))))
      (overlook-usage--insert)
      (should (string-prefix-p "C  5h" (buffer-string)))
      (should (eq (get-text-property (point-min) 'overlook-action) #'ignore)))))

(ert-deftest overlook-usage-wide-icon-keeps-columns ()
  (with-temp-buffer
    (let ((overlook-agent-icons '(("claude" . "C")))
          (overlook-usage--rows
           (list (cons "claude" (list (list "5h" 43 nil)))
                 (cons "codex" (list (list "5h" 10 nil))))))
      (cl-letf (((symbol-function 'overlook-pixel-width)
                 (lambda (string) (if (equal string "C") 2 (string-width string)))))
        (overlook-usage--insert))
      (pcase-let ((`(,claude ,codex) (split-string (buffer-string) "\n" t)))
        (should (= (1+ (string-search "5h" claude)) (string-search "5h" codex)))))))

(provide 'overlook-usage-test)

(ert-deftest overlook-usage-poller-waits-for-its-interval ()
  (let ((overlook-usage--pollers nil)
        (overlook-usage--polled (make-hash-table :test #'eq))
        (calls 0)
        (started nil))
    (cl-letf (((symbol-function 'overlook-usage-test--fetch)
               (lambda () (cl-incf calls) started)))
      (overlook-usage-add-poller 'overlook-usage-test--fetch 60)
      ;; A poller that started nothing is tried again on the next tick.
      (overlook-usage--poll)
      (overlook-usage--poll)
      (should (= calls 2))
      (setq started t)
      (overlook-usage--poll)
      (overlook-usage--poll)
      (should (= calls 3))
      ;; Once the interval has passed it runs again.
      (puthash 'overlook-usage-test--fetch (- (float-time) 61) overlook-usage--polled)
      (overlook-usage--poll)
      (should (= calls 4)))))

(ert-deftest overlook-usage-poller-error-counts-as-a-request ()
  (let ((overlook-usage--pollers nil)
        (overlook-usage--polled (make-hash-table :test #'eq))
        (calls 0))
    (cl-letf (((symbol-function 'overlook-usage-test--fetch)
               (lambda () (cl-incf calls) (error "Offline"))))
      (overlook-usage-add-poller 'overlook-usage-test--fetch)
      (overlook-usage--poll)
      (overlook-usage--poll)
      (should (= calls 1)))))

;;; overlook-usage-test.el ends here
