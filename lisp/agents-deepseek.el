;;; agents-deepseek.el --- DeepSeek balance and local Pi usage -*- lexical-binding: t; -*-

;;; Commentary:
;; Account balance comes from /user/balance; cost estimates cover only local Pi logs.
;; The key stays in local.el and is sent to curl on stdin, never in argv.

;;; Code:

(require 'agents)
(require 'json)
(require 'subr-x)

(defvar jgy/deepseek-api-key nil
  "DeepSeek API key configured in local.el.")
(defvar agents-deepseek-sessions-directory "~/.pi/agent/sessions")
(defvar agents-deepseek--balance nil)
(defvar agents-deepseek--error nil)
(defvar agents-deepseek--requested 0)
(defvar agents-deepseek--updated nil)
(defvar agents-deepseek--process nil)
(defvar agents-deepseek--cost nil)
(defvar agents-deepseek--scanned 0)
(defvar agents-deepseek--day nil)
(defvar agents-deepseek--files (make-hash-table :test #'equal))

(defun agents-deepseek--parse-balance (data)
  "Validate DATA and return currency/balance pairs, preserving decimal strings."
  (let ((rows (alist-get 'balance_infos data)))
    (unless (and rows (seq-every-p
                       (lambda (row)
                         (and (member (alist-get 'currency row) '("CNY" "USD"))
                              (stringp (alist-get 'total_balance row))
                              (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'"
                                              (alist-get 'total_balance row))))
                       rows))
      (error "Invalid balance response"))
    (mapcar (lambda (row) (cons (alist-get 'currency row)
                                (alist-get 'total_balance row))) rows)))

(defun agents-deepseek--fetch ()
  "Refresh balance asynchronously, with a five-minute retry interval."
  (when (and (bound-and-true-p jgy/deepseek-api-key)
             (not (process-live-p agents-deepseek--process))
             (>= (- (float-time) agents-deepseek--requested) 300))
    (setq agents-deepseek--requested (float-time))
    (let ((buffer (generate-new-buffer " *deepseek-balance*")))
      (condition-case nil
          (progn
            (setq agents-deepseek--process
                  (make-process
                   :name "deepseek-balance" :buffer buffer :noquery t
                   :connection-type 'pipe
                   :command '("curl" "-q" "--silent" "--fail" "--max-time" "15"
                              "--config" "-" "https://api.deepseek.com/user/balance")
                   :sentinel
                   (lambda (process _event)
                     (when (memq (process-status process) '(exit signal))
                       (unwind-protect
                           (condition-case nil
                               (with-current-buffer (process-buffer process)
                                 (unless (zerop (process-exit-status process))
                                   (error "Balance request failed"))
                                 (goto-char (point-min))
                                 (setq agents-deepseek--balance
                                       (agents-deepseek--parse-balance
                                        (json-parse-buffer :object-type 'alist :array-type 'list))
                                       agents-deepseek--updated (float-time)
                                       agents-deepseek--error nil))
                             (error (setq agents-deepseek--error t)))
                         (kill-buffer (process-buffer process)))
                       (agents--context-scan)))))
            ;; Only accept a single header value; no curl-config injection.
            (unless (string-match-p "\\`[A-Za-z0-9_-]+\\'" jgy/deepseek-api-key)
              (error "Invalid key format"))
            (process-send-string agents-deepseek--process
                                 (concat "header = \"Authorization: Bearer "
                                         jgy/deepseek-api-key "\"\n"))
            (process-send-eof agents-deepseek--process))
        (error
         (setq agents-deepseek--error t)
         (when (process-live-p agents-deepseek--process)
           (delete-process agents-deepseek--process))
         (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun agents-deepseek--file-cost (file day)
  "Read DeepSeek assistant cost estimates in USD from Pi FILE for local DAY.
Cache by modification time, size, and day.  Ignore incomplete JSONL lines."
  (let* ((attrs (file-attributes file))
         (stamp (list day (file-attribute-modification-time attrs)
                      (file-attribute-size attrs)))
         (cached (gethash file agents-deepseek--files)))
    (if (equal stamp (car cached)) (cdr cached)
      (let ((total 0) (missing nil))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (not (eobp))
            (let* ((entry (ignore-errors
                            (json-parse-string
                             (buffer-substring-no-properties (point) (line-end-position))
                             :object-type 'alist)))
                   (message (alist-get 'message entry))
                   (time (alist-get 'timestamp message))
                   (cost (alist-get 'total (alist-get 'cost (alist-get 'usage message)))))
              (when (and (equal (alist-get 'role message) "assistant")
                         (equal (alist-get 'provider message) "deepseek")
                         (numberp time)
                         (equal day (format-time-string "%F" (/ time 1000.0))))
                (if (and (numberp cost) (>= cost 0))
                    (cl-incf total cost)
                  (setq missing t))))
            (forward-line 1)))
        (setq total (unless missing total))
        (puthash file (cons stamp total) agents-deepseek--files)
        total))))

(defun agents-deepseek--scan ()
  "Sum today's local Pi DeepSeek cost estimates at most once per minute."
  (let ((day (format-time-string "%F")))
    (when (or (not (equal day agents-deepseek--day))
              (>= (- (float-time) agents-deepseek--scanned) 60))
      (setq agents-deepseek--scanned (float-time)
            agents-deepseek--day day
            agents-deepseek--cost
            (condition-case nil
                (let* ((dir (expand-file-name agents-deepseek-sessions-directory))
                       (midnight (float-time (date-to-time (concat day " 00:00:00"))))
                       (total 0))
                  (when (file-directory-p dir)
                    (dolist (file (directory-files-recursively dir "\\.jsonl\\'"))
                      (when (>= (float-time (file-attribute-modification-time
                                             (file-attributes file))) midnight)
                        (let ((cost (agents-deepseek--file-cost file day)))
                          (unless cost (error "Missing cost in Pi log"))
                          (cl-incf total cost)))))
                  total)
              (error nil))))))

(defun agents-usage-deepseek ()
  "Return account balance and explicitly scoped local Pi estimated cost."
  (when (bound-and-true-p jgy/deepseek-api-key)
    (agents-deepseek--fetch)
    (agents-deepseek--scan)
    (list "deepseek"
          (list "balance"
                (propertize
                 (if agents-deepseek--balance
                     (concat
                      (mapconcat (lambda (row)
                                   (concat (if (equal (car row) "CNY") "¥" "$")
                                           (cdr row)))
                                 agents-deepseek--balance " / ")
                      (if agents-deepseek--error " stale" ""))
                   (if agents-deepseek--error "unavailable" "loading"))
                 'face (if agents-deepseek--error 'warning 'default)
                 'help-echo "DeepSeek account balance; refreshed every 5 minutes. stale means the last refresh failed.")
                nil)
          (list "today"
                (propertize
                 (if agents-deepseek--cost
                     (format "~$%.4f" agents-deepseek--cost)
                   "?")
                 'help-echo "Today's estimated DeepSeek cost in USD from local Pi logs only (local timezone); excludes Elfeed and other clients/API keys. Uses Pi's recorded model prices, not an API-key bill. ? means unavailable or missing cost records.")
                nil))))

(add-to-list 'agents-usage-functions #'agents-usage-deepseek t)

(provide 'agents-deepseek)
;;; agents-deepseek.el ends here
