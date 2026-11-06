;;; overlook-project.el --- Repos of each perspective's project -*- lexical-binding: t; -*-

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

;; Lists the changed Git repos of each perspective's project under its
;; heading: the project root when it is a repo itself, and the repos
;; directly inside it, so a project made of several clones shows each.  A
;; clean repo stays hidden until it changes.  A repo's row shows
;; its branch and the lines changed since its last commit, and under it,
;; indented, the changed files, read asynchronously and at most every
;; `overlook-project-status-interval' seconds, and soon after a save in
;; it or a Magit refresh of it.  RET on a repo shows its
;; diff in Magit, or its status when clean; RET on a file shows its diff
;; since the last commit in Magit.  Without Magit, VC does both.
;;
;; `overlook-project-folders' adds folders lying inside a larger repo, such
;; as a project's notes kept in a shared one; such a folder's row lists
;; only the changes under it.  With `overlook-project-folder-display' set
;; to `mark', such a folder gets no row; a "*" after the perspective's
;; heading tells it has changes.
;;
;; While the project has courier's worktrees, its rows are grouped by
;; checkout, each shown while clean too: first the main checkout, holding
;; the agents in no worktree and then the changed repos, then each
;; worktree, holding the agents working in it and then its changed files,
;; or for a worktree of several repos, a row of each.

;;; Code:

