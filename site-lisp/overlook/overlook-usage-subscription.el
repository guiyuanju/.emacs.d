;;; overlook-usage-subscription.el --- Poll subscription quotas -*- lexical-binding: t; -*-

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

;; Read-only quota requests using the CLI's existing OAuth credentials.

;;; Code:

(require 'overlook-usage)

(defvar overlook-agent-shell-claude-accounts)
(declare-function overlook-agent-shell--other-account "overlook-agent-shell" (account))

(defcustom overlook-usage-subscription-interval 300
  "Seconds between subscription quota requests."
  :type 'natnum
  :group 'overlook)

(defvar overlook-usage-subscription--state (make-hash-table :test #'equal)
  "Per-row request, backoff and last successful reading plists.")

(defun overlook-usage-subscription--json (text)
  "Parse TEXT without retaining it in an error message."
  (json-parse-string text :object-type 'alist :array-type 'list :null-object nil))

(defun overlook-usage-subscription--parse (provider data)
  "Convert PROVIDER's quota DATA to usage windows."
  (let (windows)
    (pcase-dolist (`(,key . ,label)
                   (if (eq provider 'claude)
                       '((five_hour . "5h") (seven_day . "7d"))
                     '((primary_window . "5h") (secondary_window . "7d"))))
      (let* ((window (alist-get key (if (eq provider 'claude) data
                                     (alist-get 'rate_limit data))))
             (used (alist-get (if (eq provider 'claude) 'utilization 'used_percent) window))
             (reset (alist-get (if (eq provider 'claude) 'resets_at 'reset_at) window)))
        (when (and (numberp used) (<= 0 used 100))
          (when (stringp reset)
            (setq reset (float-time (date-to-time reset))))
          (unless (numberp reset) (error "Missing quota reset"))
          (push (list label used reset) windows))))
    (or (nreverse windows) (error "No quota windows"))))

(defun overlook-usage-subscription--failed (row)
  "Back off ROW after a failed query, retaining its last reading."
  (let* ((state (gethash row overlook-usage-subscription--state))
         (delay (min 3600 (max overlook-usage-subscription-interval
                                (* 2 (or (plist-get state :delay) 0))))))
    (puthash row (plist-put (plist-put (plist-put state :delay delay)
                                     :next (+ (float-time) delay))
                           :error t)
             overlook-usage-subscription--state)))

(defun overlook-usage-subscription--local (row provider)
  "Return ROW's local reading for PROVIDER."
  (copy-tree
   (cdr (assoc row (if (eq provider 'claude)
                      (overlook-usage-claude)
                    (list (overlook-usage-codex)))))))

(defun overlook-usage-subscription--request (row provider token &optional account login)
  "Query ROW for PROVIDER with TOKEN and optional ACCOUNT and LOGIN."
  (let ((buffer (generate-new-buffer " *overlook-quota*"))
        (local (overlook-usage-subscription--local row provider)))
    (condition-case nil
        (progn
          (unless (and (stringp token)
                       (string-match-p "\\`[A-Za-z0-9._~-]+\\'" token)
                       (or (null account)
                           (string-match-p "\\`[A-Za-z0-9_-]+\\'" account)))
            (error "Invalid credential"))
          (let ((process
                 (make-process
                  :name "overlook-quota" :buffer buffer :noquery t
                  :connection-type 'pipe
                  :command (list "curl" "-q" "--silent" "--fail" "--max-time" "20"
                                 "--config" "-"
                                 (if (eq provider 'claude)
                                     "https://api.anthropic.com/api/oauth/usage"
                                   "https://chatgpt.com/backend-api/wham/usage"))
                  :sentinel
                  (lambda (process _event)
                    (when (memq (process-status process) '(exit signal))
                      (unwind-protect
                          (condition-case nil
                              (progn
                                (unless (zerop (process-exit-status process))
                                  (error "Quota request failed"))
                                (let* ((data (overlook-usage-subscription--json
                                              (with-current-buffer (process-buffer process)
                                                (buffer-string))))
                                       (windows (overlook-usage-subscription--parse provider data)))
                                  (puthash row
                                           (list :windows windows :login login
                                                 :local local
                                                 :next (+ (float-time)
                                                          overlook-usage-subscription-interval))
                                           overlook-usage-subscription--state)))
                            (error (overlook-usage-subscription--failed row)))
                        (when (buffer-live-p (process-buffer process))
                          (kill-buffer (process-buffer process))))
                      (overlook-usage-scan))))))
            (puthash row (plist-put (gethash row overlook-usage-subscription--state)
                                   :process process)
                     overlook-usage-subscription--state)
            (process-send-string
             process
             (concat "header = \"Authorization: Bearer " token "\"\n"
                     (if (eq provider 'claude)
                         "header = \"anthropic-beta: oauth-2025-04-20\"\n"
                       (concat "header = \"User-Agent: codex-cli\"\n"
                               (when account
                                 (concat "header = \"ChatGPT-Account-Id: " account "\"\n"))))))
            (process-send-eof process)))
      (error
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (overlook-usage-subscription--failed row)))))

(defun overlook-usage-subscription--claude-login (row)
  "Read Claude's login credential asynchronously for ROW."
  (let* ((dir (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude"))
         (file (expand-file-name ".credentials.json" dir))
         (data (overlook-usage--read-json file))
         (token (alist-get 'accessToken (alist-get 'claudeAiOauth data))))
    (if token
        (overlook-usage-subscription--request row 'claude token)
      (if (or (not (eq system-type 'darwin))
              (not (equal (expand-file-name dir)
                          (expand-file-name "~/.claude"))))
          (overlook-usage-subscription--failed row)
        (let* ((buffer (generate-new-buffer " *overlook-quota-credential*"))
               (process
                (make-process
                 :name "overlook-quota-credential" :buffer buffer :noquery t
                 :command '("security" "find-generic-password"
                            "-s" "Claude Code-credentials" "-w")
                 :sentinel
                 (lambda (process _event)
                   (when (memq (process-status process) '(exit signal))
                     (unwind-protect
                         (condition-case nil
                             (let* ((data (overlook-usage-subscription--json
                                           (with-current-buffer (process-buffer process)
                                             (buffer-string))))
                                    (token (alist-get 'accessToken (alist-get 'claudeAiOauth data))))
                               (unless (zerop (process-exit-status process))
                                 (error "Credential unavailable"))
                               (overlook-usage-subscription--request row 'claude token))
                           (error (overlook-usage-subscription--failed row)))
                       (when (buffer-live-p (process-buffer process))
                         (kill-buffer (process-buffer process)))))))))
          (puthash row (plist-put (gethash row overlook-usage-subscription--state)
                                 :process process)
                   overlook-usage-subscription--state))))))

(defun overlook-usage-subscription--due-p (row)
  "Whether ROW may start another query."
  (let ((state (gethash row overlook-usage-subscription--state)))
    (and (not (process-live-p (plist-get state :process)))
         (>= (float-time) (or (plist-get state :next) 0)))))

(defun overlook-usage-subscription--poll ()
  "Start due quota requests for the configured accounts."
  (when overlook-usage-mode
   (let ((accounts (and (boundp 'overlook-agent-shell-claude-accounts)
                       overlook-agent-shell-claude-accounts)))
    (dolist (entry (or accounts '((nil))))
      (let* ((identity (if (fboundp 'overlook-agent-shell--other-account)
                           (overlook-agent-shell--other-account (car entry))
                         (unless (eq entry (car accounts)) (car entry))))
             (row (if identity (concat "claude @" identity) "claude")))
        (when (overlook-usage-subscription--due-p row)
          (condition-case nil
              (let ((token (cdr entry)))
                (if token
                    (overlook-usage-subscription--request
                     row 'claude (if (functionp token) (funcall token) token))
                  (overlook-usage-subscription--claude-login row)))
            (error (overlook-usage-subscription--failed row))))))
    (when (overlook-usage-subscription--due-p "codex")
      (condition-case nil
          (let* ((auth (overlook-usage--read-json
                        (expand-file-name "auth.json" (or (getenv "CODEX_HOME") "~/.codex"))))
                 (tokens (alist-get 'tokens auth)))
            (overlook-usage-subscription--request
             "codex" 'codex (alist-get 'access_token tokens)
             (alist-get 'account_id tokens) (overlook-usage-codex-login)))
        (error (overlook-usage-subscription--failed "codex")))))))

(defun overlook-usage-subscription--merge (rows)
  "Overlay successful server readings on local ROWS."
  (when (boundp 'overlook-agent-shell-claude-accounts)
    (setq rows
          (seq-remove
           (lambda (row)
             (and (string-prefix-p "claude @" (car row))
                  (not (member (substring (car row) 8)
                               (mapcar #'car overlook-agent-shell-claude-accounts)))))
           rows)))
  (maphash
   (lambda (name state)
     (when (and (or (not (string-prefix-p "claude @" name))
                    (member (substring name 8)
                            (and (boundp 'overlook-agent-shell-claude-accounts)
                                 (mapcar #'car overlook-agent-shell-claude-accounts))))
                (plist-get state :windows)
                (or (not (equal name "codex"))
                    (equal (plist-get state :login) (overlook-usage-codex-login))))
       (let ((row (assoc name rows)))
         (if row
             (when (equal (cdr row) (plist-get state :local))
               (setcdr row (plist-get state :windows)))
           (push (cons (propertize name 'overlook-action
                                   (if (equal name "codex")
                                       #'overlook-usage-open-codex
                                     #'overlook-usage-open-claude))
                       (plist-get state :windows)) rows)))))
   overlook-usage-subscription--state)
  rows)

(add-hook 'overlook-tick-hook #'overlook-usage-subscription--poll)
(add-hook 'overlook-usage-filter-functions #'overlook-usage-subscription--merge)

(provide 'overlook-usage-subscription)
;;; overlook-usage-subscription.el ends here
