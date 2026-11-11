;;; iuiw-daily.el --- Tasks that write one file a day -*- lexical-binding: t; -*-

;;; Commentary:
;; 模块用 `iuiw-daily-define' 登记任务怎么生成，`iuiw-daily-schedule' 配置几点、星期几、
;; 在哪些机器上生成。每个任务每天在自己的目录写一个 YYYY-MM-DD 文件，文件在就算做过；
;; 每小时同步一次并检查，所以到点没开机，开机后也会补上。目录在 `iuiw-sync' 仓库里
;; 的任务，各机器共享结果，先推上去的为准。新文件出现时提示一次，要点列在 overlook
;; 看板上，任一台机器打开过就不再列出。

;;; Code:

(require 'cl-lib)
(require 'iuiw-sync)

(declare-function alert "alert")
(declare-function overlook-refresh "overlook")
(declare-function overlook-section-row "overlook")
(declare-function overlook-row "overlook")

(defgroup iuiw-daily nil
  "Tasks that write one file a day."
  :group 'convenience)

(defcustom iuiw-daily-schedule '((elfeed-digest :hour 8))
  "When and where the daily tasks run.
Each element is (NAME . PLIST): :hour is the hour before which the
task does not run, :days the weekdays it runs on (0 is Sunday; nil for
every day), :hosts the machines, as named by `iuiw-sync-host', that run
it (nil for all).  Tasks not listed here do not run on this machine."
  :type '(alist :key-type symbol :value-type plist))

