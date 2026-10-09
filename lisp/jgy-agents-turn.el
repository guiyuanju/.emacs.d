;;; jgy-agents-turn.el --- Git-backed per-turn file changes -*- lexical-binding: t; -*-

;;; Commentary:
;; Clean files use the starting commit.  Only dirty/untracked text is copied.
;; Cached patches survive commits; no writes to the repository index or refs.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'generator)
(require 'map)

(defvar-local jgy-agents-turn--repos nil)
(defvar-local jgy-agents-turn--files nil)
(defvar-local jgy-agents-turn--generation 0)
(defvar-local jgy-agents-turn--timer nil)
(defvar-local jgy-agents-turn--process nil)
(defvar-local jgy-agents-turn--iterator nil)
(defvar-local jgy-agents-turn--pending nil)
(defvar-local jgy-agents-turn--hints nil)
(defvar-local jgy-agents-turn--focus nil)
(defvar-local jgy-agents-turn--seen nil)
(defvar-local jgy-agents-turn--finished nil)
(defvar-local jgy-agents-turn--temporary nil)
(defvar jgy-agents-turn-update-hook nil
  "Hook run in the agent buffer when a scan changes file entries.")
(defconst jgy-agents-turn--limit (* 1024 1024)
  "Largest file whose contents are kept for turn diffs.")

(defun jgy-agents-turn--git (dir &rest args)
  "Run Git ARGS in DIR, returning stdout or signaling on failure."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (unless (eq 0 (apply #'process-file "git" nil (list t nil) nil args))
        (error "Cannot read Git turn baseline in %s" dir))
      (buffer-string))))

(defun jgy-agents-turn--changed-args (head)
  "Git arguments listing paths differing from HEAD, or tracked paths when nil."
  (if head
      (list "diff" "--name-only" "--no-renames" "--relative" "-z" head "--" ".")
    (list "ls-files" "-z" "--cached" "--" ".")))

(defun jgy-agents-turn--untracked-args ()
  "Git arguments listing untracked paths."
  '("ls-files" "-z" "--others" "--exclude-standard" "--" "."))

(defun jgy-agents-turn--paths (repo)
  "Paths differing from REPO's original commit, plus untracked paths."
  (let ((dir (plist-get repo :dir)) (head (plist-get repo :head)))
    (delete-dups
     (apply #'append
            (mapcar (lambda (args)
                      (split-string (apply #'jgy-agents-turn--git dir args) "\0" t))
                    (list (jgy-agents-turn--changed-args head)
                          (jgy-agents-turn--untracked-args)))))))

(defun jgy-agents-turn--read (path)
  "Read PATH as text, nil if absent, or `skip' for unsupported files."
  (cond
   ((file-symlink-p path) 'skip)
   ((not (file-exists-p path)) nil)
   ((or (not (file-regular-p path))
        (> (file-attribute-size (file-attributes path)) jgy-agents-turn--limit)) 'skip)
   (t (with-temp-buffer
        (insert-file-contents path)
        (if (search-forward "\0" nil t) 'skip (buffer-string))))))

(defun jgy-agents-turn--stamp (path)
  "Cheap change hint for PATH; final verification never trusts this alone."
  (let ((attributes (file-attributes path)))
    (list (file-attribute-type attributes)
          (file-attribute-size attributes)
          (file-attribute-modification-time attributes)
          (file-attribute-status-change-time attributes)
          (file-attribute-inode-number attributes))))

(defun jgy-agents-turn-begin (root)
  "Start a turn in ROOT, saving only existing dirty/untracked contents."
  (jgy-agents-turn-cancel)
  (setq jgy-agents-turn--repos nil jgy-agents-turn--files nil
        jgy-agents-turn--finished nil
        jgy-agents-turn--seen (make-hash-table :test #'equal))
  (add-hook 'kill-buffer-hook #'jgy-agents-turn-cancel nil t)
  (dolist (dir (cons root
                    (cl-remove-if-not
                     (lambda (path) (file-exists-p (expand-file-name ".git" path)))
                     (directory-files root t "\\`[^.]" t))))
    (condition-case err
        (let* ((prefix (string-trim-right (jgy-agents-turn--git dir "rev-parse" "--show-prefix")))
               (repo (list :dir (file-name-as-directory dir) :prefix prefix
                           :head (ignore-errors
                                   (string-trim (jgy-agents-turn--git dir "rev-parse" "--verify" "HEAD")))
                           :base (make-hash-table :test #'equal)
                           :last (make-hash-table :test #'equal)
                           :stamps (make-hash-table :test #'equal))))
          (dolist (name (jgy-agents-turn--paths repo))
            (let* ((path (expand-file-name name dir))
                   (stamp (jgy-agents-turn--stamp path))
                   (text (jgy-agents-turn--read path)))
              (puthash name stamp (plist-get repo :stamps))
              (puthash name text (plist-get repo :base))
              (puthash name text (plist-get repo :last))))
          (push repo jgy-agents-turn--repos))
      (error (message "Turn diff unavailable: %s" (error-message-string err)))))
  (setq jgy-agents-turn--repos (nreverse jgy-agents-turn--repos)))

(defun jgy-agents-turn--entry (path patch directory)
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
(defmacro jgy-agents-turn--await (directory command)
  "Yield COMMAND, a full argv list, in DIRECTORY; return stdout, or signal."
  `(let* ((command ,command)
          (result (iter-yield (cons ,directory command))))
     (unless (eq (car result) 0)
       (error "Turn diff command failed: %s" (cadr command)))
     (cdr result)))

(defun jgy-agents-turn-cancel ()
  "Invalidate this turn's callbacks and release its pending work."
  (cl-incf jgy-agents-turn--generation)
  (when (timerp jgy-agents-turn--timer) (cancel-timer jgy-agents-turn--timer))
  (when (processp jgy-agents-turn--process)
    (set-process-sentinel jgy-agents-turn--process #'ignore)
    (delete-process jgy-agents-turn--process)
    (when (buffer-live-p (process-buffer jgy-agents-turn--process))
      (kill-buffer (process-buffer jgy-agents-turn--process))))
  (when jgy-agents-turn--iterator (iter-close jgy-agents-turn--iterator))
  (dolist (path jgy-agents-turn--temporary) (ignore-errors (delete-file path)))
  (setq jgy-agents-turn--timer nil jgy-agents-turn--process nil
        jgy-agents-turn--iterator nil jgy-agents-turn--pending nil
        jgy-agents-turn--hints nil jgy-agents-turn--focus nil
        jgy-agents-turn--temporary nil))

(defun jgy-agents-turn-request (&optional paths hints final)
  "Queue PATHS, or a full scan if nil; HINTS are (PATH . LINE).
FINAL requests a last full verification and stops accepting tool events."
  (unless jgy-agents-turn--finished
    (when final (setq jgy-agents-turn--finished t paths nil))
    (setq jgy-agents-turn--pending
          (if (or (null paths) (eq jgy-agents-turn--pending t)) t
            (delete-dups (append jgy-agents-turn--pending paths))))
    (when hints
      (let ((paths (delete-dups (mapcar #'car hints))))
        (setq jgy-agents-turn--focus (and (= (length paths) 1) (car paths)))))
    (dolist (hint hints)
      (setq jgy-agents-turn--hints
            (append (cl-remove (car hint) jgy-agents-turn--hints :key #'car :test #'equal)
                    (list hint))))
    (unless (or jgy-agents-turn--iterator (timerp jgy-agents-turn--timer))
      (let ((buffer (current-buffer)) (generation jgy-agents-turn--generation))
        (setq jgy-agents-turn--timer
              (run-with-timer
               (if final 0 0.15) nil
               (lambda ()
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (when (= generation jgy-agents-turn--generation)
                       (setq jgy-agents-turn--timer nil)
                       (jgy-agents-turn--start)))))))))))

(defun jgy-agents-turn-tool (id tool)
  "Consume a completed TOOL with ID, using explicit edits when available."
  (when (and jgy-agents-turn--repos jgy-agents-turn--seen
             (not jgy-agents-turn--finished)
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
           (root (plist-get (car jgy-agents-turn--repos) :dir))
           hints)
      (unless (and id (equal fingerprint (gethash id jgy-agents-turn--seen)))
        (when id (puthash id (copy-tree fingerprint) jgy-agents-turn--seen))
        (when root
          (dolist (item (append diffs nil))
            (when-let* ((path (map-elt item :file)))
              (push (cons (expand-file-name path root) (map-elt item :line)) hints)))
          (dolist (item (append locations nil))
            (when-let* ((path (map-elt item 'path)))
              (push (cons (expand-file-name path root) (map-elt item 'line)) hints)))
          (cond
           (hints (jgy-agents-turn-request (mapcar #'car hints) hints))
           ((not (member kind '("read" "search" "think" "fetch" "switch_mode")))
            (jgy-agents-turn-request))))))))

(iter-defun jgy-agents-turn--work (requested hints focus verify)
  "Scan REQUESTED paths or all paths (t), yielding external commands."
  (let (changed changed-paths)
    (dolist (repo jgy-agents-turn--repos)
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
                         (jgy-agents-turn--await
                          dir (cons "git" (jgy-agents-turn--changed-args head))) "\0" t)
                        (split-string
                         (jgy-agents-turn--await
                          dir (cons "git" (jgy-agents-turn--untracked-args))) "\0" t)
                        (hash-table-keys last)))
                    (mapcar (lambda (path) (file-relative-name path dir))
                            (cl-remove-if-not
                             (lambda (path)
                               ;; A nested repository owns its own files.
                               (eq repo (car (sort
                                              (cl-remove-if-not
                                               (lambda (candidate)
                                                 (string-prefix-p (plist-get candidate :dir) path))
                                               (copy-sequence jgy-agents-turn--repos))
                                              (lambda (a b) (> (length (plist-get a :dir))
                                                               (length (plist-get b :dir))))))))
                             requested)))))
            (dolist (name paths)
              (let* ((path (expand-file-name name dir))
                     (before (gethash name base 'unknown))
                     (hint (assoc path hints))
                     (stamp (jgy-agents-turn--stamp path))
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
                                  ((> (string-to-number (cdr result)) jgy-agents-turn--limit) 'skip)
                                  (t (jgy-agents-turn--await dir (list "git" "show" object)))))
                      (when (and (stringp before) (string-match-p "\0" before))
                        (setq before 'skip))
                      (puthash name before base)))
                  (let ((after (jgy-agents-turn--read path)))
                    (unless (equal after (gethash name last before))
                      (unless (or (eq before 'skip) (eq after 'skip))
                        (let ((old (make-temp-file "agent-before-"))
                              (new (make-temp-file "agent-after-")))
                          (setq jgy-agents-turn--temporary (list old new))
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
                                  (let ((entry (jgy-agents-turn--entry path patch dir)))
                                    (when (and hint (integerp (cdr hint)))
                                      (setf (alist-get 'line entry) (cdr hint)))
                                    (setq jgy-agents-turn--files
                                          (append (cl-remove path jgy-agents-turn--files
                                                             :key (lambda (row) (alist-get 'file row)) :test #'equal)
                                                  (list entry))
                                          changed t)
                                    (push path changed-paths))))
                            (delete-file old) (delete-file new)
                            (setq jgy-agents-turn--temporary nil))))
                      (puthash name after last))
                    (puthash name stamp stamps))))))
        (error (message "Turn diff refresh failed: %s" (error-message-string err)))))
    ;; Only the most recent unambiguous edit chooses the focus.  Discovery
    ;; order from Git does not imply edit order.
    (when changed
      (setq jgy-agents-turn--files
            (mapcar (lambda (entry)
                      (let ((copy (copy-tree entry)))
                        (setf (alist-get 'active copy)
                              (and (member focus changed-paths)
                                   (equal (alist-get 'file copy) focus)))
                        copy)) jgy-agents-turn--files))
      (run-hooks 'jgy-agents-turn-update-hook))))

(defun jgy-agents-turn--start ()
  "Start queued work, with at most one iterator per agent."
  (when (and jgy-agents-turn--pending (not jgy-agents-turn--iterator))
    (setq jgy-agents-turn--iterator
          (jgy-agents-turn--work jgy-agents-turn--pending jgy-agents-turn--hints
                                jgy-agents-turn--focus jgy-agents-turn--finished)
          jgy-agents-turn--pending nil jgy-agents-turn--hints nil
          jgy-agents-turn--focus nil)
    (jgy-agents-turn--step nil)))

(defun jgy-agents-turn--step (result)
  "Resume the current scan with subprocess RESULT."
  (condition-case err
      (let* ((command (iter-next jgy-agents-turn--iterator result))
             (default-directory (car command))
             (owner (current-buffer))
             (generation jgy-agents-turn--generation)
             (output (generate-new-buffer " *turn-diff-output*")))
        (setq jgy-agents-turn--process
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
                         (when (= generation jgy-agents-turn--generation)
                           (setq jgy-agents-turn--process nil)
                           (jgy-agents-turn--step value))))))))))
    (iter-end-of-sequence
     (setq jgy-agents-turn--iterator nil)
     (jgy-agents-turn--start))
    (error
     (message "Turn diff worker failed: %s" (error-message-string err))
     (jgy-agents-turn-cancel))))

(provide 'jgy-agents-turn)
;;; jgy-agents-turn.el ends here
