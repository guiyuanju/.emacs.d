;;; iuiw-deepseek.el --- DeepSeek balance and observed account spending -*- lexical-binding: t; -*-

;;; Commentary:
;; Account balance comes from /user/balance; spending estimates track observed balance decreases.
;; The key stays in local.el and is sent to curl on stdin, never in argv.

;;; Code:

(require 'overlook-usage)
(require 'json)

(defvar iuiw-deepseek-api-key nil
  "DeepSeek API key configured in local.el.")
(defvar iuiw-deepseek--balance nil)
(defvar iuiw-deepseek--error nil)
(defvar iuiw-deepseek--process nil)
(defvar iuiw-deepseek-state-file
  (locate-user-emacs-file "var/deepseek-spending.json"))
(defvar iuiw-deepseek--state nil)
(defvar iuiw-deepseek--loaded-key nil)

(defcustom iuiw-deepseek-usage-url "https://platform.deepseek.com/usage"
  "Page the dashboard's DeepSeek usage row opens on RET."
  :type 'string
  :group 'overlook)

(defun iuiw-deepseek-open-usage ()
  "Open DeepSeek's usage page in a browser."
  (interactive)
  (browse-url iuiw-deepseek-usage-url))

(defun iuiw-deepseek--load-state ()
  "Restore observations for this key, without storing the key itself."
  (let ((key (secure-hash 'sha256 iuiw-deepseek-api-key)))
    (unless (equal key iuiw-deepseek--loaded-key)
      (setq iuiw-deepseek--loaded-key key
            iuiw-deepseek--state
            (condition-case nil
                (with-temp-buffer
                  (insert-file-contents iuiw-deepseek-state-file)
                  (let ((data (json-parse-buffer :object-type 'alist :array-type 'list)))
                    (when (and (equal (alist-get 'key data) key)
                               (stringp (alist-get 'day data))
                               (numberp (alist-get 'since data))
                               (seq-every-p
                                (lambda (row)
                                  (and (member (alist-get 'currency row) '("CNY" "USD"))
                                       (numberp (alist-get 'last row))
                                       (numberp (alist-get 'spent row))
                                       (>= (alist-get 'spent row) 0)))
                                (alist-get 'rows data)))
                      data)))
              (error nil))))))

(defun iuiw-deepseek--record (balance &optional time)
  "Record BALANCE at TIME; accumulate decreases within the local day.
Increases establish a new baseline without erasing observed spending.
The first sample of each day starts at zero: overnight gaps are not billed
entirely to the new day.  Recharge and expiry make this only an estimate."
  (iuiw-deepseek--load-state)
  (let* ((now (or time (float-time)))
         (day (format-time-string "%F" now))
         (same-day (equal day (alist-get 'day iuiw-deepseek--state)))
         (old (and same-day (alist-get 'rows iuiw-deepseek--state)))
         (rows
          (mapcar
           (lambda (pair)
             (let* ((currency (car pair))
                    (value (string-to-number (cdr pair)))
                    (previous (seq-find
                               (lambda (row) (equal currency (alist-get 'currency row))) old)))
               `((currency . ,currency) (last . ,value)
                 (spent . ,(+ (or (alist-get 'spent previous) 0)
                              (if previous
                                  (max 0 (- (alist-get 'last previous) value)) 0))))))
           balance)))
    (setq iuiw-deepseek--state
          `((key . ,iuiw-deepseek--loaded-key) (day . ,day)
            (since . ,(if same-day (alist-get 'since iuiw-deepseek--state) now))
            (rows . ,rows)))
    (let* ((dir (file-name-directory iuiw-deepseek-state-file))
           (temporary nil))
      (make-directory dir t)
      (unwind-protect
          (progn
            (setq temporary (make-temp-file (expand-file-name ".deepseek-" dir)))
            (with-temp-file temporary
              (insert (json-encode iuiw-deepseek--state)))
            (rename-file temporary iuiw-deepseek-state-file t))
        (when (and temporary (file-exists-p temporary)) (delete-file temporary))))))

(defun iuiw-deepseek--today ()
  "Format today's observed account spending in the balance currency."
  (iuiw-deepseek--load-state)
  (if (and (equal (format-time-string "%F") (alist-get 'day iuiw-deepseek--state))
           (alist-get 'rows iuiw-deepseek--state))
      (concat
       (mapconcat (lambda (row)
                    (format "~%s%.4f" (if (equal (alist-get 'currency row) "CNY") "¥" "$")
                            (alist-get 'spent row)))
                  (alist-get 'rows iuiw-deepseek--state) " / ")
       (if iuiw-deepseek--error " stale" ""))
    "?"))

(defun iuiw-deepseek--parse-balance (data)
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

(defun iuiw-deepseek--fetch ()
  "Start a balance request unless one is running; non-nil when it did."
  (when (and iuiw-deepseek-api-key
             (not (process-live-p iuiw-deepseek--process)))
    (let ((buffer (generate-new-buffer " *deepseek-balance*")))
      (condition-case nil
          (progn
            (setq iuiw-deepseek--process
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
                                 (setq iuiw-deepseek--balance
                                       (iuiw-deepseek--parse-balance
                                        (json-parse-buffer :object-type 'alist :array-type 'list))
                                       iuiw-deepseek--error nil)
                                 (iuiw-deepseek--record iuiw-deepseek--balance))
                             (error (setq iuiw-deepseek--error t)))
                         (kill-buffer (process-buffer process)))
                       (overlook-usage-scan)))))
            ;; Only accept a single header value; no curl-config injection.
            (unless (string-match-p "\\`[A-Za-z0-9_-]+\\'" iuiw-deepseek-api-key)
              (error "Invalid key format"))
            (process-send-string iuiw-deepseek--process
                                 (concat "header = \"Authorization: Bearer "
                                         iuiw-deepseek-api-key "\"\n"))
            (process-send-eof iuiw-deepseek--process))
        (error
         (setq iuiw-deepseek--error t)
         (when (process-live-p iuiw-deepseek--process)
           (delete-process iuiw-deepseek--process))
         (when (buffer-live-p buffer) (kill-buffer buffer)))))
    t))

(defun iuiw-deepseek-usage ()
  "Return account balance and observed account spending."
  (when iuiw-deepseek-api-key
    (list (propertize "deepseek"
                      'overlook-action #'iuiw-deepseek-open-usage
                      'help-echo "RET opens DeepSeek's usage page")
          (list "balance"
                (propertize
                 (if iuiw-deepseek--balance
                     (concat
                      (mapconcat (lambda (row)
                                   (concat (if (equal (car row) "CNY") "¥" "$")
                                           (cdr row)))
                                 iuiw-deepseek--balance " / ")
                      (if iuiw-deepseek--error " stale" ""))
                   (if iuiw-deepseek--error "unavailable" "loading"))
                 'face (if iuiw-deepseek--error 'warning 'default)
                 'help-echo "DeepSeek account balance; refreshed every 5 minutes. stale means the last refresh failed.")
                nil)
          (list "today"
                (propertize
                 (iuiw-deepseek--today)
                 'face (if iuiw-deepseek--error 'warning 'default)
                 'help-echo
                 (concat "Observed account balance decreases today, including Pi, gptel and other clients. Refreshed at most every 5 minutes; local timezone. Estimate only: top-ups can hide spending, credit expiry can look like spending. "
                         (if (and (alist-get 'since iuiw-deepseek--state)
                                  (equal (format-time-string "%F") (alist-get 'day iuiw-deepseek--state)))
                             (format "Tracked since %s; earlier spending is excluded."
                                     (format-time-string "%H:%M" (alist-get 'since iuiw-deepseek--state)))
                           "Waiting for today's first balance sample.")))
                nil))))

(add-to-list 'overlook-usage-functions #'iuiw-deepseek-usage t)
(overlook-usage-add-poller #'iuiw-deepseek--fetch)

(provide 'iuiw-deepseek)
;;; iuiw-deepseek.el ends here
