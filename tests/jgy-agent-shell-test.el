;;; jgy-agent-shell-test.el --- Tests for jgy-agent-shell -*- lexical-binding: t; -*-

(require 'ert)
(require 'jgy-agent-shell)

(defun jgy-agent-shell-test--diff (file old new &optional line)
  "A diff info as agent-shell makes it."
  (append `((:old . ,old) (:new . ,new) (:file . ,file))
          (when line `((:line . ,line)))))

(ert-deftest jgy-agent-shell-files-group-agent-shell-diffs ()
  (with-temp-buffer
    (setq-local jgy-agents-identity '((root . "/project/")))
    (jgy-agent-shell--track-edit
     "a" `((:status . "completed")
           (:diffs ,(jgy-agent-shell-test--diff "a.el" "x\n" "y\nz\n" 3))))
    (jgy-agent-shell--track-edit
     "b" `((:status . "failed")
           (:diffs ,(jgy-agent-shell-test--diff "/project/b.el" "" "rejected\n"))))
    (jgy-agent-shell--track-edit
     "c" `((:status . "in_progress")
           (:diffs ,(jgy-agent-shell-test--diff "/project/a.el" "z\n" ""))))
    (jgy-agent-shell--track-edit "d" '((:status . "completed") (:title . "ls")))
    (let ((files (jgy-agent-shell--files)))
      (should (equal (mapcar (lambda (file) (alist-get 'file file)) files)
                     '("/project/a.el")))
      (let-alist (car files)
        (should (equal (list .added .removed .active .line) '(2 2 t 3)))
        (should (= (length .diffs) 2))))
    ;; A later update of the same call replaces it rather than adding another.
    (jgy-agent-shell--track-edit
     "c" `((:status . "completed")
           (:diffs ,(jgy-agent-shell-test--diff "/project/a.el" "z\n" ""))))
    (should-not (alist-get 'active (car (jgy-agent-shell--files))))
    (should (= (length (alist-get 'diffs (car (jgy-agent-shell--files)))) 2))))

(ert-deftest jgy-agent-shell-diff-renders-with-agent-shell ()
  (let ((buffer (jgy-agent-shell--diff
                 `(((file . "/project/a.el")
                    (diffs ,(jgy-agent-shell-test--diff "/project/a.el" "x\n" "y\n")))))))
    (unwind-protect
        (with-current-buffer buffer
          (should (derived-mode-p 'agent-shell-diff-mode))
          (should (string-match-p "^-x$" (buffer-string)))
          (should (string-match-p "^\\+y$" (buffer-string)))
          (should-not (get-buffer-window buffer)))
      (kill-buffer buffer))))

;;; jgy-agent-shell-test.el ends here