(require 'overlook)
(require 'diff-mode)
(require 'overlook-markers)

(declare-function magit-status-setup-buffer "magit-status")
(declare-function magit-diff-working-tree "magit-diff")
(declare-function vc-version-diff "vc")

(declare-function overlook-courier-worktree-list "overlook-courier-worktree")
(declare-function overlook-courier-worktree-path "overlook-courier-worktree")
(declare-function overlook-courier-worktree-repos "overlook-courier-worktree")
(declare-function overlook-courier-worktree-remove "overlook-courier-worktree")
(declare-function overlook-courier-worktree-at "overlook-courier-worktree")
(declare-function overlook-courier-worktree--git "overlook-courier-worktree")

(defcustom overlook-project-status-interval 30
  "Seconds before a repo's branch and changes are read again."
  :type 'number
  :group 'overlook)

(defcustom overlook-project-parallel-reads 2
  "Most repos whose status is read at once; the others wait their turn."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-project-touch-delay 0.5
  "Seconds a save or Magit refresh waits before its repos are read again.
The saves and refreshes within that time share one read."
  :type 'number
  :group 'overlook)

;;;###autoload
(defcustom overlook-project-folders #'overlook-project-root-folder
  "Function of a perspective NAME returning folders to list with its repos.
A folder inside a larger repo lists that repo's changes under it; a
folder that is a repo itself is listed as one."
  :type 'function
  :group 'overlook)

(defcustom overlook-project-folder-display 'rows
  "How changes of a folder inside a larger repo show.
`rows' lists them under the perspective like a repo's; `mark' puts a
\"*\" after the perspective's heading instead."
  :type '(choice (const rows) (const mark))
  :group 'overlook)

(defface overlook-project-repo
  '((t :inherit shadow))
  "Face of a repo's row, dimmed so agents stand out."
  :group 'overlook)

(defface overlook-project-file
  '((t :inherit overlook-project-repo))
  "Face of a changed file's name under its repo."
  :group 'overlook)

(defvar overlook-project--status (make-hash-table :test #'equal)
  "Repo or folder directory to (TIME BRANCH . FILES), as last read.
Each of FILES is (PATH CODE ADDED REMOVED FROM): PATH relative to the
repo, CODE its two-letter `git status' code, line counts since the last
commit, nil when unknown, and for a renamed file the path it had there.
A rename's CODE has R in place of the A of its new path.")

(defvar overlook-project--reading (make-hash-table :test #'equal)
  "Repo directories whose status is being read.")

(defvar overlook-project--again (make-hash-table :test #'equal)
  "Repos touched while being read, to read again once that read is done.")

(defvar overlook-project--diverged (make-hash-table :test #'equal)
  "Worktree checkout to (TIME BASE AHEAD . BEHIND), as last read.
AHEAD counts its commits not on branch BASE, BEHIND those of BASE not on it.")

(defvar overlook-project--touched nil
  "Directories saved in or refreshed by Magit since the last touch read.")

(defvar overlook-project--touch-timer nil)

(defvar overlook-project--shown nil
  "Repos and folders of the perspectives as last drawn, shown or clean.")

(defun overlook-project--numstat (numstat)
  "Line counts in NUMSTAT, from `git diff HEAD --numstat -M -z'.
Each is (PATH ADDED REMOVED), with the old path after them for a rename."
  (let ((fields (split-string (or numstat "") "\0" t))
        counts)
    (while fields
      (when (string-match "\\`\\([0-9-]+\\)\t\\([0-9-]+\\)\t\\(.*\\)" (car fields))
        (let ((added (string-to-number (match-string 1 (car fields))))
              (removed (string-to-number (match-string 2 (car fields))))
              (path (match-string 3 (car fields))))
          ;; A rename leaves the path empty and gives the old and new paths after it.
          (push (if (string-empty-p path)
                    (prog1 (list (nth 2 fields) added removed (nth 1 fields))
                      (setq fields (cddr fields)))
                  (list path added removed))
                counts)))
      (setq fields (cdr fields)))
    counts))

(defun overlook-project--parse (status &optional numstat)
  "Branch and changed files from STATUS and NUMSTAT outputs.
STATUS is from `git status --porcelain --branch --no-renames -z', NUMSTAT
from `git diff HEAD --numstat -M -z'.  A rename NUMSTAT finds folds the
old path's deletion into the new path's entry."
  (let* ((entries (split-string status "\0" t))
         (head (car entries))
         (branch (cond ((null head) nil)
                       ((string-match "\\`## No commits yet on \\(.+\\)" head)
                        (match-string 1 head))
                       ((string-match "\\`## \\(HEAD\\) (no branch)" head) "detached")
                       ((string-match "\\`## \\([^.[:space:]]+\\)" head)
                        (match-string 1 head))))
         (counts (overlook-project--numstat numstat))
         (from (delq nil (mapcar (lambda (count) (nth 3 count)) counts))))
    (cons branch
          (delq nil
                (mapcar (lambda (entry)
                          (let* ((path (substring entry 3))
                                 (code (substring entry 0 2))
                                 (count (cdr (assoc path counts))))
                            (cond ((member path from) nil)
                                  ((nth 2 count)
                                   (cons path (cons (string-replace "A" "R" code) count)))
                                  (t (cons path (cons code count))))))
                        (cdr entries))))))

(defun overlook-project-root-folder (name)
  "Perspective NAME's root."
  (when-let* ((root (overlook-perspective-root name)))
    (list root)))

(defun overlook-project--top (dir)
  "Top of the repo holding DIR, or nil."
  (when-let* ((top (locate-dominating-file dir ".git")))
    (file-name-as-directory (expand-file-name top))))

(defun overlook-project--prefix (dir)
  "DIR relative to the top of its repo, or nil when DIR is the top."
  (when-let* ((top (overlook-project--top dir))
              ((not (equal top dir))))
    (file-relative-name dir top)))

(defun overlook-project--git (dir args then)
  "Run git with ARGS in DIR, calling THEN with its output, or nil on failure."
  (let ((output (generate-new-buffer " *overlook-git*"))
        (default-directory dir))
    (make-process
     :name "overlook-git" :buffer output :noquery t
     :command (append (list (or (bound-and-true-p vc-git-program) "git")
                            "-c" "core.quotePath=false")
                      args)
     :connection-type 'pipe
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (when (buffer-live-p output)
           (let ((text (and (eq (process-exit-status process) 0)
                            (with-current-buffer output (buffer-string)))))
             (kill-buffer output)
             (funcall then text))))))))

(defun overlook-project--read (dir)
  "Read DIR's status in the background, redrawing when it changed.
Does nothing while `overlook-project-parallel-reads' repos are being read."
  (unless (or (not (file-directory-p dir))
              (gethash dir overlook-project--reading)
              (>= (hash-table-count overlook-project--reading) overlook-project-parallel-reads))
    (puthash dir t overlook-project--reading)
    (let ((top (or (overlook-project--top dir) dir))
          (paths (when-let* ((prefix (overlook-project--prefix dir)))
                   (list "--" (concat ":(literal)" prefix)))))
      (overlook-project--git
       top `("status" "--porcelain" "--branch" "--no-renames" "-z" ,@paths)
       (lambda (status)
         (if (null status)
             (progn
               (puthash dir (cons (float-time) (cdr (gethash dir overlook-project--status)))
                        overlook-project--status)
               (overlook-project--done dir))
           ;; Fails before the first commit, leaving the counts unknown.
           (overlook-project--git
            top `("diff" "HEAD" "--numstat" "-M" "-z" ,@paths)
            (lambda (numstat)
              (let ((old (cdr (gethash dir overlook-project--status)))
                    (new (overlook-project--parse status numstat)))
                (puthash dir (cons (float-time) new) overlook-project--status)
                (overlook-project--done dir)
                (unless (equal old new) (overlook-refresh)))))))))))

(defun overlook-project--done (dir)
  "Note that DIR's status is read, and start reading the next stale repo shown."
  (remhash dir overlook-project--reading)
  (when (gethash dir overlook-project--again)
    (remhash dir overlook-project--again)
    (setcar (gethash dir overlook-project--status) 0))
  (overlook-project--tick))

(defun overlook-project--status (dir)
  "DIR's last known (BRANCH . FILES), reading it again when stale."
  (let ((entry (gethash dir overlook-project--status)))
    (when (or (null entry)
              (> (- (float-time) (car entry)) overlook-project-status-interval))
      (overlook-project--read dir))
    (cdr entry)))

(defun overlook-project-open (dir)
  "Show the diff since the last commit in DIR, or its status when clean.
A folder inside a repo shows only its own changes.  Uses Magit, or VC
without it."
  (let ((default-directory (or (overlook-project--top dir) dir))
        (prefix (overlook-project--prefix dir))
        (changed (cdr (overlook-project--status dir))))
    (cond ((and changed (fboundp 'magit-diff-working-tree))
           (magit-diff-working-tree "HEAD" nil (and prefix (list prefix))))
          ((fboundp 'magit-status-setup-buffer) (magit-status-setup-buffer dir))
          (changed (vc-root-diff nil))
          (t (vc-dir dir)))))

(defun overlook-project--new-p (code)
  "Non-nil when status CODE is of a file not in the last commit.
That is an untracked or added one, intent-to-add included."
  (or (equal code "??") (string-search "A" code)))

(defun overlook-project-open-file (dir file)
  "Show the diff of FILE of repo DIR since the last commit.
FILE is an entry of DIR's status; a renamed one is shown with its old
path, and a new one visited instead.  Uses Magit, or VC without it."
  (pcase-let ((default-directory (or (overlook-project--top dir) dir))
              (`(,path ,code ,_ ,_ ,from) file))
    (cond ((and (not from) (overlook-project--new-p code) (not (string-search "D" code)))
           (find-file path))
          ((fboundp 'magit-diff-working-tree)
           (magit-diff-working-tree "HEAD" nil (if from (list from path) (list path))))
          (t (vc-version-diff (mapcar #'expand-file-name (if from (list from path) (list path)))
                              "HEAD" nil)))))

(defun overlook-project-file-diff (dir file)
  "Unified diff of FILE of repo DIR since the last commit, as text.
FILE is an entry of DIR's status; an untracked one shows as all added."
  (pcase-let ((default-directory (or (overlook-project--top dir) dir))
              (`(,path ,code ,_ ,_ ,from) file))
    (with-temp-buffer
      (apply #'process-file (or (bound-and-true-p vc-git-program) "git") nil t nil
             "-c" "core.quotePath=false"
             (if (equal code "??")
                 (list "diff" "--no-index" "--" "/dev/null" path)
               `("diff" "HEAD" "-M" "--" ,@(and from (list from)) ,path)))
      (buffer-string))))

(defun overlook-project--counts (added removed)
  "\" +ADDED −REMOVED\" in diff colors, leaving out a zero."
  (cl-flet ((count (n sign face)
              (if (and n (> n 0))
                  (propertize (format " %s%d" sign n)
                              'face `(:foreground ,(face-foreground face nil t)))
                "")))
    (concat (count added "+" 'diff-indicator-added)
            (count removed "−" 'diff-indicator-removed))))

(defun overlook-project--total (files)
  "Line counts of FILES added up, as (ADDED . REMOVED)."
  (cons (apply #'+ (mapcar (lambda (file) (or (nth 2 file) 0)) files))
        (apply #'+ (mapcar (lambda (file) (or (nth 3 file) 0)) files))))

(defun overlook-project--old-path (from path)
  "The part of FROM, a renamed file's old path, that differs from its new PATH.
Their common folders are left out, and the name when only folders changed."
  (let ((old (split-string from "/")) (new (split-string path "/")))
    (while (and (cdr old) (cdr new) (equal (car old) (car new)))
      (setq old (cdr old) new (cdr new)))
    (if (and (cdr old) (equal (car (last old)) (car (last new))))
      (concat (string-join (butlast old) "/") "/")
      (string-join old "/"))))

(defun overlook-project--file-label (file &optional prefix)
  "FILE's name, its line counts or state, then its directory below PREFIX."
  (pcase-let* ((`(,path ,code ,added ,removed ,from) file)
               (dir (file-name-directory (if prefix (file-relative-name path prefix) path)))
               (state (cond (from (concat " ← " (overlook-project--old-path from path)))
                            ((string-search "D" code) " deleted")
                            ((overlook-project--new-p code) " new"))))
    (concat (propertize (file-name-nondirectory path) 'face 'overlook-project-file)
            (overlook-project--counts added removed)
            (if state (propertize state 'face 'shadow) "")
            (if dir (propertize (concat " " dir) 'face 'shadow) ""))))

(defun overlook-project--file-row (dir file perspective)
  "The row of FILE changed in repo DIR, under its row in PERSPECTIVE."
  (overlook-row :id (list 'repo-file dir (car file))
                :content (overlook-project--file-label file (overlook-project--prefix dir))
                :action (lambda ()
                          (overlook-show-elsewhere
                           perspective (lambda () (overlook-project-open-file dir file))))
                :help (car file)
                :wrap ""
                :diff (lambda () (overlook-project-file-diff dir file))))

(defun overlook-project--worktrees (root)
  "Worktrees courier made in project ROOT, each as (DIR . NAME)."
  (when (fboundp 'overlook-courier-worktree-list)
    (mapcar (lambda (name) (cons (overlook-courier-worktree-path root name) name))
            (overlook-courier-worktree-list root))))

(defun overlook-project--worktree-dirs (perspective)
  "Folders of the worktrees of PERSPECTIVE's project."
  (when-let* ((root (overlook-perspective-root perspective)))
    (mapcar #'car (overlook-project--worktrees root))))

(defun overlook-project--label (dir)
  "The name repo DIR shows by."
  (file-name-nondirectory (directory-file-name dir)))

(defun overlook-project--changes (dirs)
  "Line counts of the changes in repos DIRS added up, as (ADDED . REMOVED)."
  (overlook-project--total
   (mapcan (lambda (dir) (copy-sequence (cdr (overlook-project--status dir)))) dirs)))

(defun overlook-project--heading (label total item action children)
  "A row of LABEL after ⎇ with TOTAL's line counts.
ITEM is its id, ACTION what RET does on it, and CHILDREN the rows under
it, indented."
  (overlook-row :id item
                :content (list (overlook-glyph-cell (propertize "⎇" 'face 'overlook-project-repo))
                               label
                               (overlook-project--counts (car total) (cdr total)))
                :help (cdr item)
                :action action
                :children children
                :nest t))

(defun overlook-project--row (dir perspective &optional width name before marks)
  "The row of repo DIR in PERSPECTIVE, its NAME padded to WIDTH.
BEFORE are rows under it ahead of the changed files.  MARKS go after
its branch.  A branch named as the row is left out."
  (pcase-let* ((`(,branch . ,files) (overlook-project--status dir))
               (name (or name (overlook-project--label dir)))
               (branch (and (not (equal branch name)) branch)))
    (overlook-project--heading
     (concat (propertize (concat (if (and branch width) (string-pad name width) name)
                                 (if branch (concat "  " branch) ""))
                         'face 'overlook-project-repo)
             marks)
     (overlook-project--total files)
     (cons 'repo dir)
     (lambda () (overlook-show-elsewhere perspective (lambda () (overlook-project-open dir))))
     (append before
             (mapcar (lambda (file) (overlook-project--file-row dir file perspective))
                     files)))))

(defun overlook-project--group-row (tree name perspective dirs before &optional marks)
  "The row of folder TREE of PERSPECTIVE by NAME, holding repos DIRS.
Under it go the rows BEFORE, then a row of each of DIRS, its line counts
their total; MARKS is as for `overlook-project--repo-rows'."
  (overlook-project--heading
   (propertize name 'face 'overlook-project-repo)
   (overlook-project--changes dirs)
   (cons 'worktree tree)
   (lambda () (overlook-show-elsewhere perspective (lambda () (dired tree))))
   (append before (overlook-project--repo-rows dirs perspective marks))))

(defun overlook-project--folders (perspective)
  "Folders of PERSPECTIVE lying inside a larger repo."
  (seq-filter #'overlook-project--prefix
              (mapcar (lambda (dir) (file-name-as-directory (expand-file-name dir)))
                      (funcall overlook-project-folders perspective))))

(defun overlook-project--heading-mark (perspective)
  "\"*\" when a folder of PERSPECTIVE inside a larger repo has changes."
  (when (and (eq overlook-project-folder-display 'mark)
             (seq-some (lambda (dir) (cdr (overlook-project--status dir)))
                       (overlook-project--folders perspective)))
    "*"))

(defun overlook-project--repo-rows (dirs perspective &optional marks)
  "A row of each repo or folder in DIRS in PERSPECTIVE, names aligned.
MARKS, a function of a DIR, returns the marks after its branch."
  (let ((width (apply #'max 0 (mapcar (lambda (dir) (string-width (overlook-project--label dir)))
                                      dirs))))
    (mapcar (lambda (dir)
              (overlook-project--row dir perspective width nil nil (and marks (funcall marks dir))))
            dirs)))

(defun overlook-project--base (checkout tree root)
  "Branch of the main checkout that CHECKOUT, in worktree TREE of ROOT, came from."
  (car (overlook-project--status
        (file-name-as-directory (expand-file-name (file-relative-name checkout tree) root)))))

(defun overlook-project--divergence (checkout base)
  "(AHEAD . BEHIND) of CHECKOUT against branch BASE as last read, or nil.
Reads it again in the background when stale, redrawing when it changed."
  (let ((entry (gethash checkout overlook-project--diverged)))
    (when (and base
               (or (null entry)
                   (not (equal (cadr entry) base))
                   (> (- (float-time) (car entry)) overlook-project-status-interval)))
      (puthash checkout (cons (float-time) (cdr entry)) overlook-project--diverged)
      (overlook-project--git
       checkout (list "rev-list" "--left-right" "--count" (concat "HEAD..." base))
       (lambda (output)
         (when-let* ((counts (and output (split-string output)))
                     (new (cons base (cons (string-to-number (car counts))
                                           (string-to-number (cadr counts)))))
                     ((not (equal new (cdr (gethash checkout overlook-project--diverged))))))
           (puthash checkout (cons (float-time) new) overlook-project--diverged)
           (overlook-refresh)))))
    (and entry (equal (cadr entry) base) (cddr entry))))

(defun overlook-project--divergence-marks (divergence)
  "Marks telling DIVERGENCE, an (AHEAD . BEHIND), or nil when unknown."
  (pcase divergence
    (`(0 . 0) nil)
    (`(0 . ,_) (propertize " merged" 'face 'shadow))
    (`(,ahead . ,behind)
     (propertize (concat (format " ↑%d" ahead) (if (> behind 0) (format " ↓%d" behind) ""))
                 'face 'shadow))))

(defun overlook-project--worktree-row (tree name root perspective)
  "The row of worktree TREE of ROOT in PERSPECTIVE, by NAME.
Under it go the rows of `overlook-worktree-functions', then its repo's
changed files, or a row of each of its repos when it has several.  Each
repo shows its commits ahead of and behind the main checkout's branch.
The row is dimmed while nothing lies in TREE, nothing is changed and no
commit is unmerged."
  (let* ((repos (overlook-courier-worktree-repos tree))
         (divergences (mapcar (lambda (dir)
                                (cons dir (overlook-project--divergence
                                           dir (overlook-project--base dir tree root))))
                              repos))
         (marks (lambda (dir)
                  (overlook-project--divergence-marks (alist-get dir divergences nil nil #'equal))))
         (before (overlook-rows 'overlook-worktree-functions perspective tree))
         (row (if (equal repos (list tree))
                  (overlook-project--row tree perspective nil name before (funcall marks tree))
                (overlook-project--group-row tree name perspective repos before marks))))
    (dolist (dir repos)
      (cl-pushnew dir overlook-project--shown :test #'equal))
    (setf (overlook-row-dim row)
          (and (seq-every-p (lambda (divergence) (eql (cadr divergence) 0)) divergences)
               (not (seq-some (lambda (dir) (cdr (overlook-project--status dir))) repos))
               (null (overlook-folder-contents tree))))
    (when (and (fboundp 'overlook-courier-worktree-at) (overlook-courier-worktree-at tree))
      (setf (overlook-row-commands row)
            (list (list :name "delete" :label "Delete"
                        :confirm (lambda () (overlook-project--delete-question tree))
                        :run (lambda () (overlook-project--delete-worktree tree) nil)))))
    row))

(defun overlook-project--main-row (root perspective)
  "The row of PERSPECTIVE's main checkout ROOT.
Under it go the rows of `overlook-worktree-functions' for no worktree."
  (let ((before (overlook-rows 'overlook-worktree-functions perspective nil)))
    (if (equal (overlook-project--top root) root)
        (overlook-project--row root perspective nil nil before)
      (overlook-project--heading
       (propertize (overlook-project--label root) 'face 'overlook-project-repo)
       (overlook-project--changes (overlook-project--changed perspective))
       (cons 'worktree root)
       (lambda () (overlook-show-elsewhere perspective (lambda () (dired root))))
       before))))

(defun overlook-project--checkout-rows (perspective)
  "Rows of PERSPECTIVE's main checkout and worktrees.
Neither shows while the project has no worktrees."
  (when-let* ((root (overlook-perspective-root perspective))
              (trees (overlook-worktrees perspective)))
    (cons (overlook-project--main-row root perspective)
          (mapcar (lambda (tree)
                    (overlook-project--worktree-row tree (overlook-project--label tree)
                                                    root perspective))
                  trees))))

(defun overlook-project--changed (perspective)
  "The repos and folders of PERSPECTIVE's project with changes to show."
  (let* ((root (overlook-perspective-root perspective))
         (dirs (and root (overlook-project-repos root)))
         (folders (overlook-project--folders perspective)))
    (dolist (dir (funcall overlook-project-folders perspective))
      (let ((dir (file-name-as-directory (expand-file-name dir))))
        (when (and (overlook-project--top dir) (not (member dir dirs)))
          (setq dirs (append dirs (list dir))))))
    ;; A clean one stays off the dashboard but is still read on each tick.
    (dolist (dir dirs)
      (cl-pushnew dir overlook-project--shown :test #'equal))
    (seq-filter (lambda (dir)
                  (and (cdr (overlook-project--status dir))
                       (not (and (eq overlook-project-folder-display 'mark)
                                 (member dir folders)))))
                dirs)))

(defun overlook-project--changed-rows (perspective dir)
  "Rows of the changed repos and folders of PERSPECTIVE's project, for DIR nil.
Under a main checkout that is a repo, its own files are on its row."
  (unless dir
    (let ((root (overlook-perspective-root perspective)))
      (overlook-project--repo-rows
       (if (and (overlook-worktrees perspective) (equal (overlook-project--top root) root))
           (remove root (overlook-project--changed perspective))
         (overlook-project--changed perspective))
       perspective))))

(defun overlook-project--uncommitted (tree)
  "The repos of worktree TREE with uncommitted changes."
  (seq-filter (lambda (dir)
                (not (string-empty-p
                      (or (ignore-errors (overlook-courier-worktree--git dir "status" "--porcelain")) ""))))
              (overlook-courier-worktree-repos tree)))

(defun overlook-project--delete-question (tree)
  "The question confirming that worktree TREE, and what lies in it, is to go."
  (pcase-let* ((`(,_ . ,name) (or (overlook-courier-worktree-at tree)
                                  (user-error "Not a worktree: %s" tree)))
               (contents (overlook-folder-contents tree))
               (changed (overlook-project--uncommitted tree))
               ;; From the last read; reading again would outlive the worktree.
               (unmerged (seq-some (lambda (dir)
                                     (> (or (nth 2 (gethash dir overlook-project--diverged)) 0) 0))
                                   (overlook-courier-worktree-repos tree))))
    (concat (format "Delete worktree %s" name)
            (if contents (format " and %s" (mapconcat #'car contents ", ")) "")
            (if changed
                (format "; uncommitted changes in %s are lost"
                        (mapconcat #'overlook-project--label changed ", "))
              "")
            (if unmerged "; its branch keeps commits not merged" "")
            "? ")))

(defun overlook-project--delete-worktree (tree)
  "Delete worktree TREE with what lies in it, such as its agents.
Its branch stays."
  (pcase-let ((`(,root . ,name) (or (overlook-courier-worktree-at tree)
                                    (user-error "Not a worktree: %s" tree))))
    (pcase-dolist (`(,_ . ,delete) (overlook-folder-contents tree)) (funcall delete))
    (let ((kill-buffer-query-functions nil))
      (dolist (buffer (buffer-list))
        (when (file-in-directory-p (buffer-local-value 'default-directory buffer) tree)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))
    (overlook-courier-worktree-remove root name t)
    (overlook-refresh)
    (message "Deleted worktree %s" name)))

(defun overlook-project-delete-worktree (tree)
  "Delete worktree TREE with what lies in it, such as its agents, once confirmed.
Its branch stays."
  (when (yes-or-no-p (overlook-project--delete-question tree))
    (overlook-project--delete-worktree tree)))

(defun overlook-project--delete (item)
  "Delete the worktree ITEM stands for, if it is one."
  (pcase item
    (`(,(or 'repo 'worktree) . ,dir)
     (when (and (fboundp 'overlook-courier-worktree-at) (overlook-courier-worktree-at dir))
       (overlook-project-delete-worktree dir)
       t))))

(defun overlook-project--forget ()
  "Start collecting the repos drawn by this render."
  (setq overlook-project--shown nil))

(defun overlook-project--tick ()
  "Read the shown repos' statuses again when stale; a change redraws."
  (mapc #'overlook-project--status overlook-project--shown))

(defun overlook-project--touch (dir)
  "Read the shown repos and folders holding DIR, or inside its repo, soon."
  (when (overlook-live-p)
    (push (file-name-as-directory (expand-file-name dir)) overlook-project--touched)
    (unless (timerp overlook-project--touch-timer)
      (setq overlook-project--touch-timer
            (run-with-timer overlook-project-touch-delay nil #'overlook-project--read-touched)))))

(defun overlook-project--read-touched ()
  "Mark the shown repos and folders touched lately stale, and read them."
  (let ((touched (delete-dups overlook-project--touched)))
    (setq overlook-project--touched nil
          overlook-project--touch-timer nil)
    (dolist (shown overlook-project--shown)
      (when (seq-some
             (lambda (dir)
               (or (string-prefix-p shown dir)
                   ;; A separate repo nested in DIR's is left alone.
                   (and (string-prefix-p dir shown)
                        (not (file-exists-p (expand-file-name ".git" shown))))))
             touched)
        (if (gethash shown overlook-project--reading)
            (puthash shown t overlook-project--again)
          (when-let* ((entry (gethash shown overlook-project--status)))
            (setcar entry 0)))))
    (overlook-project--tick)))

(defun overlook-project--saved ()
  "Read the repo of the file just saved soon."
  (when buffer-file-name
    (overlook-project--touch (file-name-directory buffer-file-name))))

(defun overlook-project--magit-refreshed ()
  "Read the repo Magit just refreshed soon."
  (overlook-project--touch default-directory))

;;;###autoload
(define-minor-mode overlook-project-mode
  "List the repos of each perspective's project on the dashboard."
  :global t
  :group 'overlook
  (overlook-toggle-hooks
   overlook-project-mode
   '((overlook-perspective-functions overlook-project--checkout-rows -50)
     (overlook-worktrees-functions overlook-project--worktree-dirs)
     (overlook-worktree-functions overlook-project--changed-rows 50)
     (overlook-heading-mark-functions overlook-project--heading-mark)
     (overlook-delete-functions overlook-project--delete)
     (overlook-before-render-hook overlook-project--forget)
     (overlook-tick-hook overlook-project--tick)
     (after-save-hook overlook-project--saved)))
  ;; Adding to the hook before Magit defines it would drop Magit's own functions.
  (if overlook-project-mode
      (with-eval-after-load 'magit-mode
        (when overlook-project-mode
          (add-hook 'magit-post-refresh-hook #'overlook-project--magit-refreshed)))
    (remove-hook 'magit-post-refresh-hook #'overlook-project--magit-refreshed))
  (overlook-refresh))

(provide 'overlook-project)
;;; overlook-project.el ends here
