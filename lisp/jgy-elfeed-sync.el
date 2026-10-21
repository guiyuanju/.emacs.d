;;; jgy-elfeed-sync.el --- Sync elfeed state across machines through git -*- lexical-binding: t; -*-

;;; Commentary:
;; 几台机器各自抓 RSS，只同步对条目做的事：已读、星标和 AI 总结。每次变化追加一行到
;; git 仓库的 jsonl，同一条目以时间最晚的记录为准；.gitattributes 的 merge=union 让
;; 两台机器同时追加也不冲突。改动后空闲时 push；启动、打开 elfeed、更新订阅时 pull。
;; 每小时检查一次今天的摘要，没有就更新订阅、生成并推上去，先推上去的机器为准。
;; gd 在侧边打开最新一份摘要。

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'elfeed)
(require 'elfeed-search)
(require 'jgy-elfeed-ai)

(defgroup jgy-elfeed-sync nil
  "Sync elfeed state across machines through git."
  :group 'elfeed)

(defcustom jgy-elfeed-sync-directory (locate-user-emacs-file "elfeed-sync/")
  "Local clone of the sync repository."
  :type 'directory)

(defcustom jgy-elfeed-sync-remote "https://github.com/guiyuanju/elfeed-sync.git"
  "Repository cloned into `jgy-elfeed-sync-directory' when it is missing."
  :type 'string)

(defcustom jgy-elfeed-sync-tags '(unread star)
  "Tags synced across machines."
  :type '(repeat symbol))

(defcustom jgy-elfeed-sync-push-delay 120
  "Idle seconds after a change before it is pushed."
  :type 'natural)

(defcustom jgy-elfeed-sync-check-interval 3600
  "Seconds between checks for today's digest."
  :type 'natural)

(defvar jgy-elfeed-sync--host (car (split-string (system-name) "\\.")))

(defvar jgy-elfeed-sync--state (make-hash-table :test #'equal)
  "Entry id to its latest state record.")

(defvar jgy-elfeed-sync--summaries (make-hash-table :test #'equal)
  "(KIND . entry id) to its latest summary record.")

(defvar jgy-elfeed-sync--applying nil
  "Non-nil while synced records are applied, so tag changes are not recorded again.")

;;; Records

(defun jgy-elfeed-sync--file (&rest parts)
  "Return PARTS joined under the sync directory."
  (expand-file-name (string-join parts "/") jgy-elfeed-sync-directory))

(defun jgy-elfeed-sync--newer-p (a b)
  "Return non-nil if record A supersedes record B."
  (let ((ta (plist-get a :t)) (tb (plist-get b :t)))
    (or (> ta tb) (and (= ta tb) (string> (plist-get a :host) (plist-get b :host))))))

(defun jgy-elfeed-sync--keep (table key record)
  "Store RECORD under KEY in TABLE unless a newer one is there."
  (let ((old (gethash key table)))
    (when (or (null old) (jgy-elfeed-sync--newer-p record old))
      (puthash key record table))))

(defun jgy-elfeed-sync--id (record)
  "Return the elfeed entry id RECORD is about."
  (cons (plist-get record :feed) (plist-get record :id)))

(defun jgy-elfeed-sync--read (dir fn)
  "Call FN with each record in DIR's jsonl files."
  (dolist (file (ignore-errors
                  (directory-files (jgy-elfeed-sync--file dir) t "\\.jsonl\\'")))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (dolist (line (split-string (buffer-string) "\n" t))
        (when-let* ((record (ignore-errors
                              (json-parse-string line :object-type 'plist
                                                 :array-type 'list :null-object nil))))
          (funcall fn record))))))

(defun jgy-elfeed-sync--load ()
  "Read every record into the tables."
  (clrhash jgy-elfeed-sync--state)
  (clrhash jgy-elfeed-sync--summaries)
  (jgy-elfeed-sync--read
   "state" (lambda (record)
             (jgy-elfeed-sync--keep jgy-elfeed-sync--state
                                    (jgy-elfeed-sync--id record) record)))
  (jgy-elfeed-sync--read
   "summaries" (lambda (record)
                 (jgy-elfeed-sync--keep jgy-elfeed-sync--summaries
                                        (cons (intern (plist-get record :kind))
                                              (jgy-elfeed-sync--id record))
                                        record))))

(defun jgy-elfeed-sync--record (entry &rest props)
  "Return a record about ENTRY with PROPS."
  (let ((id (elfeed-entry-id entry)))
    (append (list :t (float-time) :host jgy-elfeed-sync--host
                  :feed (car id) :id (cdr id))
            props)))

(defun jgy-elfeed-sync--append (dir record)
  "Append RECORD to this month's file in DIR, then schedule a push."
  (when (file-directory-p jgy-elfeed-sync-directory)
    (let ((file (jgy-elfeed-sync--file dir (format-time-string "%Y-%m.jsonl")))
          (coding-system-for-write 'utf-8-unix))
      (make-directory (file-name-directory file) t)
      (write-region (concat (decode-coding-string (json-serialize record) 'utf-8) "\n")
                    nil file t 'silent))
    (jgy-elfeed-sync--schedule-push)))

(defun jgy-elfeed-sync--synced-tags (entry)
  "Return the synced tags ENTRY has."
  (cl-remove-if-not (lambda (tag) (elfeed-tagged-p tag entry)) jgy-elfeed-sync-tags))

(defun jgy-elfeed-sync--on-tag (adding entries tags)
  "Record ENTRIES' synced tags after TAGS are added, or removed unless ADDING."
  (unless jgy-elfeed-sync--applying
    (when-let* ((tags (cl-intersection tags jgy-elfeed-sync-tags)))
      (dolist (entry entries)
        (let* ((old (jgy-elfeed-sync--synced-tags entry))
               (new (cl-remove-if-not
                     (lambda (tag) (if (memq tag tags) adding (memq tag old)))
                     jgy-elfeed-sync-tags)))
          (unless (equal old new)
            (let ((record (jgy-elfeed-sync--record
                           entry :tags (vconcat (mapcar #'symbol-name new)))))
              (puthash (elfeed-entry-id entry) record jgy-elfeed-sync--state)
              (jgy-elfeed-sync--append "state" record))))))))

(defun jgy-elfeed-sync--on-tag-add (entries tags)
  "Record ENTRIES gaining TAGS."
  (jgy-elfeed-sync--on-tag t entries tags))

(defun jgy-elfeed-sync--on-tag-remove (entries tags)
  "Record ENTRIES losing TAGS."
  (jgy-elfeed-sync--on-tag nil entries tags))

(defun jgy-elfeed-sync--on-summary (entry kind value)
  "Record ENTRY's summary of KIND, see `jgy-elfeed-ai-summary-functions' for VALUE."
  (let ((record (jgy-elfeed-sync--record
                 entry :kind (symbol-name kind)
                 :backend (if (eq kind 'summary) (symbol-name (car value)) "")
                 :text (if (eq kind 'summary) (cdr value) value))))
    (puthash (cons kind (elfeed-entry-id entry)) record jgy-elfeed-sync--summaries)
    (jgy-elfeed-sync--append "summaries" record)))

;;;###autoload
(defun jgy-elfeed-sync-export-summaries ()
  "Record the summaries already in the elfeed database that the repo lacks."
  (interactive)
  (let ((count 0))
    (elfeed-db-visit (entry)
      (dolist (kind '(summary oneline))
        (when-let* ((value (elfeed-meta entry (if (eq kind 'summary)
                                                   :jgy-ai-summary :jgy-ai-oneline))))
          (unless (gethash (cons kind (elfeed-entry-id entry)) jgy-elfeed-sync--summaries)
            (jgy-elfeed-sync--on-summary entry kind value)
            (cl-incf count)))))
    (message "elfeed sync: exported %d summaries" count)))

;;; Applying

(defun jgy-elfeed-sync--apply (entry)
  "Bring ENTRY in line with the synced records; return non-nil if it changed."
  (let ((id (elfeed-entry-id entry))
        changed)
    (when-let* ((record (gethash id jgy-elfeed-sync--state)))
      (let ((want (mapcar #'intern (plist-get record :tags)))
            (jgy-elfeed-sync--applying t))
        (dolist (tag jgy-elfeed-sync-tags)
          (unless (eq (and (memq tag want) t) (and (elfeed-tagged-p tag entry) t))
            (if (memq tag want) (elfeed-tag entry tag) (elfeed-untag entry tag))
            (setq changed t)))))
    (when-let* ((record (gethash (cons 'summary id) jgy-elfeed-sync--summaries)))
      (let ((value (cons (intern (plist-get record :backend)) (plist-get record :text))))
        (unless (equal value (elfeed-meta entry :jgy-ai-summary))
          (setf (elfeed-meta entry :jgy-ai-summary) value)
          (setq changed t))))
    (when-let* ((record (gethash (cons 'oneline id) jgy-elfeed-sync--summaries)))
      (let ((value (plist-get record :text)))
        (unless (equal value (elfeed-meta entry :jgy-ai-oneline))
          (setf (elfeed-meta entry :jgy-ai-oneline) value)
          (setq changed t))))
    changed))

(defun jgy-elfeed-sync--apply-all ()
  "Apply every record to the database and redraw what changed."
  (elfeed-db-ensure)
  (let (changed)
    (cl-flet ((visit (id)
                (when-let* ((entry (elfeed-db-get-entry id)))
                  (when (jgy-elfeed-sync--apply entry)
                    (push entry changed)))))
      (maphash (lambda (id _) (visit id)) jgy-elfeed-sync--state)
      (maphash (lambda (key _) (visit (cdr key))) jgy-elfeed-sync--summaries))
    (when-let* ((buf (and changed (get-buffer "*elfeed-search*"))))
      (with-current-buffer buf
        (elfeed-search-update :force)))))

;;; Git

(defun jgy-elfeed-sync--git (steps callback)
  "Run git STEPS in order in the sync directory.
Then call CALLBACK with an error message, or nil on success.
Each step is a list of git arguments; a step starting with :try may fail."
  (if (null steps)
      (funcall callback nil)
    (let* ((try (eq (car (car steps)) :try))
           (args (if try (cdr (car steps)) (car steps)))
           (default-directory (if (file-directory-p jgy-elfeed-sync-directory)
                                  jgy-elfeed-sync-directory
                                temporary-file-directory))
           (process-environment (cons "GIT_TERMINAL_PROMPT=0" process-environment))
           (buf (generate-new-buffer " *jgy-elfeed-sync*")))
      (make-process
       :name "jgy-elfeed-sync" :buffer buf :command (cons "git" args)
       :connection-type 'pipe :noquery t
       :sentinel (lambda (proc _event)
                   (unless (process-live-p proc)
                     (let ((out (with-current-buffer buf (string-trim (buffer-string)))))
                       (kill-buffer buf)
                       (if (or try (zerop (process-exit-status proc)))
                           (jgy-elfeed-sync--git (cdr steps) callback)
                         (funcall callback (format "git %s: %s" (car args) out))))))))))

(defvar jgy-elfeed-sync--running nil)
(defvar jgy-elfeed-sync--again nil)
(defvar jgy-elfeed-sync--callbacks nil)
(defvar jgy-elfeed-sync--last 0
  "When the last sync finished.")

;;;###autoload
(defun jgy-elfeed-sync (&optional callback)
  "Commit local records, pull, apply and push.
Then call CALLBACK with an error message, or nil on success."
  (interactive (list (lambda (err) (message "elfeed sync: %s" (or err "done")))))
  (when callback
    (setq jgy-elfeed-sync--callbacks (append jgy-elfeed-sync--callbacks (list callback))))
  (cond
   (jgy-elfeed-sync--running (setq jgy-elfeed-sync--again t))
   ((not (file-directory-p jgy-elfeed-sync-directory))
    (jgy-elfeed-sync--clone))
   (t
    (setq jgy-elfeed-sync--running t
          jgy-elfeed-sync--again nil)
    (let ((callbacks (prog1 jgy-elfeed-sync--callbacks
                       (setq jgy-elfeed-sync--callbacks nil))))
      (jgy-elfeed-sync--git
       `(("add" "-A")
         (:try "commit" "-q" "-m" ,(format "%s %s" jgy-elfeed-sync--host
                                            (format-time-string "%F %T")))
         ("pull" "-q" "--no-rebase" "--no-edit" "-X" "theirs")
         ("push" "-q"))
       (lambda (err)
         (setq jgy-elfeed-sync--running nil
               jgy-elfeed-sync--last (float-time))
         (jgy-elfeed-sync--load)
         (jgy-elfeed-sync--apply-all)
         (when (and err (not callbacks))
           (message "elfeed sync: %s" err))
         (dolist (cb callbacks) (funcall cb err))
         (when jgy-elfeed-sync--again (jgy-elfeed-sync))))))))

(defun jgy-elfeed-sync--clone ()
  "Clone the sync repository, then sync."
  (setq jgy-elfeed-sync--running t)
  (jgy-elfeed-sync--git
   `(("clone" "-q" ,jgy-elfeed-sync-remote ,(expand-file-name jgy-elfeed-sync-directory)))
   (lambda (err)
     (setq jgy-elfeed-sync--running nil)
     (if err
         (message "elfeed sync: %s" err)
       (jgy-elfeed-sync)))))

(defun jgy-elfeed-sync-soon ()
  "Sync unless a sync finished within the last minute."
  (when (> (- (float-time) jgy-elfeed-sync--last) 60)
    (jgy-elfeed-sync)))

(defvar jgy-elfeed-sync--push-timer nil)

(defun jgy-elfeed-sync--schedule-push ()
  "Sync once Emacs has been idle for `jgy-elfeed-sync-push-delay' seconds."
  (unless jgy-elfeed-sync--push-timer
    (setq jgy-elfeed-sync--push-timer
          (run-with-idle-timer jgy-elfeed-sync-push-delay nil
                               (lambda ()
                                 (setq jgy-elfeed-sync--push-timer nil)
                                 (jgy-elfeed-sync))))))

(defun jgy-elfeed-sync--on-kill ()
  "Commit and push what is left, waiting at most 10 seconds."
  (when (file-directory-p jgy-elfeed-sync-directory)
    (let ((default-directory jgy-elfeed-sync-directory)
          (process-environment (cons "GIT_TERMINAL_PROMPT=0" process-environment)))
      (call-process "git" nil nil nil "add" "-A")
      (call-process "git" nil nil nil "commit" "-q" "-m"
                    (format "%s %s" jgy-elfeed-sync--host (format-time-string "%F %T")))
      (when (string-match-p "ahead" (shell-command-to-string "git status -sb | head -1"))
        (let ((proc (start-process "jgy-elfeed-sync-push" nil "git" "push" "-q")))
          (with-timeout (10 (delete-process proc))
            (while (process-live-p proc)
              (accept-process-output proc 0.2))))))))

;;; Digest

(defvar jgy-elfeed-sync--digesting nil)

(defun jgy-elfeed-sync--digests ()
  "Return the digest files, oldest first."
  (ignore-errors (directory-files (jgy-elfeed-sync--file "digest") t "\\.org\\'")))

(defun jgy-elfeed-sync--since ()
  "Return when the latest digest was written, or a day ago if none was."
  (or (when-let* ((file (car (last (jgy-elfeed-sync--digests)))))
        (with-temp-buffer
          (insert-file-contents file)
          (when (re-search-forward "^#\\+until: \\([0-9.]+\\)" nil t)
            (string-to-number (match-string 1)))))
      (- (float-time) 86400)))

(defun jgy-elfeed-sync--entries-since (time)
  "Return the newest entries dated after TIME.
At most `jgy-elfeed-ai-digest-limit' entries."
  (let (entries)
    (elfeed-db-visit (entry)
      (when (or (<= (elfeed-entry-date entry) time)
                (>= (length entries) jgy-elfeed-ai-digest-limit))
        (elfeed-db-return))
      (push entry entries))
    (nreverse entries)))

(defun jgy-elfeed-sync--after-update (fn &optional waited)
  "Call FN once elfeed has fetched every feed, or after five minutes.
WAITED is the seconds waited so far."
  (if (or (zerop (elfeed-queue-count-total)) (> (or waited 0) 300))
      (funcall fn)
    (run-at-time 5 nil #'jgy-elfeed-sync--after-update fn (+ (or waited 0) 5))))

(defun jgy-elfeed-sync--write-digest ()
  "Digest the entries since the last digest into today's file, then sync."
  (let* ((until (float-time))
         (entries (jgy-elfeed-sync--entries-since (jgy-elfeed-sync--since)))
         (file (jgy-elfeed-sync--file (format-time-string "digest/%F.org")))
         (backend jgy-elfeed-ai-backend))
    (cl-flet ((finish (body)
                (make-directory (file-name-directory file) t)
                (let ((coding-system-for-write 'utf-8-unix))
                  (with-temp-file file
                    (insert (format "#+title: Elfeed 摘要 %s\n#+until: %.0f\n#+subtitle: %d 条 · %s · %s\n\n%s\n"
                                    (format-time-string "%F") until (length entries)
                                    backend jgy-elfeed-sync--host body))))
                (setq jgy-elfeed-sync--digesting nil)
                (jgy-elfeed-sync)
                (message "elfeed: 今日摘要已生成，在 elfeed 里按 gd 查看")))
      (if (null entries)
          (finish "没有新条目。")
        (jgy-elfeed-ai-digest-request
         entries
         (lambda (text err)
           (if text
               (finish (string-trim text))
             (setq jgy-elfeed-sync--digesting nil)
             (message "elfeed digest failed: %s" err))))))))

;;;###autoload
(defun jgy-elfeed-sync-check ()
  "Sync, then write today's digest unless some machine already has."
  (interactive)
  (unless jgy-elfeed-sync--digesting
    (setq jgy-elfeed-sync--digesting t)
    (jgy-elfeed-sync
     (lambda (err)
       (when err (message "elfeed sync: %s" err))
       (if (or err (file-exists-p (jgy-elfeed-sync--file (format-time-string "digest/%F.org"))))
           (setq jgy-elfeed-sync--digesting nil)
         (elfeed-update)
         (jgy-elfeed-sync--after-update #'jgy-elfeed-sync--write-digest 0))))))

;;;###autoload
(defun jgy-elfeed-sync-open-digest ()
  "Show the latest digest in a side window."
  (interactive)
  (let ((file (car (last (jgy-elfeed-sync--digests))))
        (buf (get-buffer-create "*elfeed-digest*")))
    (unless file (user-error "No digest yet"))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-file-contents file)
        (jgy-elfeed-ai-digest-mode)))
    (select-window (display-buffer buf '(display-buffer-in-side-window
                                         (side . right) (window-width . 0.4))))))

;;; Mode

(defvar jgy-elfeed-sync--check-timer nil)

;;;###autoload
(define-minor-mode jgy-elfeed-sync-mode
  "Sync elfeed read state, summaries and daily digests through git."
  :global t
  (when (timerp jgy-elfeed-sync--check-timer)
    (cancel-timer jgy-elfeed-sync--check-timer))
  (setq jgy-elfeed-sync--check-timer nil)
  (if jgy-elfeed-sync-mode
      (progn
        (add-hook 'elfeed-tag-hook #'jgy-elfeed-sync--on-tag-add)
        (add-hook 'elfeed-untag-hook #'jgy-elfeed-sync--on-tag-remove)
        (add-hook 'elfeed-new-entry-hook #'jgy-elfeed-sync--apply 90)
        (add-hook 'jgy-elfeed-ai-summary-functions #'jgy-elfeed-sync--on-summary)
        (add-hook 'elfeed-update-init-hook #'jgy-elfeed-sync-soon)
        (add-hook 'elfeed-search-mode-hook #'jgy-elfeed-sync-soon)
        (add-hook 'kill-emacs-hook #'jgy-elfeed-sync--on-kill)
        (setq jgy-elfeed-sync--check-timer
              (run-at-time 30 jgy-elfeed-sync-check-interval #'jgy-elfeed-sync-check)))
    (remove-hook 'elfeed-tag-hook #'jgy-elfeed-sync--on-tag-add)
    (remove-hook 'elfeed-untag-hook #'jgy-elfeed-sync--on-tag-remove)
    (remove-hook 'elfeed-new-entry-hook #'jgy-elfeed-sync--apply)
    (remove-hook 'jgy-elfeed-ai-summary-functions #'jgy-elfeed-sync--on-summary)
    (remove-hook 'elfeed-update-init-hook #'jgy-elfeed-sync-soon)
    (remove-hook 'elfeed-search-mode-hook #'jgy-elfeed-sync-soon)
    (remove-hook 'kill-emacs-hook #'jgy-elfeed-sync--on-kill)))

(provide 'jgy-elfeed-sync)
;;; jgy-elfeed-sync.el ends here
