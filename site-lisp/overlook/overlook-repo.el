;;; overlook-repo.el --- Changed repos of each project -*- lexical-binding: t; -*-

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

;; Lists the changed Git repos of each project under its
;; heading: the project root when it is a repo itself, and the repos
;; directly inside it, so a project made of several clones shows each.  A
;; clean repo stays hidden until it changes.  A repo's row shows
;; its branch and the lines changed since its last commit, and under it,
;; indented, the changed files, read asynchronously and at most every
;; `overlook-repo-status-interval' seconds, and soon after a save in
;; it or a Magit refresh of it.  RET on a repo shows its
;; diff in Magit, or its status when clean; RET on a file shows its diff
;; since the last commit in Magit.  Without Magit, VC does both.
;;
;; `overlook-repo-folders' adds folders lying inside a larger repo, such
;; as a project's notes kept in a shared one; such a folder's row lists
;; only the changes under it.  With `overlook-repo-folder-display' set
;; to `mark', such a folder gets no row; a "*" after the project's
;; heading tells it has changes.
;;
;; While the project has courier's worktrees, its rows are grouped by
;; checkout, each shown while clean too: first the main checkout, holding
;; the agents in no worktree and then the changed repos, then each
;; worktree, holding the agents working in it and then its changed files,
;; or for a worktree of several repos, a row of each.

;;; Code:

