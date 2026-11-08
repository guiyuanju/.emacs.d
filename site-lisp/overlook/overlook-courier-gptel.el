;;; overlook-courier-gptel.el --- Personas answered by single gptel requests -*- lexical-binding: t; -*-

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

;; A persona whose engine is gptel runs no agent program.  Each prompt
;; it gets is one gptel request: the persona's body is the system
;; prompt, no earlier exchange is sent, and the model may call only the
;; gptel tools its front matter names.  So a persona asked often costs
;; no agent's system prompt and no growing context.
;;
;;   ---
;;   engine: gptel
;;   backend: DeepSeek            a backend registered with gptel
;;   model: deepseek-v4-flash
;;   tools: jp_search, jp_add     names in gptel's tool registry
;;   memory: off
;;   ---
;;
;; Every exchange is appended to NAME.md in
;; `overlook-courier-gptel-history-directory', which is also the
;; persona's buffer while it runs; it is kept for reading and never sent
;; back.  `overlook-courier-gptel-ask' asks a persona from anywhere, and
;; courier delivers messages to it like to any agent.

;;; Code:

(require 'overlook-courier)
(require 'overlook-courier-persona)

(declare-function gptel-request "gptel-request")
(declare-function gptel-get-backend "gptel-request")
(declare-function gptel-get-tool "gptel-request")
(declare-function gptel-tool-name "gptel-request")
(declare-function gptel-make-fsm "gptel-request")
(declare-function gptel-fsm-info "gptel-request")
(declare-function gptel-abort "gptel")
(declare-function overlook-agent-changed "overlook-agent")
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-tools)
(defvar gptel-use-tools)
(defvar gptel-confirm-tool-calls)
(defvar gptel-include-reasoning)
(defvar gptel-include-tool-results)
(defvar gptel-stream)
(defvar gptel-request--handlers)
(defvar overlook-agent-status)
(defvar overlook-detached)

(defcustom overlook-courier-gptel-history-directory
  (locate-user-emacs-file "var/courier-gptel/")
  "Directory of each gptel persona's history, NAME.md."
  :type 'directory
  :group 'overlook-courier)

(defcustom overlook-courier-gptel-tool-result-width 120
  "Most characters of a tool result shown in a persona's history."
  :type 'natnum
  :group 'overlook-courier)

(defvar-local overlook-courier-gptel--name nil
  "The persona this buffer runs.")

(defvar-local overlook-courier-gptel--busy nil
  "Non-nil while a request is out.")

(defvar-local overlook-courier-gptel--reply nil
  "Text of the last reply, without the tool calls.")

(defvar overlook-courier-gptel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'overlook-courier-gptel-ask)
    (define-key map (kbd "C-c C-k") #'overlook-courier-gptel-abort)
    map)
  "Keymap of `overlook-courier-gptel-mode'.")

(define-minor-mode overlook-courier-gptel-mode
  "A gptel persona's history.
\\<overlook-courier-gptel-mode-map>\\[overlook-courier-gptel-ask] asks it, \
\\[overlook-courier-gptel-abort] stops the request."
  :lighter " persona")

(defun overlook-courier-gptel-names ()
  "Names of the personas whose engine is gptel."
  (seq-filter (lambda (name)
                (equal (plist-get (overlook-courier-persona name) :engine) "gptel"))
              (overlook-courier-persona-names)))

(defun overlook-courier-gptel--system (persona)
  "The system prompt of PERSONA: its body, personality and tone."
  (string-join
   (delq nil (list (let ((body (plist-get persona :body)))
                     (unless (string-empty-p body) body))
                   (when-let* ((p (plist-get persona :personality))) (concat "Personality: " p))
                   (when-let* ((tone (plist-get persona :tone))) (concat "Tone: " tone))))
   "\n\n"))

(defun overlook-courier-gptel--tools (persona)
  "The gptel tools PERSONA's front matter names."
  (mapcar #'gptel-get-tool
          (split-string (or (plist-get persona :tools) "") "[, \t]+" t)))

(defun overlook-courier-gptel--append (buffer text)
  "Append TEXT to BUFFER, keeping windows at its end following it."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (following (seq-filter (lambda (window) (= (window-point window) (point-max)))
                                 (get-buffer-window-list buffer nil t))))
      (save-excursion
        (goto-char (point-max))
        (insert text))
      (dolist (window following)
        (set-window-point window (point-max))))))

