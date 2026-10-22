;;; iuiw-diff-hl.el --- Diff-hl against a base branch -*- lexical-binding: t; -*-

;;; Commentary:
;; 让 diff-hl 以当前分支和选定分支的分叉点为基准，在真实 buffer 里看整个分支的改动。

;;; Code:

(require 'diff-hl)
(require 'magit-git)
(require 'magit-files)

(require 'vdiff)
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
Unchanged lines stay unfolded, so the whole file shows.  When either
window of the session switches to another file, the session follows it."
  (interactive)
  (iuiw-diff-hl--vdiff (current-buffer) (current-window-configuration)))

(defvar iuiw-diff-hl--vdiff-follow nil
  "Plist of the following vdiff session: :buffers, :windows and :config.")

(defun iuiw-diff-hl--vdiff (buf config)
  "Start a vdiff session for BUF; quitting it restores window CONFIG."
  (let* ((file (or (buffer-file-name buf) (user-error "Not visiting a file")))
         (rev (or (buffer-local-value 'diff-hl-reference-revision buf) "HEAD"))
         (old (with-current-buffer buf (magit-find-file-noselect rev file t t))))
    (dolist (b (list old buf))
      (with-current-buffer b (setq-local vdiff-disable-folding t)))
    (with-current-buffer buf
      (vdiff-buffers old buf nil #'iuiw-diff-hl--vdiff-on-quit nil nil))
    (setf (vdiff-session-prior-window-config
           (buffer-local-value 'vdiff--session buf))
          config)
    (setq iuiw-diff-hl--vdiff-follow
          (list :buffers (list old buf)
                :windows (list (get-buffer-window old) (get-buffer-window buf))
                :config config))
    (add-hook 'window-buffer-change-functions #'iuiw-diff-hl--vdiff-check)))

(defun iuiw-diff-hl--vdiff-on-quit (old new)
  "Kill the revision buffer OLD and restore folding in NEW."
  (setq iuiw-diff-hl--vdiff-follow nil)
  (remove-hook 'window-buffer-change-functions #'iuiw-diff-hl--vdiff-check)
  (kill-buffer old)
  (when (buffer-live-p new)
    (with-current-buffer new (kill-local-variable 'vdiff-disable-folding))))

(defun iuiw-diff-hl--vdiff-check (_frame)
  "Follow when a session window now shows another file."
  (when-let* ((state iuiw-diff-hl--vdiff-follow)
              (win (seq-find
                    (lambda (w)
                      (and (window-live-p w)
                           (let ((b (window-buffer w)))
                             (and (buffer-file-name b)
                                  (not (memq b (plist-get state :buffers)))))))
                    (plist-get state :windows))))
    (run-at-time 0 nil #'iuiw-diff-hl--vdiff-follow win)))

(defun iuiw-diff-hl--vdiff-follow (win)
  "End the session without touching windows and restart it on WIN's buffer."
  (when-let* ((state iuiw-diff-hl--vdiff-follow)
              ((window-live-p win))
              (buf (window-buffer win))
              (session-buf (cadr (plist-get state :buffers)))
              ((buffer-live-p session-buf)))
    (with-current-buffer session-buf
      (setf (vdiff-session-prior-window-config vdiff--session) nil)
      (vdiff-quit))
    (select-window win)
    (condition-case err
        (iuiw-diff-hl--vdiff buf (plist-get state :config))
      (error (message "vdiff: %s" (error-message-string err))))))

;;;###autoload
(defun iuiw-diff-hl-show-hunk-vdiff ()
  "Close the hunk popup and compare its file in vdiff."
  (interactive)
  (diff-hl-show-hunk-hide)
  (iuiw-diff-hl-vdiff))

(provide 'iuiw-diff-hl)
;;; iuiw-diff-hl.el ends here
