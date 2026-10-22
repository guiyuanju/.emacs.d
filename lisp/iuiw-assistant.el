;;; iuiw-assistant.el --- Project-independent assistant on an ACP agent -*- lexical-binding: t; -*-

;;; Commentary:
;; 两个 Antigravity shell 跑在与项目无关的目录里：一个多轮问答，一个做翻译、总结等一次性任务。
;; 任务的回复流式写进弹窗；任务 shell 每做完一次就重启，任务之间不共享上下文。
;; 两个 shell 都不进 overlook 看板。

;;; Code:

(require 'agent-shell)
(require 'agent-shell-antigravity)
(require 'markdown-mode)
(require 'subr-x)

(defgroup iuiw-assistant nil
  "Project-independent assistant."
  :group 'tools)

(defcustom iuiw-assistant-directory (locate-user-emacs-file "var/assistant/")
  "Working directory of the assistant shells, outside every project."
  :type 'directory)

(defcustom iuiw-assistant-config-function #'agent-shell-antigravity-make-agent-config
  "Function returning the `agent-shell' config the assistant runs."
  :type 'function)

(defcustom iuiw-assistant-config-options '(("thinking_level" . "low"))
  "ACP config options set on every assistant shell, as (ID . VALUE)."
  :type '(alist :key-type string :value-type string))

(defcustom iuiw-assistant-tasks
  '((translate . "把下面的内容翻译成%s。只输出译文，不要解释。")
    (summarize . "用中文总结下面的内容：先一句话结论，再列出要点。只输出总结。")
    (explain . "用中文简明解释下面的内容。"))
  "Task names and the instructions put before the text they work on.
A %s in an instruction is replaced by a language read from the user."
  :type '(alist :key-type symbol :value-type string))

(defcustom iuiw-assistant-default-input '((translate . region) (summarize . buffer))
  "What each task works on when no region is active.
`region' means the task refuses to run without one.  Tasks not listed
work on the paragraph at point."
  :type '(alist :key-type symbol
                :value-type (choice (const region) (const buffer) (const paragraph))))

(defcustom iuiw-assistant-languages
  '((?c "中文") (?e "English") (?j "日本語"))
  "Languages offered for instructions with a %s, with their keys."
  :type '(repeat (list character string)))

(defcustom iuiw-assistant-result-display-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . bottom) (window-height . 0.3))
  "Display action of the task result buffer."
  :type 'sexp)

(defcustom iuiw-assistant-chat-display-action
  '((display-buffer-reuse-window display-buffer-in-side-window)
    (side . right) (window-width . 0.4))
  "Display action of the chat shell."
  :type 'sexp)

(defconst iuiw-assistant--chat-name "*Assistant*")
(defconst iuiw-assistant--task-name "*Assistant Task*")
(defconst iuiw-assistant--result-name "*Assistant Result*")

(defvar iuiw-assistant--running nil
  "Non-nil while a task is waiting for its reply.")

(defun iuiw-assistant-shell-p ()
  "Return non-nil if the current buffer is an assistant shell."
  (file-equal-p default-directory iuiw-assistant-directory))

(defun iuiw-assistant--start (name)
  "Start a fresh assistant shell in the background, named NAME."
  (make-directory iuiw-assistant-directory t)
  (let* ((options iuiw-assistant-config-options)
         (config (cons (cons :default-config-options (lambda () options))
                       (funcall iuiw-assistant-config-function)))
         (buffer (agent-shell--start :config config
                                     :no-focus t
                                     :new-session t
                                     :session-strategy 'new
                                     :cwd iuiw-assistant-directory)))
    (shell-maker-set-buffer-name buffer name)
    buffer))

(defun iuiw-assistant--shell (name)
  "Return the live assistant shell NAME, starting it if needed."
  (let ((buffer (get-buffer name)))
    (if (buffer-live-p buffer) buffer (iuiw-assistant--start name))))

(defun iuiw-assistant--restart-task-shell ()
  "Replace the task shell with a fresh one, ready for the next task."
  (when-let* ((buffer (get-buffer iuiw-assistant--task-name)))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer)))
  (iuiw-assistant--start iuiw-assistant--task-name))

;;; Results

(defvar-local iuiw-assistant--source nil
  "Markers around the text the result was made from.")

(defvar-keymap iuiw-assistant-result-mode-map
  "q" #'iuiw-assistant-quit
  "y" #'iuiw-assistant-copy
  "r" #'iuiw-assistant-replace)

(define-derived-mode iuiw-assistant-result-mode markdown-mode "Assistant"
  "Mode of the buffer showing an assistant task's reply."
  (setq buffer-read-only t)
  (visual-line-mode 1))

(defun iuiw-assistant-quit ()
  "Close the reply, abandoning the task if it is still running."
  (interactive)
  (when iuiw-assistant--running
    (iuiw-assistant-cancel))
  (quit-window))

(defun iuiw-assistant-copy ()
  "Copy the reply."
  (interactive)
  (kill-new (string-trim (buffer-string)))
  (message "Copied"))

(defun iuiw-assistant-replace ()
  "Replace the text the reply was made from with the reply."
  (interactive)
  (pcase-let ((`(,start . ,end) iuiw-assistant--source)
              (reply (string-trim (buffer-string))))
    (unless (and start (marker-buffer start))
      (user-error "The source text is gone"))
    (with-current-buffer (marker-buffer start)
      (save-excursion
        (goto-char start)
        (delete-region start end)
        (insert reply)))
    (quit-window)))

(defun iuiw-assistant--result-buffer (start end)
  "Return the emptied result buffer for text between markers START and END."
  (with-current-buffer (get-buffer-create iuiw-assistant--result-name)
    (iuiw-assistant-result-mode)
    (let ((inhibit-read-only t)) (erase-buffer))
    (setq iuiw-assistant--source (cons start end))
    (current-buffer)))

(defun iuiw-assistant--append (buffer text)
  "Append TEXT to BUFFER, keeping windows at its end following."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (follow (seq-filter (lambda (window) (= (window-point window) (point-max)))
                                (get-buffer-window-list buffer nil t))))
        (save-excursion
          (goto-char (point-max))
          (insert text))
        (dolist (window follow)
          (set-window-point window (point-max)))))))

;;; Commands

(defun iuiw-assistant--input (task)
  "Return (START . END) markers of the text TASK works on."
  (pcase-let ((`(,start . ,end)
               (pcase (if (use-region-p) 'active (alist-get task iuiw-assistant-default-input))
                 ('active (cons (region-beginning) (region-end)))
                 ('region (user-error "Select the text to %s first" task))
                 ('buffer (cons (point-min) (point-max)))
                 (_ (or (bounds-of-thing-at-point 'paragraph)
                        (user-error "No paragraph at point"))))))
    (save-excursion
      (goto-char start)
      (skip-chars-forward " \t\n" end)
      (setq start (point))
      (goto-char end)
      (skip-chars-backward " \t\n" start)
      (setq end (point)))
    (cons (copy-marker start) (copy-marker end t))))

(defun iuiw-assistant--instruction (task)
  "Return TASK's instruction, asking for a language if it takes one."
  (let ((instruction (alist-get task iuiw-assistant-tasks)))
    (if (string-search "%s" instruction)
        (format instruction
                (cadr (read-multiple-choice "Into: " iuiw-assistant-languages)))
      instruction)))

(defun iuiw-assistant-run (task)
  "Run TASK on the region, or on its default input, and show the reply.
See `iuiw-assistant-default-input'."
  (interactive (list (intern (completing-read "Task: " iuiw-assistant-tasks nil t))))
  (when iuiw-assistant--running
    (user-error "The assistant is still working on the last task"))
  (pcase-let* ((`(,start . ,end) (iuiw-assistant--input task))
               (text (string-trim (buffer-substring-no-properties start end)))
               (instruction (if (string-empty-p text)
                                (user-error "Nothing to send")
                              (iuiw-assistant--instruction task)))
               (shell (iuiw-assistant--shell iuiw-assistant--task-name))
               (result (iuiw-assistant--result-buffer start end))
               (token nil))
    (deactivate-mark)
    (display-buffer result iuiw-assistant-result-display-action)
    (setq iuiw-assistant--running t)
    (with-current-buffer shell
      (setq token
            (agent-shell-subscribe-to
             :shell-buffer shell
             :on-event
             (lambda (event)
               (pcase (map-elt event :event)
                 ('agent-message-chunk
                  (when-let* ((chunk (map-nested-elt event '(:data :text-chunk))))
                    (iuiw-assistant--append result chunk)))
                 ('turn-complete
                  (with-current-buffer shell
                    (agent-shell-unsubscribe :subscription token))
                  (setq iuiw-assistant--running nil)
                  (run-at-time 0 nil #'iuiw-assistant--restart-task-shell)))))))
    (agent-shell-insert :text (concat instruction "\n\n" text)
                        :submit t :no-focus t :shell-buffer shell)))

(defun iuiw-assistant-translate ()
  "Translate the region into a language read from the user."
  (interactive)
  (iuiw-assistant-run 'translate))

(defun iuiw-assistant-summarize ()
  "Summarize the region, or the whole buffer."
  (interactive)
  (iuiw-assistant-run 'summarize))

(defun iuiw-assistant-explain ()
  "Explain the region, or the paragraph at point."
  (interactive)
  (iuiw-assistant-run 'explain))

(defun iuiw-assistant-cancel ()
  "Abandon the running task and restart the task shell."
  (interactive)
  (setq iuiw-assistant--running nil)
  (iuiw-assistant--restart-task-shell))

(defun iuiw-assistant-chat ()
  "Show the chat shell, or hide it when it is showing."
  (interactive)
  (let ((shell (iuiw-assistant--shell iuiw-assistant--chat-name)))
    (if-let* ((window (get-buffer-window shell)))
        (quit-window nil window)
      (select-window (display-buffer shell iuiw-assistant-chat-display-action)))))

(defun iuiw-assistant-ask (question)
  "Send QUESTION to the chat shell and show it."
  (interactive "sAsk: ")
  (let ((shell (iuiw-assistant--shell iuiw-assistant--chat-name)))
    (display-buffer shell iuiw-assistant-chat-display-action)
    (agent-shell-insert :text question :submit t :no-focus t :shell-buffer shell)))

(provide 'iuiw-assistant)
;;; iuiw-assistant.el ends here
