;;; overlook-worktree.el --- Git worktrees for projects -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
;; URL: https://github.com/guiyuanju/overlook
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Manages a project's checkouts without depending on agents or messaging.
;; A repository gets one Git worktree; a folder of repositories gets a
;; marked folder containing a worktree of each repository.  A new branch
;; may start elsewhere than the checked out commit, its start then kept
;; as the base its commits are counted against.

;;; Code:

(require 'project)
(require 'seq)
(require 'subr-x)

(defgroup overlook-worktree nil
  "Git worktrees for projects."
  :group 'overlook
  :prefix "overlook-worktree-")

(defcustom overlook-worktree-directory ".worktrees"
  "Folder, inside a project, holding its worktrees."
  :type 'string
  :group 'overlook-worktree)

(defcustom overlook-worktree-marker ".overlook"
  "File marking a folder of several repos' worktrees as one project."
  :type 'string
  :group 'overlook-worktree)

(defcustom overlook-worktree-remote "origin"
  "Remote whose default branch `overlook-worktree-default-start' gives."
  :type 'string
  :group 'overlook-worktree)

(defcustom overlook-worktree-fetch nil
  "Non-nil to fetch a remote before starting a branch at one of its branches."
  :type 'boolean
  :group 'overlook-worktree)

(defcustom overlook-worktree-copied-files nil
  "Files and folders, relative to a repo, copied into its new checkouts.
They are the untracked ones a checkout needs, such as \".env\"."
  :type '(repeat string)
  :group 'overlook-worktree)

(defcustom overlook-worktree-setup-functions '(overlook-worktree-copy-files)
  "Functions run on a worktree after checkouts are added to it.
Each is called with the worktree's PATH and the new checkouts as a list
of (REPO . CHECKOUT).  An error in one is reported and the worktree kept."
  :type 'hook
  :group 'overlook-worktree)

(defun overlook-worktree-git-program ()
  "The git program to run."
  (or (bound-and-true-p vc-git-program) "git"))

(defun overlook-worktree-git (dir &rest args)
  "Run git with ARGS in DIR; return its output, or signal its error."
  (with-temp-buffer
    (let* ((default-directory (file-name-as-directory dir))
           (status (apply #'process-file (overlook-worktree-git-program) nil t nil args)))
      (unless (eq status 0)
        (user-error "Git %s in %s: %s" (string-join args " ") (abbreviate-file-name dir)
                    (string-trim (buffer-string))))
      (string-trim (buffer-string)))))

(defun overlook-worktree--output (dir &rest args)
  "Output of git ARGS in DIR, or nil when it fails or prints nothing."
  (let ((output (ignore-errors (apply #'overlook-worktree-git dir args))))
    (and output (not (string-empty-p output)) output)))

(defun overlook-worktree--repo-p (dir)
  "Non-nil when DIR is the top of a Git repo or worktree."
  (file-exists-p (expand-file-name ".git" dir)))

(defun overlook-worktree--label (dir)
  "The name of folder DIR."
  (file-name-nondirectory (directory-file-name dir)))

(defun overlook-worktree-repos (dir)
  "DIR when it is a Git repo, else the Git repos directly inside it."
  (let ((dir (file-name-as-directory (expand-file-name dir))))
    (if (overlook-worktree--repo-p dir)
        (list dir)
      (seq-filter #'overlook-worktree--repo-p
                  (mapcar #'file-name-as-directory
                          (seq-filter #'file-directory-p
                                      (directory-files dir t "\\`[^.]")))))))

(defun overlook-worktree-path (dir branch)
  "Where the worktree of project DIR for BRANCH lies."
  (file-name-as-directory
   (expand-file-name (replace-regexp-in-string "/" "-" branch)
                     (expand-file-name overlook-worktree-directory dir))))

(defun overlook-worktree-at (path)
  "(DIR . NAME) when PATH is a worktree folder of project DIR, else nil.
NAME is as `overlook-worktree-list' gives it."
  (let* ((path (file-name-as-directory (expand-file-name path)))
         (folder (file-name-parent-directory path))
         (inside (file-name-as-directory overlook-worktree-directory))
         (name (overlook-worktree--label path)))
    (when (and folder (string-suffix-p inside folder))
      (let ((dir (substring folder 0 (- (length inside)))))
        (and (member name (overlook-worktree-list dir))
             (cons dir name))))))

(defun overlook-worktree-list (dir)
  "Names of the worktrees in project DIR, their branches with `/' as `-'."
  (let ((folder (expand-file-name overlook-worktree-directory dir)))
    (and (file-directory-p folder)
         (mapcar #'file-name-nondirectory
                 (seq-filter #'file-directory-p (directory-files folder t "\\`[^.]"))))))

(defun overlook-worktree-branch (checkout)
  "The branch checked out in CHECKOUT, or nil when detached."
  (overlook-worktree--output checkout "symbolic-ref" "--quiet" "--short" "HEAD"))

(defun overlook-worktree-main (checkout)
  "The main checkout of the repo CHECKOUT belongs to, or nil."
  (when-let* ((common (overlook-worktree--output checkout "rev-parse" "--path-format=absolute"
                                                 "--git-common-dir")))
    (file-name-directory (directory-file-name common))))

(defun overlook-worktree-default-start (repo)
  "Where a new branch of REPO starts by default.
That is the default branch of `overlook-worktree-remote', else the
branch checked out in REPO, else HEAD."
  (or (overlook-worktree--output repo "symbolic-ref" "--quiet" "--short"
                                 (format "refs/remotes/%s/HEAD" overlook-worktree-remote))
      (overlook-worktree-branch repo)
      "HEAD"))

(defun overlook-worktree--fetch (repo start)
  "Fetch the remote of START in REPO, when START is a remote branch."
  (when-let* ((ref (overlook-worktree--output repo "rev-parse" "--symbolic-full-name" start))
              (remote (and (string-match "\\`refs/remotes/\\([^/]+\\)/" ref)
                           (match-string 1 ref))))
    (overlook-worktree-git repo "fetch" "--quiet" remote)))

(defun overlook-worktree--exclude (dir)
  "Have the repo holding DIR, if any, leave out the worktrees.
They live in `overlook-worktree-directory'."
  (when-let* ((common (overlook-worktree--output dir "rev-parse" "--path-format=absolute"
                                                 "--git-common-dir")))
    (let ((file (expand-file-name "info/exclude" common))
          (line (concat overlook-worktree-directory "/")))
      (unless (and (file-exists-p file)
                   (with-temp-buffer
                     (insert-file-contents file)
                     (re-search-forward (concat "^" (regexp-quote line) "$") nil t)))
        (make-directory (file-name-directory file) t)
        (with-temp-buffer
          (when (file-exists-p file) (insert-file-contents file))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (insert line "\n")
          (write-region nil nil file nil 'silent))))))

(defun overlook-worktree--base-key (branch)
  "The Git config key holding the base of BRANCH."
  (format "branch.%s.overlookBase" branch))

(defun overlook-worktree-checked-out (repo)
  "(BRANCH . CHECKOUT) of each branch of REPO checked out, in any of its worktrees."
  (let (pairs checkout)
    (dolist (line (split-string (or (overlook-worktree--output repo "worktree" "list" "--porcelain")
                                    "")
                                "\n"))
      (cond ((string-prefix-p "worktree " line)
             (setq checkout (file-name-as-directory (substring line 9))))
            ((string-prefix-p "branch refs/heads/" line)
             (push (cons (substring line 18) checkout) pairs))))
    (nreverse pairs)))

(defun overlook-worktree-free-branches (dir)
  "Branches a worktree of project DIR can check out.
They are the local branches of its first repo checked out nowhere, or
in a worktree of DIR."
  (when-let* ((repo (car (overlook-worktree-repos dir))))
    (let ((inside (file-truename (expand-file-name overlook-worktree-directory dir)))
          (taken (overlook-worktree-checked-out repo)))
      (seq-remove (lambda (branch)
                    (when-let* ((checkout (cdr (assoc branch taken))))
                      (not (file-in-directory-p checkout inside))))
                  (overlook-worktree--refs repo "refs/heads")))))

(defun overlook-worktree-main-checkout-p (dir branch)
  "Non-nil when BRANCH is checked out in the main checkout of a repo of DIR.
DIR is a project."
  (seq-some (lambda (repo)
              (when-let* ((checkout (cdr (assoc branch (overlook-worktree-checked-out repo)))))
                (file-equal-p checkout repo)))
            (overlook-worktree-repos dir)))

(defun overlook-worktree--add-one (repo path branch start)
  "Check out BRANCH of REPO at PATH, making it at START when it does not exist.
START is as for `overlook-worktree-add'; one other than HEAD is recorded
as the branch's base."
  (make-directory (file-name-directory (directory-file-name path)) t)
  (if (overlook-worktree--output repo "rev-parse" "--verify" "--quiet"
                                 (concat "refs/heads/" branch))
      (progn
        (when-let* ((checkout (cdr (assoc branch (overlook-worktree-checked-out repo)))))
          (user-error "Branch %s is checked out in %s; pick another branch"
                      branch (abbreviate-file-name checkout)))
        (overlook-worktree-git repo "worktree" "add" (directory-file-name path) branch))
    (let ((start (if (eq start 'default) (overlook-worktree-default-start repo) start)))
      (when (and start overlook-worktree-fetch)
        (with-demoted-errors "Fetch failed: %S" (overlook-worktree--fetch repo start)))
      (apply #'overlook-worktree-git repo "worktree" "add" "--no-track" "-b" branch
             (directory-file-name path) (and start (list start)))
      (when (and start (not (equal start "HEAD")))
        (overlook-worktree-git repo "config" (overlook-worktree--base-key branch) start)))))

(defun overlook-worktree--check (path branch)
  "Signal an error when PATH holds a checkout of other than BRANCH."
  (dolist (checkout (and (file-directory-p path) (overlook-worktree-repos path)))
    (let ((held (overlook-worktree-branch checkout)))
      (unless (equal held branch)
        (user-error "%s holds branch %s, not %s"
                    (abbreviate-file-name checkout) (or held "none") branch)))))

(defun overlook-worktree--setup (path checkouts)
  "Run `overlook-worktree-setup-functions' on new CHECKOUTS of worktree PATH."
  (when checkouts
    (run-hook-wrapped 'overlook-worktree-setup-functions
                      (lambda (function)
                        (with-demoted-errors "Worktree setup failed: %S"
                          (funcall function path checkouts))
                        nil))))

(defun overlook-worktree-add (dir branch &optional start repos)
  "Make the worktree of project DIR for BRANCH and return its path.
A new branch starts at START in each repo: a revision, `default' for
`overlook-worktree-default-start', or nil for the checked out commit.
An existing branch is checked out as it is.  REPOS, some of
`overlook-worktree-repos', limits a project of several repos to them;
an existing worktree gets those of them it lacks.  New checkouts are set
up by `overlook-worktree-setup-functions'."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (path (overlook-worktree-path dir branch))
         (all (or (overlook-worktree-repos dir) (user-error "No Git repo in %s" dir)))
         (repos (if repos
                    (mapcar (lambda (repo)
                              (or (car (member (file-name-as-directory (expand-file-name repo dir))
                                               all))
                                  (user-error "No repo %s in %s" repo dir)))
                            repos)
                  all))
         (made nil))
    (overlook-worktree-git dir "check-ref-format" "--branch" branch)
    (overlook-worktree--check path branch)
    (if (equal all (list dir))
        (cond ((overlook-worktree--repo-p path))
              ((file-exists-p path)
               (user-error "%s exists and is no worktree" (abbreviate-file-name path)))
              (t (overlook-worktree--exclude dir)
                 (overlook-worktree--add-one dir path branch start)
                 (push (cons dir path) made)))
      (let ((marker (expand-file-name overlook-worktree-marker path))
            (fresh (not (file-exists-p path))))
        (unless (or fresh (file-exists-p marker))
          (user-error "%s exists and is no worktree" (abbreviate-file-name path)))
        (overlook-worktree--exclude dir)
        (condition-case err
            (progn
              (when fresh
                (make-directory path t)
                (with-temp-file marker))
              (dolist (repo repos)
                (let ((sub (file-name-as-directory
                            (expand-file-name (overlook-worktree--label repo) path))))
                  (unless (file-exists-p sub)
                    (overlook-worktree--add-one repo sub branch start)
                    (push (cons repo sub) made)))))
          (error
           (pcase-dolist (`(,repo . ,sub) made)
             (ignore-errors (overlook-worktree-git repo "worktree" "remove" "--force"
                                                   (directory-file-name sub))))
           (when fresh (ignore-errors (delete-directory path t)))
           (signal (car err) (cdr err))))))
    (overlook-worktree--setup path (nreverse made))
    path))

(defun overlook-worktree-copy-files (_path checkouts)
  "Copy `overlook-worktree-copied-files' from each repo into its new checkout.
CHECKOUTS is a list of (REPO . CHECKOUT); a file the checkout has is kept."
  (pcase-dolist (`(,repo . ,checkout) checkouts)
    (dolist (name overlook-worktree-copied-files)
      (let ((from (directory-file-name (expand-file-name name repo)))
            (to (directory-file-name (expand-file-name name checkout))))
        (when (and (file-exists-p from) (not (file-exists-p to)))
          (make-directory (file-name-directory to) t)
          (if (file-directory-p from)
              (copy-directory from to t)
            (copy-file from to nil t nil t)))))))

(defun overlook-worktree--remove (path force delete-branch)
  "Remove worktree PATH; return the labels of the repos keeping its branch.
FORCE and DELETE-BRANCH are as for `overlook-worktree-remove'."
  (let ((kept nil))
    (dolist (checkout (overlook-worktree-repos path))
      (let* ((main (and delete-branch (overlook-worktree-main checkout)))
             (name (and main (overlook-worktree-branch checkout)))
             (base (and name (overlook-worktree-base checkout))))
        (apply #'overlook-worktree-git checkout "worktree" "remove"
               (append (and force '("--force")) (list (directory-file-name checkout))))
        (when name
          (unless (and base
                       (ignore-errors
                         (overlook-worktree-git main "merge-base" "--is-ancestor" name base)
                         (overlook-worktree-git main "branch" "-D" name)
                         t))
            (push (overlook-worktree--label main) kept)))))
    (when (file-directory-p path) (delete-directory path t))
    (nreverse kept)))

(defun overlook-worktree-remove (dir branch &optional force delete-branch)
  "Remove the worktree of project DIR for BRANCH and return its path.
Git refuses while a checkout has changes, unless FORCE is non-nil.  With
DELETE-BRANCH non-nil the branch goes too in each repo where it is merged
into its base, as `overlook-worktree-base' gives it; an error names the
repos keeping it."
  (let ((path (overlook-worktree-path dir branch)))
    (unless (file-directory-p path) (user-error "No worktree %s" (abbreviate-file-name path)))
    (when-let* ((kept (overlook-worktree--remove path force delete-branch)))
      (user-error "Removed %s; its branch is kept, unmerged, in %s"
                  (abbreviate-file-name path) (string-join kept ", ")))
    path))

(defun overlook-worktree-prune (dir)
  "Clear what is left of project DIR's worktrees whose folders were deleted.
Git forgets the missing checkouts, and a worktree folder left holding
nothing but its marker goes."
  (dolist (repo (overlook-worktree-repos dir))
    (overlook-worktree-git repo "worktree" "prune"))
  (dolist (name (overlook-worktree-list dir))
    (let ((path (overlook-worktree-path dir name)))
      (when (equal (directory-files path nil "\\`\\([^.]\\|\\.[^.]\\)")
                   (list overlook-worktree-marker))
        (delete-directory path t)))))

(defun overlook-worktree-dirty-p (dir)
  "Non-nil when repo or folder DIR has uncommitted changes."
  (not (string-empty-p
        (or (ignore-errors (overlook-worktree-git dir "status" "--porcelain" "--" ".")) ""))))

(defun overlook-worktree-uncommitted (path)
  "The checkouts of worktree PATH with uncommitted changes."
  (seq-filter #'overlook-worktree-dirty-p (overlook-worktree-repos path)))

(defun overlook-worktree-recorded-base (checkout)
  "The start recorded for the branch of CHECKOUT when it was made, or nil."
  (when-let* ((branch (overlook-worktree-branch checkout)))
    (overlook-worktree--output checkout "config" "--get" (overlook-worktree--base-key branch))))

(defun overlook-worktree-base (checkout)
  "What CHECKOUT's commits are counted against.
That is the recorded base of its branch, else the branch of its main checkout."
  (or (overlook-worktree-recorded-base checkout)
      (when-let* ((main (overlook-worktree-main checkout)))
        (overlook-worktree-branch main))))

(defun overlook-worktree-divergence-args (base)
  "Git arguments counting the commits of HEAD and of BASE not in the other."
  (list "rev-list" "--left-right" "--count" (concat "HEAD..." base)))

(defun overlook-worktree-parse-divergence (output)
  "(AHEAD . BEHIND) from OUTPUT of `overlook-worktree-divergence-args', or nil."
  (when-let* ((counts (and output (split-string output)))
              ((= (length counts) 2)))
    (cons (string-to-number (car counts)) (string-to-number (cadr counts)))))

(defun overlook-worktree-divergence (checkout &optional base)
  "(AHEAD . BEHIND) of CHECKOUT against BASE, or nil when unknown.
BASE defaults to `overlook-worktree-base'.  AHEAD counts the commits of
CHECKOUT not in BASE, BEHIND those of BASE not in it."
  (when-let* ((base (or base (overlook-worktree-base checkout))))
    (overlook-worktree-parse-divergence
     (apply #'overlook-worktree--output checkout (overlook-worktree-divergence-args base)))))

(defun overlook-worktree--project ()
  "The current project's folder, its main one when in a worktree."
  (let ((root (file-name-as-directory
               (expand-file-name (if-let* ((project (project-current)))
                                     (project-root project)
                                   default-directory)))))
    (or (car (overlook-worktree-at root)) root)))

(defun overlook-worktree--refs (repo &rest kinds)
  "Short names of REPO's refs under KINDS, such as \"refs/heads\"."
  (when-let* ((output (apply #'overlook-worktree--output repo "for-each-ref"
                             "--format=%(refname:short)" kinds)))
    (split-string output "\n" t)))

;;;###autoload
(defun overlook-worktree-create (dir branch &optional start repos)
  "Make the worktree of project DIR for BRANCH at START, open it, return its path.
START and REPOS are as for `overlook-worktree-add'.  Interactively DIR
is the current project; with a prefix argument it is read, and for a
project of several repos which of them to check out too.  An empty
start is `default'."
  (interactive
   (let* ((dir (if current-prefix-arg
                   (read-directory-name "Project: " (overlook-worktree--project) nil t)
                 (overlook-worktree--project)))
          (all (or (overlook-worktree-repos dir) (user-error "No Git repo in %s" dir)))
          (repos (and current-prefix-arg (cdr all)
                      (completing-read-multiple "Repos: " (mapcar #'overlook-worktree--label all)
                                                nil t)))
          (repo (if repos (expand-file-name (car repos) dir) (car all)))
          (locals (overlook-worktree--refs repo "refs/heads"))
          (branch (completing-read "Branch: " (overlook-worktree-free-branches dir)))
          (start (unless (member branch locals)
                   (let ((input (completing-read
                                 "Start (empty: the default branch): "
                                 (overlook-worktree--refs repo "refs/heads" "refs/remotes"))))
                     (if (string-empty-p input) 'default input)))))
     (list dir branch start repos)))
  (let ((path (overlook-worktree-add dir branch start repos)))
    (when (called-interactively-p 'any) (dired path))
    path))

;;;###autoload
(defun overlook-worktree-delete (dir name &optional delete-branch)
  "Remove worktree NAME of project DIR, and its buffers, once confirmed.
With DELETE-BRANCH, interactively a prefix argument, its branch goes too
where it is merged."
  (interactive
   (let ((dir (overlook-worktree--project)))
     (list dir
           (completing-read "Delete worktree: "
                            (or (overlook-worktree-list dir) (user-error "No worktrees in %s" dir))
                            nil t)
           current-prefix-arg)))
  (let* ((path (overlook-worktree-path dir name))
         (changed (overlook-worktree-uncommitted path)))
    (when (yes-or-no-p
           (format "Delete worktree %s%s? " name
                   (if changed
                       (format "; uncommitted changes in %s are lost"
                               (mapconcat #'overlook-worktree--label changed ", "))
                     "")))
      (let ((kill-buffer-query-functions nil))
        (dolist (buffer (buffer-list))
          (when (file-in-directory-p (buffer-local-value 'default-directory buffer) path)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer))))
      (overlook-worktree-remove dir name t delete-branch)
      (message "Deleted worktree %s" name))))

(provide 'overlook-worktree)
;;; overlook-worktree.el ends here
