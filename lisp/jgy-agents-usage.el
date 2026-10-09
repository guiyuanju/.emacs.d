;;; jgy-agents-usage.el --- Claude and Codex plan usage for the dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;; The plan usage rows at the top of the agents dashboard.  Claude's windows
;; come from the rate limits agent-shell forwards, kept in `jgy-agents-usage-file'
;; so they survive a restart; Codex's from its newest session log.  Other
;; agents add a row by pushing onto `jgy-agents-usage-functions' (see
;; jgy-agents-deepseek.el).  The rows are re-read on every
;; `jgy-agents-tick-hook' while the dashboard is live.

;;; Code:

(require 'jgy-agents-dashboard)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defcustom jgy-agents-usage-file (locate-user-emacs-file "var/claude-usage.json")
  "File keeping Claude's last plan usage.
`jgy-agents-usage-save-claude' writes it."
  :type 'file
  :group 'jgy-agents)

(defcustom jgy-agents-usage-warning 80
  "Plan usage percentage from which the dashboard highlights it."
  :type 'natnum
  :group 'jgy-agents)

(defcustom jgy-agents-usage-codex-sessions-directory "~/.codex/sessions"
  "Directory where Codex writes its session logs, which carry its plan usage."
  :type 'directory
  :group 'jgy-agents)

(defcustom jgy-agents-usage-functions '(jgy-agents-usage-claude jgy-agents-usage-codex)
  "Functions returning an agent's plan usage, shown on the dashboard.
Each returns (NAME . WINDOWS), or nil when it knows none.  WINDOWS lists
\(LABEL PERCENT RESETS-AT), like (\"5h\" 42 1790963218); RESETS-AT is
seconds since the epoch, or nil.  PERCENT may instead be a formatted string
for a metric without a bar."
  :type '(repeat function)
  :group 'jgy-agents)

(defvar jgy-agents-usage--rows nil
  "Plan usage as `jgy-agents-usage-functions' last returned it.")

(defvar jgy-agents-usage--codex nil
  "Codex usage windows, as ((FILE MTIME) . WINDOWS) for the logs they came from.")

(defvar jgy-agents-usage--minute nil
  "Minute the reset countdowns were last drawn in.")

(defvar jgy-agents-usage--claude nil
  "Claude's usage windows from the last file that carried any.")

(defcustom jgy-agents-usage-claude-url "https://claude.ai/settings/usage"
  "Page the dashboard's Claude usage row opens on RET."
  :type 'string
  :group 'jgy-agents)

(defun jgy-agents-usage-open-claude ()
  "Open Claude's plan usage page in a browser."
  (interactive)
  (browse-url jgy-agents-usage-claude-url))

(defun jgy-agents-usage-save-claude (usage)
  "Save Claude's plan USAGE to `jgy-agents-usage-file'.
USAGE maps window keys like `five_hour' to alists with `used_percentage'
and `resets_at'."
  (make-directory (file-name-directory jgy-agents-usage-file) t)
  (let ((temp (make-temp-file (expand-file-name "claude-usage"
                                                (file-name-directory jgy-agents-usage-file)))))
    (with-temp-file temp (insert (json-encode usage)))
    (rename-file temp jgy-agents-usage-file t)))

(defun jgy-agents-usage-claude ()
  "Claude's plan usage, as `jgy-agents-usage-save-claude' saved it.
A file without any windows, or none at all, keeps the last reading, so the
row stays visible while Claude Code reconnects instead of dropping out."
  (let ((usage (ignore-errors
                 (with-temp-buffer
                   (insert-file-contents jgy-agents-usage-file)
                   (json-parse-buffer :object-type 'alist :null-object nil)))))
    (when-let* ((windows
                 (when usage
                   (cl-loop for (key . label) in '((five_hour . "5h") (seven_day . "7d"))
                            for window = (alist-get key usage)
                            when (alist-get 'used_percentage window)
                            collect (list label it (let ((resets (alist-get 'resets_at window)))
                                                     (and (numberp resets) resets)))))))
      (setq jgy-agents-usage--claude windows))
    (when jgy-agents-usage--claude
      (cons (propertize "claude"
                        'jgy-agents-action #'jgy-agents-usage-open-claude
                        'help-echo "RET opens Claude's usage page")
            jgy-agents-usage--claude))))

(defcustom jgy-agents-usage-codex-url "https://chatgpt.com/settings/usage?tab=overview"
  "Page the dashboard's Codex usage row opens on RET."
  :type 'string
  :group 'jgy-agents)

(defun jgy-agents-usage-open-codex ()
  "Open Codex's plan usage page in a browser."
  (interactive)
  (browse-url jgy-agents-usage-codex-url))

(defun jgy-agents-usage--codex-logs ()
  "Codex session logs, newest first.
Logs live in 年/月/日/rollout-时间-….jsonl, so name order is time order."
  (let ((dir (expand-file-name jgy-agents-usage-codex-sessions-directory)))
    (dotimes (_ 3)
      (setq dir (and dir (file-directory-p dir)
                     (car (last (directory-files dir t "\\`[0-9]+\\'"))))))
    (and dir (reverse (directory-files dir t "\\`rollout-.*\\.jsonl\\'")))))

(defun jgy-agents-usage--codex-rate-limits (file)
  "Rate limits of the last token count in Codex session log FILE, or nil."
  (with-temp-buffer
    ;; 日志可能有几十 MB，只读结尾。
    (let ((size (file-attribute-size (file-attributes file))))
      (insert-file-contents file nil (max 0 (- size 262144)) size))
    (goto-char (point-max))
    (when (search-backward "\"rate_limits\":{" nil t)
      (alist-get 'rate_limits
                 (alist-get 'payload
                            (json-parse-string (buffer-substring (line-beginning-position)
                                                                 (line-end-position))
                                               :object-type 'alist :null-object nil))))))

(defun jgy-agents-usage--codex-windows (limits)
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

(defun jgy-agents-usage--codex-usage-windows (logs)
  "Windows from the newest of LOGS that carries any, or nil.
Recent logs can report none once a limit is reached; the newest real
reading is then kept instead of the row disappearing."
  (seq-some (lambda (file)
              (ignore-errors
                (jgy-agents-usage--codex-windows (jgy-agents-usage--codex-rate-limits file))))
            logs))

(defun jgy-agents-usage-codex ()
  "Codex's plan usage, from its newest session log that reports any.
Recent logs report none once a limit is reached; the last reading then
stays, so the row and its reset countdown remain visible."
  (when-let* ((logs (jgy-agents-usage--codex-logs)))
    (let ((stamp (list (car logs)
                       (file-attribute-modification-time (file-attributes (car logs))))))
      (unless (equal stamp (car jgy-agents-usage--codex))
        (setq jgy-agents-usage--codex
              (cons stamp (or (jgy-agents-usage--codex-usage-windows logs)
                              (cdr jgy-agents-usage--codex))))))
    (when-let* ((windows (cdr jgy-agents-usage--codex)))
      (cons (propertize "codex"
                        'jgy-agents-action #'jgy-agents-usage-open-codex
                        'help-echo "RET opens Codex's usage page")
            windows))))


(defface jgy-agents-usage-bar
  '((t :inherit font-lock-keyword-face))
  "Face of the used part of a plan usage bar."
  :group 'jgy-agents)

(defface jgy-agents-usage-bar-track
  '((((background dark)) :foreground "#333333")
    (t :foreground "#d4d4d4"))
  "Face of the unused part of a plan usage bar."
  :group 'jgy-agents)

(defun jgy-agents-usage--bar (percentage width)
  "A bar WIDTH columns long filled to PERCENTAGE.
It turns `warning' from `jgy-agents-usage-warning'."
  (let ((filled (min width (round (* percentage width) 100))))
    (concat (propertize (make-string filled ?━)
                        'face (if (>= percentage jgy-agents-usage-warning) 'warning 'jgy-agents-usage-bar))
            (propertize (make-string (- width filled) ?━) 'face 'jgy-agents-usage-bar-track))))

(defun jgy-agents-usage--insert ()
  "Insert a row per agent in `jgy-agents-usage--rows', with a bar per usage window.
A window past its reset counts as empty, and a row with no windows is
left out; anything the agent ever reported stays listed.  A row whose
name carries `jgy-agents-action' runs it when the line is visited."
  (let* ((now (float-time))
         (past (lambda (window) (and (numberp (nth 2 window)) (<= (nth 2 window) now))))
         (rows (seq-filter #'cdr jgy-agents-usage--rows))
         (name-width (apply #'max 0 (mapcar (lambda (row) (string-width (car row))) rows)))
         (count (apply #'max 1 (mapcar (lambda (row) (length (cdr row))) rows)))
         (window (get-buffer-window (current-buffer) t))
         (columns (if window (window-body-width window) jgy-agents-dashboard-width))
         ;; 每个窗口除了条还要 14 列：5h、百分比和重置倒计时；窗口之间空 3 列，行尾留 1 列。
         (bar (max 4 (min 20 (/ (- columns (length jgy-agents-dashboard-indent) name-width 2 1
                                   (* count 14) (* (1- count) 3))
                                count)))))
    (pcase-dolist (`(,name . ,windows) rows)
      (insert (if-let* ((action (get-text-property 0 'jgy-agents-action name)))
                  (propertize jgy-agents-dashboard-indent 'jgy-agents-action action)
                jgy-agents-dashboard-indent)
              name (make-string (- (+ name-width 2) (string-width name)) ?\s)
              (mapconcat
               (lambda (window)
                 (pcase-let* ((`(,label ,percentage ,resets)
                               (if (funcall past window) (list (car window) 0 nil) window)))
                   (if (stringp percentage)
                       (concat (propertize label 'face 'shadow)
                               (make-string (max 1 (- (+ bar 14)
                                                      (string-width label)
                                                      (string-width percentage))) ?\s)
                               percentage)
                     (concat (propertize label 'face 'shadow) " "
                             (jgy-agents-usage--bar percentage bar)
                             (propertize (format " %3d%%" (floor percentage))
                                         'face (if (>= percentage jgy-agents-usage-warning)
                                                   'warning
                                                 'default))
                             (propertize (format " %-5s"
                                                 (if resets (jgy-agents-format-duration (- resets now)) ""))
                                         'face 'shadow)))))
               windows "   ")
              "\n"))))

;;; Scan

(defun jgy-agents-usage-scan ()
  "Refresh plan usage and redraw the dashboard when it changed."
  (let ((usage (delq nil (mapcar (lambda (function) (ignore-errors (funcall function)))
                                 jgy-agents-usage-functions))))
    (unless (and (equal usage jgy-agents-usage--rows)
                 (or (null usage) (equal jgy-agents-usage--minute
                                         (floor (float-time) 60))))
      (setq jgy-agents-usage--rows usage
            jgy-agents-usage--minute (floor (float-time) 60))
      (jgy-agents-refresh))))

(defun jgy-agents-usage--tick ()
  "Re-read plan usage while the dashboard is live."
  (when (jgy-agents-dashboard-live-p)
    (jgy-agents-usage-scan)))

(defun jgy-agents-usage--section (_frame)
  "Insert the Usage section of the dashboard."
  (jgy-agents-dashboard-insert-section "Usage" #'jgy-agents-usage--insert))

(add-hook 'jgy-agents-dashboard-functions #'jgy-agents-usage--section -50)
(add-hook 'jgy-agents-tick-hook #'jgy-agents-usage--tick)

(provide 'jgy-agents-usage)
;;; jgy-agents-usage.el ends here
