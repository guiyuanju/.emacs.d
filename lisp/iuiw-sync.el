;;; iuiw-sync.el --- Share data across machines through a git repository -*- lexical-binding: t; -*-

;;; Commentary:
;; 几台机器共用一个 git 仓库存数据：记录追加到 jsonl，.gitattributes 的 merge=union
;; 让两台机器同时追加也不冲突；其他文件以先推上去的为准。改动后空闲时 push，退出
;; Emacs 时最多等 10 秒推完。每个用户按子目录分开，同步完成后经
;; `iuiw-sync-after-functions' 重读自己的数据。

;;; Code:

(require 'cl-lib)
(require 'json)

(defgroup iuiw-sync nil
  "Share data across machines through a git repository."
  :group 'convenience)

(defcustom iuiw-sync-directory (locate-user-emacs-file "sync/")
  "Local clone of the sync repository."
  :type 'directory)

(defcustom iuiw-sync-remote "https://github.com/guiyuanju/emacs-sync.git"
  "Repository cloned into `iuiw-sync-directory' when it is missing."
  :type 'string)

(defconst iuiw-sync--old-directory (locate-user-emacs-file "elfeed-sync/")
  "Where the clone lived when the repository was named elfeed-sync.")

(defcustom iuiw-sync-push-delay 120
  "Idle seconds after a change before it is pushed."
  :type 'natural)

(defvar iuiw-sync-host (car (split-string (system-name) "\\."))
  "This machine's name, as written into records.")

(defvar iuiw-sync-after-functions nil
  "Functions called with an error message, or nil, after each sync.")

;;; Records

(defun iuiw-sync-file (&rest parts)
  "Return PARTS joined under the sync directory."
  (expand-file-name (string-join parts "/") iuiw-sync-directory))

(defun iuiw-sync-newer-p (a b)
  "Return non-nil if record A supersedes record B."
  (let ((ta (plist-get a :t)) (tb (plist-get b :t)))
    (or (> ta tb) (and (= ta tb) (string> (plist-get a :host) (plist-get b :host))))))

(defun iuiw-sync-keep (table key record)
  "Store RECORD under KEY in TABLE unless a newer one is there."
  (let ((old (gethash key table)))
    (when (or (null old) (iuiw-sync-newer-p record old))
      (puthash key record table))))

(defun iuiw-sync-read (dir fn)
  "Call FN with each record in DIR's jsonl files."
  (dolist (file (ignore-errors (directory-files (iuiw-sync-file dir) t "\\.jsonl\\'")))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (dolist (line (split-string (buffer-string) "\n" t))
        (when-let* ((record (ignore-errors
                              (json-parse-string line :object-type 'plist
                                                 :array-type 'list :null-object nil))))
          (funcall fn record))))))

(defun iuiw-sync-record (&rest props)
  "Return a record with PROPS, stamped with the time and this host."
  (append (list :t (float-time) :host iuiw-sync-host) props))

(defun iuiw-sync-append (dir record)
  "Append RECORD to this month's file in DIR, then schedule a push."
  (when (file-directory-p iuiw-sync-directory)
    (let ((file (iuiw-sync-file dir (format-time-string "%Y-%m.jsonl")))
          (coding-system-for-write 'utf-8-unix))
      (make-directory (file-name-directory file) t)
      (write-region (concat (decode-coding-string (json-serialize record) 'utf-8) "\n")
                    nil file t 'silent))
    (iuiw-sync-schedule-push)))

;;; Git

(defun iuiw-sync--git (steps callback)
  "Run git STEPS in order in the sync directory.
Then call CALLBACK with an error message, or nil on success.
Each step is a list of git arguments; a step starting with :try may fail."
  (if (null steps)
      (funcall callback nil)
    (let* ((try (eq (car (car steps)) :try))
           (args (if try (cdr (car steps)) (car steps)))
           (default-directory (if (file-directory-p iuiw-sync-directory)
                                  iuiw-sync-directory
                                temporary-file-directory))
           (process-environment (cons "GIT_TERMINAL_PROMPT=0" process-environment))
           (buf (generate-new-buffer " *iuiw-sync*")))
      (make-process
       :name "iuiw-sync" :buffer buf :command (cons "git" args)
       :connection-type 'pipe :noquery t
       :sentinel (lambda (proc _event)
                   (unless (process-live-p proc)
                     (let ((out (with-current-buffer buf (string-trim (buffer-string)))))
                       (kill-buffer buf)
                       (if (or try (zerop (process-exit-status proc)))
                           (iuiw-sync--git (cdr steps) callback)
                         (funcall callback (format "git %s: %s" (car args) out))))))))))

(defvar iuiw-sync--running nil)
(defvar iuiw-sync--again nil)
(defvar iuiw-sync--callbacks nil)
(defvar iuiw-sync--last 0
  "When the last sync finished.")

(defun iuiw-sync--commit-message ()
  "Message for a sync commit: this host and the time."
  (format "%s %s" iuiw-sync-host (format-time-string "%F %T")))

(defun iuiw-sync--take-callbacks ()
  "Return the waiting callbacks and forget them."
  (prog1 iuiw-sync--callbacks (setq iuiw-sync--callbacks nil)))

;;;###autoload
(defun iuiw-sync (&optional callback)
  "Commit local changes, pull, push and run `iuiw-sync-after-functions'.
Then call CALLBACK with an error message, or nil on success."
  (interactive (list (lambda (err) (message "sync: %s" (or err "done")))))
  (when callback
    (setq iuiw-sync--callbacks (append iuiw-sync--callbacks (list callback))))
  (cond
   (iuiw-sync--running (setq iuiw-sync--again t))
   ((not (file-directory-p iuiw-sync-directory))
    (iuiw-sync--clone))
   (t
    (setq iuiw-sync--running t
          iuiw-sync--again nil)
    (let ((callbacks (iuiw-sync--take-callbacks)))
      (iuiw-sync--git
       `(("add" "-A")
         (:try "commit" "-q" "-m" ,(iuiw-sync--commit-message))
         ("pull" "-q" "--no-rebase" "--no-edit" "-X" "theirs")
         ("push" "-q"))
       (lambda (err)
         (setq iuiw-sync--running nil
               iuiw-sync--last (float-time))
         (run-hook-with-args 'iuiw-sync-after-functions err)
         (when (and err (not callbacks))
           (message "sync: %s" err))
         (dolist (cb callbacks) (funcall cb err))
         (when iuiw-sync--again (iuiw-sync))))))))

(defun iuiw-sync--clone ()
  "Clone the sync repository, then sync."
  (setq iuiw-sync--running t)
  (iuiw-sync--git
   `(("clone" "-q" ,iuiw-sync-remote ,(expand-file-name iuiw-sync-directory)))
   (lambda (err)
     (setq iuiw-sync--running nil)
     (if (not err)
         (iuiw-sync)
       (setq iuiw-sync--again nil)
       (let ((callbacks (iuiw-sync--take-callbacks)))
         (unless callbacks
           (message "sync: %s" err))
         (dolist (cb callbacks) (funcall cb err)))))))

(defun iuiw-sync-soon ()
  "Sync unless a sync finished within the last minute."
  (when (> (- (float-time) iuiw-sync--last) 60)
    (iuiw-sync)))

(defvar iuiw-sync--push-timer nil)

(defun iuiw-sync-schedule-push ()
  "Sync once Emacs has been idle for `iuiw-sync-push-delay' seconds."
  (unless iuiw-sync--push-timer
    (setq iuiw-sync--push-timer
          (run-with-idle-timer iuiw-sync-push-delay nil
                               (lambda ()
                                 (setq iuiw-sync--push-timer nil)
                                 (iuiw-sync))))))

(defun iuiw-sync--on-kill ()
  "Commit and push what is left, waiting at most 10 seconds."
  (when (file-directory-p iuiw-sync-directory)
    (let ((default-directory iuiw-sync-directory)
          (process-environment (cons "GIT_TERMINAL_PROMPT=0" process-environment)))
      (call-process "git" nil nil nil "add" "-A")
      (call-process "git" nil nil nil "commit" "-q" "-m" (iuiw-sync--commit-message))
      (when (string-match-p "ahead" (shell-command-to-string "git status -sb | head -1"))
        (let ((proc (start-process "iuiw-sync-push" nil "git" "push" "-q")))
          (with-timeout (10 (delete-process proc))
            (while (process-live-p proc)
              (accept-process-output proc 0.2))))))))

(defun iuiw-sync--migrate ()
  "Move the elfeed-sync clone to `iuiw-sync-directory'.
Then point it at `iuiw-sync-remote'."
  (when (and (file-directory-p iuiw-sync--old-directory)
             (not (file-exists-p iuiw-sync-directory)))
    (rename-file (directory-file-name iuiw-sync--old-directory)
                 (directory-file-name iuiw-sync-directory))
    (let ((default-directory iuiw-sync-directory))
      (call-process "git" nil nil nil "remote" "set-url" "origin" iuiw-sync-remote))))

;;;###autoload
(define-minor-mode iuiw-sync-mode
  "Push what is left in the sync repository when Emacs exits."
  :global t
  (if iuiw-sync-mode
      (progn
        (iuiw-sync--migrate)
        (add-hook 'kill-emacs-hook #'iuiw-sync--on-kill))
    (remove-hook 'kill-emacs-hook #'iuiw-sync--on-kill)))

(provide 'iuiw-sync)
;;; iuiw-sync.el ends here
