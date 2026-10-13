;;; overlook-usage-codex-test.el --- Codex dashboard usage checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-usage)

(defconst overlook-usage-codex-test--good
  (concat "{\"payload\":{\"rate_limits\":{\"primary\":{\"used_percent\":99.0,"
          "\"window_minutes\":300,\"resets_at\":1791586523},\"secondary\":"
          "{\"used_percent\":16.0,\"window_minutes\":10080,"
          "\"resets_at\":1792173323}}}}\n"))

(defconst overlook-usage-codex-test--none
  "{\"payload\":{\"rate_limits\":{\"primary\":null,\"secondary\":null}}}\n")

(defun overlook-usage-codex-test--write (root name text)
  "Write a session log NAME with TEXT under ROOT/2026/10/10."
  (let ((file (expand-file-name (concat "2026/10/10/" name) root)))
    (make-directory (file-name-directory file) t)
    (write-region text nil file)))

(ert-deftest overlook-usage-codex-windows-ignore-null-limit-windows ()
  (should (equal (overlook-usage--codex-windows
                  '((primary . nil) (secondary . nil)))
                 nil)))

(ert-deftest overlook-usage-codex-keeps-newest-real-reading ()
  (let* ((root (make-temp-file "codex-sessions" t))
         (overlook-usage-codex-sessions-directory root)
         (overlook-usage--codex nil))
    (unwind-protect
        (progn
          (overlook-usage-codex-test--write root "rollout-2026-10-10T03-44-22-a.jsonl"
                                    overlook-usage-codex-test--good)
          (overlook-usage-codex-test--write root "rollout-2026-10-10T03-44-32-b.jsonl"
                                    overlook-usage-codex-test--none)
          (should (equal (overlook-usage-codex)
                         '("codex" ("5h" 99.0 1791586523) ("7d" 16.0 1792173323)))))
      (delete-directory root t))))

(ert-deftest overlook-usage-codex-without-any-reading-stays-hidden ()
  (let* ((root (make-temp-file "codex-sessions" t))
         (overlook-usage-codex-sessions-directory root)
         (overlook-usage--codex nil))
    (unwind-protect
        (progn
          (overlook-usage-codex-test--write root "rollout-2026-10-10T03-44-32-b.jsonl"
                                    overlook-usage-codex-test--none)
          (should-not (overlook-usage-codex)))
      (delete-directory root t))))

(ert-deftest overlook-usage-codex-row-opens-usage-page ()
  (let* ((root (make-temp-file "codex-sessions" t))
         (overlook-usage-codex-sessions-directory root)
         (overlook-usage--codex nil))
    (unwind-protect
        (progn
          (overlook-usage-codex-test--write root "rollout-2026-10-10T03-44-22-a.jsonl"
                                    overlook-usage-codex-test--good)
          (should (eq (get-text-property 0 'overlook-action (car (overlook-usage-codex)))
                      #'overlook-usage-open-codex)))
      (delete-directory root t))))

(provide 'overlook-usage-codex-test)
;;; overlook-usage-codex-test.el ends here
