;;; jgy-agent-shell.el --- Run agents.el's agents through agent-shell -*- lexical-binding: t; -*-

;;; Commentary:
;; 用 agent-shell（ACP）代替 Ghostel 里的 CLI；tab 归属、看板和快捷键由 agents.el 负责。
;; 套餐用量取自 claude-agent-acp 在 usage_update 的 _meta 里转发的 rate limit，
;; 按 bin/claude-statusline 的格式写进 `agents-usage-file'。

;;; Code:

(require 'acp)
(require 'agent-shell)
(require 'agents)
(require 'map)

(defvar no-littering-var-directory)

(defconst jgy/agent-shell-configs
  '(("claude" . agent-shell-anthropic-make-claude-code-config)
    ("codex" . agent-shell-openai-make-codex-config)
    ("pi" . agent-shell-pi-make-agent-config))
  "Agent name to the function making its agent-shell config.")

(defun jgy/agent-shell-dot-subdir (subdir)
  "Return SUBDIR of this project's agent-shell data, kept out of the repository."
  (expand-file-name
   subdir
   (expand-file-name (file-name-nondirectory (directory-file-name (agent-shell-cwd)))
                     (expand-file-name "agent-shell"
                                       (or (bound-and-true-p no-littering-var-directory)
                                           user-emacs-directory)))))

(defun jgy/agent-shell--on-event (event)
  "Report agent-shell EVENT to `agents-report'."
  (pcase (map-elt event :event)
    ((or 'input-submitted 'permission-response 'tool-call-update 'agent-message-chunk)
     (agents-report 'working))
    ('permission-request (agents-report 'attention))
    ((or 'turn-complete 'error) (agents-report 'finished))))

(defun jgy/agent-shell--context ()
  "Return the context window percentage in use from the shell's usage state."
  (let* ((usage (map-elt agent-shell--state :usage))
         (used (map-elt usage :context-used))
         (size (map-elt usage :context-size)))
    (when (and used size (> size 0))
      (round (* 100.0 used) size))))

(defun jgy/agent-shell--save-usage (notification)
  "Write the plan usage windows carried by NOTIFICATION to `agents-usage-file'."
  (when-let* ((windows (map-nested-elt notification
                                       '(params update _meta _claude/rateLimit unifiedWindows))))
    (let ((usage (mapcar (pcase-lambda (`(,key . ,window))
                           `(,key (used_percentage . ,(round (* 100 (or (map-elt window 'utilization) 0))))
                                  (resets_at . ,(map-elt window 'resetsAt))))
                         windows))
          (temp (make-temp-file (expand-file-name "claude-usage"
                                                  (file-name-directory agents-usage-file)))))
      (with-temp-file temp (insert (json-encode usage)))
      (rename-file temp agents-usage-file t))))

(defun jgy/agent-shell--insert (text)
  "Insert TEXT at this shell's prompt without submitting it."
  (agent-shell-insert :text text :shell-buffer (current-buffer) :no-focus t))

(defun jgy/agent-shell-start (name root)
  "Start agent NAME in ROOT with agent-shell and return its buffer."
  (let* ((make-config (or (alist-get name jgy/agent-shell-configs nil nil #'equal)
                          (user-error "No agent-shell config for %s" name)))
         (default-directory root)
         (agent-shell-cwd-function (lambda () root))
         (buffer (agent-shell--start :config (funcall make-config)
                                     :no-focus t :new-session t)))
    (with-current-buffer buffer
      (setq agents-identity `((kind . agent) (agent . ,name) (root . ,root)
                              (insert . jgy/agent-shell--insert)
                              (context . jgy/agent-shell--context)))
      (agent-shell-subscribe-to :shell-buffer buffer :on-event #'jgy/agent-shell--on-event)
      (acp-subscribe-to-notifications :client (map-elt agent-shell--state :client)
                                      :buffer buffer
                                      :on-notification #'jgy/agent-shell--save-usage))
    buffer))

(provide 'jgy-agent-shell)
;;; jgy-agent-shell.el ends here
