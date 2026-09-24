;;; jgy-worktree.el --- Git worktrees opened as tab workspaces -*- lexical-binding: t; -*-

;;; Commentary:
;; 每个分支一个 worktree，一个同名 tab。

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'tab-bar)

(defvar jgy/code-directory "~/code/okj/"
  "Directory containing Git repositories.")
(defvar jgy/worktree-directory "~/code/okj/worktree/"
  "Directory in which to create Git worktrees.")

(defun jgy/worktree--repos ()
  "Return Git repositories directly below `jgy/code-directory'."
  (let ((root (file-name-as-directory (expand-file-name jgy/code-directory)))
        (worktrees (file-name-as-directory (expand-file-name jgy/worktree-directory))))
    (seq-filter
     (lambda (name)
       (let ((directory (file-name-as-directory (expand-file-name name root))))
         (and (not (equal directory worktrees))
              (file-exists-p (expand-file-name ".git" directory)))))
     (directory-files root nil directory-files-no-dot-files-regexp))))

(defun jgy/worktree--git-lines (repo &rest args)
  "Return lines from git -C REPO ARGS."
  (apply #'process-lines "git" "-C" repo args))

(defun jgy/worktree--branches (repo)
  "Return local and origin branch names in REPO."
  (seq-uniq
   (append
    (jgy/worktree--git-lines repo "for-each-ref" "--format=%(refname:short)"
                             "refs/heads")
    (seq-remove
     (lambda (branch) (equal branch "HEAD"))
     (jgy/worktree--git-lines repo "for-each-ref" "--format=%(refname:strip=3)"
                              "refs/remotes/origin")))))

(defun jgy/worktree--read-branch (repo)
  "Read a branch name in REPO, keeping unknown names selectable.
Vertico selects the prompt line when nothing matches, and `C-k' from the
first candidate moves back up to it; `M-RET' submits the input outright."
  (let* ((branches (jgy/worktree--branches repo))
         (table
          (lambda (string predicate action)
            (if (eq action 'metadata)
                '(metadata (display-sort-function . identity)
                           (cycle-sort-function . identity))
              (complete-with-action action branches string predicate)))))
    (string-trim (completing-read "Branch: " table))))

(defun jgy/worktree--checkout (repo branch)
  "Return the existing checkout for BRANCH in REPO, if any."
  (let ((lines (jgy/worktree--git-lines repo "worktree" "list" "--porcelain"))
        path found)
    (dolist (line lines found)
      (cond
       ((string-prefix-p "worktree " line)
        (setq path (string-remove-prefix "worktree " line)))
       ((equal line (concat "branch refs/heads/" branch))
        (setq found path))))))

(defun jgy/worktree--ref-p (repo ref)
  "Return non-nil when REF exists in REPO."
  (zerop (call-process "git" nil nil nil "-C" repo
                       "show-ref" "--verify" "--quiet" ref)))

(defun jgy/worktree--create (repo branch path)
  "Create a checkout of BRANCH from REPO at PATH."
  (unless (zerop (call-process "git" nil nil nil "-C" repo
                               "check-ref-format" "--branch" branch))
    (user-error "Invalid branch name: %s" branch))
  (when (file-exists-p path)
    (user-error "Worktree path already exists: %s" path))
  (make-directory (file-name-directory path) t)
  (let ((args (cond
               ((jgy/worktree--ref-p repo (concat "refs/heads/" branch))
                (list "worktree" "add" path branch))
               ((jgy/worktree--ref-p repo (concat "refs/remotes/origin/" branch))
                (list "worktree" "add" "--track" "-b" branch path
                      (concat "origin/" branch)))
               (t (list "worktree" "add" "-b" branch path)))))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil "-C" repo args))
        (user-error "%s" (string-trim (buffer-string))))))
  path)

(defun jgy/worktree--visit (repo branch)
  "Check out BRANCH of REPO, reusing any existing worktree, in its own tab."
  (when (string-empty-p branch) (user-error "Branch cannot be empty"))
  (let* ((repo-name (file-name-nondirectory (directory-file-name repo)))
         (slug (replace-regexp-in-string "[/\\]" "-" branch))
         (path (or (jgy/worktree--checkout repo branch)
                   (jgy/worktree--create
                    repo branch
                    (expand-file-name (format "%s_%s" repo-name slug)
                                      jgy/worktree-directory)))))
    (tab-bar-switch-to-tab (format "%s:%s" repo-name slug))
    (dired path)))

(defun jgy/worktree--main-repo ()
  "Return the main checkout of the current Git repository, even from a worktree."
  (let ((common (car (ignore-errors
                       (process-lines "git" "rev-parse" "--path-format=absolute"
                                      "--git-common-dir")))))
    (unless common (user-error "Not inside a Git repository"))
    (file-name-directory (directory-file-name common))))

(defun jgy/worktree-open ()
  "Open a branch worktree in a matching tab workspace."
  (interactive)
  (let* ((repos (or (jgy/worktree--repos)
                    (user-error "No repositories under %s" jgy/code-directory)))
         (repo (expand-file-name (completing-read "Repository: " repos nil t)
                                 jgy/code-directory)))
    (jgy/worktree--visit repo (jgy/worktree--read-branch repo))))

(provide 'jgy-worktree)
;;; jgy-worktree.el ends here
