;;; jgy-agents-deepseek.el --- DeepSeek balance and observed account spending -*- lexical-binding: t; -*-

;;; Commentary:
;; Account balance comes from /user/balance; spending estimates track observed balance decreases.
;; The key stays in local.el and is sent to curl on stdin, never in argv.

;;; Code:

(require 'jgy-agents-usage)
(require 'json)
(require 'subr-x)

(defvar jgy-deepseek-api-key nil
  "DeepSeek API key configured in local.el.")
(defvar jgy-agents-deepseek--balance nil)
(defvar jgy-agents-deepseek--error nil)
(defvar jgy-agents-deepseek--requested 0)
(defvar jgy-agents-deepseek--process nil)
(defvar jgy-agents-deepseek-state-file
  (locate-user-emacs-file "var/deepseek-spending.json"))
(defvar jgy-agents-deepseek--state nil)
(defvar jgy-agents-deepseek--loaded-key nil)

(defcustom jgy-agents-deepseek-usage-url "https://platform.deepseek.com/usage"
  "Page the dashboard's DeepSeek usage row opens on RET."
  :type 'string
  :group 'jgy-agents)

(defun jgy-agents-deepseek-open-usage ()
  "Open DeepSeek's usage page in a browser."
  (interactive)
  (browse-url jgy-agents-deepseek-usage-url))

(defun jgy-agents-deepseek--load-state ()
  "Restore observations for this key, without storing the key itself."
  (let ((key (secure-hash 'sha256 jgy-deepseek-api-key)))
    (unless (equal key jgy-agents-deepseek--loaded-key)
      (setq jgy-agents-deepseek--loaded-key key
            jgy-agents-deepseek--state
            (condition-case nil
                (with-temp-buffer
                  (insert-file-contents jgy-agents-deepseek-state-file)
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

(defun jgy-agents-deepseek--record (balance &optional time)
  "Record BALANCE at TIME; accumulate decreases within the local day.
Increases establish a new baseline without erasing observed spending.
The first sample of each day starts at zero: overnight gaps are not billed
entirely to the new day.  Recharge and expiry make this only an estimate."
  (jgy-agents-deepseek--load-state)
  (let* ((now (or time (float-time)))
         (day (format-time-string "%F" now))
         (same-day (equal day (alist-get 'day jgy-agents-deepseek--state)))
         (old (and same-day (alist-get 'rows jgy-agents-deepseek--state)))
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
    (setq jgy-agents-deepseek--state
          `((key . ,jgy-agents-deepseek--loaded-key) (day . ,day)
            (since . ,(if same-day (alist-get 'since jgy-agents-deepseek--state) now))
            (rows . ,rows)))
    (let* ((dir (file-name-directory jgy-agents-deepseek-state-file))
           (temporary nil))
      (make-directory dir t)
      (unwind-protect
          (progn
            (setq temporary (make-temp-file (expand-file-name ".deepseek-" dir)))
            (with-temp-file temporary
              (insert (json-encode jgy-agents-deepseek--state)))
            (rename-file temporary jgy-agents-deepseek-state-file t))
        (when (and temporary (file-exists-p temporary)) (delete-file temporary))))))

(defun jgy-agents-deepseek--today ()
  "Format today's observed account spending in the balance currency."
  (jgy-agents-deepseek--load-state)
  (if (and (equal (format-time-string "%F") (alist-get 'day jgy-agents-deepseek--state))
           (alist-get 'rows jgy-agents-deepseek--state))
      (concat
       (mapconcat (lambda (row)
                    (format "~%s%.4f" (if (equal (alist-get 'currency row) "CNY") "¥" "$")
                            (alist-get 'spent row)))
                  (alist-get 'rows jgy-agents-deepseek--state) " / ")
       (if jgy-agents-deepseek--error " stale" ""))
    "?"))

(defun jgy-agents-deepseek--parse-balance (data)
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

(defun jgy-agents-deepseek--fetch ()
  "Refresh balance asynchronously, with a five-minute retry interval."
  (when (and (bound-and-true-p jgy-deepseek-api-key)
             (not (process-live-p jgy-agents-deepseek--process))
             (>= (- (float-time) jgy-agents-deepseek--requested) 300))
    (setq jgy-agents-deepseek--requested (float-time))
    (let ((buffer (generate-new-buffer " *deepseek-balance*")))
      (condition-case nil
          (progn
            (setq jgy-agents-deepseek--process
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
                                 (setq jgy-agents-deepseek--balance
                                       (jgy-agents-deepseek--parse-balance
                                        (json-parse-buffer :object-type 'alist :array-type 'list))
                                       jgy-agents-deepseek--error nil)
                                 (jgy-agents-deepseek--record jgy-agents-deepseek--balance))
                             (error (setq jgy-agents-deepseek--error t)))
                         (kill-buffer (process-buffer process)))
                       (jgy-agents--context-scan)))))
            ;; Only accept a single header value; no curl-config injection.
            (unless (string-match-p "\\`[A-Za-z0-9_-]+\\'" jgy-deepseek-api-key)
              (error "Invalid key format"))
            (process-send-string jgy-agents-deepseek--process
                                 (concat "header = \"Authorization: Bearer "
                                         jgy-deepseek-api-key "\"\n"))
            (process-send-eof jgy-agents-deepseek--process))
        (error
         (setq jgy-agents-deepseek--error t)
         (when (process-live-p jgy-agents-deepseek--process)
           (delete-process jgy-agents-deepseek--process))
         (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun jgy-agents-usage-deepseek ()
  "Return account balance and observed account spending."
  (when (bound-and-true-p jgy-deepseek-api-key)
    (jgy-agents-deepseek--fetch)
    (list (propertize "deepseek"
                      'jgy-agents-action #'jgy-agents-deepseek-open-usage
                      'help-echo "RET opens DeepSeek's usage page")
          (list "balance"
                (propertize
                 (if jgy-agents-deepseek--balance
                     (concat
                      (mapconcat (lambda (row)
                                   (concat (if (equal (car row) "CNY") "¥" "$")
                                           (cdr row)))
                                 jgy-agents-deepseek--balance " / ")
                      (if jgy-agents-deepseek--error " stale" ""))
                   (if jgy-agents-deepseek--error "unavailable" "loading"))
                 'face (if jgy-agents-deepseek--error 'warning 'default)
                 'help-echo "DeepSeek account balance; refreshed every 5 minutes. stale means the last refresh failed.")
                nil)
          (list "today"
                (propertize
                 (jgy-agents-deepseek--today)
                 'face (if jgy-agents-deepseek--error 'warning 'default)
                 'help-echo
                 (concat "Observed account balance decreases today, including Pi, gptel and other clients. Refreshed at most every 5 minutes; local timezone. Estimate only: top-ups can hide spending, credit expiry can look like spending. "
                         (if (and (alist-get 'since jgy-agents-deepseek--state)
                                  (equal (format-time-string "%F") (alist-get 'day jgy-agents-deepseek--state)))
                             (format "Tracked since %s; earlier spending is excluded."
                                     (format-time-string "%H:%M" (alist-get 'since jgy-agents-deepseek--state)))
                           "Waiting for today's first balance sample.")))
                nil))))

(add-to-list 'jgy-agents-usage-functions #'jgy-agents-usage-deepseek t)

(provide 'jgy-agents-deepseek)
;;; jgy-agents-deepseek.el ends here
