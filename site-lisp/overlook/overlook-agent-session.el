;;; overlook-agent-session.el --- Saved agent sessions and fork relations -*- lexical-binding: t; -*-

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

;; Persists sessions and fork relations and resumes saved agents.
;; Storage formats are independent of the dashboard layout.

;;; Code:

(require 'overlook-agent-core)

(declare-function overlook-show-elsewhere "overlook" (project show))

(defcustom overlook-agent-saved-file (locate-user-emacs-file "overlook-agents.eld")
  "File keeping the agents to offer for resuming after a restart."
  :type 'file
  :group 'overlook)

(defcustom overlook-agent-forks-file (locate-user-emacs-file "overlook-forks.eld")
  "File keeping the session each forked session was forked from."
  :type 'file
  :group 'overlook)

(defvar overlook-agent-saved nil
  "Agents of an earlier Emacs not resumed yet.
Each is an alist with keys `agent', `root', `session' and `project',
and `title' and `active', the time of its last turn, when known.")

(defvar overlook-agent--saved-loaded nil
  "Non-nil once `overlook-agent-saved-file' has been read.")

(defvar overlook-agent--saved-written nil
  "The agents last written to `overlook-agent-saved-file'.")

(defvar overlook-agent-forks nil
  "Alist of each forked session id to the session id it was forked from.")

(defvar overlook-agent--forks-written nil
  "The forks last written to `overlook-agent-forks-file'.")

(defvar overlook-agent-save-functions nil
  "Functions of an agent buffer returning entries to keep in its saved alist.")

(defvar overlook-agent-resume-functions nil
  "Functions of a saved alist called before it is resumed.
One may refuse by signaling an error.")

(defun overlook-agent--saved-entry (buffer)
  "Return BUFFER's resumable session data, or nil without a session."
  (when-let* ((session (overlook-agent-session buffer)))
    `((agent . ,(overlook-agent-get buffer 'agent))
      (root . ,(overlook-agent-get buffer 'root))
      (session . ,session)
      (project . ,(overlook-agent-project buffer))
      (title . ,(overlook-agent-title buffer))
      (active . ,(when-let* ((turn (buffer-local-value 'overlook-agent-turn buffer)))
                   (or (cdr turn) (car turn))))
      ,@(seq-mapcat (lambda (fn) (funcall fn buffer)) overlook-agent-save-functions))))

(defun overlook-agent--to-save ()
  "Running agents with a session, then the saved ones not resumed."
  (append (delq nil (mapcar #'overlook-agent--saved-entry (overlook-agent-buffers)))
          overlook-agent-saved))

(defun overlook-agent-close (buffer)
  "Close BUFFER while preserving its resumable session when available."
  (overlook-agent-load-saved)
  (let ((saved (overlook-agent--saved-entry buffer)))
    (when saved
      (let ((agents (overlook-agent--to-save)))
        (overlook-agent--write overlook-agent-saved-file agents)
        (setq overlook-agent--saved-written agents)))
    (overlook-agent-kill buffer)
    (when (buffer-live-p buffer)
      (user-error "The agent could not be closed"))
    (when saved
      (setq overlook-agent-saved
            (cons saved (seq-remove (lambda (entry)
                                      (equal (alist-get 'session entry)
                                             (alist-get 'session saved)))
                                    overlook-agent-saved))))
    (with-demoted-errors "overlook: closed agent notification: %S"
      (overlook-agent-save)
      (overlook-agent-changed))
    t))

(defun overlook-agent--forked-from (buffer)
  "Session id agent BUFFER's session was forked from, as its frontend says, or nil."
  (when-let* ((forked-from (overlook-agent-get buffer 'forked-from)))
    (with-current-buffer buffer (ignore-errors (funcall forked-from)))))

(defun overlook-agent-fork-parent (session)
  "Session id SESSION was forked from, or nil."
  (and session (alist-get session overlook-agent-forks nil nil #'equal)))

(defun overlook-agent-note-forks ()
  "Add the forks among running agents to `overlook-agent-forks'."
  (dolist (buffer (overlook-agent-buffers))
    (let ((session (overlook-agent-session buffer))
          (parent (overlook-agent--forked-from buffer)))
      (when (and session parent (not (equal session parent))
                 (not (overlook-agent-fork-parent session)))
        (push (cons session parent) overlook-agent-forks)))))

(defun overlook-agent--write (file data)
  "Print DATA to FILE."
  (make-directory (file-name-directory file) t)
  (let ((print-length nil)
        (print-level nil))
    (with-temp-file file
      (prin1 data (current-buffer)))))

(defun overlook-agent--read (file)
  "The data in FILE, or nil when it is missing or unreadable."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (ignore-errors (read (current-buffer))))))

(defun overlook-agent-save ()
  "Write the agents to resume later and the forks, each to its file, if changed."
  (with-demoted-errors "overlook: saving agents: %S"
    (let ((agents (overlook-agent--to-save)))
      (unless (equal agents overlook-agent--saved-written)
        (overlook-agent--write overlook-agent-saved-file agents)
        (setq overlook-agent--saved-written agents)))
    (overlook-agent-note-forks)
    (unless (equal overlook-agent-forks overlook-agent--forks-written)
      (overlook-agent--write overlook-agent-forks-file overlook-agent-forks)
      (setq overlook-agent--forks-written overlook-agent-forks))))

(defun overlook-agent-load-saved ()
  "Read the saved agents and the forks once, skipping sessions already running."
  (unless overlook-agent--saved-loaded
    (setq overlook-agent--saved-loaded t)
    (let ((running (mapcar #'overlook-agent-session (overlook-agent-buffers)))
          (agents (overlook-agent--read overlook-agent-saved-file))
          (forks (seq-filter (lambda (fork) (and (stringp (car-safe fork)) (stringp (cdr fork))))
                             (overlook-agent--read overlook-agent-forks-file))))
      (setq overlook-agent-saved
            (seq-remove (lambda (saved) (member (alist-get 'session saved) running))
                        (seq-filter #'consp agents))
            overlook-agent--saved-written agents
            overlook-agent-forks (append overlook-agent-forks forks)
            overlook-agent--forks-written forks))))

(defun overlook-agent--resume (saved)
  "Resume SAVED agent from `overlook-agent-saved' and return its buffer."
  (run-hook-with-args 'overlook-agent-resume-functions saved)
  (setq overlook-agent-saved (delq saved overlook-agent-saved))
  (let ((root (alist-get 'root saved)))
    (unless (file-directory-p root)
      (overlook-agent-changed)
      (user-error "%s is gone; forgot its agent" root))
    (let ((overlook-agent-resuming saved)
          (overlook-agent-starting-project (or (overlook-agent-saved-project saved)
                                               (overlook-orphan-project)
                                               (overlook-current-project))))
      (overlook-agent-start (alist-get 'agent saved) root (alist-get 'session saved)))))

(defun overlook-agent-saved-project (saved)
  "The project SAVED agent was in, when it still exists."
  (car (member (alist-get 'project saved) (overlook-projects))))

(defun overlook-agent-resume-visit (saved)
  "Resume SAVED agent in its project and show it there."
  (overlook-show-elsewhere (or (overlook-agent-saved-project saved)
                               (overlook-orphan-project))
                           (lambda () (overlook-agent-show (overlook-agent--resume saved)))))

(defun overlook-agent-resume (saved)
  "Resume SAVED agent in its project, without showing it; return its buffer."
  (overlook-agent--resume saved))

(defun overlook-agent-forget (saved)
  "Forget SAVED agent."
  (setq overlook-agent-saved (delq saved overlook-agent-saved))
  (overlook-agent-changed))

(defun overlook-agent-forget-project (name)
  "Forget the saved agents of project NAME."
  (setq overlook-agent-saved
        (seq-remove (lambda (saved) (equal (alist-get 'project saved) name))
                    overlook-agent-saved))
  (overlook-agent-changed))

(provide 'overlook-agent-session)
;;; overlook-agent-session.el ends here
