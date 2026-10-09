;;; jgy-agent-diff.el --- Git-backed per-turn file changes -*- lexical-binding: t; -*-

;;; Commentary:
;; Clean files use the starting commit.  Only dirty/untracked text is copied.
;; Cached patches survive commits; no writes to the repository index or refs.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'generator)
(require 'map)

(defvar-local jgy-agent-diff--repos nil)
(defvar-local jgy-agent-diff--files nil)
(defvar-local jgy-agent-diff--generation 0)
(defvar-local jgy-agent-diff--timer nil)
(defvar-local jgy-agent-diff--process nil)
(defvar-local jgy-agent-diff--iterator nil)
(defvar-local jgy-agent-diff--pending nil)
(defvar-local jgy-agent-diff--hints nil)
(defvar-local jgy-agent-diff--focus nil)
(defvar-local jgy-agent-diff--seen nil)
(defvar-local jgy-agent-diff--finished nil)
(defvar-local jgy-agent-diff--temporary nil)
(defvar jgy-agent-diff-update-hook nil
  "Hook run in the agent buffer when a scan changes file entries.")
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

(defun jgy-agent-diff--stamp (path)
  "Cheap change hint for PATH; final verification never trusts this alone."
  (let ((attributes (file-attributes path)))
    (list (file-attribute-type attributes)
          (file-attribute-size attributes)
          (file-attribute-modification-time attributes)
          (file-attribute-status-change-time attributes)
          (file-attribute-inode-number attributes))))

(defun jgy-agent-diff-begin (root)
  "Start a turn in ROOT, saving only existing dirty/untracked contents."
  (jgy-agent-diff-cancel)
  (setq jgy-agent-diff--repos nil jgy-agent-diff--files nil
        jgy-agent-diff--finished nil
        jgy-agent-diff--seen (make-hash-table :test #'equal))
  (add-hook 'kill-buffer-hook #'jgy-agent-diff-cancel nil t)
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
                           :last (make-hash-table :test #'equal)
                           :stamps (make-hash-table :test #'equal))))
          (dolist (name (jgy-agent-diff--paths repo))
            (let* ((path (expand-file-name name dir))
                   (stamp (jgy-agent-diff--stamp path))
                   (text (jgy-agent-diff--read path)))
              (puthash name stamp (plist-get repo :stamps))
              (puthash name text (plist-get repo :base))
              (puthash name text (plist-get repo :last))))
          (push repo jgy-agent-diff--repos))
      (error (message "Turn diff unavailable: %s" (error-message-string err)))))
  (setq jgy-agent-diff--repos (nreverse jgy-agent-diff--repos)))

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

;; The iterator yields subprocess commands.  Only bounded file reads and result
;; publication run in Emacs; Git and diff never block the event handler.
(defmacro jgy-agent-diff--await (directory &rest command)
  "Yield COMMAND in DIRECTORY and return stdout, or signal on failure."
  `(let ((result (iter-yield (cons ,directory (list ,@command)))))
     (unless (eq (car result) 0)
       (error "Turn diff command failed: %s" ,(car command)))
     (cdr result)))

(defun jgy-agent-diff-cancel ()
  "Invalidate this turn's callbacks and release its pending work."
  (cl-incf jgy-agent-diff--generation)
  (when (timerp jgy-agent-diff--timer) (cancel-timer jgy-agent-diff--timer))
  (when (processp jgy-agent-diff--process)
    (set-process-sentinel jgy-agent-diff--process #'ignore)
    (delete-process jgy-agent-diff--process)
    (when (buffer-live-p (process-buffer jgy-agent-diff--process))
      (kill-buffer (process-buffer jgy-agent-diff--process))))
  (when jgy-agent-diff--iterator (iter-close jgy-agent-diff--iterator))
  (dolist (path jgy-agent-diff--temporary) (ignore-errors (delete-file path)))
  (setq jgy-agent-diff--timer nil jgy-agent-diff--process nil
        jgy-agent-diff--iterator nil jgy-agent-diff--pending nil
        jgy-agent-diff--hints nil jgy-agent-diff--focus nil
        jgy-agent-diff--temporary nil))

(defun jgy-agent-diff-request (&optional paths hints final)
  "Queue PATHS, or a full scan if nil; HINTS are (PATH . LINE).
FINAL requests a last full verification and stops accepting tool events."
  (unless jgy-agent-diff--finished
    (when final (setq jgy-agent-diff--finished t paths nil))
    (setq jgy-agent-diff--pending
          (if (or (null paths) (eq jgy-agent-diff--pending t)) t
            (delete-dups (append jgy-agent-diff--pending paths))))
    (when hints
      (let ((paths (delete-dups (mapcar #'car hints))))
        (setq jgy-agent-diff--focus (and (= (length paths) 1) (car paths)))))
    (dolist (hint hints)
      (setq jgy-agent-diff--hints
            (append (cl-remove (car hint) jgy-agent-diff--hints :key #'car :test #'equal)
                    (list hint))))
    (unless (or jgy-agent-diff--iterator (timerp jgy-agent-diff--timer))
      (let ((buffer (current-buffer)) (generation jgy-agent-diff--generation))
        (setq jgy-agent-diff--timer
              (run-with-timer
               (if final 0 0.15) nil
               (lambda ()
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (when (= generation jgy-agent-diff--generation)
                       (setq jgy-agent-diff--timer nil)
                       (jgy-agent-diff--start)))))))))))

(defun jgy-agent-diff-tool (id tool)
  "Consume a completed TOOL with ID, using explicit edits when available."
  (when (and jgy-agent-diff--repos jgy-agent-diff--seen
             (not jgy-agent-diff--finished)
             (member (map-elt tool :status) '("completed" "failed")))
    ;; Updates can enrich the same completed call later, so dedupe the payload,
    ;; not just the ID.  Read locations alone are never evidence of an edit.
    (let* ((kind (map-elt tool :kind))
           (diffs (map-elt tool :diffs))
           (locations (and (or diffs (member kind '("edit" "delete" "move")))
                           (map-elt tool :locations)))
           (fingerprint (secure-hash 'sha256
                                     (prin1-to-string
                                      (list kind (map-elt tool :status) diffs locations))))
           (root (plist-get (car jgy-agent-diff--repos) :dir))
           hints)
      (unless (and id (equal fingerprint (gethash id jgy-agent-diff--seen)))
        (when id (puthash id (copy-tree fingerprint) jgy-agent-diff--seen))
        (when root
          (dolist (item (append diffs nil))
            (when-let* ((path (map-elt item :file)))
              (push (cons (expand-file-name path root) (map-elt item :line)) hints)))
          (dolist (item (append locations nil))
            (when-let* ((path (map-elt item 'path)))
              (push (cons (expand-file-name path root) (map-elt item 'line)) hints)))
          (cond
           (hints (jgy-agent-diff-request (mapcar #'car hints) hints))
           ((not (member kind '("read" "search" "think" "fetch" "switch_mode")))
            (jgy-agent-diff-request))))))))

(iter-defun jgy-agent-diff--work (requested hints focus verify)
  "Scan REQUESTED paths or all paths (t), yielding external commands."
  (let (changed changed-paths)
    (dolist (repo jgy-agent-diff--repos)
      (condition-case err
          (let* ((dir (plist-get repo :dir))
                 (head (plist-get repo :head))
                 (base (plist-get repo :base))
                 (last (plist-get repo :last))
                 (stamps (or (plist-get repo :stamps)
                             (let ((table (make-hash-table :test #'equal)))
                               (setf (plist-get repo :stamps) table) table)))
                 (paths
                  (if (eq requested t)
                      (delete-dups
                       (append
                        (split-string
                         (if head
                             (jgy-agent-diff--await dir "git" "diff" "--name-only"
                                                   "--no-renames" "--relative" "-z" head "--" ".")
                           (jgy-agent-diff--await dir "git" "ls-files" "-z" "--cached" "--" ".")) "\0" t)
                        (split-string
                         (jgy-agent-diff--await dir "git" "ls-files" "-z" "--others"
                                               "--exclude-standard" "--" ".") "\0" t)
                        (hash-table-keys last)))
                    (mapcar (lambda (path) (file-relative-name path dir))
                            (cl-remove-if-not
                             (lambda (path)
                               ;; A nested repository owns its own files.
                               (eq repo (car (sort
                                              (cl-remove-if-not
                                               (lambda (candidate)
                                                 (string-prefix-p (plist-get candidate :dir) path))
                                               (copy-sequence jgy-agent-diff--repos))
                                              (lambda (a b) (> (length (plist-get a :dir))
                                                               (length (plist-get b :dir))))))))
                             requested)))))
            (dolist (name paths)
              (let* ((path (expand-file-name name dir))
                     (before (gethash name base 'unknown))
                     (hint (assoc path hints))
                     (stamp (jgy-agent-diff--stamp path))
                     ;; Honor the same ignored-file boundary on the fast path.
                     (ignored (and (not (eq requested t))
                                   (eq 0 (car (iter-yield
                                              (list dir "git" "check-ignore" "-q" "--" name)))))))
                (unless (or ignored
                            (and (not verify) (not hint)
                                 (equal stamp (gethash name stamps 'unknown))))
                  (when (eq before 'unknown)
                    (let* ((object (and head (concat head ":" (plist-get repo :prefix) name)))
                           (result (and object (iter-yield (list dir "git" "cat-file" "-s" object)))))
                      (setq before
                            (cond ((or (null result) (not (eq (car result) 0))) nil)
                                  ((> (string-to-number (cdr result)) jgy-agent-diff--limit) 'skip)
                                  (t (jgy-agent-diff--await dir "git" "show" object))))
                      (when (and (stringp before) (string-match-p "\0" before))
                        (setq before 'skip))
                      (puthash name before base)))
                  (let ((after (jgy-agent-diff--read path)))
                    (unless (equal after (gethash name last before))
                      (unless (or (eq before 'skip) (eq after 'skip))
                        (let ((old (make-temp-file "agent-before-"))
                              (new (make-temp-file "agent-after-")))
                          (setq jgy-agent-diff--temporary (list old new))
                          (unwind-protect
                              (let ((coding-system-for-write 'utf-8-unix))
                                (with-temp-file old (insert (or before "")))
                                (with-temp-file new (insert (or after "")))
                                (let* ((result (iter-yield
                                                (list dir "diff" "-u" "--label"
                                                      (if before (concat "a/" name) "/dev/null")
                                                      "--label" (if after (concat "b/" name) "/dev/null")
                                                      old new)))
                                       (patch (cdr result)))
                                  (unless (memq (car result) '(0 1)) (error "Cannot compute turn diff"))
                                  (when (and (string-empty-p patch) (not (eq (null before) (null after))))
                                    (setq patch (format "--- %s\n+++ %s\n"
                                                        (if before (concat "a/" name) "/dev/null")
                                                        (if after (concat "b/" name) "/dev/null"))))
                                  (let ((entry (jgy-agent-diff--entry path patch dir)))
                                    (when (and hint (integerp (cdr hint)))
                                      (setf (alist-get 'line entry) (cdr hint)))
                                    (setq jgy-agent-diff--files
                                          (append (cl-remove path jgy-agent-diff--files
                                                             :key (lambda (row) (alist-get 'file row)) :test #'equal)
                                                  (list entry))
                                          changed t)
                                    (push path changed-paths))))
                            (delete-file old) (delete-file new)
                            (setq jgy-agent-diff--temporary nil))))
                      (puthash name after last))
                    (puthash name stamp stamps))))))
        (error (message "Turn diff refresh failed: %s" (error-message-string err)))))
    ;; Only the most recent unambiguous edit chooses the focus.  Discovery
    ;; order from Git does not imply edit order.
    (when changed
      (setq jgy-agent-diff--files
            (mapcar (lambda (entry)
                      (let ((copy (copy-tree entry)))
                        (setf (alist-get 'active copy)
                              (and (member focus changed-paths)
                                   (equal (alist-get 'file copy) focus)))
                        copy)) jgy-agent-diff--files))
      (run-hooks 'jgy-agent-diff-update-hook))))

(defun jgy-agent-diff--start ()
  "Start queued work, with at most one iterator per agent."
  (when (and jgy-agent-diff--pending (not jgy-agent-diff--iterator))
    (setq jgy-agent-diff--iterator
          (jgy-agent-diff--work jgy-agent-diff--pending jgy-agent-diff--hints
                                jgy-agent-diff--focus jgy-agent-diff--finished)
          jgy-agent-diff--pending nil jgy-agent-diff--hints nil
          jgy-agent-diff--focus nil)
    (jgy-agent-diff--step nil)))

(defun jgy-agent-diff--step (result)
  "Resume the current scan with subprocess RESULT."
  (condition-case err
      (let* ((command (iter-next jgy-agent-diff--iterator result))
             (default-directory (car command))
             (owner (current-buffer))
             (generation jgy-agent-diff--generation)
             (output (generate-new-buffer " *turn-diff-output*")))
        (setq jgy-agent-diff--process
              (make-process
               :name "turn-diff" :buffer output :command (cdr command)
               :connection-type 'pipe :coding 'utf-8-unix :noquery t
               :sentinel
               (lambda (process _event)
                 (when (memq (process-status process) '(exit signal))
                   (let ((value (cons (process-exit-status process)
                                      (if (buffer-live-p output)
                                          (with-current-buffer output (buffer-string)) ""))))
                     (when (buffer-live-p output) (kill-buffer output))
                     (when (buffer-live-p owner)
                       (with-current-buffer owner
                         (when (= generation jgy-agent-diff--generation)
                           (setq jgy-agent-diff--process nil)
                           (jgy-agent-diff--step value))))))))))
    (iter-end-of-sequence
     (setq jgy-agent-diff--iterator nil)
     (jgy-agent-diff--start))
    (error
     (message "Turn diff worker failed: %s" (error-message-string err))
     (jgy-agent-diff-cancel))))

(provide 'jgy-agent-diff)
;;; jgy-agent-diff.el ends here