(defun overlook-courier-gptel--paragraph (buffer)
  "End BUFFER with a blank line, unless it does already."
  (with-current-buffer buffer
    (let ((tail (buffer-substring-no-properties (max (point-min) (- (point-max) 2)) (point-max))))
      (unless (equal tail "\n\n")
        (overlook-courier-gptel--append buffer (if (string-suffix-p "\n" tail) "\n" "\n\n"))))))

(defun overlook-courier-gptel--set-status (buffer status)
  "Show STATUS, an `overlook-agent-status' value, for persona BUFFER."
  (with-current-buffer buffer
    (setq-local overlook-agent-status status))
  (when (fboundp 'overlook-agent-changed) (overlook-agent-changed)))

(defun overlook-courier-gptel--tool-line (tool args result)
  "A history line for TOOL called with ARGS and giving RESULT."
  (let ((text (replace-regexp-in-string "[ \t\n]+" " " (format "%s" result))))
    (format "> %s %s → %s\n" (gptel-tool-name tool)
            (replace-regexp-in-string "\n" " " (prin1-to-string args))
            (truncate-string-to-width text overlook-courier-gptel-tool-result-width nil nil "…"))))

(defun overlook-courier-gptel--finish (buffer state info)
  "End persona BUFFER's request, which reached gptel STATE with INFO."
  (when (buffer-live-p buffer)
    (let* ((name (buffer-local-value 'overlook-courier-gptel--name buffer))
           (error (pcase state
                    ('DONE nil)
                    ('ABRT "Aborted")
                    (_ (string-trim (format "%s %s" (or (plist-get info :status) "")
                                            (or (plist-get info :error) "")))))))
      (with-current-buffer buffer
        (setq overlook-courier-gptel--busy nil))
      (overlook-courier-gptel--append buffer (if error (format "\n> Failed: %s\n" error) "\n"))
      (with-current-buffer buffer
        (let ((save-silently t)) (save-buffer)))
      (overlook-courier-gptel--set-status buffer (if error 'failed 'idle))
      (overlook-courier-turn-finished name error))))

(defun overlook-courier-gptel--handlers (buffer)
  "The gptel request handlers, ending persona BUFFER's request when it ends."
  (mapcar (lambda (entry)
            (if (memq (car entry) '(DONE ERRS ABRT))
                (append entry (list (lambda (fsm)
                                      (overlook-courier-gptel--finish
                                       buffer (car entry) (gptel-fsm-info fsm)))))
              entry))
          gptel-request--handlers))

(defun overlook-courier-gptel--send (buffer prompt &optional from)
  "Send PROMPT to the persona of BUFFER, from agent FROM or the user."
  (require 'gptel)
  (with-current-buffer buffer
    (when overlook-courier-gptel--busy
      (user-error "%s is still answering" overlook-courier-gptel--name))
    (let* ((name overlook-courier-gptel--name)
           (persona (or (overlook-courier-persona name) (user-error "No persona %s" name)))
           (backend (or (plist-get persona :backend) (user-error "Persona %s names no backend" name)))
           (tools (overlook-courier-gptel--tools persona)))
      (setq overlook-courier-gptel--busy t
            overlook-courier-gptel--reply "")
      (overlook-courier-turn-started name)
      (overlook-courier-gptel--set-status buffer 'working)
      (overlook-courier-gptel--append
       buffer (format "\n## %s%s\n\n%s\n\n" (format-time-string "%F %R")
                      (if from (concat " · " from) "") (string-trim prompt)))
      (condition-case err
          (let ((gptel-backend (gptel-get-backend backend))
                (gptel-model (if-let* ((model (plist-get persona :model))) (intern model) gptel-model))
                (gptel-tools tools)
                (gptel-use-tools (and tools t))
                (gptel-confirm-tool-calls nil)
                (gptel-include-tool-results nil)
                (gptel-include-reasoning nil)
                (gptel-stream t))
            (gptel-request prompt
              :buffer buffer :stream t
              :system (overlook-courier-gptel--system persona)
              :fsm (gptel-make-fsm :handlers (overlook-courier-gptel--handlers buffer))
              :callback
              (lambda (response _info)
                (pcase response
                  ((pred stringp)
                   (with-current-buffer buffer
                     (setq overlook-courier-gptel--reply (concat overlook-courier-gptel--reply response)))
                   (overlook-courier-gptel--append buffer response))
                  (`(tool-result . ,results)
                   (overlook-courier-gptel--paragraph buffer)
                   (pcase-dolist (`(,tool ,args ,result) results)
                     (overlook-courier-gptel--append
                      buffer (overlook-courier-gptel--tool-line tool args result)))
                   (overlook-courier-gptel--append buffer "\n"))))))
        (error (overlook-courier-gptel--finish buffer 'ERRS (list :error (error-message-string err))))))))

(defun overlook-courier-gptel--buffer (name)
  "The buffer of running gptel persona NAME, or nil."
  (when-let* ((agent (overlook-courier-agent name))
              (buffer (overlook-courier-agent-buffer agent))
              ((buffer-live-p buffer))
              ((buffer-local-value 'overlook-courier-gptel--name buffer)))
    buffer))

(defun overlook-courier-gptel-start (persona task from)
  "Run PERSONA, a plist from `overlook-courier-persona', for agent FROM.
It answers TASK at once if non-nil."
  (let* ((name (plist-get persona :name))
         (file (expand-file-name (concat name ".md") overlook-courier-gptel-history-directory))
         (buffer (progn (make-directory overlook-courier-gptel-history-directory t)
                        (find-file-noselect file))))
    (with-current-buffer buffer
      (rename-buffer (format "*%s*" name) t)
      (setq overlook-courier-gptel--name name
            buffer-read-only t)
      (setq-local overlook-detached t)
      (overlook-courier-gptel-mode 1))
    (overlook-courier-register
     name :buffer buffer :parent from
     :deliver (lambda (text) (overlook-courier-gptel--send buffer text))
     :ready (lambda () (not (buffer-local-value 'overlook-courier-gptel--busy buffer)))
     :reply (lambda () (buffer-local-value 'overlook-courier-gptel--reply buffer)))
    (when task (overlook-courier-gptel--send buffer task from))
    buffer))

(defvar overlook-courier-gptel--last nil
  "The gptel persona asked last.")

(defun overlook-courier-gptel-ask (name text)
  "Ask gptel persona NAME about TEXT, starting it if nobody runs it.
TEXT defaults to the region.  In a persona's buffer NAME is that persona;
elsewhere, with several gptel personas, a prefix argument picks one."
  (interactive
   (let* ((names (or (overlook-courier-gptel-names) (user-error "No persona runs on gptel")))
          (name (cond (overlook-courier-gptel--name)
                      ((and (not current-prefix-arg) (member overlook-courier-gptel--last names))
                       overlook-courier-gptel--last)
                      ((and (not current-prefix-arg) (null (cdr names))) (car names))
                      (t (completing-read "Ask persona: " names nil t)))))
     (list name
           (let ((region (when (use-region-p)
                           (buffer-substring-no-properties (region-beginning) (region-end)))))
             (read-string (format "Ask %s: " name) region)))))
  (setq overlook-courier-gptel--last name)
  (let ((buffer (or (overlook-courier-gptel--buffer name)
                    (progn (overlook-courier-persona-start name :wait t)
                           (overlook-courier-gptel--buffer name)))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)) (goto-char (point-max))))
    (display-buffer buffer)
    (dolist (window (get-buffer-window-list buffer nil t))
      (set-window-point window (with-current-buffer buffer (point-max))))
    (overlook-courier-gptel--send buffer text)))

(defun overlook-courier-gptel-abort ()
  "Stop the request of the persona whose buffer this is."
  (interactive)
  (unless overlook-courier-gptel--busy (user-error "Nothing to stop"))
  (gptel-abort (current-buffer)))

(add-to-list 'overlook-courier-persona-engines
             (cons "gptel" (lambda (persona task from)
                             (overlook-courier-gptel-start persona task from))))

(provide 'overlook-courier-gptel)
;;; overlook-courier-gptel.el ends here
