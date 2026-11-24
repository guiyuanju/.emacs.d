;;; overlook-agent-diff.el --- Follow an agent's edits as diffs -*- lexical-binding: t; -*-

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

;; `overlook-agent-diff-mode' shows each file edit an agent finishes as a
;; diff, in a buffer of the agent's own beside it, whether the edit
;; needed approval or not.  The buffer holds the edits of the current
;; turn, newest last; the next prompt starts it afresh.  It pops up only
;; while the agent is shown on the selected frame; otherwise it fills
;; quietly, and `overlook-agent-diff-show' shows it.

;;; Code:

(require 'diff-mode)
(require 'overlook-agent-core)

(defgroup overlook-agent-diff nil
  "Agents' edits shown as diffs as they happen."
  :group 'overlook)

(defcustom overlook-agent-diff-display-action
  '((display-buffer-reuse-window display-buffer-use-some-window display-buffer-pop-up-window)
    (inhibit-same-window . t)
    (window-width . 0.3))
  "How to show an agent's diff buffer when an edit finishes.
A `display-buffer' action; the agent's window is never used.  Its
`window-width' or `window-height', a fraction of the frame or a number
of columns or lines, sizes a window made for the diff."
  :type 'sexp)

(defcustom overlook-agent-diff-context 3
  "Lines of context around each change."
  :type 'natnum)

(defvar-local overlook-agent-diff--shown nil
  "Tool call IDs whose diffs this diff buffer holds.")

(defvar-local overlook-agent-diff--stale nil
  "Non-nil when this diff buffer holds a past turn's edits.")

(defvar-local overlook-agent-diff--agent nil
  "The agent buffer this diff buffer follows.")

(defun overlook-agent-diff--buffer-name (agent)
  "Name of AGENT buffer's diff buffer."
  (format "*overlook-diff: %s*" (buffer-name agent)))

(defun overlook-agent-diff--buffer (agent)
  "AGENT buffer's diff buffer, made when missing."
  (let ((name (overlook-agent-diff--buffer-name agent)))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (diff-mode)
          ;; The file holds neither the removed lines nor, after later
          ;; edits, the added ones, so highlight the hunk text alone.
          (setq-local diff-font-lock-syntax 'hunk-only)
          (setq buffer-read-only t
                overlook-agent-diff--agent agent
                default-directory (buffer-local-value 'default-directory agent))
          (current-buffer)))))

(defun overlook-agent-diff--run-diff (old new label)
  "Unified diff of strings OLD and NEW, both named LABEL; nil when equal."
  (let ((old-file (make-temp-file "overlook-diff-old"))
        (new-file (make-temp-file "overlook-diff-new"))
        (coding-system-for-write 'utf-8-unix)
        (coding-system-for-read 'utf-8-unix))
    (unwind-protect
        (progn
          (write-region old nil old-file nil 'silent)
          (write-region new nil new-file nil 'silent)
          (with-temp-buffer
            (call-process diff-command nil t nil
                          (format "-U%d" overlook-agent-diff-context)
                          "--label" label "--label" label old-file new-file)
            (unless (zerop (buffer-size))
              (buffer-string))))
      (delete-file old-file)
      (delete-file new-file))))

(defun overlook-agent-diff--whole (file old new)
  "FILE's text before and after replacing OLD with NEW, as (BEFORE . AFTER).
Agents send an edit as the replaced snippet alone; it is found in FILE,
which already holds NEW, so the diff gets real line numbers and context.
Nil when FILE is unreadable or NEW is not found in it."
  (when (and (> (length new) 0) (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((after (buffer-string)))
        (goto-char (point-min))
        (when (search-forward new nil t)
          (replace-match old t t)
          (cons (buffer-string) after))))))

(defun overlook-agent-diff--text (diff)
  "Unified diff of DIFF, an edit (:file F :old OLD :new NEW); nil when empty."
  (let* ((file (plist-get diff :file))
         (old (or (plist-get diff :old) ""))
         (new (or (plist-get diff :new) ""))
         (whole (overlook-agent-diff--whole file old new)))
    (if whole
        (overlook-agent-diff--run-diff (car whole) (cdr whole) file)
      ;; Snippets rarely end in a newline; without one diff marks both sides.
      (let ((line (lambda (text) (if (string-suffix-p "\n" text) text (concat text "\n")))))
        (overlook-agent-diff--run-diff (funcall line old) (funcall line new) file)))))

(defun overlook-agent-diff--add (agent id diffs)
  "Append the edits DIFFS of tool call ID to AGENT's diff buffer.
Return the buffer's position where they start, or nil when nothing was added."
  (let ((buffer (overlook-agent-diff--buffer agent)))
    (with-current-buffer buffer
      (when overlook-agent-diff--stale
        (let ((inhibit-read-only t)) (erase-buffer))
        (setq overlook-agent-diff--stale nil
              overlook-agent-diff--shown nil))
      (unless (member id overlook-agent-diff--shown)
        (push id overlook-agent-diff--shown)
        (let ((texts (delq nil (mapcar #'overlook-agent-diff--text diffs))))
          (when texts
            (let ((inhibit-read-only t)
                  (start (point-max)))
              (save-excursion
                (goto-char start)
                (dolist (text texts) (insert text)))
              start)))))))

(defun overlook-agent-diff--reveal (agent buffer start)
  "Show BUFFER beside AGENT with START at its top, without selecting it."
  (let ((window (or (get-buffer-window buffer)
                    (when (get-buffer-window agent)
                      (display-buffer buffer overlook-agent-diff-display-action)))))
    (when (window-live-p window)
      (set-window-point window start)
      (set-window-start window start))))

(defun overlook-agent-diff--event (agent event)
  "Follow EVENT of AGENT buffer: show a finished edit, or start a turn."
  (pcase (plist-get event :type)
    ('prompt
     (when-let* ((buffer (get-buffer (overlook-agent-diff--buffer-name agent))))
       (with-current-buffer buffer (setq overlook-agent-diff--stale t))))
    ('tool
     (when-let* (((equal (plist-get event :status) "completed"))
                 (diffs (seq-filter (lambda (diff) (plist-get diff :file))
                                    (plist-get event :diffs)))
                 ((buffer-live-p agent))
                 (start (with-current-buffer agent
                          (overlook-agent-diff--add agent (plist-get event :id) diffs))))
       (overlook-agent-diff--reveal agent (overlook-agent-diff--buffer agent) start)))))

;;;###autoload
(defun overlook-agent-diff-show (agent)
  "Show the diffs of AGENT buffer's edits in this turn, or the last.
Interactively, the agent shown here, else the agent of the diff buffer
at point."
  (interactive
   (list (or (and (overlook-agent-p (current-buffer)) (current-buffer))
             overlook-agent-diff--agent
             (seq-find #'overlook-agent-p
                       (mapcar #'window-buffer (window-list)))
             (user-error "No agent here"))))
  (let ((buffer (get-buffer (overlook-agent-diff--buffer-name agent))))
    (unless buffer (user-error "No edits from %s yet" (buffer-name agent)))
    (display-buffer buffer overlook-agent-diff-display-action)))

;;;###autoload
(define-minor-mode overlook-agent-diff-mode
  "Show each file edit an agent finishes as a diff beside the agent."
  :global t
  :group 'overlook-agent-diff
  (overlook-toggle-hooks
   overlook-agent-diff-mode
   '((overlook-agent-event-functions overlook-agent-diff--event))))

(provide 'overlook-agent-diff)
;;; overlook-agent-diff.el ends here
