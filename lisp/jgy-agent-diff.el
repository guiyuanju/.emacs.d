;;; jgy-agent-diff.el --- Git-backed per-turn file changes -*- lexical-binding: t; -*-

;;; Commentary:
;; Clean files use the starting commit.  Only dirty/untracked text is copied.
;; Cached patches survive commits; no writes to the repository index or refs.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(defvar-local jgy-agent-diff--repos nil)
(defvar-local jgy-agent-diff--files nil)
(defconst jgy-agent-diff--limit (* 1024 1024)
  "Largest file whose contents are kept for turn diffs.")

(defun jgy-agent-diff--git (dir &rest args)
  "Run Git ARGS in DIR, returning stdout or signaling on failure."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (eq 0 (apply #'process-file "git" nil (list t nil) nil args))
        (error "Cannot read Git turn baseline in %s" dir))
      (buffer-string))))

(defun jgy-agent-diff--paths (repo)
  "Paths differing from REPO's original commit, plus untracked paths."
  (let ((dir (plist-get repo :dir)) (head (plist-get repo :head)))
    (delete-dups
     (append
      (split-string
       (if head
           (jgy-agent-diff--git dir "diff" "--name-only" "--no-renames" "--relative"
                                "-z" head "--" ".")
         (jgy-agent-diff--git dir "ls-files" "-z" "--cached" "--" ".")) "\0" t)
      (split-string (jgy-agent-diff--git dir "ls-files" "-z" "--others"
                                       "--exclude-standard" "--" ".") "\0" t)))))

(defun jgy-agent-diff--read (path)
  "Read PATH as text, nil if absent, or `skip' for unsupported files."
  (cond
   ((file-symlink-p path) 'skip)
   ((not (file-exists-p path)) nil)
   ((or (not (file-regular-p path))
        (> (file-attribute-size (file-attributes path)) jgy-agent-diff--limit)) 'skip)
   (t (with-temp-buffer
        (insert-file-contents path)
        (if (search-forward "\0" nil t) 'skip (buffer-string))))))

(defun jgy-agent-diff--base (repo name)
  "Get NAME's starting content in REPO, lazily reading clean Git blobs."
  (let* ((cache (plist-get repo :base))
         (known (gethash name cache 'unknown)))
    (if (not (eq known 'unknown)) known
      (let* ((head (plist-get repo :head))
             (object (and head (concat head ":" (plist-get repo :prefix) name)))
             (size (and object (ignore-errors
                                 (string-to-number
                                  (jgy-agent-diff--git (plist-get repo :dir)
                                                       "cat-file" "-s" object)))))
             (text (cond ((null size) nil)
                         ((> size jgy-agent-diff--limit) 'skip)
                         (t (jgy-agent-diff--git (plist-get repo :dir) "show" object)))))
        (when (and (stringp text) (string-match-p "\0" text)) (setq text 'skip))
        (puthash name text cache)
        text))))

(defun jgy-agent-diff-begin (root)
  "Start a turn in ROOT, saving only existing dirty/untracked contents."
  (setq jgy-agent-diff--repos nil jgy-agent-diff--files nil)
  (dolist (dir (cons root
                    (cl-remove-if-not
                     (lambda (path) (file-exists-p (expand-file-name ".git" path)))
                     (directory-files root t "\\`[^.]" t))))
    (condition-case err
        (let* ((prefix (string-trim-right (jgy-agent-diff--git dir "rev-parse" "--show-prefix")))
               (repo (list :dir (file-name-as-directory dir) :prefix prefix
                           :head (ignore-errors
                                   (string-trim (jgy-agent-diff--git dir "rev-parse" "--verify" "HEAD")))
                           :base (make-hash-table :test #'equal)
                           :last (make-hash-table :test #'equal))))
          (dolist (name (jgy-agent-diff--paths repo))
            (let ((text (jgy-agent-diff--read (expand-file-name name dir))))
              (puthash name text (plist-get repo :base))
              (puthash name text (plist-get repo :last))))
          (push repo jgy-agent-diff--repos))
      (error (message "Turn diff unavailable: %s" (error-message-string err)))))
  (setq jgy-agent-diff--repos (nreverse jgy-agent-diff--repos)))

(defun jgy-agent-diff--patch (name before after)
  "Return a unified patch for NAME from BEFORE to AFTER."
  (let ((old (make-temp-file "agent-before-"))
        (new (make-temp-file "agent-after-")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file old (insert (or before "")))
            (with-temp-file new (insert (or after ""))))
          (with-temp-buffer
            (let ((status (process-file "diff" nil t nil "-u"
                                        "--label" (if before (concat "a/" name) "/dev/null")
                                        "--label" (if after (concat "b/" name) "/dev/null")
                                        old new)))
              (unless (memq status '(0 1)) (error "Cannot compute turn diff")))
            (when (and (zerop (buffer-size)) (not (eq (null before) (null after))))
              (insert (format "--- %s\n+++ %s\n"
                              (if before (concat "a/" name) "/dev/null")
                              (if after (concat "b/" name) "/dev/null"))))
            (buffer-string)))
      (delete-file old) (delete-file new))))

(defun jgy-agent-diff--entry (path patch directory)
  "Make an agent file entry for PATH and PATCH relative to DIRECTORY."
  (let ((added 0) (removed 0) line)
    (with-temp-buffer
      (insert patch)
      (goto-char (point-min))
      (forward-line 2)
      (while (not (eobp))
        (cond ((looking-at "^+") (cl-incf added))
              ((looking-at "^-") (cl-incf removed))
              ((and (null line) (looking-at "^@@ .* [+]\\([0-9]+\\)"))
               (setq line (string-to-number (match-string 1)))))
        (forward-line 1)))
    `((file . ,path) (directory . ,directory) (added . ,added) (removed . ,removed)
      (active . nil) (line . ,line) (diff . ,patch))))

(defun jgy-agent-diff-scan ()
  "Update turn patches only for real content changes, including committed ones."
  (let (changed)
    (dolist (repo jgy-agent-diff--repos)
      (condition-case err
          (let* ((last (plist-get repo :last))
                 ;; Previously seen paths catch deletion and restoration to HEAD.
                 (paths (delete-dups (append (jgy-agent-diff--paths repo)
                                             (hash-table-keys last)))))
            (dolist (name paths)
              (let* ((path (expand-file-name name (plist-get repo :dir)))
                     (before (jgy-agent-diff--base repo name))
                     (previous (gethash name last before))
                     (after (jgy-agent-diff--read path)))
                (unless (equal after previous)
                  (unless (or (eq before 'skip) (eq after 'skip))
                    (let* ((patch (jgy-agent-diff--patch name before after))
                           (entry (jgy-agent-diff--entry path patch (plist-get repo :dir))))
                      (setq jgy-agent-diff--files
                            (append (cl-remove path jgy-agent-diff--files
                                               :key (lambda (item) (alist-get 'file item))
                                               :test #'equal)
                                    (list entry))
                            changed t)))
                  (puthash name after last)))))
        (error (message "Turn diff refresh failed: %s" (error-message-string err)))))
    changed))

(provide 'jgy-agent-diff)
;;; jgy-agent-diff.el ends here