(require 'overlook-data)
(require 'overlook)
(require 'diff-mode)
(require 'overlook-markers)
(require 'overlook-worktree)

(declare-function magit-status-setup-buffer "magit-status")
(declare-function magit-diff-working-tree "magit-diff")
(declare-function vc-version-diff "vc")

(defcustom overlook-repo-status-interval 30
  "Seconds before a repo's branch and changes are read again."
  :type 'number
  :group 'overlook)

(defcustom overlook-repo-parallel-reads 2
  "Most repos whose status is read at once; the others wait their turn."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-repo-count-limit 1000000
  "Most bytes of an untracked file whose lines are counted."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-repo-touch-delay 0.5
  "Seconds a save or Magit refresh waits before its repos are read again.
The saves and refreshes within that time share one read."
  :type 'number
  :group 'overlook)

;;;###autoload
(defcustom overlook-repo-folders #'overlook-repo-root-folder
  "Function of a project NAME returning folders to list with its repos.
A folder inside a larger repo lists that repo's changes under it; a
folder that is a repo itself is listed as one."
  :type 'function
  :group 'overlook)

(defcustom overlook-repo-ignored nil
  "Repos left off the dashboard, such as a data clone inside a project.
They do not keep their project from closing either."
  :type '(repeat directory)
  :group 'overlook)

(defcustom overlook-repo-folder-display 'rows
  "How changes of a folder inside a larger repo show.
`rows' lists them under the project like a repo's; `mark' puts a
\"*\" after the project's heading instead."
  :type '(choice (const rows) (const mark))
  :group 'overlook)

(defface overlook-repo-name
  '((t :inherit shadow))
  "Face of a repo's row, dimmed so agents stand out."
  :group 'overlook)

(defface overlook-repo-file
  '((t :inherit overlook-repo-name))
  "Face of a changed file's name under its repo."
  :group 'overlook)

(defvar overlook-repo--status (make-hash-table :test #'equal)
  "Repo or folder directory to (TIME BRANCH . FILES), as last read.
Each of FILES is (PATH CODE ADDED REMOVED FROM): PATH relative to the
repo, CODE its two-letter `git status' code, line counts since the last
commit, nil when unknown, and for a renamed file the path it had there.
A rename's CODE has R in place of the A of its new path.")

(defvar overlook-repo--reading (make-hash-table :test #'equal)
  "Repo directories whose status is being read.")

(defvar overlook-repo--again (make-hash-table :test #'equal)
  "Repos touched while being read, to read again once that read is done.")

(defvar overlook-repo--diverged (make-hash-table :test #'equal)
  "Worktree checkout to (TIME BASE AHEAD . BEHIND), as last read.
AHEAD counts its commits not on branch BASE, BEHIND those of BASE not on it.")

(defvar overlook-repo--bases (make-hash-table :test #'equal)
  "Worktree checkout to (BASE), BASE the one recorded for its branch or nil.")

(defvar overlook-repo--touched nil
  "Directories saved in or refreshed by Magit since the last touch read.")

(defvar overlook-repo--touch-timer nil)

(defvar overlook-repo--shown nil
  "Repos and folders of the projects as last drawn, shown or clean.")

(defun overlook-repo--numstat (numstat)
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

(defun overlook-repo--parse (status &optional numstat)
  "Branch and changed files from STATUS and NUMSTAT outputs.
STATUS is from `git status --porcelain --branch --no-renames -uall -z', NUMSTAT
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
         (counts (make-hash-table :test #'equal))
         (from (make-hash-table :test #'equal)))
    (dolist (count (overlook-repo--numstat numstat))
      (puthash (car count) (cdr count) counts)
      (when (nth 3 count)
        (puthash (nth 3 count) t from)))
    (cons branch
          (delq nil
                (mapcar (lambda (entry)
                          (let* ((path (substring entry 3))
                                 (code (substring entry 0 2))
                                 (count (gethash path counts)))
                            (cond ((gethash path from) nil)
                                  ((nth 2 count)
                                   (cons path (cons (string-replace "A" "R" code) count)))
                                  (t (cons path (cons code count))))))
                        (cdr entries))))))

(defun overlook-repo--file-lines (file)
  "Lines in FILE as git counts them, or nil for a binary or big one."
  (when-let* ((attributes (file-attributes file))
              ((eq (file-attribute-type attributes) nil))
              ((<= (file-attribute-size attributes) overlook-repo-count-limit)))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (goto-char (point-min))
      (unless (search-forward "\0" nil t)
        (count-lines (point-min) (point-max))))))

(defun overlook-repo--count-new (top files)
  "FILES of repo TOP, a new one git gave no line counts for counted as all added."
  (mapcar (lambda (file)
            (pcase-let ((`(,path ,code ,added) file))
              (if-let* (((not added))
                        ((overlook-repo--new-p code))
                        ((not (string-search "D" code)))
                        (lines (overlook-repo--file-lines (expand-file-name path top))))
                  (list path code lines 0)
                file)))
          files))

(defun overlook-repo-root-folder (name)
  "Project NAME's root."
  (when-let* ((root (overlook-project-root name)))
    (list root)))

(defun overlook-repo--top (dir)
  "Top of the repo holding DIR, or nil."
  (when-let* ((top (locate-dominating-file dir ".git")))
    (file-name-as-directory (expand-file-name top))))

(defun overlook-repo--prefix (dir)
  "DIR relative to the top of its repo, or nil when DIR is the top."
  (when-let* ((top (overlook-repo--top dir))
              ((not (equal top dir))))
    (file-relative-name dir top)))

(defun overlook-repo--git (dir args then)
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

(defun overlook-repo--read (dir)
  "Read DIR's status in the background, redrawing when it changed.
Does nothing while `overlook-repo-parallel-reads' repos are being read."
  (unless (or (not (file-directory-p dir))
              (gethash dir overlook-repo--reading)
              (>= (hash-table-count overlook-repo--reading) overlook-repo-parallel-reads))
    (puthash dir t overlook-repo--reading)
    (let ((top (or (overlook-repo--top dir) dir))
          (paths (when-let* ((prefix (overlook-repo--prefix dir)))
                   (list "--" (concat ":(literal)" prefix)))))
      (overlook-repo--git
       top `("status" "--porcelain" "--branch" "--no-renames" "-uall" "-z" ,@paths)
       (lambda (status)
         (if (null status)
             (progn
               (puthash dir (cons (float-time) (cdr (gethash dir overlook-repo--status)))
                        overlook-repo--status)
               (overlook-repo--done dir))
           ;; Fails before the first commit, leaving the counts unknown.
           (overlook-repo--git
            top `("diff" "HEAD" "--numstat" "-M" "-z" ,@paths)
            (lambda (numstat)
              (let ((old (cdr (gethash dir overlook-repo--status)))
                    (new (let ((parsed (overlook-repo--parse status numstat)))
                           (cons (car parsed)
                                 (overlook-repo--count-new top (cdr parsed))))))
                (puthash dir (cons (float-time) new) overlook-repo--status)
                (overlook-repo--done dir)
                (unless (equal old new) (overlook-refresh)))))))))))

(defun overlook-repo--done (dir)
  "Note that DIR's status is read, and start reading the next stale repo shown."
  (remhash dir overlook-repo--reading)
  (when (gethash dir overlook-repo--again)
    (remhash dir overlook-repo--again)
    (setcar (gethash dir overlook-repo--status) 0))
  (overlook-repo--tick))

(defun overlook-repo--status (dir)
  "DIR's last known (BRANCH . FILES), reading it again when stale."
  (let ((entry (gethash dir overlook-repo--status)))
    (when (or (null entry)
              (> (- (float-time) (car entry)) overlook-repo-status-interval))
      (overlook-repo--read dir))
    (cdr entry)))

(defun overlook-repo-open (dir)
  "Show the diff since the last commit in DIR, or its status when clean.
A folder inside a repo shows only its own changes.  Uses Magit, or VC
without it."
  (let ((default-directory (or (overlook-repo--top dir) dir))
        (prefix (overlook-repo--prefix dir))
        (changed (cdr (overlook-repo--status dir))))
    (cond ((and changed (fboundp 'magit-diff-working-tree))
           (magit-diff-working-tree "HEAD" nil (and prefix (list prefix))))
          ((fboundp 'magit-status-setup-buffer) (magit-status-setup-buffer dir))
          (changed (vc-root-diff nil))
          (t (vc-dir dir)))))

(defun overlook-repo--new-p (code)
  "Non-nil when status CODE is of a file not in the last commit.
That is an untracked or added one, intent-to-add included."
  (or (equal code "??") (string-search "A" code)))

(defun overlook-repo-open-file (dir file)
  "Show the diff of FILE of repo DIR since the last commit.
FILE is an entry of DIR's status; a renamed one is shown with its old
path, and a new one visited instead.  Uses Magit, or VC without it."
  (pcase-let ((default-directory (or (overlook-repo--top dir) dir))
              (`(,path ,code ,_ ,_ ,from) file))
    (cond ((and (not from) (overlook-repo--new-p code) (not (string-search "D" code)))
           (find-file path))
          ((fboundp 'magit-diff-working-tree)
           (magit-diff-working-tree "HEAD" nil (if from (list from path) (list path))))
          (t (vc-version-diff (mapcar #'expand-file-name (if from (list from path) (list path)))
                              "HEAD" nil)))))

(defun overlook-repo-file-diff (dir file)
  "Unified diff of FILE of repo DIR since the last commit, as text.
FILE is an entry of DIR's status; an untracked one shows as all added."
  (pcase-let ((default-directory (or (overlook-repo--top dir) dir))
              (`(,path ,code ,_ ,_ ,from) file))
    (with-temp-buffer
      (apply #'process-file (or (bound-and-true-p vc-git-program) "git") nil t nil
             "-c" "core.quotePath=false"
             (if (equal code "??")
                 (list "diff" "--no-index" "--" "/dev/null" path)
               `("diff" "HEAD" "-M" "--" ,@(and from (list from)) ,path)))
      (buffer-string))))

(defun overlook-repo--counts (added removed)
  "\" +ADDED −REMOVED\" in diff colors, leaving out a zero."
  (cl-flet ((count (n sign face)
              (if (and n (> n 0))
                  (propertize (format " %s%d" sign n)
                              'face `(:foreground ,(face-foreground face nil t)))
                "")))
    (concat (count added "+" 'diff-indicator-added)
            (count removed "−" 'diff-indicator-removed))))

(defun overlook-repo--total (files)
  "Line counts of FILES added up, as (ADDED . REMOVED)."
  (cons (apply #'+ (mapcar (lambda (file) (or (nth 2 file) 0)) files))
        (apply #'+ (mapcar (lambda (file) (or (nth 3 file) 0)) files))))

(defun overlook-repo--old-path (from path)
  "The part of FROM, a renamed file's old path, that differs from its new PATH.
Their common folders are left out, and the name when only folders changed."
  (let ((old (split-string from "/")) (new (split-string path "/")))
    (while (and (cdr old) (cdr new) (equal (car old) (car new)))
      (setq old (cdr old) new (cdr new)))
    (if (and (cdr old) (equal (car (last old)) (car (last new))))
      (concat (string-join (butlast old) "/") "/")
      (string-join old "/"))))

(defun overlook-repo--file-dir (file prefix)
  "The folder of FILE's path below PREFIX, or nil at PREFIX itself."
  (let ((path (car file)))
    (file-name-directory (if prefix (file-relative-name path prefix) path))))

(defun overlook-repo--shared-folders (dir other)
  "Length of the leading folders folder DIR shares with folder OTHER."
  (let ((shared 0) (i 0))
    (while (and (< i (min (length dir) (length other)))
                (eq (aref dir i) (aref other i)))
      (when (eq (aref dir i) ?/) (setq shared (1+ i)))
      (setq i (1+ i)))
    shared))

(defun overlook-repo--file-label (file &optional prefix shared)
  "FILE's folder below PREFIX, its name, then its line counts or state.
Abbreviate every folder to its initial.
The first SHARED characters of the original folder show as blanks."
  (pcase-let* ((`(,path ,code ,added ,removed ,from) file)
               (dir (or (overlook-repo--file-dir file prefix) ""))
               (shared (or shared 0))
               (folders (split-string dir "/" t))
               (offset 0)
               (label ""))
    (dolist (folder folders)
      (let ((part (substring folder 0 1)))
        (setq label
              (concat label
                      (if (< offset shared)
                          (make-string (1+ (string-width part)) ?\s)
                        (concat part "/")))))
      (setq offset (+ offset (length folder) 1)))
    (let ((state (cond (from (concat " ← " (overlook-repo--old-path from path)))
                      ((string-search "D" code) " deleted")
                      ((overlook-repo--new-p code) " new"))))
      (concat (propertize label 'face 'shadow)
              (propertize (file-name-nondirectory path) 'face 'overlook-repo-file)
              (overlook-repo--counts added removed)
              (if state (propertize state 'face 'shadow) "")))))

(defun overlook-repo--file-row (dir file project &optional shared)
  "The row of FILE changed in repo DIR, under its row in PROJECT.
SHARED is as for `overlook-repo--file-label'."
  (overlook-row :id (list 'repo-file dir (car file))
                :content (overlook-repo--file-label file (overlook-repo--prefix dir) shared)
                :action (lambda ()
                          (overlook-show-elsewhere
                           project (lambda () (overlook-repo-open-file dir file))))
                :help (car file)
                :wrap ""
                :diff (lambda () (overlook-repo-file-diff dir file))))

(defun overlook-repo--file-rows (dir files project)
  "Rows of FILES changed in repo DIR, under its row in PROJECT.
They go grouped by folder, each blanking the leading folders it shares
with the row above."
  (let* ((prefix (overlook-repo--prefix dir))
         (folder (lambda (file) (or (overlook-repo--file-dir file prefix) "")))
         (last ""))
    (mapcar (lambda (file)
              (let ((this (funcall folder file)))
                (prog1 (overlook-repo--file-row
                        dir file project (overlook-repo--shared-folders this last))
                  (setq last this))))
            (sort (copy-sequence files)
                  (lambda (a b) (string< (funcall folder a) (funcall folder b)))))))

(defun overlook-repo--worktrees (root)
  "Worktrees in project ROOT, each as (DIR . NAME)."
  (mapcar (lambda (name) (cons (overlook-worktree-path root name) name))
          (overlook-worktree-list root)))

(defun overlook-repo--worktree-dirs (project)
  "Folders of the worktrees of PROJECT's root."
  (when-let* ((root (overlook-project-root project)))
    (mapcar #'car (overlook-repo--worktrees root))))

(defun overlook-repo--label (dir)
  "The name repo DIR shows by."
  (file-name-nondirectory (directory-file-name dir)))

(defun overlook-repo--changes (dirs)
  "Line counts of the changes in repos DIRS added up, as (ADDED . REMOVED)."
  (overlook-repo--total
   (mapcan (lambda (dir) (copy-sequence (cdr (overlook-repo--status dir)))) dirs)))

(defun overlook-repo--heading (label total item action children)
  "A row of LABEL after ⎇ with TOTAL's line counts.
ITEM is its id, ACTION what RET does on it, and CHILDREN the rows under
it, indented."
  (overlook-row :id item
                :content (list (overlook-glyph-cell (propertize "⎇" 'face 'overlook-repo-name))
                               label
                               (overlook-repo--counts (car total) (cdr total)))
                :help (cdr item)
                :action action
                :children children
                :nest t))

(defun overlook-repo--row (dir project &optional width name before marks)
  "The row of repo DIR in PROJECT, its NAME padded to WIDTH.
BEFORE are rows under it ahead of the changed files.  MARKS go after
its branch.  A branch named as the row is left out."
  (pcase-let* ((`(,branch . ,files) (overlook-repo--status dir))
               (data (overlook-repo-data (cons 'repo dir)))
               (name (or name (plist-get data :title)))
               (branch (and (not (equal branch name)) branch)))
    (overlook-repo--heading
     (concat (propertize (concat (if (and branch width) (string-pad name width) name)
                                 (if branch (concat "  " branch) ""))
                         'face 'overlook-repo-name)
             marks)
     (cons (plist-get data :added) (plist-get data :removed))
     (cons 'repo dir)
     (lambda () (overlook-show-elsewhere project (lambda () (overlook-repo-open dir))))
     (append before (overlook-repo--file-rows dir files project)))))

(defun overlook-repo--group-row (tree name project dirs before &optional marks)
  "The row of folder TREE of PROJECT by NAME, holding repos DIRS.
Under it go the rows BEFORE, then a row of each of DIRS, its line counts
their total; MARKS is as for `overlook-repo--repo-rows'."
  (overlook-repo--heading
   (propertize name 'face 'overlook-repo-name)
   (overlook-repo--changes dirs)
   (cons 'worktree tree)
   (lambda () (overlook-show-elsewhere project (lambda () (dired tree))))
   (append before (overlook-repo--repo-rows dirs project marks))))

(defun overlook-repo--folders (project)
  "Folders of PROJECT lying inside a larger repo."
  (seq-filter #'overlook-repo--prefix
              (mapcar (lambda (dir) (file-name-as-directory (expand-file-name dir)))
                      (funcall overlook-repo-folders project))))

(defun overlook-repo--heading-mark (project)
  "\"*\" when a folder of PROJECT inside a larger repo has changes."
  (when (and (eq overlook-repo-folder-display 'mark)
             (seq-some (lambda (dir) (cdr (overlook-repo--status dir)))
                       (overlook-repo--folders project)))
    "*"))

(defun overlook-repo--repo-rows (dirs project &optional marks)
  "A row of each repo or folder in DIRS in PROJECT, names aligned.
MARKS, a function of a DIR, returns the marks after its branch."
  (let ((width (apply #'max 0 (mapcar (lambda (dir) (string-width (overlook-repo--label dir)))
                                      dirs))))
    (mapcar (lambda (dir)
              (overlook-repo--row dir project width nil nil (and marks (funcall marks dir))))
            dirs)))

(defun overlook-repo--base (checkout tree root)
  "What CHECKOUT, in worktree TREE of ROOT, is counted against.
That is the base recorded for its branch, else the branch of its main checkout."
  (or (car (with-memoization (gethash checkout overlook-repo--bases)
             (list (overlook-worktree-recorded-base checkout))))
      (car (overlook-repo--status
            (file-name-as-directory (expand-file-name (file-relative-name checkout tree) root))))))

(defun overlook-repo--divergence (checkout base)
  "(AHEAD . BEHIND) of CHECKOUT against branch BASE as last read, or nil.
Reads it again in the background when stale, redrawing when it changed."
  (let ((entry (gethash checkout overlook-repo--diverged)))
    (when (and base
               (or (null entry)
                   (not (equal (cadr entry) base))
                   (> (- (float-time) (car entry)) overlook-repo-status-interval)))
      (puthash checkout (cons (float-time) (cdr entry)) overlook-repo--diverged)
      (overlook-repo--git
       checkout (overlook-worktree-divergence-args base)
       (lambda (output)
         (when-let* ((counts (overlook-worktree-parse-divergence output))
                     (new (cons base counts))
                     ((not (equal new (cdr (gethash checkout overlook-repo--diverged))))))
           (puthash checkout (cons (float-time) new) overlook-repo--diverged)
           (overlook-refresh)))))
    (and entry (equal (cadr entry) base) (cddr entry))))

(defun overlook-repo--divergence-marks (divergence)
  "Marks telling DIVERGENCE, an (AHEAD . BEHIND), or nil when unknown."
  (pcase divergence
    (`(0 . 0) nil)
    (`(0 . ,_) (propertize " merged" 'face 'shadow))
    (`(,ahead . ,behind)
     (propertize (concat (format " ↑%d" ahead) (if (> behind 0) (format " ↓%d" behind) ""))
                 'face 'shadow))))

(defun overlook-repo--worktree-row (tree name root project)
  "The row of worktree TREE of ROOT in PROJECT, by NAME.
Under it go the rows of `overlook-worktree-functions', then its repo's
changed files, or a row of each of its repos when it has several.  Each
repo shows its commits ahead of and behind the main checkout's branch.
The row is dimmed while nothing lies in TREE, nothing is changed and no
commit is unmerged."
  (let* ((repos (overlook-worktree-repos tree))
         (divergences (mapcar (lambda (dir)
                                (cons dir (overlook-repo--divergence
                                           dir (overlook-repo--base dir tree root))))
                              repos))
         (marks (lambda (dir)
                  (overlook-repo--divergence-marks (alist-get dir divergences nil nil #'equal))))
         (before (overlook-rows 'overlook-worktree-functions project tree))
         (row (if (equal repos (list tree))
                  (overlook-repo--row tree project nil name before (funcall marks tree))
                (overlook-repo--group-row tree name project repos before marks))))
    (dolist (dir repos)
      (cl-pushnew dir overlook-repo--shown :test #'equal))
    (setf (overlook-row-dim row)
          (and (seq-every-p (lambda (divergence) (eql (cadr divergence) 0)) divergences)
               (not (seq-some (lambda (dir) (cdr (overlook-repo--status dir))) repos))
               (null (overlook-folder-contents tree))))
    (when (overlook-worktree-at tree)
      (setf (overlook-row-commands row)
            (list (list :name "delete" :label "Delete"
                        :confirm (lambda () (overlook-repo--delete-question tree))
                        :run (lambda () (overlook-repo--delete-worktree tree) nil)))))
    row))

(defun overlook-repo--main-row (root project)
  "The row of PROJECT's main checkout ROOT.
Under it go the rows of `overlook-worktree-functions' for no worktree."
  (let ((before (overlook-rows 'overlook-worktree-functions project nil)))
    (if (equal (overlook-repo--top root) root)
        (overlook-repo--row root project nil nil before)
      (overlook-repo--heading
       (propertize (overlook-repo--label root) 'face 'overlook-repo-name)
       (overlook-repo--changes (overlook-repo--changed project))
       (cons 'worktree root)
       (lambda () (overlook-show-elsewhere project (lambda () (dired root))))
       before))))

(defun overlook-repo--checkout-rows (project)
  "Rows of PROJECT's main checkout and worktrees.
Neither shows while the project has no worktrees."
  (when-let* ((root (overlook-project-root project))
              (trees (overlook-worktrees project)))
    (cons (overlook-repo--main-row root project)
          (mapcar (lambda (tree)
                    (overlook-repo--worktree-row tree (overlook-repo--label tree)
                                                    root project))
                  trees))))

(defun overlook-repo--dirs (project)
  "The repos of PROJECT's root and its folders lying in a repo."
  (let* ((root (overlook-project-root project))
         (ignored (mapcar (lambda (dir) (file-name-as-directory (expand-file-name dir)))
                          overlook-repo-ignored))
         (dirs (seq-remove (lambda (dir) (member dir ignored))
                           (and root (overlook-project-repos root)))))
    (dolist (dir (funcall overlook-repo-folders project))
      (let ((dir (file-name-as-directory (expand-file-name dir))))
        (when (and (overlook-repo--top dir) (not (member dir dirs)))
          (setq dirs (append dirs (list dir))))))
    dirs))

(defun overlook-repo--changed (project)
  "The repos and folders of PROJECT with changes to show."
  (let ((dirs (overlook-repo--dirs project))
        (folders (overlook-repo--folders project)))
    ;; A clean one stays off the dashboard but is still read on each tick.
    (dolist (dir dirs)
      (cl-pushnew dir overlook-repo--shown :test #'equal))
    (seq-filter (lambda (dir)
                  (and (cdr (overlook-repo--status dir))
                       (not (and (eq overlook-repo-folder-display 'mark)
                                 (member dir folders)))))
                dirs)))

(defun overlook-repo--changed-rows (project dir)
  "Rows of the changed repos and folders of PROJECT, for DIR nil.
Under a main checkout that is a repo, its own files are on its row."
  (unless dir
    (let ((root (overlook-project-root project)))
      (overlook-repo--repo-rows
       (if (and (overlook-worktrees project) (equal (overlook-repo--top root) root))
           (remove root (overlook-repo--changed project))
         (overlook-repo--changed project))
       project))))

(defun overlook-repo--close-blocker (project)
  "Why PROJECT cannot close: uncommitted changes in its repos, or nil.
Its folders and worktrees count too."
  (when-let* ((changed (seq-filter #'overlook-worktree-dirty-p
                                   (append (overlook-repo--dirs project)
                                           (mapcan #'overlook-worktree-repos
                                                   (overlook-worktrees project))))))
    (format "uncommitted changes in %s" (mapconcat #'overlook-repo--label changed ", "))))

(defun overlook-repo--delete-question (tree)
  "The question confirming that worktree TREE, and what lies in it, is to go."
  (pcase-let* ((`(,_ . ,name) (or (overlook-worktree-at tree)
                                  (user-error "Not a worktree: %s" tree)))
               (contents (overlook-folder-contents tree))
               (changed (overlook-worktree-uncommitted tree))
               ;; From the last read; reading again would outlive the worktree.
               (unmerged (seq-some (lambda (dir)
                                     (> (or (nth 2 (gethash dir overlook-repo--diverged)) 0) 0))
                                   (overlook-worktree-repos tree))))
    (concat (format "Delete worktree %s" name)
            (if contents (format " and %s" (mapconcat #'car contents ", ")) "")
            (if changed
                (format "; uncommitted changes in %s are lost"
                        (mapconcat #'overlook-repo--label changed ", "))
              "")
            (if unmerged "; its branch keeps commits not merged" "")
            "? ")))

(defun overlook-repo--delete-worktree (tree)
  "Delete worktree TREE with what lies in it, such as its agents.
Its branch stays."
  (pcase-let ((`(,root . ,name) (or (overlook-worktree-at tree)
                                    (user-error "Not a worktree: %s" tree))))
    (pcase-dolist (`(,_ . ,delete) (overlook-folder-contents tree)) (funcall delete))
    (let ((kill-buffer-query-functions nil))
      (dolist (buffer (buffer-list))
        (when (file-in-directory-p (buffer-local-value 'default-directory buffer) tree)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))
    (overlook-worktree-remove root name t)
    (dolist (checkout (hash-table-keys overlook-repo--bases))
      (when (string-prefix-p tree checkout) (remhash checkout overlook-repo--bases)))
    (overlook-refresh)
    (message "Deleted worktree %s" name)))

(defun overlook-repo-delete-worktree (tree)
  "Delete worktree TREE with what lies in it, such as its agents, once confirmed.
Its branch stays."
  (when (yes-or-no-p (overlook-repo--delete-question tree))
    (overlook-repo--delete-worktree tree)))

(defun overlook-repo--delete (item)
  "Delete the worktree ITEM stands for, if it is one."
  (pcase item
    (`(,(or 'repo 'worktree) . ,dir)
     (when (overlook-worktree-at dir)
       (overlook-repo-delete-worktree dir)
       t))))

(defun overlook-repo--forget ()
  "Start collecting the repos drawn by this render."
  (setq overlook-repo--shown nil))

(defun overlook-repo--tick ()
  "Read the shown repos' statuses again when stale; a change redraws."
  (mapc #'overlook-repo--status overlook-repo--shown))

(defun overlook-repo--touch (dir)
  "Read the shown repos and folders holding DIR, or inside its repo, soon."
  (when (overlook-updating-p)
    (push (file-name-as-directory (expand-file-name dir)) overlook-repo--touched)
    (unless (timerp overlook-repo--touch-timer)
      (setq overlook-repo--touch-timer
            (run-with-timer overlook-repo-touch-delay nil #'overlook-repo--read-touched)))))

(defun overlook-repo--read-touched ()
  "Mark the shown repos and folders touched lately stale, and read them."
  (let ((touched (delete-dups overlook-repo--touched)))
    (setq overlook-repo--touched nil
          overlook-repo--touch-timer nil)
    (dolist (shown overlook-repo--shown)
      (when (seq-some
             (lambda (dir)
               (or (string-prefix-p shown dir)
                   ;; A separate repo nested in DIR's is left alone.
                   (and (string-prefix-p dir shown)
                        (not (file-exists-p (expand-file-name ".git" shown))))))
             touched)
        (if (gethash shown overlook-repo--reading)
            (puthash shown t overlook-repo--again)
          (when-let* ((entry (gethash shown overlook-repo--status)))
            (setcar entry 0)))))
    (overlook-repo--tick)))

(defun overlook-repo--saved ()
  "Read the repo of the file just saved soon."
  (when buffer-file-name
    (overlook-repo--touch (file-name-directory buffer-file-name))))

(defun overlook-repo--magit-refreshed ()
  "Read the repo Magit just refreshed soon."
  (overlook-repo--touch default-directory))

(defvar overlook-repo-mode)

(defun overlook-repo--watch-magit (&rest _)
  "Refresh after Magit does, once Magit has defined its hook."
  (when (featurep 'magit-mode)
    (remove-hook 'after-load-functions #'overlook-repo--watch-magit)
    (when overlook-repo-mode
      (add-hook 'magit-post-refresh-hook #'overlook-repo--magit-refreshed))))

;;;###autoload
(define-minor-mode overlook-repo-mode
  "List the repos of each project on the dashboard."
  :global t
  :group 'overlook
  (overlook-toggle-hooks
   overlook-repo-mode
   '((overlook-project-functions overlook-repo--checkout-rows -50)
     (overlook-worktrees-functions overlook-repo--worktree-dirs)
     (overlook-worktree-functions overlook-repo--changed-rows 50)
     (overlook-heading-mark-functions overlook-repo--heading-mark)
     (overlook-delete-functions overlook-repo--delete)
     (overlook-project-close-blockers overlook-repo--close-blocker)
     (overlook-before-render-hook overlook-repo--forget)
     (overlook-tick-hook overlook-repo--tick)
     (after-save-hook overlook-repo--saved)))
  ;; Adding to the hook before Magit defines it would drop Magit's own functions.
  (if overlook-repo-mode
      (progn
        (add-hook 'after-load-functions #'overlook-repo--watch-magit)
        (overlook-repo--watch-magit))
    (remove-hook 'after-load-functions #'overlook-repo--watch-magit)
    (remove-hook 'magit-post-refresh-hook #'overlook-repo--magit-refreshed))
  (overlook-refresh))

(defun overlook-repo-data (key)
  "Repository KEY as paths, status and change counts."
  (pcase key
    (`(repo-file ,dir ,path)
     (when-let* ((file (assoc path (cdr (overlook-repo--status dir)))))
       (list :kind "file" :title (file-name-nondirectory path)
             :repositoryId (overlook-data-id (cons 'repo dir))
             :path path :subtitle (or (file-name-directory path) "")
             :status (nth 1 file) :added (nth 2 file) :removed (nth 3 file)
             :from (nth 4 file))))
    (`(repo . ,dir)
     (pcase-let* ((`(,branch . ,files) (overlook-repo--status dir))
                  (`(,added . ,removed) (overlook-repo--total files)))
       (list :kind "repo" :title (overlook-repo--label dir) :branch branch
             :repositoryId (overlook-data-id (cons 'repo dir))
             :added added :removed removed)))
    (`(worktree . ,dir)
     (list :kind "folder" :title (overlook-repo--label dir)))))

(defun overlook-repo--row-data (row)
  "Compatibility adapter for ROW's business data."
  (overlook-repo-data (overlook-row-id row)))

(add-hook 'overlook-data-functions #'overlook-repo-data)

(provide 'overlook-repo)
;;; overlook-repo.el ends here
