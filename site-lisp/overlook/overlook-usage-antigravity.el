;;; overlook-usage-antigravity.el --- Antigravity plan quota on the overlook dashboard -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
;; URL: https://github.com/guiyuanju/overlook
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; An antigravity row in the dashboard's Usage section: the weekly limit
;; the Gemini models share, on macOS.  Loading this file adds the row; it
;; shows once a reading arrives.
;;
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
(require 'overlook-agent-update)

(defconst overlook-usage-antigravity--script
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

(defvar overlook-usage-antigravity--windows nil)
(defvar overlook-usage-antigravity--error nil)
(defvar overlook-usage-antigravity--process nil)
(defvar overlook-usage-antigravity--waiting nil
  "Non-nil while a quota request is unanswered.")

(defun overlook-usage-antigravity--user-agent ()
  "User agent naming the installed antigravity-acp version."
  (format "antigravity/%s darwin/arm64"
          (or (alist-get 'version (overlook-agent-update--acp-installed "antigravity-acp"))
              "1.4.1")))

(defun overlook-usage-antigravity--parse (data)
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

(defun overlook-usage-antigravity--answer (line)
  "Record the quota answer LINE from the shell."
  (setq overlook-usage-antigravity--waiting nil)
  (condition-case nil
      (progn
        (unless (string-prefix-p "ok " line)
          (error "Quota request failed"))
        (setq overlook-usage-antigravity--windows
              (overlook-usage-antigravity--parse
               (json-parse-string (substring line 3) :object-type 'alist :array-type 'list))
              overlook-usage-antigravity--error nil))
    (error (setq overlook-usage-antigravity--error t)))
  (overlook-usage-scan))

(defun overlook-usage-antigravity--filter (process output)
  "Hand each complete line of PROCESS OUTPUT to the answer handler."
  (with-current-buffer (process-buffer process)
    (goto-char (point-max))
    (insert output)
    (goto-char (point-min))
    (while (search-forward "\n" nil t)
      (let ((line (buffer-substring-no-properties (point-min) (1- (point)))))
        (delete-region (point-min) (point))
        (overlook-usage-antigravity--answer line)))))

(defun overlook-usage-antigravity--process ()
  "Return the live quota shell, starting it if needed."
  (unless (process-live-p overlook-usage-antigravity--process)
    (setq overlook-usage-antigravity--waiting nil
          overlook-usage-antigravity--process
          (make-process
           :name "antigravity-quota" :buffer (generate-new-buffer " *antigravity-quota*")
           :noquery t :connection-type 'pipe
           :command (list "sh" "-c" overlook-usage-antigravity--script "sh" (overlook-usage-antigravity--user-agent))
           :filter #'overlook-usage-antigravity--filter
           :sentinel (lambda (process _event)
                       (unless (process-live-p process)
                         (kill-buffer (process-buffer process))
                         (setq overlook-usage-antigravity--waiting nil))))))
  overlook-usage-antigravity--process)

(defun overlook-usage-antigravity--fetch ()
  "Ask for the quota unless a request is unanswered; non-nil when it asked."
  (unless overlook-usage-antigravity--waiting
    (setq overlook-usage-antigravity--waiting t)
    (process-send-string (overlook-usage-antigravity--process) "\n")
    t))

(defun overlook-usage-antigravity-usage ()
  "Antigravity's Gemini usage, as last fetched.
A blank first window puts the weekly one under the other rows' 7d column."
  (when overlook-usage-antigravity--windows
    (cons (propertize "antigravity"
                      'face (and overlook-usage-antigravity--error 'warning)
                      'help-echo (if overlook-usage-antigravity--error
                                     "Last quota refresh failed; showing the previous reading"
                                   "Weekly limit shared by the Gemini models; refreshed every 5 minutes"))
          (cons '("" "" nil) overlook-usage-antigravity--windows))))

(add-to-list 'overlook-usage-functions #'overlook-usage-antigravity-usage t)
(overlook-usage-add-poller #'overlook-usage-antigravity--fetch)

(provide 'overlook-usage-antigravity)
;;; overlook-usage-antigravity.el ends here
