;;; overlook-worktree-test.el --- Worktree dependency boundaries -*- lexical-binding: t; -*-

(require 'ert)

(defun overlook-worktree-test--batch (paths form)
  "Evaluate FORM in a fresh Emacs with load PATHS; report failures as test errors."
  (with-temp-buffer
    (let ((status (call-process
                   (expand-file-name invocation-name invocation-directory)
                   nil t nil "-Q" "--batch" "--eval"
                   (prin1-to-string
                    `(progn
                       (setq load-path (append ',paths load-path))
                       (require 'cl-lib)
                       ,form)))))
      (unless (eql status 0)
        (ert-fail (buffer-string))))))

(ert-deftest overlook-worktree-loads-without-courier-or-dashboard ()
  (overlook-worktree-test--batch
   (list (file-name-directory (locate-library "overlook-worktree")))
   '(progn
      (setq overlook-courier-worktree-directory "checkouts"
            overlook-courier-worktree-marker ".project")
      (require 'overlook-worktree)
      (cl-assert (equal overlook-worktree-directory "checkouts"))
      (cl-assert (equal overlook-worktree-marker ".project"))
      (let ((overlook-courier-worktree-directory "trees"))
        (cl-assert (equal (overlook-worktree-path "/tmp/project" "fix/login")
                          "/tmp/project/trees/fix-login/")))
      (cl-assert (equal overlook-worktree-directory "checkouts"))
      (cl-assert (not (featurep 'overlook-courier)))
      (cl-assert (not (featurep 'overlook))))))

(ert-deftest overlook-repo-discovers-worktrees-without-courier ()
  (overlook-worktree-test--batch
   load-path
   '(progn
      (require 'overlook-repo)
      (let* ((root (make-temp-file "overlook-worktree" t))
             (tree (expand-file-name ".worktrees/fix/" root)))
        (unwind-protect
            (progn
              (make-directory tree t)
              (cl-assert (equal (overlook-repo--worktrees root)
                                (list (cons tree "fix")))))
          (delete-directory root t)))
      (cl-assert (not (featurep 'overlook-courier)))
      (cl-assert (not (featurep 'overlook-agent))))))
