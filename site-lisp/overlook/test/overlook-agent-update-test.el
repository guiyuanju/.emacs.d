;;; overlook-agent-update-test.el --- Agent update checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-agent-update)

(ert-deftest overlook-agent-update-test-npm-findings ()
  "Missing, outdated and half-installed packages are offered; sound ones are not."
  (let ((overlook-agent-update-npm-packages '(("a" "ok" "old" "gone" "broken"))))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (name &optional _remote) (not (equal name "broken-bin")))))
      (should (equal
               (overlook-agent-update--npm-findings
                '((ok (bin (ok-bin . "x.js")))
                  (old (bin (old-bin . "x.js")))
                  (broken (bin (broken-bin . "x.js")))
                  (gone-not . nil))
                '((old (current . "1.0") (latest . "1.1"))))
               '((npm "old" "1.0→1.1" "old")
                 (npm "gone" "not installed" "gone")
                 (npm "broken" "broken" "broken")))))))

;;; overlook-agent-update-test.el ends here
