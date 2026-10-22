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
;; `overlook-usage-file' so they survive a restart; Codex's from its newest
;; session log.  Both are undocumented and may stop working.  Add a row by
;; pushing onto `overlook-usage-functions'.  The rows are re-read on every
;; `overlook-tick-hook'.

;;; Code:

(require 'overlook)
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defvar overlook-agent-icons)

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

(defcustom overlook-usage-functions '(overlook-usage-claude overlook-usage-codex)
  "Functions returning an agent's plan usage, shown on the dashboard.
Each returns (NAME . WINDOWS), or nil when it knows none.  WINDOWS lists
\(LABEL PERCENT RESETS-AT), like (\"5h\" 42 1790963218); RESETS-AT is
seconds since the epoch, or nil.  PERCENT may instead be a formatted string
for a metric without a bar."
  :type '(repeat function)
  :group 'overlook)

(defvar overlook-usage--rows nil
  "Plan usage as `overlook-usage-functions' last returned it.")

(defvar overlook-usage--codex nil
  "Codex usage windows, as ((FILE MTIME) . WINDOWS) for the logs they came from.")

(defvar overlook-usage--minute nil
  "Minute the reset countdowns were last drawn in.")

(defvar overlook-usage--claude nil
  "Claude's usage windows from the last file that carried any.")

(defcustom overlook-usage-claude-url "https://claude.ai/settings/usage"
  "Page the dashboard's Claude usage row opens on RET."
  :type 'string
  :group 'overlook)

(defun overlook-usage-open-claude ()
  "Open Claude's plan usage page in a browser."
  (interactive)
  (browse-url overlook-usage-claude-url))

(defun overlook-usage-save-claude (usage)
  "Save Claude's plan USAGE to `overlook-usage-file'.
USAGE maps window keys like `five_hour' to alists with `used_percentage'
and `resets_at'."
  (make-directory (file-name-directory overlook-usage-file) t)
  (let ((temp (make-temp-file (expand-file-name "claude-usage"
                                                (file-name-directory overlook-usage-file)))))
    (with-temp-file temp (insert (json-encode usage)))
    (rename-file temp overlook-usage-file t)))

(defun overlook-usage-claude ()
  "Claude's plan usage, as `overlook-usage-save-claude' saved it.
A file without any windows, or none at all, keeps the last reading, so the
row stays visible while Claude Code reconnects instead of dropping out."
  (let ((usage (ignore-errors
                 (with-temp-buffer
                   (insert-file-contents overlook-usage-file)
                   (json-parse-buffer :object-type 'alist :null-object nil)))))
    (when-let* ((windows
                 (when usage
                   (cl-loop for (key . label) in '((five_hour . "5h") (seven_day . "7d"))
                            for window = (alist-get key usage)
                            when (alist-get 'used_percentage window)
                            collect (list label it (let ((resets (alist-get 'resets_at window)))
                                                     (and (numberp resets) resets)))))))
      (setq overlook-usage--claude windows))
    (when overlook-usage--claude
      (cons (propertize "claude"
                        'overlook-action #'overlook-usage-open-claude
                        'help-echo "RET opens Claude's usage page")
            overlook-usage--claude))))

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

(defun overlook-usage--label (name)
  "NAME as `overlook-agent-icons' draws it, keeping NAME's properties."
  (if-let* ((icon (alist-get (substring-no-properties name)
                             (bound-and-true-p overlook-agent-icons) nil nil #'equal)))
      (let ((icon (copy-sequence icon))
            (face (get-text-property 0 'face name)))
        (cl-loop for (property value) on (text-properties-at 0 name) by #'cddr
                 unless (eq property 'face)
                 do (put-text-property 0 (length icon) property value icon))
        (when face (add-face-text-property 0 (length icon) face nil icon))
        icon)
    name))

(defun overlook-usage--insert ()
  "Insert a row per agent in `overlook-usage--rows', with a bar per usage window.
A window past its reset counts as empty, and a row with no windows is
left out; anything the agent ever reported stays listed.  A row whose
name carries `overlook-action' runs it when the line is visited.
Columns are as wide as their widest entry, and the bars take what the
window has left, so a row never wraps."
  (let* ((now (float-time))
         (rows (mapcar (lambda (row)
                         (cons (car row)
                               (mapcar (lambda (window)
                                         (if (and (numberp (nth 2 window)) (<= (nth 2 window) now))
                                             (list (car window) 0 nil)
                                           window))
                                       (cdr row))))
                       (seq-filter #'cdr overlook-usage--rows)))
         (shown (mapcar (lambda (row) (overlook-usage--label (car row))) rows))
         (windows (mapcan (lambda (row) (copy-sequence (cdr row))) rows))
         (texts (seq-filter (lambda (window) (stringp (nth 1 window))) windows))
         (meters (seq-remove (lambda (window) (stringp (nth 1 window))) windows))
         (countdown (lambda (window)
                      (if (nth 2 window) (overlook-format-duration (- (nth 2 window) now)) "")))
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
         (name-width (apply #'max 0 (mapcar #'string-width shown)))
         (count (apply #'max 1 (mapcar (lambda (row) (length (cdr row))) rows)))
         (window (get-buffer-window (current-buffer) t))
         (columns (if window (window-body-width window) (overlook-columns)))
         ;; Windows are 3 columns apart, and the row leaves 1 at its end.
         (bar (max 4 (- text-width fixed)
                   (min 20 (/ (- columns (length overlook-indent) name-width 2 1
                                 (* count fixed) (* (1- count) 3))
                              count)))))
    (cl-loop
     for (name . windows) in rows
     for icon in shown
     do
     (overlook-insert-row
       (propertize
        (concat
         (if-let* ((action (get-text-property 0 'overlook-action name)))
             (propertize overlook-indent 'overlook-action action)
           overlook-indent)
         icon (make-string (- (+ name-width 2) (string-width icon)) ?\s)
         (mapconcat
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
                      (propertize (concat " " (string-pad (funcall countdown (list label percentage resets))
                                                          countdown-width))
                                  'face 'shadow))))
          windows "   ")
         "\n")
        'overlook-item (cons 'usage (substring-no-properties name)))))))

;;; Scan

(defun overlook-usage-scan ()
  "Refresh plan usage and redraw the dashboard when it changed."
  (let ((usage (delq nil (mapcar (lambda (function) (ignore-errors (funcall function)))
                                 overlook-usage-functions))))
    (unless (and (equal usage overlook-usage--rows)
                 (or (null usage) (equal overlook-usage--minute
                                         (floor (float-time) 60))))
      (setq overlook-usage--rows usage
            overlook-usage--minute (floor (float-time) 60))
      (overlook-refresh))))

(defun overlook-usage--section ()
  "Insert the Usage section of the dashboard."
  (overlook-insert-section "Usage" #'overlook-usage--insert))

;;;###autoload
(define-minor-mode overlook-usage-mode
  "Show agents' plan usage at the top of the dashboard."
  :global t
  :group 'overlook
  (overlook-toggle-hooks
   overlook-usage-mode
   '((overlook-sections overlook-usage--section -50)
     (overlook-tick-hook overlook-usage-scan)))
  (overlook-refresh))

(provide 'overlook-usage)
;;; overlook-usage.el ends here
