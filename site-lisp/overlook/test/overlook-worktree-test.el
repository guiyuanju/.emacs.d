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
      (require 'overlook-worktree)
      (let ((overlook-worktree-directory "trees"))
        (cl-assert (equal (overlook-worktree-path "/tmp/project" "fix/login")
                          "/tmp/project/trees/fix-login/")))
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

(require 'overlook-worktree)

(defmacro overlook-worktree-test--with-project (repos &rest body)
  "Run BODY with `root' a temp project of REPOS, each a repo with one commit.
REPOS nil makes the project itself one repo."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "overlook-worktree" t)))
          (process-environment
           (append '("GIT_CONFIG_GLOBAL=/dev/null" "GIT_CONFIG_NOSYSTEM=1"
                     "GIT_AUTHOR_NAME=t" "GIT_AUTHOR_EMAIL=t@t"
                     "GIT_COMMITTER_NAME=t" "GIT_COMMITTER_EMAIL=t@t")
                   process-environment))
          (overlook-worktree-setup-functions nil)
          (overlook-worktree-fetch nil))
     (unwind-protect
         (progn
           (dolist (repo (or ,repos '(nil)))
             (overlook-worktree-test--repo (if repo (expand-file-name repo root) root)))
           ,@body)
       (delete-directory root t))))

(defun overlook-worktree-test--repo (dir)
  "Make DIR a repo on branch main with one commit."
  (make-directory dir t)
  (overlook-worktree-git dir "init" "-q" "-b" "main")
  (write-region "a\n" nil (expand-file-name "a" dir) nil 'silent)
  (overlook-worktree-git dir "add" "a")
  (overlook-worktree-git dir "commit" "-q" "-m" "a"))

(defun overlook-worktree-test--commit (dir name)
  "Commit a new file NAME in DIR."
  (write-region "x\n" nil (expand-file-name name dir) nil 'silent)
  (overlook-worktree-git dir "add" name)
  (overlook-worktree-git dir "commit" "-q" "-m" name))

(ert-deftest overlook-worktree-add-starts-at-a-revision-and-records-it ()
  (overlook-worktree-test--with-project nil
    (overlook-worktree-git root "branch" "release")
    (overlook-worktree-test--commit root "b")
    (let ((path (overlook-worktree-add root "fix/x" "release")))
      (should (equal path (expand-file-name ".worktrees/fix-x/" root)))
      (should (equal (overlook-worktree-branch path) "fix/x"))
      (should-not (file-exists-p (expand-file-name "b" path)))
      (should (equal (overlook-worktree-recorded-base path) "release"))
      (should (equal (overlook-worktree-base path) "release"))
      (should (equal (file-truename (overlook-worktree-main path)) (file-truename root)))
      (overlook-worktree-test--commit path "c")
      (should (equal (overlook-worktree-divergence path) '(1 . 0)))
      (should (equal (overlook-worktree-divergence path "main") '(1 . 1)))
      (should (equal (overlook-worktree-add root "fix/x") path)))))

(ert-deftest overlook-worktree-add-defaults-to-head-and-the-main-branch ()
  (overlook-worktree-test--with-project nil
    (let ((path (overlook-worktree-add root "a")))
      (should (equal (overlook-worktree-default-start root) "main"))
      (should-not (overlook-worktree-recorded-base path))
      (should (equal (overlook-worktree-base path) "main"))
      (should (equal (overlook-worktree-divergence path) '(0 . 0))))
    (should (equal (overlook-worktree-recorded-base (overlook-worktree-add root "b" 'default))
                   "main"))))

(ert-deftest overlook-worktree-add-refuses-a-folder-of-another-branch ()
  (overlook-worktree-test--with-project nil
    (overlook-worktree-add root "fix/x")
    (should-error (overlook-worktree-add root "fix-x") :type 'user-error)))

(ert-deftest overlook-worktree-add-checks-out-some-repos-then-more ()
  (overlook-worktree-test--with-project '("api" "web" "doc")
    (let ((path (overlook-worktree-add root "f" nil '("api"))))
      (should (file-exists-p (expand-file-name overlook-worktree-marker path)))
      (should (equal (mapcar #'overlook-worktree--label (overlook-worktree-repos path))
                     '("api")))
      (overlook-worktree-add root "f" nil (list (expand-file-name "web" root)))
      (should (equal (mapcar #'overlook-worktree--label (overlook-worktree-repos path))
                     '("api" "web")))
      (should-error (overlook-worktree-add root "f" nil '("nope")) :type 'user-error))))

(ert-deftest overlook-worktree-add-rolls-back-a-failed-folder ()
  (overlook-worktree-test--with-project '("api" "web")
    (should-error (overlook-worktree-add root "f" "no-such-rev"))
    (should-not (file-exists-p (overlook-worktree-path root "f")))
    (should-not (overlook-worktree-list root))))

(ert-deftest overlook-worktree-setup-copies-files-into-new-checkouts ()
  (overlook-worktree-test--with-project '("api")
    (let* ((api (expand-file-name "api/" root))
           (overlook-worktree-copied-files '(".env" "conf/" "missing"))
           (seen nil)
           (overlook-worktree-setup-functions
            (list #'overlook-worktree-copy-files
                  (lambda (_path _checkouts) (error "Boom"))
                  (lambda (path checkouts) (push (cons path checkouts) seen)))))
      (write-region "K=1\n" nil (expand-file-name ".env" api) nil 'silent)
      (make-directory (expand-file-name "conf" api))
      (write-region "c\n" nil (expand-file-name "conf/c" api) nil 'silent)
      (let* ((path (overlook-worktree-add root "f"))
             (checkout (expand-file-name "api/" path)))
        (should (file-exists-p (expand-file-name ".env" checkout)))
        (should (file-exists-p (expand-file-name "conf/c" checkout)))
        (should (equal seen (list (list path (cons api checkout)))))
        (overlook-worktree-add root "f")
        (should (= (length seen) 1))))))

(ert-deftest overlook-worktree-remove-deletes-only-merged-branches ()
  (overlook-worktree-test--with-project '("api" "web")
    (let ((path (overlook-worktree-add root "f")))
      (overlook-worktree-test--commit (expand-file-name "web/" path) "w")
      (should-error (overlook-worktree-remove root "f" nil t) :type 'user-error)
      (should-not (file-exists-p path))
      (should-not (overlook-worktree--output (expand-file-name "api" root)
                                             "rev-parse" "--verify" "--quiet" "refs/heads/f"))
      (should (overlook-worktree--output (expand-file-name "web" root)
                                         "rev-parse" "--verify" "--quiet" "refs/heads/f")))))

(ert-deftest overlook-worktree-uncommitted-names-dirty-checkouts ()
  (overlook-worktree-test--with-project '("api" "web")
    (let ((path (overlook-worktree-add root "f")))
      (write-region "y\n" nil (expand-file-name "web/a" path) nil 'silent)
      (should (equal (overlook-worktree-uncommitted path)
                     (list (expand-file-name "web/" path))))
      (should-error (overlook-worktree-remove root "f") :type 'user-error)
      (overlook-worktree-remove root "f" t)
      (should-not (file-exists-p path)))))

(ert-deftest overlook-worktree-prune-clears-deleted-worktrees ()
  (overlook-worktree-test--with-project '("api")
    (let ((path (overlook-worktree-add root "f")))
      (delete-directory (expand-file-name "api" path) t)
      (overlook-worktree-prune root)
      (should-not (file-exists-p path))
      (should-not (string-match-p
                   "\\.worktrees"
                   (overlook-worktree-git (expand-file-name "api" root) "worktree" "list"))))))
