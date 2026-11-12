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
;; The persona's buffer is a comint buffer: type at its prompt to ask it;
;; the header line says no earlier question is sent.  Every exchange is
;; also appended to NAME.md in `overlook-courier-gptel-history-directory',
;; kept for reading and never sent back; each start moves it to archive/.
;; `overlook-courier-gptel-ask' asks a persona from anywhere, and courier
;; delivers messages to it like to any agent.  With overlook-agent
;; loaded the buffer is an agent too, so views that follow agents, like
;; overlook-remote, list it, prompt it and show its replies.

;;; Code:

(require 'comint)
(require 'overlook-courier)
(require 'overlook-courier-persona)

(declare-function gptel-request "gptel-request")
(declare-function gptel-get-backend "gptel-request")
(declare-function gptel-get-tool "gptel-request")
(declare-function gptel-tool-name "gptel-request")
(declare-function gptel-make-fsm "gptel-request")
(declare-function gptel-fsm-info "gptel-request")
(declare-function gptel-abort "gptel")
(declare-function markdown-overlays-put "markdown-overlays")
(declare-function overlook-agent-event "overlook-agent")
(declare-function overlook-agent-p "overlook-agent")
(declare-function overlook-agent-register "overlook-agent")
(declare-function overlook-agent-report "overlook-agent")
(defvar overlook-agent-identity)
(defvar overlook-agent-error)
(defvar gptel-backend)
(defvar gptel-model)
(defvar gptel-tools)
(defvar gptel-use-tools)
(defvar gptel-confirm-tool-calls)
(defvar gptel-include-reasoning)
(defvar gptel-include-tool-results)
(defvar gptel-stream)
(defvar gptel-request--handlers)
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

(defvar-local overlook-courier-gptel--entry ""
  "The exchange in progress, as it goes to the history file.")

(defvar-local overlook-courier-gptel--reply-start nil
  "Marker where the reply in progress starts.")

(defvar-local overlook-courier-gptel--spinner nil
  "The overlay showing the spinner while a request is out.")

(defconst overlook-courier-gptel--spinner-frames "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  "Frames of the spinner, one character each.")

(defvar-local overlook-courier-gptel--own-turns nil
  "Non-nil when this persona tells courier of its turns itself.
Otherwise it is an overlook agent courier learned of, and whose turns
reach courier through overlook's turn hooks.")

(defvar overlook-courier-gptel-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap comint-send-input] #'overlook-courier-gptel-submit)
    (define-key map [remap comint-interrupt-subjob] #'overlook-courier-gptel-abort)
    (define-key map (kbd "C-c C-k") #'overlook-courier-gptel-abort)
    map)
  "Keymap of `overlook-courier-gptel-mode'.")

(define-derived-mode overlook-courier-gptel-mode comint-mode "Persona"
  "A gptel persona's buffer, asked at its prompt.
\\<overlook-courier-gptel-mode-map>\\[overlook-courier-gptel-submit] asks it, \
\\[overlook-courier-gptel-abort] stops the request."
  (setq-local comint-input-sender #'overlook-courier-gptel--input-sender)
  (setq-local comint-prompt-read-only t)
  (setq-local comint-process-echoes nil)
  (setq-local mode-line-process '(overlook-courier-gptel--busy ":answering"))
  (setq-local header-line-format
              '(:eval (propertize (format " %s answers each question alone; it sees none of the earlier ones"
                                          overlook-courier-gptel--name)
                                  'face 'shadow)))
  (visual-line-mode 1))

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

(defun overlook-courier-gptel--file (name)
  "The history file of persona NAME."
  (expand-file-name (concat name ".md") overlook-courier-gptel-history-directory))

(defun overlook-courier-gptel--archive (name)
  "Move persona NAME's history to archive/NAME-TIME.md, if it has any."
  (let ((file (overlook-courier-gptel--file name)))
    (when (and (file-exists-p file) (> (file-attribute-size (file-attributes file)) 0))
      (let ((archive (expand-file-name "archive/" overlook-courier-gptel-history-directory)))
        (make-directory archive t)
        (rename-file file (expand-file-name (format-time-string (concat name "-%Y%m%d-%H%M%S.md"))
                                            archive))))))

(defun overlook-courier-gptel--show (text &optional face)
  "Show TEXT with FACE before the input at the current buffer's prompt."
  (comint-output-filter (get-buffer-process (current-buffer))
                        (if face (propertize text 'font-lock-face face) text)))

(defun overlook-courier-gptel--prompt ()
  "Show the current buffer's prompt."
  (overlook-courier-gptel--show (format "%s> " overlook-courier-gptel--name)))

(defun overlook-courier-gptel--render (start end)
  "Format the Markdown between START and END, when markdown-overlays is around."
  (when (require 'markdown-overlays nil t)
    (save-excursion
      (save-restriction
        (narrow-to-region start end)
        (let ((inhibit-read-only t)) (markdown-overlays-put))))))

(defun overlook-courier-gptel--spin ()
  "Show a spinner where the current buffer's reply goes, until the request ends.
The overlay stays after text inserted at it, so it follows the reply."
  (overlook-courier-gptel--stop-spinner)
  (let* ((mark (process-mark (get-buffer-process (current-buffer))))
         (overlay (make-overlay mark mark nil t t))
         (frame 0)
         (timer nil))
    (setq timer (run-at-time
                 0 0.1
                 (lambda ()
                   (if (not (overlay-buffer overlay))
                       (cancel-timer timer)
                     (setq frame (% (1+ frame) (length overlook-courier-gptel--spinner-frames)))
                     (overlay-put overlay 'after-string
                                  (propertize (string (aref overlook-courier-gptel--spinner-frames frame))
                                              'face 'shadow))))))
    (overlay-put overlay 'after-string
                 (propertize (string (aref overlook-courier-gptel--spinner-frames 0)) 'face 'shadow))
    (setq overlook-courier-gptel--spinner overlay)))

(defun overlook-courier-gptel--stop-spinner ()
  "Remove the current buffer's spinner; its timer then stops itself."
  (when overlook-courier-gptel--spinner
    (delete-overlay overlook-courier-gptel--spinner)
    (setq overlook-courier-gptel--spinner nil)))

(defun overlook-courier-gptel--append (buffer text &optional face)
  "Add TEXT to the exchange in persona BUFFER, shown with FACE."
  (with-current-buffer buffer
    (setq overlook-courier-gptel--entry (concat overlook-courier-gptel--entry text))
    (overlook-courier-gptel--show text face)))

(defun overlook-courier-gptel--paragraph (buffer)
  "End the exchange in BUFFER with a blank line, unless it does already."
  (with-current-buffer buffer
    (let ((entry overlook-courier-gptel--entry))
      (unless (string-suffix-p "\n\n" entry)
        (overlook-courier-gptel--append buffer (if (string-suffix-p "\n" entry) "\n" "\n\n"))))))

(defun overlook-courier-gptel--agent-p (buffer)
  "Non-nil when persona BUFFER is an overlook agent."
  (and (fboundp 'overlook-agent-p) (overlook-agent-p buffer)))

(defun overlook-courier-gptel--turn-started (buffer)
  "Start persona BUFFER's turn."
  (with-current-buffer buffer
    (when (overlook-courier-gptel--agent-p buffer) (overlook-agent-report 'working))
    (when overlook-courier-gptel--own-turns
      (overlook-courier-turn-started overlook-courier-gptel--name))))

(defun overlook-courier-gptel--turn-finished (buffer error)
  "End persona BUFFER's turn, failed with message ERROR if non-nil."
  (with-current-buffer buffer
    (when (overlook-courier-gptel--agent-p buffer)
      (setq overlook-agent-error error)
      (overlook-agent-report (if error 'failed 'finished)))
    (when overlook-courier-gptel--own-turns
      (overlook-courier-turn-finished overlook-courier-gptel--name error))))

(defun overlook-courier-gptel--event (buffer type &rest properties)
  "Tell the views following persona BUFFER of event TYPE with PROPERTIES."
  (when (overlook-courier-gptel--agent-p buffer)
    (with-current-buffer buffer (apply #'overlook-agent-event type properties))))

(defun overlook-courier-gptel--make-agent (buffer persona)
  "Make persona BUFFER an overlook agent running PERSONA, if overlook-agent is on.
Its identity names the persona, so courier knows it by the persona's name
and the dashboard lists it with the personas, not in a project."
  (when (fboundp 'overlook-agent-register)
    (let ((name (plist-get persona :name))
          (backend (plist-get persona :backend)))
      (with-current-buffer buffer
        (setq-local overlook-agent-identity
                    `((agent . ,(if backend (downcase backend) "gptel"))
                      (root . ,(overlook-courier-persona-directory persona))
                      (persona . ,name)
                      (title . ,(lambda () name))
                      (submit . ,(lambda (text) (overlook-courier-gptel--send buffer text)))
                      (ready . ,(lambda () (not overlook-courier-gptel--busy)))
                      (reply . ,(lambda () overlook-courier-gptel--reply))
                      (remote-controls . ,(lambda () '(:actions ("stop" "restart"))))
                      (remote-action . overlook-courier-gptel--remote-action))))
      (overlook-agent-register buffer name))))

(defun overlook-courier-gptel--tool-line (tool args result)
  "A history line for TOOL called with ARGS and giving RESULT."
  (let ((text (replace-regexp-in-string "[ \t\n]+" " " (format "%s" result))))
    (format "> %s %s → %s\n" (gptel-tool-name tool)
            (replace-regexp-in-string "\n" " " (prin1-to-string args))
            (truncate-string-to-width text overlook-courier-gptel-tool-result-width nil nil "…"))))

(defun overlook-courier-gptel--finish (buffer state info)
  "End persona BUFFER's request, which reached gptel STATE with INFO."
  (when (buffer-live-p buffer)
    (let* ((error (pcase state
                    ('DONE nil)
                    ('ABRT "Aborted")
                    (_ (string-trim (format "%s %s" (or (plist-get info :status) "")
                                            (or (plist-get info :error) "")))))))
      (overlook-courier-gptel--append buffer (if error (format "\n> Failed: %s\n" error) "\n")
                                      (and error 'error))
      (with-current-buffer buffer
        (let ((file (overlook-courier-gptel--file overlook-courier-gptel--name))
              (coding-system-for-write 'utf-8))
          (make-directory (file-name-directory file) t)
          (write-region overlook-courier-gptel--entry nil file t 'silent))
        (overlook-courier-gptel--render overlook-courier-gptel--reply-start
                                        (process-mark (get-buffer-process buffer)))
        (overlook-courier-gptel--stop-spinner)
        (setq overlook-courier-gptel--busy nil)
        (overlook-courier-gptel--show "\n")
        (overlook-courier-gptel--prompt))
      (overlook-courier-gptel--event buffer (if error 'error 'end) :text error)
      (overlook-courier-gptel--turn-finished buffer error))))

(defun overlook-courier-gptel--handlers (buffer)
  "The gptel request handlers, ending persona BUFFER's request when it ends."
  (mapcar (lambda (entry)
            (if (memq (car entry) '(DONE ERRS ABRT))
                (append entry (list (lambda (fsm)
                                      (overlook-courier-gptel--finish
                                       buffer (car entry) (gptel-fsm-info fsm)))))
              entry))
          gptel-request--handlers))

(defun overlook-courier-gptel--send (buffer prompt &optional from typed)
  "Send PROMPT to the persona of BUFFER, from agent FROM or the user.
TYPED means it was typed at the buffer's prompt, so it shows there already."
  (require 'gptel)
  (with-current-buffer buffer
    (when overlook-courier-gptel--busy
      (user-error "%s is still answering" overlook-courier-gptel--name))
    (let* ((name overlook-courier-gptel--name)
           (persona (or (overlook-courier-persona name) (user-error "No persona %s" name)))
           (backend (or (plist-get persona :backend) (user-error "Persona %s names no backend" name)))
           (tools (overlook-courier-gptel--tools persona)))
      (setq overlook-courier-gptel--busy t
            overlook-courier-gptel--reply ""
            overlook-courier-gptel--entry
            (format "\n## %s%s\n\n%s\n\n" (format-time-string "%F %R")
                    (if from (concat " · " from) "") (string-trim prompt)))
      (unless typed
        (overlook-courier-gptel--show (concat (string-trim prompt) "\n") 'comint-highlight-input))
      (overlook-courier-gptel--show "\n")
      (setq overlook-courier-gptel--reply-start (copy-marker (process-mark (get-buffer-process buffer))))
      (overlook-courier-gptel--spin)
      (overlook-courier-gptel--turn-started buffer)
      (overlook-courier-gptel--event buffer 'prompt :text prompt)
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
                   (overlook-courier-gptel--append buffer response)
                   (overlook-courier-gptel--event buffer 'text :text response))
                  (`(tool-result . ,results)
                   (overlook-courier-gptel--paragraph buffer)
                   (pcase-dolist (`(,tool ,args ,result) results)
                     (overlook-courier-gptel--append
                      buffer (overlook-courier-gptel--tool-line tool args result) 'shadow)
                     (overlook-courier-gptel--event
                      buffer 'tool :id (format "%s-%s" (gptel-tool-name tool) (float-time))
                      :title (format "%s %s" (gptel-tool-name tool)
                                     (replace-regexp-in-string "\n" " " (prin1-to-string args)))
                      :status "completed" :kind "other" :output (format "%s" result)))
                   (overlook-courier-gptel--append buffer "\n"))))))
        (error (overlook-courier-gptel--finish buffer 'ERRS (list :error (error-message-string err))))))))

(defun overlook-courier-gptel--input-sender (_process input)
  "Ask this buffer's persona INPUT, typed at its prompt."
  (overlook-courier-gptel--send (current-buffer) input nil t))

(defun overlook-courier-gptel-submit ()
  "Ask this buffer's persona the input at its prompt."
  (interactive)
  (let ((mark (process-mark (get-buffer-process (current-buffer)))))
    (when (>= (point) mark)
      (when overlook-courier-gptel--busy
        (user-error "%s is still answering" overlook-courier-gptel--name))
      (when (string-blank-p (buffer-substring-no-properties mark (point-max)))
        (user-error "Nothing to ask"))))
  (comint-send-input))

(defun overlook-courier-gptel--buffer (name)
  "The buffer of running gptel persona NAME, or nil."
  (when-let* ((agent (overlook-courier-agent name))
              (buffer (overlook-courier-agent-buffer agent))
              ((buffer-live-p buffer))
              ((buffer-local-value 'overlook-courier-gptel--name buffer)))
    buffer))

(defun overlook-courier-gptel-start (persona task from)
  "Run PERSONA, a plist from `overlook-courier-persona', for agent FROM.
It answers TASK at once if non-nil.  Its earlier history goes to the archive."
  (let* ((name (plist-get persona :name))
         (buffer (generate-new-buffer (format "*%s*" name))))
    (overlook-courier-gptel--archive name)
    (with-current-buffer buffer
      (overlook-courier-gptel-mode)
      (setq overlook-courier-gptel--name name)
      (setq-local overlook-detached t)
      (set-marker (process-mark (make-pipe-process :name (format "persona-%s" name)
                                                   :buffer buffer :noquery t))
                  (point-max))
      (overlook-courier-gptel--prompt))
    (overlook-courier-gptel--make-agent buffer persona)
    (if-let* ((agent (overlook-courier-agent name)))
        (setf (overlook-courier-agent-parent agent) from)
      (with-current-buffer buffer (setq overlook-courier-gptel--own-turns t))
      (overlook-courier-register
       name :buffer buffer :parent from
       :deliver (lambda (text) (overlook-courier-gptel--send buffer text))
       :ready (lambda () (not (buffer-local-value 'overlook-courier-gptel--busy buffer)))
       :reply (lambda () (buffer-local-value 'overlook-courier-gptel--reply buffer))))
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
    (with-current-buffer buffer (goto-char (point-max)))
    (display-buffer buffer)
    (dolist (window (get-buffer-window-list buffer nil t))
      (set-window-point window (with-current-buffer buffer (point-max))))
    (overlook-courier-gptel--send buffer text)))

(defun overlook-courier-gptel-abort ()
  "Stop the request of the persona whose buffer this is."
  (interactive)
  (unless overlook-courier-gptel--busy (user-error "Nothing to stop"))
  (gptel-abort (current-buffer)))

(defun overlook-courier-gptel-restart ()
  "Start the persona of this buffer afresh, its history moved to the archive.
The history goes to archive/NAME-TIME.md in
`overlook-courier-gptel-history-directory'.  Return the new buffer."
  (interactive)
  (let ((name (or overlook-courier-gptel--name (user-error "Not a gptel persona's buffer"))))
    (when overlook-courier-gptel--busy (user-error "%s is still answering" name))
    (let ((kill-buffer-query-functions nil)) (kill-buffer))
    (overlook-courier-persona-start name :wait t)
    (let ((buffer (overlook-courier-gptel--buffer name)))
      (when (called-interactively-p 'any) (pop-to-buffer-same-window buffer))
      buffer)))

(defun overlook-courier-gptel--remote-action (action _text)
  "Run session ACTION from a remote view; return the persona's buffer."
  (pcase action
    ("stop" (overlook-courier-gptel-abort) (current-buffer))
    ("restart" (overlook-courier-gptel-restart))
    (_ (user-error "Unknown session action: %s" action))))

(add-to-list 'overlook-courier-persona-engines
             (cons "gptel" (lambda (persona task from)
                             (overlook-courier-gptel-start persona task from))))

(provide 'overlook-courier-gptel)
;;; overlook-courier-gptel.el ends here
