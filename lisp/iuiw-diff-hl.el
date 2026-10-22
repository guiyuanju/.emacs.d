;;; iuiw-diff-hl.el --- Diff-hl against a base branch -*- lexical-binding: t; -*-

;;; Commentary:
;; 让 diff-hl 以当前分支和选定分支的分叉点为基准，在真实 buffer 里看整个分支的改动。

;;; Code:

(require 'diff-hl)
(require 'magit-git)
(require 'magit-files)

(declare-function vdiff-buffers "vdiff")
(defvar vdiff-disable-folding)
(declare-function diff-hl-show-hunk-hide "diff-hl-show-hunk")

(defun iuiw-diff-hl--repo-project ()
  "Return the VC project of the current Git repository.
A `.overlook' project can span several repositories, which cannot share
one reference revision."
  (let ((root (or (magit-toplevel) (user-error "Not inside a Git repository"))))
    (project-try-vc root)))

;;;###autoload
(defun iuiw-diff-hl-against-branch ()
  "Toggle diff-hl between HEAD and the fork point with a chosen branch.
Commits merged to the branch after the fork stay out."
  (interactive)
  (let* ((proj (iuiw-diff-hl--repo-project))
         (root (diff-hl--project-root proj)))
    (if (assoc root diff-hl-reference-revision-projects-cache)
        (progn (diff-hl-reset-reference-rev-in-project proj)
               (message "diff-hl: against HEAD"))
      (let* ((branch (magit-read-branch-or-commit
                      "Diff against" (iuiw-diff-hl--default-base)
                      (magit-get-current-branch)))
             (fork (or (magit-git-string "merge-base" branch "HEAD")
                       (user-error "No common ancestor with %s" branch))))
        (diff-hl-set-reference-rev-in-project-internal fork proj)
        (message "diff-hl: against %s (fork point %s)"
                 branch (magit-rev-abbrev fork))))))

(defun iuiw-diff-hl--default-base ()
  "Return the branch the primary remote's HEAD points to, else main's upstream."
  (or (and-let* ((remote (magit-primary-remote)))
        (magit-git-string "symbolic-ref" "--short"
                          (format "refs/remotes/%s/HEAD" remote)))
      (and-let* ((main (magit-main-branch)))
        (or (magit-get-upstream-branch main) main))))

;;;###autoload
(defun iuiw-diff-hl-vdiff ()
  "Compare this file with diff-hl's reference revision in vdiff.
Unchanged lines stay unfolded, so the whole file shows."
  (interactive)
  (require 'vdiff)
  (let* ((file (or buffer-file-name (user-error "Not visiting a file")))
         (rev (or diff-hl-reference-revision "HEAD"))
         (old (magit-find-file-noselect rev file t t)))
    (dolist (buf (list old (current-buffer)))
      (with-current-buffer buf (setq-local vdiff-disable-folding t)))
    (vdiff-buffers old (current-buffer) nil
                   (lambda (old new)
                     (kill-buffer old)
                     (with-current-buffer new
                       (kill-local-variable 'vdiff-disable-folding)))
                   t nil)))

;;;###autoload
(defun iuiw-diff-hl-show-hunk-vdiff ()
  "Close the hunk popup and compare its file in vdiff."
  (interactive)
  (diff-hl-show-hunk-hide)
  (iuiw-diff-hl-vdiff))

(provide 'iuiw-diff-hl)
;;; iuiw-diff-hl.el ends here
