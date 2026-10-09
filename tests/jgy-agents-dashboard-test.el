;;; jgy-agents-dashboard-test.el --- Dashboard layout checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'jgy-agents-usage)

(ert-deftest jgy-agents-dashboard-sections-follow-hook-depth ()
  (let ((jgy-agents-dashboard-functions jgy-agents-dashboard-functions)
        (jgy-agents-usage--rows '(("claude" ("5h" 10 nil))))
        (dashboard (get-buffer-create jgy-agents-dashboard--name)))
    (add-hook 'jgy-agents-dashboard-functions
              (lambda (_frame)
                (jgy-agents-dashboard-insert-section "Todo" (lambda () (insert "x\n"))))
              50)
    (unwind-protect
        (with-current-buffer dashboard
          (jgy-agents-dashboard-mode)
          (jgy-agents-dashboard--render)
          (let ((text (buffer-string)))
            (should (< (string-search "Usage" text)
                       (string-search "Agents" text)
                       (string-search "Todo" text)))))
      (kill-buffer dashboard))))

(provide 'jgy-agents-dashboard-test)
;;; jgy-agents-dashboard-test.el ends here
