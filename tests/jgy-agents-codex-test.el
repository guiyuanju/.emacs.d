;;; jgy-agents-codex-test.el --- Codex dashboard usage checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'jgy-agents-usage)

(defconst jgy-agents-codex-test--good
  (concat "{\"payload\":{\"rate_limits\":{\"primary\":{\"used_percent\":99.0,"
          "\"window_minutes\":300,\"resets_at\":1791586523},\"secondary\":"
          "{\"used_percent\":16.0,\"window_minutes\":10080,"
          "\"resets_at\":1792173323}}}}\n"))

(defconst jgy-agents-codex-test--none
  "{\"payload\":{\"rate_limits\":{\"primary\":null,\"secondary\":null}}}\n")

(defun jgy-agents-codex-test--write (root name text)
  "Write a session log NAME with TEXT under ROOT/2026/10/10."
  (let ((file (expand-file-name (concat "2026/10/10/" name) root)))
    (make-directory (file-name-directory file) t)
    (write-region text nil file)))

(ert-deftest jgy-agents-codex-windows-ignore-null-limit-windows ()
  (should (equal (jgy-agents-usage--codex-windows
                  '((primary . nil) (secondary . nil)))
                 nil)))

(ert-deftest jgy-agents-codex-keeps-newest-real-reading ()
  (let* ((root (make-temp-file "codex-sessions" t))
         (jgy-agents-usage-codex-sessions-directory root)
         (jgy-agents-usage--codex nil))
    (unwind-protect
        (progn
          (jgy-agents-codex-test--write root "rollout-2026-10-10T03-44-22-a.jsonl"
                                    jgy-agents-codex-test--good)
          (jgy-agents-codex-test--write root "rollout-2026-10-10T03-44-32-b.jsonl"
                                    jgy-agents-codex-test--none)
          (should (equal (jgy-agents-usage-codex)
                         '("codex" ("5h" 99.0 1791586523) ("7d" 16.0 1792173323)))))
      (delete-directory root t))))

(ert-deftest jgy-agents-codex-without-any-reading-stays-hidden ()
  (let* ((root (make-temp-file "codex-sessions" t))
         (jgy-agents-usage-codex-sessions-directory root)
         (jgy-agents-usage--codex nil))
    (unwind-protect
        (progn
          (jgy-agents-codex-test--write root "rollout-2026-10-10T03-44-32-b.jsonl"
                                    jgy-agents-codex-test--none)
          (should-not (jgy-agents-usage-codex)))
      (delete-directory root t))))

(ert-deftest jgy-agents-codex-row-opens-usage-page ()
  (let* ((root (make-temp-file "codex-sessions" t))
         (jgy-agents-usage-codex-sessions-directory root)
         (jgy-agents-usage--codex nil))
    (unwind-protect
        (progn
          (jgy-agents-codex-test--write root "rollout-2026-10-10T03-44-22-a.jsonl"
                                    jgy-agents-codex-test--good)
          (should (eq (get-text-property 0 'jgy-agents-action (car (jgy-agents-usage-codex)))
                      #'jgy-agents-usage-open-codex)))
      (delete-directory root t))))

(provide 'jgy-agents-codex-test)
;;; jgy-agents-codex-test.el ends here
