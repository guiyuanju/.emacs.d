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
;; its branch and the lines changed since its last commit, and under it
;; the changed files, read asynchronously and at most every
;; `overlook-project-status-interval' seconds.  RET on a repo shows its
;; diff in Magit, or its status when clean; RET on a file compares it with
;; its last commit in Ediff.  Without Magit, VC does both.
;;
;; `overlook-project-folders' adds folders lying inside a larger repo, such
;; as a project's notes kept in a shared one; such a folder's row lists
;; only the changes under it.  With `overlook-project-folder-display' set
;; to `mark', such a folder gets no row; a "*" after the perspective's
;; heading tells it has changes.

;;; Code:

(require 'overlook)
(require 'diff-mode)
(require 'overlook-markers)

(declare-function magit-status-setup-buffer "magit-status")
(declare-function magit-diff-working-tree "magit-diff")
(declare-function magit-ediff-show-working-tree "magit-ediff")
(declare-function magit-ediff-compare "magit-ediff")
(declare-function magit--git-wash "magit-git")
(declare-function magit-diff-wash-diffs "magit-diff")
(declare-function vc-version-ediff "vc")

(defcustom overlook-project-status-interval 10
  "Seconds before a repo's branch and changes are read again."
  :type 'number
  :group 'overlook)

(defcustom overlook-project-files 5
  "Changed files listed under a repo before the rest fold into one line.
That line unfolds to list the rest."
  :type 'natnum
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

(defconst overlook-project--file-indent ""
  "Indent of the files under a repo.")

(defvar overlook-project--status (make-hash-table :test #'equal)
  "Repo or folder directory to (TIME BRANCH . FILES), as last read.
Each of FILES is (PATH CODE ADDED REMOVED FROM): PATH relative to the
repo, CODE its two-letter `git status' code, line counts since the last
commit, nil when unknown, and for a renamed file the path it had there.
A rename's CODE has R in place of the A of its new path.")

(defvar overlook-project--reading (make-hash-table :test #'equal)
  "Repo directories whose status is being read.")

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
     :command (append '("git" "-c" "core.quotePath=false") args)
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
  "Read DIR's status in the background, redrawing when it changed."
  (unless (gethash dir overlook-project--reading)
    (puthash dir t overlook-project--reading)
    (let ((top (or (overlook-project--top dir) dir))
          (paths (when-let* ((prefix (overlook-project--prefix dir)))
                   (list "--" (concat ":(literal)" prefix)))))
      (overlook-project--git
       top `("status" "--porcelain" "--branch" "--no-renames" "-z" ,@paths)
       (lambda (status)
         (if (null status)
             (remhash dir overlook-project--reading)
           ;; Fails before the first commit, leaving the counts unknown.
           (overlook-project--git
            top `("diff" "HEAD" "--numstat" "-M" "-z" ,@paths)
            (lambda (numstat)
              (remhash dir overlook-project--reading)
              (let ((old (cdr (gethash dir overlook-project--status)))
                    (new (overlook-project--parse status numstat)))
                (puthash dir (cons (float-time) new) overlook-project--status)
                (unless (equal old new) (overlook-refresh)))))))))))

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
  "Compare FILE of repo DIR with its last commit in Ediff.
FILE is an entry of DIR's status; a renamed one is compared with its old
path, a deleted one shown as a diff, and a new one visited instead."
  (pcase-let ((default-directory (or (overlook-project--top dir) dir))
              (`(,path ,code ,_ ,_ ,from) file))
    (cond ((and from (require 'magit-ediff nil t))
           (magit-ediff-compare "HEAD" "{worktree}" from path))
          ((string-search "D" code)
           (if (fboundp 'magit-diff-working-tree)
               (magit-diff-working-tree "HEAD" nil (list path))
             (vc-root-diff nil)))
          ((overlook-project--new-p code) (find-file path))
          ((require 'magit-ediff nil t) (magit-ediff-show-working-tree path))
          (t (vc-version-ediff (list (expand-file-name path)) "HEAD" nil)))))

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

(defun overlook-project--insert-diff (dir file action)
  "Insert Magit's diff of FILE, from repo DIR's status, against the last commit.
ACTION replaces Magit's keys on it, which expect a Magit buffer of DIR."
  (require 'magit)
  (pcase-let ((default-directory (or (overlook-project--top dir) dir))
              (`(,path ,code ,_ ,_ ,from) file)
              (start (point)))
    (magit-insert-section (overlook-project-diff path)
      ;; An untracked file's diff against /dev/null exits with 1.
      (magit--git-wash #'magit-diff-wash-diffs 'wash-anyway
        "diff" "--no-prefix"
        (cond ((equal code "??") (list "--no-index" "--" null-device path))
              (from (list "-M" "HEAD" "--" from path))
              (t (list "HEAD" "--" path)))))
    (remove-list-of-text-properties start (point) '(keymap))
    (put-text-property start (point) 'overlook-action action)))

(defun overlook-project--insert-file (dir file perspective)
  "Insert the row of FILE changed in repo DIR, under its row in PERSPECTIVE."
  (let* ((prefix overlook-project--file-indent)
         (action (lambda ()
                   (overlook-show-elsewhere
                    perspective (lambda () (overlook-project-open-file dir file))))))
    (overlook-insert-row (propertize (concat prefix
                                             (overlook-project--file-label
                                              file (overlook-project--prefix dir))
                                             "\n")
                                     'overlook-item (list 'repo-file dir (car file))
                                     'overlook-action action
                                     'help-echo (car file)
                                     'wrap-prefix prefix)
                         (and (fboundp 'magit-diff-working-tree)
                              (lambda ()
                                (magit-insert-section-body
                                  (overlook-project--insert-diff dir file action))))
                         t)))

(defun overlook-project--insert-files (dir files perspective)
  "Insert FILES changed in repo DIR, under its row in PERSPECTIVE.
Past `overlook-project-files' the rest fold into one line with their totals."
  (let ((prefix overlook-project--file-indent)
        (rest (nthcdr overlook-project-files files)))
    (dolist (file (seq-take files overlook-project-files))
      (overlook-project--insert-file dir file perspective))
    (when rest
      (let ((total (overlook-project--total rest)))
        (overlook-insert-row (propertize
                              (concat prefix
                                      (propertize (format "…+%d" (length rest)) 'face 'shadow)
                                      (overlook-project--counts (car total) (cdr total))
                                      "\n")
                              'overlook-item (list 'repo-files dir)
                              'overlook-action (lambda ()
                                                 (overlook-show-elsewhere
                                                  perspective (lambda () (overlook-project-open dir))))
                              'help-echo (mapconcat #'car rest "\n")
                              'wrap-prefix prefix)
                             (lambda ()
                               (dolist (file rest)
                                 (overlook-project--insert-file dir file perspective)))
                             t)))))

(defun overlook-project--row (dir perspective width)
  "Insert the row of repo DIR in PERSPECTIVE, its name padded to WIDTH."
  (pcase-let* ((`(,branch . ,files) (overlook-project--status dir))
               (total (overlook-project--total files))
               (name (file-name-nondirectory (directory-file-name dir))))
    (overlook-insert-row (propertize
                          (concat overlook-indent
                                  (propertize (concat (overlook-glyph-cell "⎇")
                                                      (if branch (string-pad name width) name)
                                                      (if branch (concat "  " branch) ""))
                                              'face 'overlook-project-repo)
                                  (overlook-project--counts (car total) (cdr total))
                                  "\n")
                          'overlook-item (cons 'repo dir)
                          'help-echo dir
                          'overlook-action (lambda ()
                                             (overlook-show-elsewhere
                                              perspective (lambda () (overlook-project-open dir)))))
                         (lambda () (overlook-project--insert-files dir files perspective)))))

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

(defun overlook-project--insert (perspective)
  "Insert the changed repos and folders of PERSPECTIVE's project."
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
    (let* ((dirs (seq-filter (lambda (dir)
                               (and (cdr (overlook-project--status dir))
                                    (not (and (eq overlook-project-folder-display 'mark)
                                              (member dir folders)))))
                             dirs))
           (width (apply #'max 0 (mapcar (lambda (dir)
                                           (string-width (file-name-nondirectory
                                                          (directory-file-name dir))))
                                         dirs))))
      (dolist (dir dirs)
        (overlook-project--row dir perspective width)))))

(defun overlook-project--forget ()
  "Start collecting the repos drawn by this render."
  (setq overlook-project--shown nil))

(defun overlook-project--tick ()
  "Read the shown repos' statuses again when stale; a change redraws."
  (mapc #'overlook-project--status overlook-project--shown))

;;;###autoload
(define-minor-mode overlook-project-mode
  "List the repos of each perspective's project on the dashboard."
  :global t
  :group 'overlook
  (overlook-toggle-hooks
   overlook-project-mode
   '((overlook-perspective-functions overlook-project--insert 50)
     (overlook-heading-mark-functions overlook-project--heading-mark)
     (overlook-before-render-hook overlook-project--forget)
     (overlook-tick-hook overlook-project--tick)))
  (overlook-refresh))

(provide 'overlook-project)
;;; overlook-project.el ends here
