;;; overlook-agent-rules.el --- Let every agent read the same rules -*- lexical-binding: t; -*-

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

;; Claude Code and pi read CLAUDE.md in every ancestor folder; Codex reads
;; only AGENTS.md, and only from the Git root down.  For every agent to
;; read the rules in `overlook-agent-rules-file', Codex needs two settings
;; kept outside any repo: a fallback to CLAUDE.md in its config.toml, and
;; its global AGENTS.md linked to the rules.  `overlook-agent-rules-check'
;; offers to add what is missing; `overlook-agent-rules-check-once' on
;; `overlook-mode-hook' runs it when the dashboard first opens.

;;; Code:

(require 'seq)

(defcustom overlook-agent-rules-file nil
  "Rules every agent should read, usually a CLAUDE.md above your projects.
nil turns the check off."
  :type '(choice (const :tag "None" nil) file)
  :group 'overlook)

(defconst overlook-agent-rules--fallback-line "project_doc_fallback_filenames = [\"CLAUDE.md\"]"
  "Codex setting that makes it read CLAUDE.md where there is no AGENTS.md.")

(defun overlook-agent-rules--codex-home ()
  "Codex's configuration directory."
  (file-name-as-directory (or (getenv "CODEX_HOME") "~/.codex")))

(defun overlook-agent-rules--codex-config ()
  "Codex's config.toml."
  (expand-file-name "config.toml" (overlook-agent-rules--codex-home)))

(defun overlook-agent-rules--codex-agents ()
  "Codex's global AGENTS.md."
  (expand-file-name "AGENTS.md" (overlook-agent-rules--codex-home)))

(defun overlook-agent-rules--codex-p ()
  "Non-nil when Codex is installed on this machine."
  (or (executable-find "codex-acp") (executable-find "codex")
      (file-directory-p (overlook-agent-rules--codex-home))))

(defun overlook-agent-rules--config-setting ()
  "The fallback setting line in Codex's config.toml, or nil."
  (let ((file (overlook-agent-rules--codex-config)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (when (re-search-forward "^[ \t]*project_doc_fallback_filenames[ \t]*=.*$" nil t)
          (match-string 0))))))

(defun overlook-agent-rules--fallback-ok-p ()
  "Non-nil when Codex falls back to CLAUDE.md."
  (when-let* ((line (overlook-agent-rules--config-setting)))
    (string-match-p "\"CLAUDE\\.md\"" line)))

(defun overlook-agent-rules--fallback-fix ()
  "Put the fallback setting at the top of config.toml, outside any table."
  (when (overlook-agent-rules--config-setting)
    (user-error "%s sets project_doc_fallback_filenames already; add \"CLAUDE.md\" to it"
                (overlook-agent-rules--codex-config)))
  (let ((file (overlook-agent-rules--codex-config)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (when (file-exists-p file)
        (insert-file-contents file))
      (goto-char (point-min))
      (insert overlook-agent-rules--fallback-line "\n"))))

(defun overlook-agent-rules--agents-ok-p ()
  "Non-nil when Codex's global AGENTS.md links to the rules."
  (let ((link (overlook-agent-rules--codex-agents)))
    (and (file-symlink-p link)
         (file-equal-p link overlook-agent-rules-file))))

(defun overlook-agent-rules--agents-fix ()
  "Link Codex's global AGENTS.md to the rules."
  (let ((link (overlook-agent-rules--codex-agents)))
    (when (or (file-symlink-p link) (file-exists-p link))
      (user-error "%s exists and is not a link to %s" link overlook-agent-rules-file))
    (make-directory (file-name-directory link) t)
    (make-symbolic-link (expand-file-name overlook-agent-rules-file) link)))

(defconst overlook-agent-rules-checks
  '(("Codex reads CLAUDE.md" overlook-agent-rules--fallback-ok-p
     overlook-agent-rules--fallback-fix)
    ("Codex's global AGENTS.md links to the rules" overlook-agent-rules--agents-ok-p
     overlook-agent-rules--agents-fix))
  "Codex settings as (DESCRIPTION OK-P FIX).")

;;;###autoload
(defun overlook-agent-rules-check (&optional verbose)
  "Offer to set up agents that cannot read `overlook-agent-rules-file'.
With VERBOSE, also report when nothing is missing."
  (interactive (list t))
  (let ((missing (and overlook-agent-rules-file
                      (overlook-agent-rules--codex-p)
                      (file-exists-p overlook-agent-rules-file)
                      (seq-remove (lambda (check) (funcall (nth 1 check)))
                                  overlook-agent-rules-checks))))
    (cond
     ((null missing)
      (when verbose (message "Every agent reads the rules")))
     ((y-or-n-p (format "Agents cannot read the rules; missing: %s.  Fix now? "
                        (mapconcat #'car missing "; ")))
      (dolist (check missing)
        (funcall (nth 2 check)))
      (message "Fixed: %s" (mapconcat #'car missing "; "))))))

;;;###autoload
(defun overlook-agent-rules-check-once ()
  "Run `overlook-agent-rules-check' once, when Emacs is next idle."
  (remove-hook 'overlook-mode-hook #'overlook-agent-rules-check-once)
  (run-with-idle-timer 1 nil #'overlook-agent-rules-check))

(provide 'overlook-agent-rules)
;;; overlook-agent-rules.el ends here
