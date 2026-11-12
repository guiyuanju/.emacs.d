;;; overlook-usage.el --- Claude and Codex plan usage for the dashboard -*- lexical-binding: t; -*-

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

;; Plan usage rows at the top of the dashboard: how much of each agent's
;; subscription windows is used and when they reset.  Claude's windows come
;; from the rate limits claude-agent-acp forwards to agent-shell, kept in
;; `overlook-usage-file' so they survive a restart, and those of another
;; account in a file of its own beside it, shown as a row of its own; Codex's from its newest
;; session log.  Both are undocumented and may stop working.  Add a row by
;; pushing onto `overlook-usage-functions'.  The rows are re-read on every
;; `overlook-tick-hook'.  A row fetched over the network registers its
;; request with `overlook-usage-add-poller' and calls `overlook-usage-scan'
;; when the answer arrives.

;;; Code:

(require 'overlook-data)
(require 'overlook)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)


(defcustom overlook-usage-file (locate-user-emacs-file "overlook-claude-usage.json")
  "File keeping Claude's last plan usage.
`overlook-usage-save-claude' writes it."
  :type 'file
  :group 'overlook)

(defcustom overlook-usage-warning 80
  "Plan usage percentage from which the dashboard highlights it."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-usage-codex-sessions-directory "~/.codex/sessions"
  "Directory where Codex writes its session logs, which carry its plan usage."
  :type 'directory
  :group 'overlook)

(defcustom overlook-usage-accounts nil
  "Accounts behind usage rows named without one, keyed by row name.
Like ((\"claude\" . \"work\") (\"codex\" . \"home\")); a row's account
is drawn by its label in `overlook-account-labels'.  A row not listed
shows the account `overlook-usage-login-functions' finds."
  :type '(alist :key-type string :value-type string)
  :group 'overlook)

(defcustom overlook-usage-login-functions
  '(("claude" . overlook-usage-claude-login) ("codex" . overlook-usage-codex-login))
  "Functions naming the account a usage row's agent is logged in as.
Keyed by row name.
They are asked for rows without an account in `overlook-usage-accounts'."
  :type '(alist :key-type string :value-type function)
  :group 'overlook)

(defvar overlook-usage-current-functions nil
  "Functions telling whether a usage row's account is the one in use.
Each is called with the row's name, like \"claude\" or \"claude @home\",
and returns non-nil when new agents run as that row's account.  They are
asked only for agents with more than one row; the account of an agent's
only row is the one in use.  Its name is drawn in
`overlook-usage-current-account'.")

(defface overlook-usage-current-account
  '((t :inherit default))
  "Face of the account name of the usage row whose account is in use."
  :group 'overlook)

(defvar overlook-usage--json-cache nil
  "Alist of each file read by `overlook-usage--read-json' to (MTIME . JSON).")

(defun overlook-usage--read-json (file)
  "FILE parsed as JSON alists, re-read only when it changes; nil if unreadable."
  (when-let* ((mtime (file-attribute-modification-time (file-attributes file))))
    (let ((cached (alist-get file overlook-usage--json-cache nil nil #'equal)))
      (if (equal (car cached) mtime)
          (cdr cached)
        (let ((json (ignore-errors
                      (with-temp-buffer
                        (insert-file-contents file)
                        (json-parse-buffer :object-type 'alist :null-object nil)))))
          (setf (alist-get file overlook-usage--json-cache nil nil #'equal) (cons mtime json))
          json)))))

(defun overlook-usage--email-name (email)
  "The part of EMAIL before @, or nil."
  (and (stringp email) (car (split-string email "@"))))

(defun overlook-usage-claude-login ()
  "The account Claude Code is logged in as, from its config file."
  (overlook-usage--email-name
   (let-alist (overlook-usage--read-json
               (expand-file-name ".claude.json" (or (getenv "CLAUDE_CONFIG_DIR") "~")))
     .oauthAccount.emailAddress)))

(defun overlook-usage-codex-login ()
  "The account Codex is logged in as, from the ID token in its auth file."
  (when-let* ((token (let-alist (overlook-usage--read-json
                                 (expand-file-name "auth.json" (or (getenv "CODEX_HOME") "~/.codex")))
                       .tokens.id_token))
              (payload (cadr (split-string token "\\."))))
    (overlook-usage--email-name
     (ignore-errors
       (alist-get 'email
                  (json-parse-string
                   (decode-coding-string
                    (base64-decode-string (concat payload (make-string (% (- 4 (% (length payload) 4)) 4) ?=))
                                          t)
                    'utf-8)
                   :object-type 'alist))))))

(defcustom overlook-usage-functions '(overlook-usage-claude overlook-usage-codex)
  "Functions returning an agent's plan usage, shown on the dashboard.
Each returns (NAME . WINDOWS), a list of them, or nil when it knows
none.  WINDOWS lists (LABEL PERCENT RESETS-AT), like (\"5h\" 42
1790963218); RESETS-AT is seconds since the epoch, or nil, or a string
drawn in place of the countdown.  PERCENT may instead be a formatted
string for a metric without a bar."
  :type '(repeat function)
  :group 'overlook)

(defvar overlook-usage--rows nil
  "Plan usage as `overlook-usage-functions' last returned it.")

(defvar overlook-usage--codex nil
  "Codex usage windows, as ((FILE MTIME) . WINDOWS) for the logs they came from.")

(defvar overlook-usage--minute nil
  "Minute the reset countdowns were last drawn in.")

(defvar overlook-usage--claude nil
  "Alist of each Claude account to its windows from the last file that carried any.
The account of `overlook-usage-file' is nil.")

(defcustom overlook-usage-claude-url "https://claude.ai/settings/usage"
  "Page the dashboard's Claude usage row opens on RET."
  :type 'string
  :group 'overlook)

(defun overlook-usage-open-claude ()
  "Open Claude's plan usage page in a browser."
  (interactive)
  (browse-url overlook-usage-claude-url))

(defun overlook-usage--claude-file (account)
  "File keeping the Claude usage of ACCOUNT, nil for `overlook-usage-file'."
  (if account
      (concat (file-name-sans-extension overlook-usage-file) "-" account
              (if-let* ((extension (file-name-extension overlook-usage-file)))
                  (concat "." extension)
                ""))
    overlook-usage-file))

(defun overlook-usage--claude-accounts ()
  "Accounts with a Claude usage file, nil for `overlook-usage-file' first."
  (let ((base (file-name-nondirectory (file-name-sans-extension overlook-usage-file)))
        (extension (file-name-extension overlook-usage-file t)))
    (cons nil
          (mapcar (lambda (file)
                    (substring (file-name-nondirectory file) (1+ (length base))
                               (- (length (file-name-nondirectory file)) (length extension))))
                  (ignore-errors
                    (directory-files (file-name-directory overlook-usage-file) t
                                     (concat "\\`" (regexp-quote base) "-.+"
                                             (regexp-quote extension) "\\'")))))))

(defun overlook-usage-save-claude (usage &optional account)
  "Save Claude's plan USAGE of ACCOUNT, nil for the one in `overlook-usage-file'.
USAGE maps window keys like `five_hour' to alists with `used_percentage'
and `resets_at'."
  (make-directory (file-name-directory overlook-usage-file) t)
  (let ((temp (make-temp-file (expand-file-name "claude-usage"
                                                (file-name-directory overlook-usage-file)))))
    (with-temp-file temp (insert (json-encode usage)))
    (rename-file temp (overlook-usage--claude-file account) t)))

(defun overlook-usage--claude-windows (account)
  "Claude's usage windows of ACCOUNT as its file has them, or nil."
  (when-let* ((usage (ignore-errors
                       (with-temp-buffer
                         (insert-file-contents (overlook-usage--claude-file account))
                         (json-parse-buffer :object-type 'alist :null-object nil)))))
    (cl-loop for (key . label) in '((five_hour . "5h") (seven_day . "7d"))
             for window = (alist-get key usage)
             when (alist-get 'used_percentage window)
             collect (list label it (let ((resets (alist-get 'resets_at window)))
                                      (and (numberp resets) resets))))))

(defun overlook-usage-claude ()
  "Claude's plan usage of each account, as `overlook-usage-save-claude' saved it.
A file without any windows, or none at all, keeps the last reading, so the
row stays visible while Claude Code reconnects instead of dropping out."
  (dolist (account (overlook-usage--claude-accounts))
    (when-let* ((windows (overlook-usage--claude-windows account)))
      (setf (alist-get account overlook-usage--claude nil nil #'equal) windows)))
  (mapcar (pcase-lambda (`(,account . ,windows))
            (cons (propertize (if account (concat "claude @" account) "claude")
                              'overlook-action #'overlook-usage-open-claude
                              'help-echo "RET opens Claude's usage page")
                  windows))
          (sort (copy-sequence overlook-usage--claude)
                (lambda (a b) (and (null (car a)) (car b))))))

(defcustom overlook-usage-codex-url "https://chatgpt.com/settings/usage?tab=overview"
  "Page the dashboard's Codex usage row opens on RET."
  :type 'string
  :group 'overlook)

(defun overlook-usage-open-codex ()
  "Open Codex's plan usage page in a browser."
  (interactive)
  (browse-url overlook-usage-codex-url))

(defun overlook-usage--codex-logs ()
  "Codex session logs, newest first.
Logs live in YYYY/MM/DD/rollout-TIME-….jsonl, so name order is time order."
  (let ((dir (expand-file-name overlook-usage-codex-sessions-directory)))
    (dotimes (_ 3)
      (setq dir (and dir (file-directory-p dir)
                     (car (last (directory-files dir t "\\`[0-9]+\\'"))))))
    (and dir (reverse (directory-files dir t "\\`rollout-.*\\.jsonl\\'")))))

(defun overlook-usage--codex-rate-limits (file)
  "Rate limits of the last token count in Codex session log FILE, or nil."
  (with-temp-buffer
    ;; Logs can grow to tens of megabytes, so read only their end.
    (let ((size (file-attribute-size (file-attributes file))))
      (insert-file-contents file nil (max 0 (- size 262144)) size))
    (goto-char (point-max))
    (when (search-backward "\"rate_limits\":{" nil t)
      (alist-get 'rate_limits
                 (alist-get 'payload
                            (json-parse-string (buffer-substring (line-beginning-position)
                                                                 (line-end-position))
                                               :object-type 'alist :null-object nil))))))

(defun overlook-usage--codex-windows (limits)
  "Usage windows described by Codex rate LIMITS, or nil when it has none.
Recent logs can carry a LIMITS map whose windows are null; those count as
none, so the last real reading is kept instead of replacing it."
  (when limits
    (cl-loop for key in '(primary secondary)
             for window = (alist-get key limits)
             for minutes = (alist-get 'window_minutes window)
             when (and minutes (alist-get 'used_percent window))
             collect (list (if (>= minutes 1440)
                               (format "%dd" (/ minutes 1440))
                             (format "%dh" (/ minutes 60)))
                           it
                           (alist-get 'resets_at window)))))

(defun overlook-usage--codex-usage-windows (logs)
  "Windows from the newest of LOGS that carries any, or nil.
Recent logs can report none once a limit is reached; the newest real
reading is then kept instead of the row disappearing."
  (seq-some (lambda (file)
              (ignore-errors
                (overlook-usage--codex-windows (overlook-usage--codex-rate-limits file))))
            logs))

(defun overlook-usage-codex ()
  "Codex's plan usage, from its newest session log that reports any.
Recent logs report none once a limit is reached; the last reading then
stays, so the row and its reset countdown remain visible."
  (when-let* ((logs (overlook-usage--codex-logs)))
    (let ((stamp (list (car logs)
                       (file-attribute-modification-time (file-attributes (car logs))))))
      (unless (equal stamp (car overlook-usage--codex))
        (setq overlook-usage--codex
              (cons stamp (or (overlook-usage--codex-usage-windows logs)
                              (cdr overlook-usage--codex))))))
    (when-let* ((windows (cdr overlook-usage--codex)))
      (cons (propertize "codex"
                        'overlook-action #'overlook-usage-open-codex
                        'help-echo "RET opens Codex's usage page")
            windows))))


(defun overlook-usage-next-reset (name &optional now)
  "Return the next usable reset time for usage row NAME after NOW.
When several windows are exhausted, wait for all of them to reset."
  (let* ((now (or now (float-time)))
         (rows (append (overlook-usage-claude)
                       (when-let* ((row (overlook-usage-codex))) (list row))))
         (windows (cdr (assoc name rows)))
         (exhausted (seq-filter (lambda (window) (>= (nth 1 window) 100)) windows))
         (selected (or exhausted windows)))
    (when (and selected
               (seq-every-p (lambda (window) (numberp (nth 2 window))) selected))
      (let ((times (mapcar (lambda (window) (nth 2 window)) selected)))
        (if exhausted
            (max now (apply #'max times))
          (when-let* ((future (seq-filter (lambda (time) (> time now)) times)))
            (apply #'min future)))))))

(defface overlook-usage-bar
  '((t :inherit font-lock-keyword-face))
  "Face of the used part of a plan usage bar."
  :group 'overlook)

(defface overlook-usage-bar-track
  '((((background dark)) :foreground "#333333")
    (t :foreground "#d4d4d4"))
  "Face of the unused part of a plan usage bar."
  :group 'overlook)

(defun overlook-usage--bar (percentage width)
  "A bar WIDTH columns long filled to PERCENTAGE.
It turns `warning' from `overlook-usage-warning'."
  (let ((filled (min width (round (* percentage width) 100))))
    (concat (propertize (make-string filled ?━)
                        'face (if (>= percentage overlook-usage-warning) 'warning 'overlook-usage-bar))
            (propertize (make-string (- width filled) ?━) 'face 'overlook-usage-bar-track))))

(defun overlook-usage--label (name &optional current)
  "NAME as `overlook-agent-icons' draws it, keeping NAME's properties.
In a NAME like \"claude @home\", the agent's name before \" @\" is drawn
by its icon and the account as `overlook-account-name' draws it, or in
`overlook-usage-current-account' when CURRENT is non-nil.  So is the
account `overlook-usage-accounts' gives, else the one it is logged in as."
  (let* ((at (string-search " @" name))
         (agent (if at (substring name 0 at) name))
         (account (if at
                      (substring-no-properties name (+ at 2))
                    (let ((row (substring-no-properties name)))
                      (or (alist-get row overlook-usage-accounts nil nil #'equal)
                          (when-let* ((login (alist-get row overlook-usage-login-functions
                                                        nil nil #'equal)))
                            (funcall login)))))))
    (concat (overlook-icon agent)
            (and account
                 (concat " " (if current
                                 (propertize (substring-no-properties (overlook-account-name account))
                                             'face 'overlook-usage-current-account)
                               (overlook-account-name account)))))))

(defun overlook-usage--agent (name)
  "The agent of usage row NAME, the part before \" @\"."
  (substring-no-properties name 0 (string-search " @" name)))

(defun overlook-usage--labels (names)
  "The labels of the usage rows NAMES, each agent's account in use highlighted."
  (let ((agents (mapcar #'overlook-usage--agent names)))
    (cl-mapcar (lambda (name agent)
                 (overlook-usage--label
                  name (or (= (cl-count agent agents :test #'equal) 1)
                           (run-hook-with-args-until-success 'overlook-usage-current-functions
                                                             (substring-no-properties name)))))
               names agents)))

(defun overlook-usage--dashboard-rows ()
  "A row per agent in `overlook-usage--rows', with a bar per usage window.
A window past its reset counts as empty, and a row with no windows is
left out; anything the agent ever reported stays listed.  A row whose
name carries `overlook-action' runs it when the line is visited.
Columns are as wide as their widest entry, and the bars take what the
window has left, up to 20 columns; where that is too little, each window
takes a line of its own, under the first, and its bar fills the line."
  (let* ((now (float-time))
         (rows (mapcar (lambda (row)
                         (cons (car row) (overlook-usage-windows (cdr row) now)))
                       (seq-filter #'cdr overlook-usage--rows)))
         (shown (overlook-usage--labels (mapcar #'car rows)))
         (windows (mapcan (lambda (row) (copy-sequence (cdr row))) rows))
         (texts (seq-filter (lambda (window) (stringp (nth 1 window))) windows))
         (meters (seq-remove (lambda (window) (stringp (nth 1 window))) windows))
         (countdown (lambda (window)
                      (let ((resets (nth 2 window)))
                        (cond ((stringp resets) resets)
                              (resets (overlook-format-duration (- resets now)))
                              (t "")))))
         (label-width (apply #'max 0 (mapcar (lambda (window) (string-width (car window))) meters)))
         (countdown-width (apply #'max 0 (mapcar (lambda (window)
                                                   (string-width (funcall countdown window)))
                                                 meters)))
         ;; A meter's label, percentage like " 42%" and countdown, around its bar.
         (fixed (+ label-width 1 5 1 countdown-width))
         ;; Text values end where percentages do, in the countdown column only when short of room.
         (tail (if meters (1+ countdown-width) 0))
         (text-width (apply #'max 0 (mapcar (lambda (window)
                                              (+ (string-width (car window)) 1
                                                 (string-width (nth 1 window))))
                                            texts)))
         (count (apply #'max 1 (mapcar (lambda (row) (length (cdr row))) rows)))
         ;; Measured as drawn, so once the first row is drawn.
         (name-width nil)
         ;; Windows are 3 columns apart, and the row leaves 1 at its end;
         ;; bars shorter than 8 to share a line get a line each, filling it.
         (bar (lambda (columns)
                (max 4 (- text-width fixed)
                     (if (not columns)
                         12
                       (let* ((room (- columns 2 1
                                       (with-memoization name-width
                                         (apply #'max 0 (mapcar #'overlook-string-columns
                                                                shown)))))
                              (shared (- (/ (- room (* (1- count) 3)) count) fixed)))
                         (if (and (> count 1) (>= shared 8))
                             (min 20 shared)
                           (- room fixed))))))))
    (cl-loop
     for (name . windows) in rows
     for icon in shown
     collect
     (let ((windows windows) (icon icon))
       (overlook-row
        :id (cons 'usage (substring-no-properties name))
        :action (get-text-property 0 'overlook-action name)
        :face 'overlook-tabular
        :content
        (lambda (columns)
          (let ((bar (funcall bar columns)))
            (list
             (list :pad icon :like shown) "  "
             (list
              :wrap
              (mapcar
               (pcase-lambda (`(,label ,percentage ,resets))
                 (if (stringp percentage)
                     (let* ((room (- (+ bar fixed) (string-width label) (string-width percentage)))
                            (trailing (max 0 (min tail (1- room)))))
                       (concat (propertize label 'face 'shadow)
                               (make-string (max 1 (- room trailing)) ?\s)
                               percentage
                               (make-string trailing ?\s)))
                   (concat (propertize (string-pad label label-width) 'face 'shadow) " "
                           (overlook-usage--bar percentage bar)
                           (propertize (format " %3d%%" (floor percentage))
                                       'face (if (>= percentage overlook-usage-warning)
                                                 'warning
                                               'default))
                           (let ((text (concat " " (string-pad (funcall countdown
                                                                         (list label percentage resets))
                                                                countdown-width))))
                             (if (stringp resets) text (propertize text 'face 'shadow))))))
               windows)
              :gap 3)))))))))

;;; Pollers

(defvar overlook-usage--pollers nil
  "Alist of (FUNCTION . INTERVAL) from `overlook-usage-add-poller'.")

(defvar overlook-usage--polled (make-hash-table :test #'eq)
  "Poller function to the time it last started a request.")

(defun overlook-usage-add-poller (function &optional interval)
  "Call FUNCTION while the dashboard is live, at most every INTERVAL seconds.
INTERVAL defaults to 300.  FUNCTION starts a request and returns non-nil,
or returns nil when it started none, such as while the last one is
unanswered; it is then tried again on the next tick.  An error counts as
a started request."
  (setf (alist-get function overlook-usage--pollers) (or interval 300)))

(defun overlook-usage--poll ()
  "Call the pollers whose interval has passed."
  (pcase-dolist (`(,function . ,interval) overlook-usage--pollers)
    (when (and (>= (- (float-time) (gethash function overlook-usage--polled 0))
                   interval)
               (condition-case nil (funcall function) (error t)))
      (puthash function (float-time) overlook-usage--polled))))

;;; Scan

(defvar overlook-usage-state-change-hook nil
  "Functions called with row NAME and STATE, either exhausted or available.
Recovery includes expiry of all exhausted windows, even without new readings.")

(defvar overlook-usage--states (make-hash-table :test #'equal)
  "Last known availability per subscription row.")

(defun overlook-usage-state (name)
  "Return NAME's current quota state, or nil when readings are unknown."
  (let ((windows (overlook-usage-windows
                  (cdr (assoc name overlook-usage--rows)))))
    (cond
     ((seq-some (lambda (w) (and (numberp (nth 1 w)) (>= (nth 1 w) 100)))
                windows)
      'exhausted)
     ((and windows (seq-every-p (lambda (w) (numberp (nth 1 w))) windows))
      'available))))

(defun overlook-usage-near-limit-p (agent)
  "Non-nil when the plan new AGENT agents run on is near its limit.
That is a window of its row at `overlook-usage-warning' or more; of
several rows of AGENT's, the account in use's.  Unknown usage is not."
  (let* ((rows (seq-filter (lambda (row) (equal (overlook-usage--agent (car row)) agent))
                           overlook-usage--rows))
         (row (if (cdr rows)
                  (seq-find (lambda (row)
                              (run-hook-with-args-until-success
                               'overlook-usage-current-functions (substring-no-properties (car row))))
                            rows)
                (car rows))))
    (seq-some (lambda (window)
                (and (numberp (nth 1 window)) (>= (nth 1 window) overlook-usage-warning)))
              (overlook-usage-windows (cdr row)))))

(defun overlook-usage--publish ()
  "Publish known availability transitions once per row."
  (dolist (row overlook-usage--rows)
    (let* ((name (substring-no-properties (car row)))
           (state (overlook-usage-state name)))
      (when (and state (not (eq state (gethash name overlook-usage--states))))
        (puthash name state overlook-usage--states)
        (run-hook-with-args 'overlook-usage-state-change-hook name state)))))

(defvar overlook-usage-filter-functions nil
  "Functions transforming collected usage rows before publishing.")

(defun overlook-usage-scan ()
  "Refresh plan usage and redraw the dashboard when it changed."
  (let ((usage (mapcan (lambda (function)
                         (let ((rows (ignore-errors (funcall function))))
                           (if (stringp (car rows)) (list rows) (copy-sequence rows))))
                       overlook-usage-functions)))
    (dolist (function overlook-usage-filter-functions)
      (setq usage (funcall function usage)))
    (unless (and (equal usage overlook-usage--rows)
                 (or (null usage) (equal overlook-usage--minute
                                         (floor (float-time) 60))))
      (setq overlook-usage--rows usage
            overlook-usage--minute (floor (float-time) 60))
      (overlook-refresh))
    (overlook-usage--publish)))

(defun overlook-usage--section ()
  "The Usage section of the dashboard."
  (overlook-section-row "Usage" (overlook-usage--dashboard-rows)))

;;;###autoload
(define-minor-mode overlook-usage-mode
  "Show agents' plan usage at the top of the dashboard."
  :global t
  :group 'overlook
  (when overlook-usage-mode (require 'overlook-usage-subscription))
  (if overlook-usage-mode
      (overlook-start-updates 'usage)
    (overlook-stop-updates 'usage))
  (overlook-toggle-hooks
   overlook-usage-mode
   '((overlook-sections overlook-usage--section -50)
     (overlook-tick-hook overlook-usage--poll)
     (overlook-tick-hook overlook-usage-scan)))
  (overlook-refresh))

(defun overlook-usage-windows (windows &optional now)
  "Current values of WINDOWS, counting expired windows as empty at NOW."
  (let ((now (or now (float-time))))
    (mapcar (lambda (window)
              (if (and (numberp (nth 2 window)) (<= (nth 2 window) now))
                  (list (car window) 0 nil)
                window))
            windows)))

(defun overlook-usage-data (key)
  "Usage KEY's windows as values, independent of the dashboard bars."
  (pcase key
    (`(usage . ,name)
     (let* ((provider (overlook-usage--agent name))
            (at (string-search " @" name))
            (account (if at (substring name (+ at 2))
                       (alist-get name overlook-usage-accounts nil nil #'equal))))
       (list :kind "usage" :title provider :provider provider :account account
             :windows
             (vconcat
              (mapcar (pcase-lambda (`(,label ,value ,reset))
                        (list :label label :value value :reset reset))
                      (overlook-usage-windows
                       (cdr (assoc name overlook-usage--rows))))))))))

(defun overlook-usage--row-data (row)
  "Compatibility adapter for ROW's business data."
  (overlook-usage-data (overlook-row-id row)))

(add-hook 'overlook-data-functions #'overlook-usage-data)

(provide 'overlook-usage)
;;; overlook-usage.el ends here
