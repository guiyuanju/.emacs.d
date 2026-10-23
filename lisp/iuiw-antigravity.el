;;; iuiw-antigravity.el --- Antigravity plan quota on the overlook dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;; Quota comes from Antigravity's undocumented retrieveUserQuotaSummary,
;; which only answers a client calling itself Antigravity.  The OAuth refresh
;; credentials antigravity-acp keeps in the macOS keychain stay inside one
;; long-lived shell: they never reach Emacs or any process's argv.
;; antigravity-acp recreates the keychain item whenever it writes it, which
;; drops `security' from the item's access list, so the shell reads it once
;; and again only after the token endpoint rejects it; each read may ask
;; for permission.

;;; Code:

(require 'overlook-usage)
(require 'iuiw-agent-update)

(defconst iuiw-antigravity--script
  "c=
while read -r _; do
  [ -n \"$c\" ] || c=$(security find-generic-password -s gemini -a antigravity-acp -w) || c=
  [ -n \"$c\" ] || { echo 'err keychain'; continue; }
  resp=$(printf '%s' \"$c\" \\
    | jq -r '\"client_id=\\(.client_id|@uri)&client_secret=\\(.client_secret|@uri)&refresh_token=\\(.refresh_token|@uri)&grant_type=refresh_token\"' \\
    | curl -q -sf --max-time 15 -d @- \"$(printf '%s' \"$c\" | jq -r .token_uri)\")
  [ $? -eq 22 ] && c=
  tok=$(printf '%s' \"$resp\" | jq -er .access_token) || { echo 'err token'; continue; }
  out=$(printf 'header = \"Authorization: Bearer %s\"\\n' \"$tok\" \\
    | curl -q -sf --max-time 15 --config - -A \"$1\" -H 'Content-Type: application/json' \\
        -d \"$(printf '%s' \"$c\" | jq -c '{project: .project_id}')\" \\
        https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary \\
    | jq -c .) && echo \"ok $out\" || echo 'err quota'
done"
  "Shell script answering each input line with one line of Antigravity's quota.
The line is \"ok JSON\" or \"err STEP\"; $1 is the user agent.")

(defvar iuiw-antigravity--windows nil)
(defvar iuiw-antigravity--error nil)
(defvar iuiw-antigravity--process nil)
(defvar iuiw-antigravity--waiting nil
  "Non-nil while a quota request is unanswered.")

(defun iuiw-antigravity--user-agent ()
  "User agent naming the installed antigravity-acp version."
  (format "antigravity/%s darwin/arm64"
          (or (alist-get 'version (iuiw-agent-update--acp-installed "antigravity-acp"))
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

(defun iuiw-antigravity--answer (line)
  "Record the quota answer LINE from the shell."
  (setq iuiw-antigravity--waiting nil)
  (condition-case nil
      (progn
        (unless (string-prefix-p "ok " line)
          (error "Quota request failed"))
        (setq iuiw-antigravity--windows
              (iuiw-antigravity--parse
               (json-parse-string (substring line 3) :object-type 'alist :array-type 'list))
              iuiw-antigravity--error nil))
    (error (setq iuiw-antigravity--error t)))
  (overlook-usage-scan))

(defun iuiw-antigravity--filter (process output)
  "Hand each complete line of PROCESS OUTPUT to `iuiw-antigravity--answer'."
  (with-current-buffer (process-buffer process)
    (goto-char (point-max))
    (insert output)
    (goto-char (point-min))
    (while (search-forward "\n" nil t)
      (let ((line (buffer-substring-no-properties (point-min) (1- (point)))))
        (delete-region (point-min) (point))
        (iuiw-antigravity--answer line)))))

(defun iuiw-antigravity--process ()
  "Return the live quota shell, starting it if needed."
  (unless (process-live-p iuiw-antigravity--process)
    (setq iuiw-antigravity--waiting nil
          iuiw-antigravity--process
          (make-process
           :name "antigravity-quota" :buffer (generate-new-buffer " *antigravity-quota*")
           :noquery t :connection-type 'pipe
           :command (list "sh" "-c" iuiw-antigravity--script "sh" (iuiw-antigravity--user-agent))
           :filter #'iuiw-antigravity--filter
           :sentinel (lambda (process _event)
                       (unless (process-live-p process)
                         (kill-buffer (process-buffer process))
                         (setq iuiw-antigravity--waiting nil))))))
  iuiw-antigravity--process)

(defun iuiw-antigravity--fetch ()
  "Ask for the quota unless a request is unanswered; non-nil when it asked."
  (unless iuiw-antigravity--waiting
    (setq iuiw-antigravity--waiting t)
    (process-send-string (iuiw-antigravity--process) "\n")
    t))

(defun iuiw-antigravity-usage ()
  "Antigravity's Gemini usage, as last fetched.
A blank first window puts the weekly one under the other rows' 7d column."
  (when iuiw-antigravity--windows
    (cons (propertize "antigravity"
                      'face (and iuiw-antigravity--error 'warning)
                      'help-echo (if iuiw-antigravity--error
                                     "Last quota refresh failed; showing the previous reading"
                                   "Weekly limit shared by the Gemini models; refreshed every 5 minutes"))
          (cons '("" "" nil) iuiw-antigravity--windows))))

(add-to-list 'overlook-usage-functions #'iuiw-antigravity-usage t)
(overlook-usage-add-poller #'iuiw-antigravity--fetch)

(provide 'iuiw-antigravity)
;;; iuiw-antigravity.el ends here
