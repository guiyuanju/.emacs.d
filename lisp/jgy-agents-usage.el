;;; jgy-agents-usage.el --- Claude and Codex plan usage for the dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;; The plan usage rows at the top of the agents dashboard.  Claude's windows
;; come from the file bin/claude-statusline writes; Codex's from its newest
;; session log.  Other agents add a row by pushing onto
;; `agents-usage-functions' (see jgy-agents-deepseek.el).
;;
;; jgy-agents.el drives the refresh through `agents-usage-scan'.

;;; Code:

(require 'jgy-agents)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defcustom agents-usage-file
  (expand-file-name "claude-usage.json" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "File where bin/claude-statusline saves Claude's plan usage."
  :type 'file
  :group 'agents)

(defcustom agents-usage-warning 80
  "Plan usage percentage from which the dashboard highlights it."
  :type 'natnum
  :group 'agents)

(defcustom agents-codex-sessions-directory "~/.codex/sessions"
  "Directory where Codex writes its session logs, which carry its plan usage."
  :type 'directory
  :group 'agents)

(defcustom agents-usage-functions '(agents-usage-claude agents-usage-codex)
  "Functions returning an agent's plan usage, shown on the dashboard.
Each returns (NAME . WINDOWS), or nil when it knows none.  WINDOWS lists
\(LABEL PERCENT RESETS-AT), like (\"5h\" 42 1790963218); RESETS-AT is
seconds since the epoch, or nil.  PERCENT may instead be a formatted string
for a metric without a bar.  WINDOWS may also be a string of text rows."
  :type '(repeat function)
  :group 'agents)

(defvar agents--usage nil
  "Plan usage as `agents-usage-functions' last returned it.")

(defvar agents--codex-usage nil
  "Codex usage windows, as ((FILE MTIME) . WINDOWS) for the logs they came from.")

(defvar agents--usage-minute nil
  "Minute the reset countdowns were last drawn in.")

(defvar agents--claude-usage nil
  "Claude's usage windows from the last file that carried any.")

(defcustom agents-claude-usage-url "https://claude.ai/settings/usage"
  "Page the dashboard's Claude usage row opens on RET."
  :type 'string
  :group 'agents)

(defun agents-claude-open-usage ()
  "Open Claude's plan usage page in a browser."
  (interactive)
  (browse-url agents-claude-usage-url))

(defun agents-usage-claude ()
  "Claude's plan usage, as bin/claude-statusline saved it in `agents-usage-file'.
A file without any windows, or none at all, keeps the last reading, so the
row stays visible while Claude Code reconnects instead of dropping out."
  (let ((usage (ignore-errors
                 (with-temp-buffer
                   (insert-file-contents agents-usage-file)
                   (json-parse-buffer :object-type 'alist :null-object nil)))))
    (when-let* ((windows
                 (when usage
                   (cl-loop for (key . label) in '((five_hour . "5h") (seven_day . "7d"))
                            for window = (alist-get key usage)
                            when (alist-get 'used_percentage window)
                            collect (list label it (let ((resets (alist-get 'resets_at window)))
                                                     (and (numberp resets) resets)))))))
      (setq agents--claude-usage windows))
    (when agents--claude-usage
      (cons (propertize "claude"
                        'agents-action #'agents-claude-open-usage
                        'help-echo "RET opens Claude's usage page")
            agents--claude-usage))))

(defcustom agents-codex-usage-url "https://chatgpt.com/settings/usage?tab=overview"
  "Page the dashboard's Codex usage row opens on RET."
  :type 'string
  :group 'agents)

(defun agents-codex-open-usage ()
  "Open Codex's plan usage page in a browser."
  (interactive)
  (browse-url agents-codex-usage-url))

(defun agents--codex-logs ()
  "Codex session logs, newest first.
Logs live in 年/月/日/rollout-时间-….jsonl, so name order is time order."
  (let ((dir (expand-file-name agents-codex-sessions-directory)))
    (dotimes (_ 3)
      (setq dir (and dir (file-directory-p dir)
                     (car (last (directory-files dir t "\\`[0-9]+\\'"))))))
    (and dir (reverse (directory-files dir t "\\`rollout-.*\\.jsonl\\'")))))

(defun agents--codex-rate-limits (file)
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

(defun agents--codex-windows (limits)
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

(defun agents--codex-usage-windows (logs)
  "Windows from the newest of LOGS that carries any, or nil.
Recent logs can report none once a limit is reached; the newest real
reading is then kept instead of the row disappearing."
  (seq-some (lambda (file)
              (ignore-errors
                (agents--codex-windows (agents--codex-rate-limits file))))
            logs))

(defun agents-usage-codex ()
  "Codex's plan usage, from its newest session log that reports any.
Recent logs report none once a limit is reached; the last reading then
stays, so the row and its reset countdown remain visible."
  (when-let* ((logs (agents--codex-logs)))
    (let ((stamp (list (car logs)
                       (file-attribute-modification-time (file-attributes (car logs))))))
      (unless (equal stamp (car agents--codex-usage))
        (setq agents--codex-usage
              (cons stamp (or (agents--codex-usage-windows logs)
                              (cdr agents--codex-usage))))))
    (when-let* ((windows (cdr agents--codex-usage)))
      (cons (propertize "codex"
                        'agents-action #'agents-codex-open-usage
                        'help-echo "RET opens Codex's usage page")
            windows))))


(defface agents-bar
  '((t :inherit font-lock-keyword-face))
  "Face of the used part of a plan usage bar."
  :group 'agents)

(defface agents-bar-track
  '((((background dark)) :foreground "#333333")
    (t :foreground "#d4d4d4"))
  "Face of the unused part of a plan usage bar."
  :group 'agents)

(defun agents--usage-bar (percentage width)
  "A bar WIDTH columns long filled to PERCENTAGE.
It turns `warning' from `agents-usage-warning'."
  (let ((filled (min width (round (* percentage width) 100))))
    (concat (propertize (make-string filled ?━)
                        'face (if (>= percentage agents-usage-warning) 'warning 'agents-bar))
            (propertize (make-string (- width filled) ?━) 'face 'agents-bar-track))))

(defun agents--usage-insert ()
  "Insert a row per agent in `agents--usage', with a bar per usage window.
A window past its reset counts as empty, and a row with no windows is
left out; anything the agent ever reported stays listed.  A row whose
name carries `agents-action' runs it when the line is visited."
  (let* ((now (float-time))
         (past (lambda (window) (and (numberp (nth 2 window)) (<= (nth 2 window) now))))
         (rows (seq-filter (lambda (row) (or (stringp (cdr row)) (cdr row))) agents--usage))
         (name-width (apply #'max 0 (mapcar (lambda (row) (string-width (car row))) rows)))
         (count (apply #'max 1 (mapcar (lambda (row) (if (stringp (cdr row)) 0 (length (cdr row)))) rows)))
         (window (get-buffer-window (current-buffer) t))
         (columns (if window (window-body-width window) agents-dashboard-width))
         ;; 每个窗口除了条还要 14 列：5h、百分比和重置倒计时；窗口之间空 3 列，行尾留 1 列。
         (bar (max 4 (min 20 (/ (- columns (length agents--indent) name-width 2 1
                                   (* count 14) (* (1- count) 3))
                                count)))))
    (pcase-dolist (`(,name . ,windows) rows)
      (insert (if-let* ((action (get-text-property 0 'agents-action name)))
                  (propertize agents--indent 'agents-action action)
                agents--indent)
              name (make-string (- (+ name-width 2) (string-width name)) ?\s)
              (if (stringp windows)
                  (replace-regexp-in-string
                   "\n" (concat "\n" agents--indent (make-string (+ name-width 2) ?\s))
                   windows t t)
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
                               (agents--usage-bar percentage bar)
                               (propertize (format " %3d%%" (floor percentage))
                                           'face (if (>= percentage agents-usage-warning)
                                                     'warning
                                                   'default))
                               (propertize (format " %-5s"
                                                   (if resets (agents--duration (- resets now)) ""))
                                           'face 'shadow)))))
                 windows "   "))
              "\n"))))

;;; Scan

(defun agents-usage-scan ()
  "Refresh plan usage and redraw the dashboard when it changed."
  (let ((usage (delq nil (mapcar (lambda (function) (ignore-errors (funcall function)))
                                 agents-usage-functions))))
    (unless (and (equal usage agents--usage)
                 (or (null usage) (equal agents--usage-minute
                                         (floor (float-time) 60))))
      (setq agents--usage usage
            agents--usage-minute (floor (float-time) 60))
      (agents--dashboard-schedule))))

(provide 'jgy-agents-usage)
;;; jgy-agents-usage.el ends here
