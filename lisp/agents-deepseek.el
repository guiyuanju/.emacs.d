;;; agents-deepseek.el --- DeepSeek balance and observed account spending -*- lexical-binding: t; -*-

;;; Commentary:
;; Account balance comes from /user/balance; spending estimates track observed balance decreases.
;; The key stays in local.el and is sent to curl on stdin, never in argv.

;;; Code:

(require 'agents-usage)
(require 'json)
(require 'subr-x)

(defvar jgy/deepseek-api-key nil
  "DeepSeek API key configured in local.el.")
(defvar agents-deepseek--balance nil)
(defvar agents-deepseek--error nil)
(defvar agents-deepseek--requested 0)
(defvar agents-deepseek--process nil)
(defvar agents-deepseek-state-file
  (locate-user-emacs-file "var/deepseek-spending.json"))
(defvar agents-deepseek--state nil)
(defvar agents-deepseek--loaded-key nil)

(defcustom agents-deepseek-usage-url "https://platform.deepseek.com/usage"
  "Page the dashboard's DeepSeek usage row opens on RET."
  :type 'string
  :group 'agents)

(defun agents-deepseek-open-usage ()
  "Open DeepSeek's usage page in a browser."
  (interactive)
  (browse-url agents-deepseek-usage-url))

(defun agents-deepseek--load-state ()
  "Restore observations for this key, without storing the key itself."
  (let ((key (secure-hash 'sha256 jgy/deepseek-api-key)))
    (unless (equal key agents-deepseek--loaded-key)
      (setq agents-deepseek--loaded-key key
            agents-deepseek--state
            (condition-case nil
                (with-temp-buffer
                  (insert-file-contents agents-deepseek-state-file)
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

(defun agents-deepseek--record (balance &optional time)
  "Record BALANCE at TIME; accumulate decreases within the local day.
Increases establish a new baseline without erasing observed spending.
The first sample of each day starts at zero: overnight gaps are not billed
entirely to the new day.  Recharge and expiry make this only an estimate."
  (agents-deepseek--load-state)
  (let* ((now (or time (float-time)))
         (day (format-time-string "%F" now))
         (same-day (equal day (alist-get 'day agents-deepseek--state)))
         (old (and same-day (alist-get 'rows agents-deepseek--state)))
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
    (setq agents-deepseek--state
          `((key . ,agents-deepseek--loaded-key) (day . ,day)
            (since . ,(if same-day (alist-get 'since agents-deepseek--state) now))
            (rows . ,rows)))
    (let* ((dir (file-name-directory agents-deepseek-state-file))
           (temporary nil))
      (make-directory dir t)
      (unwind-protect
          (progn
            (setq temporary (make-temp-file (expand-file-name ".deepseek-" dir)))
            (with-temp-file temporary
              (insert (json-encode agents-deepseek--state)))
            (rename-file temporary agents-deepseek-state-file t))
        (when (and temporary (file-exists-p temporary)) (delete-file temporary))))))

(defun agents-deepseek--today ()
  "Format today's observed account spending in the balance currency."
  (agents-deepseek--load-state)
  (if (and (equal (format-time-string "%F") (alist-get 'day agents-deepseek--state))
           (alist-get 'rows agents-deepseek--state))
      (concat
       (mapconcat (lambda (row)
                    (format "~%s%.4f" (if (equal (alist-get 'currency row) "CNY") "¥" "$")
                            (alist-get 'spent row)))
                  (alist-get 'rows agents-deepseek--state) " / ")
       (if agents-deepseek--error " stale" ""))
    "?"))

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
                                       agents-deepseek--error nil)
                                 (agents-deepseek--record agents-deepseek--balance))
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

(defun agents-usage-deepseek ()
  "Return account balance and observed account spending."
  (when (bound-and-true-p jgy/deepseek-api-key)
    (agents-deepseek--fetch)
    (list (propertize "deepseek"
                      'agents-action #'agents-deepseek-open-usage
                      'help-echo "RET opens DeepSeek's usage page")
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
                 (agents-deepseek--today)
                 'face (if agents-deepseek--error 'warning 'default)
                 'help-echo
                 (concat "Observed account balance decreases today, including Pi, gptel and other clients. Refreshed at most every 5 minutes; local timezone. Estimate only: top-ups can hide spending, credit expiry can look like spending. "
                         (if (and (alist-get 'since agents-deepseek--state)
                                  (equal (format-time-string "%F") (alist-get 'day agents-deepseek--state)))
                             (format "Tracked since %s; earlier spending is excluded."
                                     (format-time-string "%H:%M" (alist-get 'since agents-deepseek--state)))
                           "Waiting for today's first balance sample.")))
                nil))))

(add-to-list 'agents-usage-functions #'agents-usage-deepseek t)

(provide 'agents-deepseek)
;;; agents-deepseek.el ends here
