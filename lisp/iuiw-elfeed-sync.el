;;; iuiw-elfeed-sync.el --- Sync elfeed state across machines through git -*- lexical-binding: t; -*-

;;; Commentary:
;; 几台机器各自抓 RSS，只同步对条目做的事：已读、星标和 AI 总结。每次变化追加一行到
;; `iuiw-sync' 仓库的 jsonl，同一条目以时间最晚的记录为准。启动、打开 elfeed、更新
;; 订阅时同步。
;; 每日摘要的生成在这里，任务的登记和显示在 `iuiw-elfeed-digest'。

;;; Code:

(require 'cl-lib)
(require 'elfeed)
(require 'elfeed-search)
(require 'iuiw-elfeed-ai)
(require 'iuiw-sync)
(require 'iuiw-daily)
(require 'iuiw-elfeed-digest)

(defgroup iuiw-elfeed-sync nil
  "Sync elfeed state across machines through git."
  :group 'elfeed)

(defcustom iuiw-elfeed-sync-tags '(unread star)
  "Tags synced across machines."
  :type '(repeat symbol))

(defvar iuiw-elfeed-sync--state (make-hash-table :test #'equal)
  "Entry id to its latest state record.")

(defvar iuiw-elfeed-sync--summaries (make-hash-table :test #'equal)
  "(KIND . entry id) to its latest summary record.")

(defvar iuiw-elfeed-sync--applying nil
  "Non-nil while synced records are applied, so tag changes are not recorded again.")

;;; Records

(defun iuiw-elfeed-sync--id (record)
  "Return the elfeed entry id RECORD is about."
  (cons (plist-get record :feed) (plist-get record :id)))

(defun iuiw-elfeed-sync--load ()
  "Read every record into the tables."
  (clrhash iuiw-elfeed-sync--state)
  (clrhash iuiw-elfeed-sync--summaries)
  (iuiw-sync-read
   "state" (lambda (record)
             (iuiw-sync-keep iuiw-elfeed-sync--state
                             (iuiw-elfeed-sync--id record) record)))
  (iuiw-sync-read
   "summaries" (lambda (record)
                 (iuiw-sync-keep iuiw-elfeed-sync--summaries
                                 (cons (intern (plist-get record :kind))
                                       (iuiw-elfeed-sync--id record))
                                 record))))

(defun iuiw-elfeed-sync--record (entry &rest props)
  "Return a record about ENTRY with PROPS."
  (let ((id (elfeed-entry-id entry)))
    (apply #'iuiw-sync-record :feed (car id) :id (cdr id) props)))

(defun iuiw-elfeed-sync--synced-tags (entry)
  "Return the synced tags ENTRY has."
  (cl-remove-if-not (lambda (tag) (elfeed-tagged-p tag entry)) iuiw-elfeed-sync-tags))

(defun iuiw-elfeed-sync--on-tag (adding entries tags)
  "Record ENTRIES' synced tags after TAGS are added, or removed unless ADDING."
  (unless iuiw-elfeed-sync--applying
    (when-let* ((tags (cl-intersection tags iuiw-elfeed-sync-tags)))
      (dolist (entry entries)
        (let* ((old (iuiw-elfeed-sync--synced-tags entry))
               (new (cl-remove-if-not
                     (lambda (tag) (if (memq tag tags) adding (memq tag old)))
                     iuiw-elfeed-sync-tags)))
          (unless (equal old new)
            (let ((record (iuiw-elfeed-sync--record
                           entry :tags (vconcat (mapcar #'symbol-name new)))))
              (puthash (elfeed-entry-id entry) record iuiw-elfeed-sync--state)
              (iuiw-sync-append "state" record))))))))

(defun iuiw-elfeed-sync--on-tag-add (entries tags)
  "Record ENTRIES gaining TAGS."
  (iuiw-elfeed-sync--on-tag t entries tags))

(defun iuiw-elfeed-sync--on-tag-remove (entries tags)
  "Record ENTRIES losing TAGS."
  (iuiw-elfeed-sync--on-tag nil entries tags))

(defun iuiw-elfeed-sync--on-summary (entry kind value)
  "Record ENTRY's summary of KIND.
See `iuiw-elfeed-ai-summary-functions' for VALUE."
  (let ((record (iuiw-elfeed-sync--record
                 entry :kind (symbol-name kind)
                 :backend (if (eq kind 'summary) (symbol-name (car value)) "")
                 :text (if (eq kind 'summary) (cdr value) value))))
    (puthash (cons kind (elfeed-entry-id entry)) record iuiw-elfeed-sync--summaries)
    (iuiw-sync-append "summaries" record)))

;;;###autoload
(defun iuiw-elfeed-sync-export-summaries ()
  "Record the summaries already in the elfeed database that the repo lacks."
  (interactive)
  (let ((count 0))
    (elfeed-db-visit (entry)
      (dolist (kind '(summary oneline))
        (when-let* ((value (elfeed-meta entry (if (eq kind 'summary)
                                                   :iuiw-ai-summary :iuiw-ai-oneline))))
          (unless (gethash (cons kind (elfeed-entry-id entry)) iuiw-elfeed-sync--summaries)
            (iuiw-elfeed-sync--on-summary entry kind value)
            (cl-incf count)))))
    (message "elfeed sync: exported %d summaries" count)))

;;; Applying

(defun iuiw-elfeed-sync--apply (entry)
  "Bring ENTRY in line with the synced records; return non-nil if it changed."
  (let ((id (elfeed-entry-id entry))
        changed)
    (when-let* ((record (gethash id iuiw-elfeed-sync--state)))
      (let ((want (mapcar #'intern (plist-get record :tags)))
            (iuiw-elfeed-sync--applying t))
        (dolist (tag iuiw-elfeed-sync-tags)
          (unless (eq (and (memq tag want) t) (and (elfeed-tagged-p tag entry) t))
            (if (memq tag want) (elfeed-tag entry tag) (elfeed-untag entry tag))
            (setq changed t)))))
    (when-let* ((record (gethash (cons 'summary id) iuiw-elfeed-sync--summaries)))
      (let ((value (cons (intern (plist-get record :backend)) (plist-get record :text))))
        (unless (equal value (elfeed-meta entry :iuiw-ai-summary))
          (setf (elfeed-meta entry :iuiw-ai-summary) value)
          (setq changed t))))
    (when-let* ((record (gethash (cons 'oneline id) iuiw-elfeed-sync--summaries)))
      (let ((value (plist-get record :text)))
        (unless (equal value (elfeed-meta entry :iuiw-ai-oneline))
          (setf (elfeed-meta entry :iuiw-ai-oneline) value)
          (setq changed t))))
    changed))

(defun iuiw-elfeed-sync--apply-all ()
  "Apply every record to the database and redraw what changed."
  (elfeed-db-ensure)
  (let (changed)
    (cl-flet ((visit (id)
                (when-let* ((entry (elfeed-db-get-entry id)))
                  (when (iuiw-elfeed-sync--apply entry)
                    (push entry changed)))))
      (maphash (lambda (id _) (visit id)) iuiw-elfeed-sync--state)
      (maphash (lambda (key _) (visit (cdr key))) iuiw-elfeed-sync--summaries))
    (when-let* ((buf (and changed (get-buffer "*elfeed-search*"))))
      (with-current-buffer buf
        (elfeed-search-update :force)))))

;;; Syncing

(defun iuiw-elfeed-sync--after-sync (_err)
  "Reread the records and apply them."
  (iuiw-elfeed-sync--load)
  (iuiw-elfeed-sync--apply-all))

;;; Digest

(defun iuiw-elfeed-sync--entries-since (time)
  "Return the newest entries dated after TIME.
At most `iuiw-elfeed-ai-digest-limit' entries."
  (let (entries)
    (elfeed-db-visit (entry)
      (when (or (<= (elfeed-entry-date entry) time)
                (>= (length entries) iuiw-elfeed-ai-digest-limit))
        (elfeed-db-return))
      (push entry entries))
    (nreverse entries)))

(defun iuiw-elfeed-sync--after-update (fn &optional waited)
  "Call FN once elfeed has fetched every feed, or after five minutes.
WAITED is the seconds waited so far."
  (if (or (zerop (elfeed-queue-count-total)) (> (or waited 0) 300))
      (funcall fn)
    (run-at-time 5 nil #'iuiw-elfeed-sync--after-update fn (+ (or waited 0) 5))))

(defun iuiw-elfeed-sync--write-digest (done)
  "Digest the entries since the last digest into today's file.
The digested entries are marked read.  Then call DONE with an error
message, or nil."
  (let* ((until (float-time))
         (entries (iuiw-elfeed-sync--entries-since (iuiw-elfeed-digest-since)))
         (file (iuiw-daily-file 'elfeed-digest))
         (backend iuiw-elfeed-ai-backend))
    (cl-flet ((finish (body)
                (make-directory (file-name-directory file) t)
                (let ((coding-system-for-write 'utf-8-unix))
                  (with-temp-file file
                    (insert (format "#+title: Elfeed 摘要 %s\n#+until: %.0f\n#+subtitle: %d 条 · %s · %s\n\n%s\n"
                                    (format-time-string "%F") until (length entries)
                                    backend iuiw-sync-host body))))
                (when entries
                  (elfeed-untag entries 'unread)
                  (when-let* ((buf (get-buffer "*elfeed-search*")))
                    (with-current-buffer buf (elfeed-search-update :force))))
                (funcall done nil)))
      (if (null entries)
          (finish "没有新条目。")
        (iuiw-elfeed-ai-digest-request
         entries
         (lambda (text err)
           (if text
               (finish (string-trim text))
             (funcall done err))))))))

(defun iuiw-elfeed-sync--run-digest (done)
  "Update the feeds, then write today's digest and call DONE."
  (elfeed-update)
  (iuiw-elfeed-sync--after-update (lambda () (iuiw-elfeed-sync--write-digest done)) 0))

;;; Mode

;;;###autoload
(define-minor-mode iuiw-elfeed-sync-mode
  "Sync elfeed read state and summaries through git."
  :global t
  (pcase-dolist (`(,hook ,fn ,depth)
                 '((elfeed-tag-hook iuiw-elfeed-sync--on-tag-add)
                   (elfeed-untag-hook iuiw-elfeed-sync--on-tag-remove)
                   (elfeed-new-entry-hook iuiw-elfeed-sync--apply 90)
                   (iuiw-elfeed-ai-summary-functions iuiw-elfeed-sync--on-summary)
                   (iuiw-sync-after-functions iuiw-elfeed-sync--after-sync)
                   (elfeed-update-init-hook iuiw-sync-soon)
                   (elfeed-search-mode-hook iuiw-sync-soon)))
    (if iuiw-elfeed-sync-mode (add-hook hook fn depth) (remove-hook hook fn))))

(provide 'iuiw-elfeed-sync)
;;; iuiw-elfeed-sync.el ends here
