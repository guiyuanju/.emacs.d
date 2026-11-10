;;; overlook-agent-courier.el --- Agents on the overlook dashboard messaging each other -*- lexical-binding: t; -*-

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

;; Registers each agent overlook runs with courier, so agents can message,
;; spawn and monitor each other.  An agent started while the mode is on
;; learns its courier id from $COURIER_ID and finds the courier script on
;; its PATH.  Its errors and requests for the user reach the agent that
;; spawned it.  A spawned agent opens in the project whose root holds the
;; folder it works in, else in its parent's; the dashboard marks who
;; spawned it, and the messages waiting for it.  An agent handed off to
;; the user gets its task at its prompt, unsent.  A Personas section
;; lists courier's personas; RET starts one, or shows the agent running it.
;; A persona that may run several times lists its agents under it, each
;; by its session title; RET on the persona starts another.
;; Agents running a persona are listed there only, and kept out of the
;; projects: RET shows one in the current project.  What a persona
;; spawns goes to the project whose root holds its folder, else to the
;; orphans'.
;; An agent resumed in a later Emacs keeps its courier id.

;;; Code:

(require 'overlook-agent)
(require 'overlook-courier)
(require 'overlook-courier-persona)

(defvar overlook-agent-shell-configs)

(defvar-local overlook-agent-courier-id nil
  "This agent's courier id.")
(put 'overlook-agent-courier-id 'permanent-local t)

(defvar overlook-agent-courier--parent nil
  "Courier id of the agent spawning the agent being started, or nil.")

(defvar overlook-agent-courier--as nil
  "Courier id the agent being started must get, or nil.")

(defun overlook-agent-courier--environment (name root)
  "Environment telling agent NAME starting in ROOT its courier id.
A resumed agent gets its earlier id back unless another agent has it."
  (overlook-courier-environment
   (or overlook-agent-courier--as
       (when-let* ((id (alist-get 'courier overlook-agent-resuming)))
         (and (not (overlook-courier-agent id)) id))
       (overlook-courier-new-id name root))))

(defun overlook-agent-courier--check-resume (saved)
  "Refuse to resume SAVED agent when it ran a persona some agent runs now."
  (when-let* ((id (alist-get 'courier saved))
              ((overlook-courier-persona-of id))
              (agent (overlook-courier-agent id)))
    (user-error "Persona %s runs already in %s; stop it first" id
                (buffer-name (overlook-courier-agent-buffer agent)))))

(defun overlook-agent-courier--persona-item-p (item)
  "Non-nil when dashboard ITEM, a live or saved agent, runs a persona."
  (when-let* ((id (pcase item
                    (`(agent . ,buffer) (buffer-local-value 'overlook-agent-courier-id buffer))
                    (`(saved . ,saved) (alist-get 'courier saved)))))
    (overlook-courier-persona-of id)))

(defun overlook-agent-courier--saved (buffer)
  "Entries keeping agent BUFFER's courier id for when it is resumed."
  (when-let* ((id (buffer-local-value 'overlook-agent-courier-id buffer)))
    `((courier . ,id))))

(defun overlook-agent-courier--register (buffer)
  "Register agent BUFFER with courier once its frontend is ready.
Its id comes from its $COURIER_ID, else the persona its identity names."
  (with-current-buffer buffer
    (when-let* (((not (and overlook-agent-courier-id (overlook-courier-agent overlook-agent-courier-id))))
                ((overlook-agent-get buffer 'submit)))
      (let* ((environment (overlook-agent-get buffer 'environment))
             (id (or (seq-some (lambda (entry)
                                 (and (string-prefix-p "COURIER_ID=" entry)
                                      (substring entry (length "COURIER_ID="))))
                               environment)
                     (overlook-agent-get buffer 'persona)
                     (overlook-courier-new-id (or (overlook-agent-get buffer 'agent) "agent")
                                     (or (overlook-agent-get buffer 'root) default-directory))))
            (reply (overlook-agent-get buffer 'reply))
            (transcript (overlook-agent-get buffer 'transcript)))
        (setq overlook-agent-courier-id id)
        (overlook-courier-register
         id
         :buffer buffer
         :parent overlook-agent-courier--parent
         :deliver (lambda (text) (overlook-agent-submit buffer text))
         :ready (lambda () (overlook-agent-ready-p buffer))
         :reply (and reply (lambda () (overlook-agent-call buffer 'reply)))
         :insert (and (overlook-agent-get buffer 'insert)
                      (lambda (text) (overlook-agent-call buffer 'insert text)))
         :transcript (and transcript
                          (lambda () (overlook-agent-call buffer 'transcript))))))))

(defun overlook-agent-courier--detach-persona (buffer)
  "Keep agent BUFFER out of the projects when it runs a persona."
  (when (and (not (buffer-local-value 'overlook-detached buffer))
             (overlook-agent-courier--persona-item-p (cons 'agent buffer)))
    (overlook-detach buffer)))

(defun overlook-agent-courier--sync ()
  "Register the agents courier does not know yet, and detach the personas."
  (dolist (buffer (overlook-agent-buffers))
    (overlook-agent-courier--register buffer)
    (overlook-agent-courier--detach-persona buffer)))

(defun overlook-agent-courier--turn-started ()
  "Tell courier this agent started a turn."
  (overlook-courier-turn-started overlook-agent-courier-id))

(defun overlook-agent-courier--turn-finished ()
  "Tell courier this agent finished a turn, and the error it failed with."
  (overlook-courier-turn-finished overlook-agent-courier-id overlook-agent-error))

(defun overlook-agent-courier--blocked ()
  "Tell courier this agent waits for the user, and on what."
  (overlook-courier-blocked overlook-agent-courier-id
                   (or (overlook-agent-brief (current-buffer)) "a request")))

(defun overlook-agent-courier--spawn (name directory parent &optional effort as)
  "Start agent NAME in DIRECTORY for agent PARENT and return its id.
It belongs to the project `overlook-agent-project-at' finds for
DIRECTORY, else to PARENT's.  It starts at reasoning EFFORT if non-nil,
with courier id AS if non-nil.
A persona opens in no project, and what a persona spawns outside the
projects goes to `overlook-orphan-project'."
  (let* ((parent-buffer (when-let* ((agent (overlook-courier-agent parent))) (overlook-courier-agent-buffer agent)))
         (project (if (and as (overlook-courier-persona-of as))
                      'none
                    (or (overlook-agent-project-at directory)
                        (and (buffer-live-p parent-buffer)
                             (if (buffer-local-value 'overlook-detached parent-buffer)
                                 (overlook-orphan-project)
                               (overlook-agent-project parent-buffer))))))
         (buffer (let ((overlook-agent-courier--parent parent)
                       (overlook-agent-courier--as as)
                       (overlook-agent-starting-project project))
                   (overlook-agent-start name directory nil t effort))))
    (let ((overlook-agent-courier--parent parent)) (overlook-agent-courier--register buffer))
    (overlook-agent-courier--detach-persona buffer)
    (buffer-local-value 'overlook-agent-courier-id buffer)))

(defun overlook-agent-courier--mark (buffer)
  "Who spawned agent BUFFER and how many messages wait for it."
  (when-let* ((agent (overlook-courier-agent (buffer-local-value 'overlook-agent-courier-id buffer))))
    (let ((parent (overlook-courier-agent-parent agent))
          (pending (length (overlook-courier-agent-mailbox agent))))
      (concat (if parent (propertize (concat " ← " parent) 'face 'shadow) "")
              (if (> pending 0) (propertize (format " ✉%d" pending) 'face 'warning) "")))))

(defun overlook-agent-courier--persona-icon-name (persona)
  "Name of PERSONA's icon in `overlook-agent-icons'.
Its backend's, when that has an icon, else its engine's."
  (let ((backend (plist-get persona :backend)))
    (if (and backend (alist-get (downcase backend) overlook-agent-icons nil nil #'equal))
        (downcase backend)
      (or (plist-get persona :engine) "?"))))

(defun overlook-agent-courier--instance-row (id persona)
  "The row of the agent of courier ID running PERSONA, by its session title."
  (let* ((buffer (overlook-courier-agent-buffer (overlook-courier-agent id)))
         (status (buffer-local-value 'overlook-agent-status buffer))
         (brief (overlook-agent-brief buffer)))
    (overlook-row :id (cons 'agent buffer)
                  :content (list "  "
                                 (overlook-icon
                                  (propertize (overlook-agent-courier--persona-icon-name persona)
                                              'face (overlook-agent-status-face status)))
                                 " " (or (overlook-agent-title buffer)
                                         (propertize "New conversation" 'face 'shadow))
                                 (and brief (not (eq status 'idle))
                                      (overlook-agent-brief-segment buffer brief 0)))
                  :attention (and (memq status '(waiting failed done)) t)
                  :face (pcase status
                          ((or 'waiting 'failed) 'overlook-agent-waiting)
                          ('done 'overlook-agent-done))
                  :action (lambda () (overlook-agent-visit buffer))
                  :help (concat id (if brief (concat "\n" brief) ""))
                  :commands (list (list :name "kill" :label "Kill"
                                        :confirm (lambda () (overlook-agent-kill-question buffer))
                                        :run (lambda () (overlook-agent-kill buffer)))))))

(defun overlook-agent-courier--multiple-row (name persona)
  "The row of persona NAME, PERSONA, that may run several times.
Its agents are listed under it."
  (let ((ids (overlook-courier-persona-instances name)))
    (overlook-row :id (cons 'persona name)
                  :content (list (overlook-icon
                                  (propertize (overlook-agent-courier--persona-icon-name persona)
                                              'face (unless ids 'shadow)))
                                 " " name
                                 (overlook-align-right
                                  (propertize (if ids (format "%d running" (length ids)) "offline")
                                              'face 'shadow)
                                  1))
                  :action (lambda () (overlook-persona-converse name))
                  :commands (list (list :name "new" :label "New conversation"
                                        :run (lambda ()
                                               (overlook-courier-agent-buffer
                                                (overlook-courier-agent
                                                 (overlook-courier-persona-start name))))))
                  :help (concat (if-let* ((description (plist-get persona :description)))
                                    (concat description "\n")
                                  "")
                                "RET: start a conversation; e: edit it")
                  :children (mapcar (lambda (id) (overlook-agent-courier--instance-row id persona)) ids))))

(defun overlook-persona-converse (name)
  "Start a conversation with persona NAME and show it in another window.
NAME is one of the personas that may run several times."
  (interactive
   (let ((names (seq-filter (lambda (name)
                              (overlook-courier-persona-multiple-p (overlook-courier-persona name)))
                            (overlook-courier-persona-names))))
     (list (cond ((null names) (user-error "No persona has multiple on"))
                 ((null (cdr names)) (car names))
                 (t (completing-read "Converse with: " names nil t))))))
  (pop-to-buffer (overlook-courier-agent-buffer
                  (overlook-courier-agent (overlook-courier-persona-start name)))))

(defun overlook-agent-courier--persona-row (name)
  "The row of persona NAME: its model's icon, colored by its status, and its name.
While it runs in an agent buffer, the row stands for that agent."
  (let* ((persona (overlook-courier-persona name))
         (agent (overlook-courier-agent name))
         (buffer (and agent (overlook-courier-agent-buffer agent)))
         (running (buffer-live-p buffer))
         (meta (propertize (if running "" "offline") 'face 'shadow)))
    (if (overlook-courier-persona-multiple-p persona)
        (overlook-agent-courier--multiple-row name persona)
      (overlook-row :id (if (and running (overlook-agent-p buffer))
                            (cons 'agent buffer)
                          (cons 'persona name))
                    :content (list (overlook-icon
                                    (propertize (overlook-agent-courier--persona-icon-name persona)
						'face (if running
                                                          (overlook-agent-status-face
                                                           (buffer-local-value 'overlook-agent-status buffer))
							'shadow)))
                                   " " (plist-get persona :name)
                                   (overlook-align-right meta 1))
                    :action (if running
				(lambda () (overlook-agent-visit buffer))
                              (lambda () (overlook-persona-start name)))
                    :commands (list (if running
					(list :name "open" :label "Open" :run (lambda () buffer))
                                      (list :name "start" :label "Start"
                                            :run (lambda ()
                                                   (overlook-courier-agent-buffer
                                                    (overlook-courier-agent
                                                     (overlook-courier-persona-start name)))))))
                    :help (concat (if-let* ((description (plist-get persona :description)))
                                      (concat description "\n")
                                    "")
                                  (if running "RET: show it" "RET: start it; e: edit it"))))))

(defun overlook-agent-courier--personas-section ()
  "The Personas section: a row per persona, or one to make the first."
  (when overlook-courier-persona-directories
    (overlook-section-row
     "Personas"
     (if-let* ((names (overlook-courier-persona-names)))
         (mapcar #'overlook-agent-courier--persona-row names)
       (list (overlook-row :content (propertize "No personas yet; RET makes one" 'face 'shadow)
                           :action #'overlook-persona-new)))
     #'overlook-persona-new)))

(defun overlook-persona-start (name &optional directory engine effort)
  "Start persona NAME, by default in its own directory on its own engine.
With a prefix argument, ask for the DIRECTORY, ENGINE and reasoning EFFORT."
  (interactive
   (let ((name (completing-read "Start persona: " (seq-remove #'overlook-courier-agent (overlook-courier-persona-names))
                                nil t)))
     (cons name
           (when current-prefix-arg
             (let ((persona (overlook-courier-persona name)))
               (list (read-directory-name "In directory: " (overlook-courier-persona-directory persona))
                     (completing-read "Engine: "
                                      (and (boundp 'overlook-agent-shell-configs)
                                           (mapcar #'car overlook-agent-shell-configs))
                                      nil nil (plist-get persona :engine))
                     (let ((effort (read-string "Effort (empty for its own): ")))
                       (and (not (string-empty-p effort)) effort))))))))
  (overlook-courier-persona-start name :directory directory :engine engine :effort effort)
  (message "Started persona %s" name))

(defconst overlook-agent-courier--persona-template "---
engine: claude
effort:
description: %s
avatar:
personality:
tone:
---
%s

## Background
"
  "Text of a new persona.md, given its description and role.")

(defun overlook-persona-new (name directory)
  "Make persona NAME in DIRECTORY, one of `overlook-courier-persona-directories'.
Opens its persona.md to fill in."
  (interactive
   (list (let ((name (read-string "New persona: ")))
           (unless (overlook-courier-persona-name-p name)
             (user-error "Persona names are lowercase letters, digits, - and _"))
           (when (overlook-courier-persona name) (user-error "Persona %s exists" name))
           name)
         (if (cdr overlook-courier-persona-directories)
             (completing-read "In: " overlook-courier-persona-directories nil t)
           (or (car overlook-courier-persona-directories)
               (user-error "Set `overlook-courier-persona-directories' first")))))
  (let ((folder (expand-file-name name directory)))
    (make-directory (expand-file-name "memory" folder) t)
    (find-file (expand-file-name "persona.md" folder))
    (when (= (buffer-size) 0)
      (insert (format overlook-agent-courier--persona-template
                      (read-string "One-line description: ")
                      "Your role, and the rules you keep."))
      (save-buffer))))

(defun overlook-persona-edit (name)
  "Open persona NAME's persona.md; on the dashboard, the persona at point."
  (interactive
   (list (pcase (and (derived-mode-p 'overlook-mode) (overlook-item-at-point))
           (`(persona . ,name) name)
           ((and `(agent . ,buffer)
                 (guard (member (buffer-local-value 'overlook-agent-courier-id buffer)
                                (overlook-courier-persona-names))))
            (buffer-local-value 'overlook-agent-courier-id buffer))
           (_ (completing-read "Edit persona: " (overlook-courier-persona-names) nil t)))))
  (find-file (expand-file-name "persona.md" (plist-get (overlook-courier-persona name) :folder))))

;;;###autoload
(define-minor-mode overlook-agent-courier-mode
  "Let overlook's agents message, spawn and monitor each other through courier.
Turning it on links courier's skills where agents find them; see
`overlook-courier-link-skills'."
  :global t
  :group 'overlook
  (overlook-toggle-hooks
   overlook-agent-courier-mode
   '((overlook-agent-environment-functions overlook-agent-courier--environment)
     (overlook-agent-changed-hook overlook-agent-courier--sync)
     (overlook-agent-turn-start-hook overlook-agent-courier--turn-started)
     (overlook-agent-turn-end-hook overlook-agent-courier--turn-finished)
     (overlook-agent-attention-hook overlook-agent-courier--blocked)
     (overlook-agent-row-marks overlook-agent-courier--mark)
     (overlook-agent-hide-functions overlook-agent-courier--persona-item-p)
     (overlook-sections overlook-agent-courier--personas-section -9)
     (overlook-agent-save-functions overlook-agent-courier--saved)
     (overlook-agent-resume-functions overlook-agent-courier--check-resume)
     (overlook-courier-changed-hook overlook-refresh)))
  (setq overlook-courier-spawn-function (and overlook-agent-courier-mode #'overlook-agent-courier--spawn))
  (when overlook-agent-courier-mode
    (overlook-agent-courier--sync)
    (overlook-courier-link-skills))
  (overlook-refresh))

(overlook-define-key "e" #'overlook-persona-edit)

(provide 'overlook-agent-courier)
;;; overlook-agent-courier.el ends here
