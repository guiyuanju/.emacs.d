;;; iuiw-antigravity.el --- Antigravity plan quota on the overlook dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;; Quota comes from Antigravity's undocumented retrieveUserQuotaSummary,
;; which only answers a client calling itself Antigravity.  The OAuth refresh
;; credentials antigravity-acp keeps in the macOS keychain stay inside the
;; shell pipeline: they never reach Emacs or any process's argv.

;;; Code:

(require 'overlook-usage)
(require 'iuiw-agent-update)
(require 'json)
(require 'subr-x)

(defconst iuiw-antigravity--script
  "c=$(security find-generic-password -s gemini -a antigravity-acp -w) || exit 2
tok=$(printf '%s' \"$c\" \\
  | jq -r '\"client_id=\\(.client_id|@uri)&client_secret=\\(.client_secret|@uri)&refresh_token=\\(.refresh_token|@uri)&grant_type=refresh_token\"' \\
  | curl -q -sf --max-time 15 -d @- \"$(printf '%s' \"$c\" | jq -r .token_uri)\" \\
  | jq -er .access_token) || exit 3
printf 'header = \"Authorization: Bearer %s\"\\n' \"$tok\" \\
  | curl -q -sf --max-time 15 --config - -A \"$1\" -H 'Content-Type: application/json' \\
      -d \"$(printf '%s' \"$c\" | jq -c '{project: .project_id}')\" \\
      https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
  "Shell script printing Antigravity's quota groups; $1 is the user agent.")

(defvar iuiw-antigravity--windows nil)
(defvar iuiw-antigravity--error nil)
(defvar iuiw-antigravity--requested 0)
(defvar iuiw-antigravity--process nil)

(defun iuiw-antigravity--user-agent ()
  "User agent naming the installed antigravity-acp version."
  (format "antigravity/%s darwin/arm64"
          (or (ignore-errors
                (with-temp-buffer
                  (insert-file-contents
                   (expand-file-name "antigravity-acp/agent.json" iuiw-agent-update-acp-directory))
                  (alist-get 'version (json-parse-buffer :object-type 'alist))))
              "1.4.1")))

(defun iuiw-antigravity--parse (data)
  "The Gemini models' weekly window from retrieveUserQuotaSummary DATA.
A missing `remainingFraction' is proto3 omitting zero, so the limit is used up."
  (or (mapcan
       (lambda (group)
         (mapcan (lambda (bucket)
                   (when (equal (alist-get 'bucketId bucket) "gemini-weekly")
                     (list (list "7d"
                                 (* 100 (- 1 (or (alist-get 'remainingFraction bucket) 0)))
                                 (when-let* ((time (alist-get 'resetTime bucket)))
                                   (float-time (date-to-time time)))))))
                 (alist-get 'buckets group)))
       (alist-get 'groups data))
      (error "No Gemini quota in response")))

(defun iuiw-antigravity--fetch ()
  "Refresh the quota asynchronously, at most every five minutes."
  (when (and (not (process-live-p iuiw-antigravity--process))
             (>= (- (float-time) iuiw-antigravity--requested) 300))
    (setq iuiw-antigravity--requested (float-time))
    (setq iuiw-antigravity--process
          (make-process
           :name "antigravity-quota" :buffer (generate-new-buffer " *antigravity-quota*")
           :noquery t :connection-type 'pipe
           :command (list "sh" "-c" iuiw-antigravity--script "sh" (iuiw-antigravity--user-agent))
           :sentinel
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (unwind-protect
                   (condition-case nil
                       (with-current-buffer (process-buffer process)
                         (unless (zerop (process-exit-status process))
                           (error "Quota request failed"))
                         (goto-char (point-min))
                         (setq iuiw-antigravity--windows
                               (iuiw-antigravity--parse
                                (json-parse-buffer :object-type 'alist :array-type 'list))
                               iuiw-antigravity--error nil))
                     (error (setq iuiw-antigravity--error t)))
                 (kill-buffer (process-buffer process)))
               (overlook-usage-scan)))))))

(defun iuiw-antigravity-usage ()
  "Antigravity's plan usage per model group, as last fetched."
  (when iuiw-antigravity--windows
    (cons (propertize "antigravity"
                      'face (and iuiw-antigravity--error 'warning)
                      'help-echo (if iuiw-antigravity--error
                                     "Last quota refresh failed; showing the previous reading"
                                   "Weekly limit shared by the Gemini models; refreshed every 5 minutes"))
          iuiw-antigravity--windows)))

(defun iuiw-antigravity--tick ()
  "Refresh the quota while the dashboard is live."
  (when (overlook-live-p)
    (iuiw-antigravity--fetch)))

(add-to-list 'overlook-usage-functions #'iuiw-antigravity-usage t)
(add-hook 'overlook-tick-hook #'iuiw-antigravity--tick)

(provide 'iuiw-antigravity)
;;; iuiw-antigravity.el ends here
