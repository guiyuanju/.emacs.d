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

;; Lists the Git repos of each perspective's project under its heading:
;; the project root when it is a repo itself, and the repos directly inside
;; it, so a project made of several clones shows each.  A repo's row shows
;; its branch and the lines changed since its last commit, and under it
;; the changed files, read asynchronously and at most every
;; `overlook-project-status-interval' seconds.  RET on a repo shows its
;; diff in Magit, or its status when clean; RET on a file compares it with
;; its last commit in Ediff.  Without Magit, VC does both.

;;; Code:

(require 'overlook)
(require 'diff-mode)
(require 'overlook-markers)

(declare-function magit-status-setup-buffer "magit-status")
(declare-function magit-diff-working-tree "magit-diff")
(declare-function magit-ediff-show-working-tree "magit-ediff")
(declare-function vc-version-ediff "vc")

(defcustom overlook-project-status-interval 10
  "Seconds before a repo's branch and changes are read again."
  :type 'number
  :group 'overlook)

(defcustom overlook-project-files 5
  "Changed files listed under a repo before the rest fold into one line."
  :type 'natnum
  :group 'overlook)

(defface overlook-project-repo
  '((t :inherit shadow))
  "Face of a repo's row, dimmed so agents stand out."
  :group 'overlook)

(defface overlook-project-file
  '((t :inherit overlook-project-repo))
  "Face of a changed file's name under its repo."
  :group 'overlook)

(defconst overlook-project--file-indent "        "
  "Indent of the files under a repo, two columns past its name.")

(defvar overlook-project--status (make-hash-table :test #'equal)
  "Repo directory to (TIME BRANCH . FILES), as last read.
Each of FILES is (PATH CODE ADDED REMOVED): PATH relative to the repo,
CODE its two-letter `git status' code, and line counts since the last
commit, nil when unknown.")

(defvar overlook-project--reading (make-hash-table :test #'equal)
  "Repo directories whose status is being read.")

(defvar overlook-project--shown nil
  "Repo directories on the dashboard as last drawn.")

(defun overlook-project--parse (status &optional numstat)
  "Branch and changed files from STATUS and NUMSTAT outputs.
STATUS is from `git status --porcelain --branch -z', NUMSTAT from
`git diff HEAD --numstat -z'; both list paths without renames."
  (let* ((entries (split-string status "\0" t))
         (head (car entries))
         (branch (cond ((null head) nil)
                       ((string-match "\\`## No commits yet on \\(.+\\)" head)
                        (match-string 1 head))
                       ((string-match "\\`## \\(HEAD\\) (no branch)" head) "detached")
                       ((string-match "\\`## \\([^.[:space:]]+\\)" head)
                        (match-string 1 head))))
         (counts (mapcar (lambda (line)
                           (when (string-match "\\`\\([0-9-]+\\)\t\\([0-9-]+\\)\t\\(.+\\)" line)
                             (list (match-string 3 line)
                                   (string-to-number (match-string 1 line))
                                   (string-to-number (match-string 2 line)))))
                         (split-string (or numstat "") "\0" t))))
    (cons branch
          (mapcar (lambda (entry)
                    (let ((path (substring entry 3)))
                      (cons path (cons (substring entry 0 2) (cdr (assoc path counts))))))
                  (cdr entries)))))

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
    (overlook-project--git
     dir '("status" "--porcelain" "--branch" "--no-renames" "-z")
     (lambda (status)
       (if (null status)
           (remhash dir overlook-project--reading)
         ;; Fails before the first commit, leaving the counts unknown.
         (overlook-project--git
          dir '("diff" "HEAD" "--numstat" "--no-renames" "-z")
          (lambda (numstat)
            (remhash dir overlook-project--reading)
            (let ((old (cdr (gethash dir overlook-project--status)))
                  (new (overlook-project--parse status numstat)))
              (puthash dir (cons (float-time) new) overlook-project--status)
              (unless (equal old new) (overlook-refresh))))))))))

(defun overlook-project--status (dir)
  "DIR's last known (BRANCH . FILES), reading it again when stale."
  (let ((entry (gethash dir overlook-project--status)))
    (when (or (null entry)
              (> (- (float-time) (car entry)) overlook-project-status-interval))
      (overlook-project--read dir))
    (cdr entry)))

(defun overlook-project-open (dir)
  "Show repo DIR's changes since its last commit, or its status when clean.
Uses Magit, or VC without it."
  (let ((default-directory dir)
        (changed (cdr (overlook-project--status dir))))
    (cond ((and changed (fboundp 'magit-diff-working-tree)) (magit-diff-working-tree "HEAD"))
          ((fboundp 'magit-status-setup-buffer) (magit-status-setup-buffer dir))
          (changed (vc-root-diff nil))
          (t (vc-dir dir)))))

(defun overlook-project-open-file (dir file)
  "Compare FILE of repo DIR with its last commit in Ediff.
FILE is an entry of DIR's status; an untracked file is visited instead,
and a deleted one shown as a diff."
  (pcase-let ((default-directory dir)
              (`(,path ,code . ,_) file))
    (cond ((equal code "??") (find-file path))
          ((string-search "D" code)
           (if (fboundp 'magit-diff-working-tree)
               (magit-diff-working-tree "HEAD" nil (list path))
             (vc-root-diff nil)))
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

(defun overlook-project--file-label (file)
  "FILE's name, its line counts or state, then its directory."
  (pcase-let* ((`(,path ,code ,added ,removed) file)
               (dir (file-name-directory path))
               (state (cond ((equal code "??") " new")
                            ((string-search "D" code) " deleted"))))
    (concat (propertize (file-name-nondirectory path) 'face 'overlook-project-file)
            (overlook-project--counts added removed)
            (if state (propertize state 'face 'shadow) "")
            (if dir (propertize (concat " " dir) 'face 'shadow) ""))))

(defun overlook-project--insert-files (dir files perspective)
  "Insert FILES changed in repo DIR, under its row in PERSPECTIVE.
Past `overlook-project-files' the rest fold into one line with their totals."
  (let ((prefix overlook-project--file-indent)
        (rest (nthcdr overlook-project-files files)))
    (dolist (file (seq-take files overlook-project-files))
      (overlook-insert-row (propertize (concat prefix (overlook-project--file-label file) "\n")
                                       'overlook-item (list 'repo-file dir (car file))
                                       'overlook-action (lambda ()
                                                          (overlook-show-elsewhere
                                                           perspective
                                                           (lambda () (overlook-project-open-file dir file))))
                                       'help-echo (car file)
                                       'wrap-prefix prefix)))
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
                              'wrap-prefix prefix))))))

(defun overlook-project--row (dir perspective width)
  "Insert the row of repo DIR in PERSPECTIVE, its name padded to WIDTH."
  (push dir overlook-project--shown)
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

(defun overlook-project--insert (perspective)
  "Insert the repos of PERSPECTIVE's project."
  (when-let* ((root (overlook-perspective-root perspective)))
    (let* ((dirs (overlook-project-repos root))
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
  (if overlook-project-mode
      (progn
        (add-hook 'overlook-perspective-functions #'overlook-project--insert 50)
        (add-hook 'overlook-before-render-hook #'overlook-project--forget)
        (add-hook 'overlook-tick-hook #'overlook-project--tick))
    (remove-hook 'overlook-perspective-functions #'overlook-project--insert)
    (remove-hook 'overlook-before-render-hook #'overlook-project--forget)
    (remove-hook 'overlook-tick-hook #'overlook-project--tick))
  (overlook-refresh))

(provide 'overlook-project)
;;; overlook-project.el ends here
