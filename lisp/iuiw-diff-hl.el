;;; iuiw-diff-hl.el --- Diff-hl against a base branch -*- lexical-binding: t; -*-

;;; Commentary:
;; 让 diff-hl 以当前分支和选定分支的分叉点为基准，在真实 buffer 里看整个分支的改动。

;;; Code:

(require 'diff-hl)
(require 'magit-git)

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

(provide 'iuiw-diff-hl)
;;; iuiw-diff-hl.el ends here