(defcustom iuiw-daily-check-interval 3600
  "Seconds between checks for due tasks."
  :type 'natural)

(defvar iuiw-daily--tasks nil
  "Task name to its properties, as given to `iuiw-daily-define'.")

(defvar iuiw-daily--running nil
  "Names of the tasks being run.")

(defvar iuiw-daily--announced (make-hash-table :test #'eq)
  "Task name to the latest file already announced.")

(defvar iuiw-daily--seen (make-hash-table :test #'equal)
  "(task name . file base name) of the files opened on some machine.")

(defun iuiw-daily-define (name &rest props)
  "Define the daily task NAME with PROPS.
:title       What the dashboard and the notification call it.
:directory   Function returning the directory of its files.
:extension   Extension of its files, without the dot.
:run         Function called with a callback; it writes today's file,
             then calls the callback with an error message, or nil.
:describe    Optional function of a file, giving the notification's text.
:points      Function of a file, giving the strings the dashboard lists.
:open        Function of a file that shows it.
:depth       Depth of its section in `overlook-sections'; 70 by default.
The dashboard section is the function `iuiw-daily-section-NAME'."
  (setf (alist-get name iuiw-daily--tasks) props)
  (unless (gethash name iuiw-daily--announced)
    (puthash name (or (iuiw-daily-latest name) 'none) iuiw-daily--announced))
  (let ((section (intern (format "iuiw-daily-section-%s" name))))
    (defalias section (lambda () (iuiw-daily--section name))
      (format "The overlook section of the daily task `%s'." name))
    (with-eval-after-load 'overlook
      (add-hook 'overlook-sections section (or (plist-get props :depth) 70)))))

(defun iuiw-daily--get (name prop)
  "Return PROP of task NAME."
  (plist-get (alist-get name iuiw-daily--tasks) prop))

;;; Files

(defun iuiw-daily--directory (name)
  "Return the directory of task NAME's files."
  (file-name-as-directory (funcall (iuiw-daily--get name :directory))))

(defun iuiw-daily-file (name &optional time)
  "Return task NAME's file for the day of TIME, today by default."
  (expand-file-name (format-time-string (concat "%F." (iuiw-daily--get name :extension)) time)
                    (iuiw-daily--directory name)))

(defun iuiw-daily-files (name)
  "Return task NAME's files, oldest first."
  (ignore-errors
    (directory-files (iuiw-daily--directory name) t
                     (concat "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\."
                             (regexp-quote (iuiw-daily--get name :extension)) "\\'"))))

(defun iuiw-daily-latest (name)
  "Return task NAME's newest file, or nil."
  (car (last (iuiw-daily-files name))))

(defun iuiw-daily--shared-p (name)
  "Return non-nil if task NAME's files live in the sync repository."
  (file-in-directory-p (iuiw-daily--directory name) iuiw-sync-directory))

;;; Running

(defun iuiw-daily--due-p (name)
  "Return non-nil if task NAME should run now on this machine."
  (when-let* ((entry (assq name iuiw-daily-schedule))
              ((alist-get name iuiw-daily--tasks)))
    (let* ((schedule (cdr entry))
           (now (decode-time))
           (days (plist-get schedule :days))
           (hosts (plist-get schedule :hosts)))
      (and (or (null hosts) (member iuiw-sync-host hosts))
           (or (null days) (memq (decoded-time-weekday now) days))
           (>= (decoded-time-hour now) (or (plist-get schedule :hour) 0))
           (not (memq name iuiw-daily--running))
           (not (file-exists-p (iuiw-daily-file name)))))))

(defun iuiw-daily-run (name)
  "Run task NAME now, whether or not it is due."
  (interactive (list (intern (completing-read "Run daily task: "
                                              (mapcar #'car iuiw-daily--tasks) nil t))))
  (unless (memq name iuiw-daily--running)
    (push name iuiw-daily--running)
    (condition-case err
        (funcall (iuiw-daily--get name :run)
                 (lambda (err) (iuiw-daily--finish name err)))
      (error (iuiw-daily--finish name (error-message-string err))))))

(defun iuiw-daily--finish (name err)
  "Note that task NAME ended with ERR, or nil on success."
  (setq iuiw-daily--running (delq name iuiw-daily--running))
  (cond
   (err (message "%s failed: %s" (iuiw-daily--get name :title) err))
   ((iuiw-daily--shared-p name) (iuiw-sync))
   (t (iuiw-daily--announce))))

;;;###autoload
(defun iuiw-daily-check ()
  "Sync, then run the tasks that are due.
Tasks writing into the sync repository wait for a sync that succeeded."
  (interactive)
  (iuiw-sync
   (lambda (err)
     (when err (message "sync: %s" err))
     (dolist (name (mapcar #'car iuiw-daily--tasks))
       (when (and (iuiw-daily--due-p name)
                  (not (and err (iuiw-daily--shared-p name))))
         (iuiw-daily-run name))))))

;;; Seen

(defun iuiw-daily--load-seen ()
  "Read the seen records from the sync repository."
  (clrhash iuiw-daily--seen)
  (iuiw-sync-read
   "seen" (lambda (record)
            (puthash (if-let* ((task (plist-get record :task)))
                         (cons (intern task) (plist-get record :key))
                       (cons 'elfeed-digest (plist-get record :digest)))
                     t iuiw-daily--seen))))

(defun iuiw-daily--seen-p (name file)
  "Return non-nil if task NAME's FILE was opened on some machine."
  (gethash (cons name (file-name-base file)) iuiw-daily--seen))

(defun iuiw-daily--mark-seen (name file)
  "Record task NAME's FILE as seen, for every machine."
  (let ((key (cons name (file-name-base file))))
    (unless (gethash key iuiw-daily--seen)
      (puthash key t iuiw-daily--seen)
      (iuiw-sync-append "seen" (iuiw-sync-record :task (symbol-name name) :key (cdr key)))
      (when (fboundp 'overlook-refresh) (overlook-refresh)))))

(defun iuiw-daily--unseen ()
  "Return the names of the tasks whose latest file is still unseen."
  (cl-remove-if-not (lambda (name)
                      (when-let* ((file (iuiw-daily-latest name)))
                        (not (iuiw-daily--seen-p name file))))
                    (mapcar #'car iuiw-daily--tasks)))

;;; Showing

(defun iuiw-daily--announce ()
  "Announce each task's latest file if it is new, whichever machine wrote it."
  (let (new)
    (pcase-dolist (`(,name . ,_) iuiw-daily--tasks)
      (let ((file (iuiw-daily-latest name)))
        (when (and file (not (equal file (gethash name iuiw-daily--announced))))
          (puthash name file iuiw-daily--announced)
          (setq new t)
          (let ((title (format "%s %s" (iuiw-daily--get name :title) (file-name-base file)))
                (text (if-let* ((describe (iuiw-daily--get name :describe)))
                          (funcall describe file)
                        "已生成")))
            (message "%s：%s" title text)
            (alert text :title title)))))
    (when (and new (fboundp 'overlook-refresh)) (overlook-refresh))))

(defun iuiw-daily--after-sync (_err)
  "Reread the seen records and announce new files."
  (let ((unseen (iuiw-daily--unseen)))
    (iuiw-daily--load-seen)
    (unless (equal unseen (iuiw-daily--unseen))
      (when (fboundp 'overlook-refresh) (overlook-refresh))))
  (iuiw-daily--announce))

;;;###autoload
(defun iuiw-daily-open (name &optional file)
  "Show task NAME's FILE, its latest by default, and mark it seen."
  (interactive (list (intern (completing-read "Open daily task: "
                                              (mapcar #'car iuiw-daily--tasks) nil t))))
  (let ((file (or file (iuiw-daily-latest name))))
    (unless file (user-error "%s: nothing yet" (iuiw-daily--get name :title)))
    (iuiw-daily--mark-seen name file)
    (funcall (iuiw-daily--get name :open) file)))

(defun iuiw-daily--section (name)
  "The overlook section of the points in task NAME's latest file.
Nil once the file is seen."
  (when-let* ((file (iuiw-daily-latest name))
              ((not (iuiw-daily--seen-p name file))))
    (let ((open (lambda () (iuiw-daily-open name file))))
      (overlook-section-row
       (concat (iuiw-daily--get name :title) " "
               (propertize (file-name-base file) 'face 'shadow))
       (mapcar (lambda (point)
                 (overlook-row :content (list (propertize "•" 'face 'shadow) " " point)
                               :action open
                               :wrap "  "))
               (funcall (iuiw-daily--get name :points) file))))))

;;; Mode

(defvar iuiw-daily--timer nil)

;;;###autoload
(define-minor-mode iuiw-daily-mode
  "Run the daily tasks of `iuiw-daily-schedule' when they are due."
  :global t
  (when (timerp iuiw-daily--timer)
    (cancel-timer iuiw-daily--timer))
  (setq iuiw-daily--timer nil)
  (if (not iuiw-daily-mode)
      (remove-hook 'iuiw-sync-after-functions #'iuiw-daily--after-sync)
    (add-hook 'iuiw-sync-after-functions #'iuiw-daily--after-sync)
    (iuiw-daily--load-seen)
    (setq iuiw-daily--timer
          (run-at-time 30 iuiw-daily-check-interval #'iuiw-daily-check))))

(provide 'iuiw-daily)
;;; iuiw-daily.el ends here
