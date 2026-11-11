;;; overlook-agent-resume.el --- Continue an agent after its quota resets -*- lexical-binding: t; -*-

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

;; One-shot, session-bound continuation appointments with idle sleep prevention.

;;; Code:

(require 'overlook-agent)
(require 'overlook-usage)
(require 'system-sleep nil t)

(declare-function system-sleep-block-sleep "system-sleep")
(declare-function system-sleep-unblock-sleep "system-sleep")

(defcustom overlook-agent-resume-delay 300
  "Seconds to wait after the subscription quota resets."
  :type 'natnum
  :group 'overlook)

(defvar overlook-agent-resume--jobs nil
  "Alist of agent buffers to appointment plists.")
(defvar overlook-agent-resume--timer nil
  "One-shot timer for the next appointment deadline.")
(defvar overlook-agent-resume--awake nil
  "Sleep token held while appointments are active.")
(defvar overlook-agent-resume--sending nil
  "Buffer currently receiving the scheduled continuation.")

(defun overlook-agent-resume--sync ()
  "Maintain the appointment timer and idle sleep assertion."
  (when (timerp overlook-agent-resume--timer)
    (cancel-timer overlook-agent-resume--timer))
  (setq overlook-agent-resume--timer nil)
  (let ((deadlines
         (delq nil
               (mapcar (lambda (entry)
                         (let ((job (cdr entry)))
                           (pcase (plist-get job :phase)
                             ('waiting (plist-get job :at))
                             ('submitted (+ (plist-get job :sent) 120)))))
                       overlook-agent-resume--jobs))))
    (when deadlines
      (setq overlook-agent-resume--timer
            (run-at-time (max 0 (- (apply #'min deadlines) (float-time)))
                         nil #'overlook-agent-resume--tick))))
  (if overlook-agent-resume--jobs
      (progn
        (when (and (fboundp 'system-sleep-block-sleep)
                   (not overlook-agent-resume--awake))
          (condition-case err
              (setq overlook-agent-resume--awake
                    (system-sleep-block-sleep "Overlook continuation" t))
            (error (message "Cannot prevent sleep: %s" (error-message-string err))))))
    (when (timerp overlook-agent-resume--timer)
      (cancel-timer overlook-agent-resume--timer))
    (setq overlook-agent-resume--timer nil)
    (when (and overlook-agent-resume--awake
               (fboundp 'system-sleep-unblock-sleep))
      (system-sleep-unblock-sleep overlook-agent-resume--awake))
    (setq overlook-agent-resume--awake nil)))

(defun overlook-agent-resume-cancel (buffer)
  "Cancel BUFFER's continuation appointment and release its sleep assertion."
  (setq overlook-agent-resume--jobs (assq-delete-all buffer overlook-agent-resume--jobs))
  (overlook-agent-resume--sync)
  (overlook-agent-changed))

(defun overlook-agent-resume--killed ()
  "Cancel any appointment belonging to the buffer being killed."
  (when (assq (current-buffer) overlook-agent-resume--jobs)
    (overlook-agent-resume-cancel (current-buffer))))

(defun overlook-agent-resume--started ()
  "Track the scheduled turn, or cancel when another turn starts first."
  (when-let* ((entry (assq (current-buffer) overlook-agent-resume--jobs)))
    (if (or (eq overlook-agent-resume--sending (current-buffer))
            (eq (plist-get (cdr entry) :phase) 'submitted))
        (progn (setf (plist-get (cdr entry) :phase) 'running)
               (overlook-agent-resume--sync)
               (overlook-agent-changed))
      (overlook-agent-resume-cancel (current-buffer)))))

(defun overlook-agent-resume--ended ()
  "Release the sleep assertion when the scheduled turn ends."
  (when-let* ((entry (assq (current-buffer) overlook-agent-resume--jobs))
              ((memq (plist-get (cdr entry) :phase) '(submitted running))))
    (overlook-agent-resume-cancel (current-buffer))))

(defun overlook-agent-resume--stopped ()
  "Automatically await quota recovery when an exhausted agent stops."
  (overlook-agent-resume--ended)
  (overlook-usage-scan)
  (let* ((buffer (current-buffer))
         (row (overlook-agent-call buffer 'usage-row))
         (session (overlook-agent-session buffer)))
    (when (and session row
               (eq (overlook-usage-state row) 'exhausted)
               (overlook-agent-get buffer 'submit)
               (overlook-agent-get buffer 'ready)
               (not (assq buffer overlook-agent-resume--jobs)))
      (push (cons buffer (list :session session :row row :phase 'quota))
            overlook-agent-resume--jobs)
      (add-hook 'kill-buffer-hook #'overlook-agent-resume--killed nil t)
      (overlook-agent-resume--sync)
      (overlook-agent-changed))))

(defun overlook-agent-resume--usage (row state)
  "Continue appointments for ROW after its quota STATE recovers."
  (when (eq state 'available)
    (dolist (entry overlook-agent-resume--jobs)
      (when (and (equal row (plist-get (cdr entry) :row))
                 (eq (plist-get (cdr entry) :phase) 'quota))
        (setf (plist-get (cdr entry) :phase) 'waiting
              (plist-get (cdr entry) :at)
              (+ (float-time) overlook-agent-resume-delay))))
    (overlook-agent-resume--sync)
    (overlook-agent-changed)))

(defun overlook-agent-resume--tick ()
  "Check session identity and send due continuations once."
  (dolist (entry (copy-sequence overlook-agent-resume--jobs))
    (let ((buffer (car entry)) (job (cdr entry)) (now (float-time)))
      (condition-case err
          (cond
           ((or (not (buffer-live-p buffer))
                (not (equal (plist-get job :session) (overlook-agent-session buffer)))
                (not (equal (plist-get job :row)
                            (overlook-agent-call buffer 'usage-row))))
            (overlook-agent-resume-cancel buffer))
           ((and (eq (plist-get job :phase) 'submitted)
                 (>= now (+ (plist-get job :sent) 120)))
            (overlook-agent-resume-cancel buffer)
            (message "Continuation did not start in %s" (buffer-name buffer)))
           ((and (eq (plist-get job :phase) 'waiting)
                 (>= now (plist-get job :at)))
            (if (not (overlook-agent-call
                      buffer (if (overlook-agent-get buffer 'resume-ready)
                                 'resume-ready 'ready)))
                (progn
                  (overlook-agent-resume-cancel buffer)
                  (message "Continuation cancelled: %s is busy or has draft input"
                           (buffer-name buffer)))
              (setf (plist-get (cdr entry) :phase) 'submitted
                    (plist-get (cdr entry) :sent) now)
              (let ((overlook-agent-resume--sending buffer))
                (overlook-agent-call buffer
                                     (if (overlook-agent-get buffer 'resume-submit)
                                         'resume-submit 'submit)
                                     "continue"))
              (overlook-agent-changed))))
        (error
         (overlook-agent-resume-cancel buffer)
         (message "Continuation failed: %s" (error-message-string err))))))
  (overlook-agent-resume--sync))

;;;###autoload
(defun overlook-agent-resume-toggle (&optional buffer)
  "Schedule or cancel continuation for BUFFER after its next quota reset.
Interactively use the agent at point, or the current agent buffer."
  (interactive)
  (let ((buffer (or buffer (overlook-agent-at-point)
                    (and overlook-agent-identity (current-buffer)))))
    (unless (and buffer (overlook-agent-p buffer))
      (user-error "Choose an agent buffer or dashboard agent row"))
    (if (assq buffer overlook-agent-resume--jobs)
        (progn (overlook-agent-resume-cancel buffer)
               (message "Continuation cancelled"))
      (unless (and (overlook-agent-get buffer 'submit)
                   (overlook-agent-get buffer 'ready)
                   (overlook-agent-call buffer (if (overlook-agent-get buffer 'resume-ready)
                                               'resume-ready 'ready)))
        (user-error "Agent must be ready to continue"))
      (let* ((session (overlook-agent-session buffer))
             (row (overlook-agent-call buffer 'usage-row))
             (reset (and row (overlook-usage-next-reset row))))
        (unless session (user-error "Agent has no active session"))
        (unless reset (user-error "No reliable subscription reset time for this agent"))
        (let ((at (+ reset overlook-agent-resume-delay)))
          (push (cons buffer (list :session session :row row :at at
                                   :phase (if (eq (overlook-usage-state row) 'exhausted)
                                              'quota 'waiting)))
                overlook-agent-resume--jobs)
          (with-current-buffer buffer
            (add-hook 'kill-buffer-hook #'overlook-agent-resume--killed nil t))
          (overlook-agent-resume--sync)
          (overlook-agent-changed)
          (message "%s: continue at %s (%s)" (buffer-name buffer)
                   (format-time-string "%m-%d %H:%M" at) row))))))

(defun overlook-agent-resume--mark (buffer)
  "Return the appointment mark for agent BUFFER."
  (when-let* ((job (cdr (assq buffer overlook-agent-resume--jobs))))
    (propertize
     (if (eq (plist-get job :phase) 'quota)
         (format " awaiting %s quota" (plist-get job :row))
       (if (eq (plist-get job :phase) 'waiting)
         (format " continue %s %s" (plist-get job :row)
                 (format-time-string "%m-%d %H:%M" (plist-get job :at)))
       " auto-continued"))
     'face 'warning)))

(defun overlook-agent-resume--commands (buffer)
  "Return appointment commands for agent BUFFER."
  (when (or (assq buffer overlook-agent-resume--jobs)
            (overlook-agent-get buffer 'usage-row))
    (list (list :name "resume" :label (if (assq buffer overlook-agent-resume--jobs)
                                         "Cancel continuation" "Continue after quota reset")
                :run (lambda () (overlook-agent-resume-toggle buffer))))))

(add-hook 'overlook-agent-turn-start-hook #'overlook-agent-resume--started)
(add-hook 'overlook-agent-turn-end-hook #'overlook-agent-resume--stopped)
(add-hook 'overlook-usage-state-change-hook #'overlook-agent-resume--usage)
(add-hook 'overlook-agent-attention-hook #'overlook-agent-resume--ended)
(add-hook 'overlook-agent-row-marks #'overlook-agent-resume--mark)
(add-hook 'overlook-agent-command-functions #'overlook-agent-resume--commands)

(provide 'overlook-agent-resume)
;;; overlook-agent-resume.el ends here
