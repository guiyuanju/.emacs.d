;;; overlook-project.el --- Repos of each perspective's project -*- lexical-binding: t; -*-

;;; Commentary:

;; Lists the Git repos of each perspective's project under its heading:
;; the project root when it is a repo itself, and the repos directly inside
;; it, so a project made of several clones shows each.  A repo's row shows
;; its branch and how many files it has uncommitted, read asynchronously
;; and at most every `overlook-project-status-interval' seconds.  RET opens
;; it in Magit, or VC when Magit is not installed.

;;; Code:

(require 'overlook)

(declare-function magit-status-setup-buffer "magit-status")

(defcustom overlook-project-status-interval 10
  "Seconds before a repo's branch and changes are read again."
  :type 'number
  :group 'overlook)

(defface overlook-project-branch
  '((t :inherit shadow))
  "Face of a repo's branch."
  :group 'overlook)

(defface overlook-project-dirty
  '((t :inherit warning))
  "Face of a repo's count of uncommitted files."
  :group 'overlook)

(defvar overlook-project--status (make-hash-table :test #'equal)
  "Repo directory to (TIME BRANCH . CHANGED), as last read.")

(defvar overlook-project--reading (make-hash-table :test #'equal)
  "Repo directories whose status is being read.")

(defvar overlook-project--shown nil
  "Repo directories on the dashboard as last drawn.")

(defun overlook-project-repos (root)
  "ROOT when it is a Git repo, then the Git repos directly inside it."
  (let ((root (file-name-as-directory (expand-file-name root))))
    (append
     (and (file-exists-p (expand-file-name ".git" root)) (list root))
     (seq-filter (lambda (dir) (file-exists-p (expand-file-name ".git" dir)))
                 (mapcar #'file-name-as-directory
                         (seq-filter #'file-directory-p
                                     (directory-files root t "\\`[^.]" t)))))))

(defun overlook-project--parse (output)
  "Branch and count of changed files from `git status --porcelain --branch' OUTPUT."
  (let* ((lines (split-string output "\n" t))
         (head (car lines))
         (branch (cond ((null head) nil)
                       ((string-match "\\`## No commits yet on \\(.+\\)" head)
                        (match-string 1 head))
                       ((string-match "\\`## \\(HEAD\\) (no branch)" head) "detached")
                       ((string-match "\\`## \\([^.[:space:]]+\\)" head)
                        (match-string 1 head)))))
    (cons branch (length (cdr lines)))))

(defun overlook-project--read (dir)
  "Read DIR's status in the background, redrawing when it changed."
  (unless (gethash dir overlook-project--reading)
    (puthash dir t overlook-project--reading)
    (let ((output (generate-new-buffer " *overlook-git*"))
          (default-directory dir))
      (make-process
       :name "overlook-git" :buffer output :noquery t
       :command '("git" "status" "--porcelain" "--branch")
       :connection-type 'pipe
       :sentinel
       (lambda (process _event)
         (unless (process-live-p process)
           (remhash dir overlook-project--reading)
           (when (buffer-live-p output)
             (let ((status (and (eq (process-exit-status process) 0)
                                (overlook-project--parse
                                 (with-current-buffer output (buffer-string))))))
               (kill-buffer output)
               (when status
                 (let ((old (cdr (gethash dir overlook-project--status))))
                   (puthash dir (cons (float-time) status) overlook-project--status)
                   (unless (equal old status) (overlook-refresh))))))))))))

(defun overlook-project--status (dir)
  "DIR's last known (BRANCH . CHANGED), reading it again when stale."
  (let ((entry (gethash dir overlook-project--status)))
    (when (or (null entry)
              (> (- (float-time) (car entry)) overlook-project-status-interval))
      (overlook-project--read dir))
    (cdr entry)))

(defun overlook-project-open (dir)
  "Open repo DIR in Magit, or VC without Magit."
  (if (fboundp 'magit-status-setup-buffer)
      (magit-status-setup-buffer dir)
    (vc-dir dir)))

(defun overlook-project--row (dir perspective)
  (push dir overlook-project--shown)
  (pcase-let ((`(,branch . ,changed) (overlook-project--status dir)))
    (insert (propertize
             (concat overlook-indent
                     (file-name-nondirectory (directory-file-name dir))
                     (if branch (concat "  " (propertize branch 'face 'overlook-project-branch)) "")
                     (if (and changed (> changed 0))
                         (propertize (format "  ●%d" changed) 'face 'overlook-project-dirty)
                       "")
                     "\n")
             'overlook-item (cons 'repo dir)
             'help-echo dir
             'overlook-action (lambda ()
                                (overlook-show-elsewhere
                                 perspective (lambda () (overlook-project-open dir))))))))

(defun overlook-project--insert (perspective)
  "Insert the repos of PERSPECTIVE's project."
  (when-let* ((root (overlook-perspective-root perspective)))
    (dolist (dir (overlook-project-repos root))
      (overlook-project--row dir perspective))))

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
        (add-hook 'overlook-perspective-functions #'overlook-project--insert -50)
        (add-hook 'overlook-before-render-hook #'overlook-project--forget)
        (add-hook 'overlook-tick-hook #'overlook-project--tick))
    (remove-hook 'overlook-perspective-functions #'overlook-project--insert)
    (remove-hook 'overlook-before-render-hook #'overlook-project--forget)
    (remove-hook 'overlook-tick-hook #'overlook-project--tick))
  (overlook-refresh))

(provide 'overlook-project)
;;; overlook-project.el ends here
