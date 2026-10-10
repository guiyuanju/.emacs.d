;;; overlook-agent-shell-test.el --- Tests for overlook-agent-shell -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-agent-shell)

(defun overlook-agent-shell-test--diff (file old new &optional line)
  "A diff info as agent-shell makes it."
  (append `((:old . ,old) (:new . ,new) (:file . ,file))
          (when line `((:line . ,line)))))

(ert-deftest overlook-agent-shell-files-group-agent-shell-diffs ()
  (with-temp-buffer
    (setq-local overlook-agent-identity '((root . "/project/")))
    (overlook-agent-shell--track-edit
     "a" `((:status . "completed")
           (:diffs ,(overlook-agent-shell-test--diff "a.el" "x\n" "y\nz\n" 3))))
    (overlook-agent-shell--track-edit
     "b" `((:status . "failed")
           (:diffs ,(overlook-agent-shell-test--diff "/project/b.el" "" "rejected\n"))))
    (overlook-agent-shell--track-edit
     "c" `((:status . "in_progress")
           (:diffs ,(overlook-agent-shell-test--diff "/project/a.el" "z\n" ""))))
    (overlook-agent-shell--track-edit "d" '((:status . "completed") (:title . "ls")))
    (let ((files (overlook-agent-shell--files)))
      (should (equal (mapcar (lambda (file) (alist-get 'file file)) files)
                     '("/project/a.el")))
      (let-alist (car files)
        (should (equal (list .added .removed .active .line) '(2 2 t 3)))
        (should (= (length .diffs) 2))))
    ;; A later update of the same call replaces it rather than adding another.
    (overlook-agent-shell--track-edit
     "c" `((:status . "completed")
           (:diffs ,(overlook-agent-shell-test--diff "/project/a.el" "z\n" ""))))
    (should-not (alist-get 'active (car (overlook-agent-shell--files))))
    (should (= (length (alist-get 'diffs (car (overlook-agent-shell--files)))) 2))))

(ert-deftest overlook-agent-shell-diff-renders-with-agent-shell ()
  (let ((buffer (overlook-agent-shell--diff
                 `(((file . "/project/a.el")
                    (diffs ,(overlook-agent-shell-test--diff "/project/a.el" "x\n" "y\n")))))))
    (unwind-protect
        (with-current-buffer buffer
          (should (derived-mode-p 'agent-shell-diff-mode))
          (should (string-match-p "^-x$" (buffer-string)))
          (should (string-match-p "^\\+y$" (buffer-string)))
          (should-not (get-buffer-window buffer)))
      (kill-buffer buffer))))

;;; overlook-agent-shell-test.el ends here
