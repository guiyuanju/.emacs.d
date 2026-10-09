;;; jgy-ai.el --- Agent CLIs -*- lexical-binding: t; -*-

;;; Commentary:
;; agent 由 agents.el 管理（tab 归属、看板），经 agent-shell 用 ACP 运行；
;; 在项目文件夹内时以项目根为工作目录。

;;; Code:

(declare-function agents-project-root "agents")
(declare-function jgy/project-root "jgy-project")

(defun jgy/agent-root ()
  "Return the project folder when inside one, else the version-control root."
  (or (jgy/project-root) (agents-project-root)))

(defun jgy/claude-check-statusline ()
  "Say how to set up the status line the agent dashboard reads context usage from."
  (let ((file (expand-file-name "~/.claude/settings.json"))
        (script (expand-file-name "bin/claude-statusline" user-emacs-directory)))
    (unless (and (file-readable-p file)
                 (with-temp-buffer
                   (insert-file-contents file)
                   (search-forward "claude-statusline" nil t)))
      (message "Agent dashboard: for context usage, add to %s: \"statusLine\": {\"type\": \"command\", \"command\": \"%s\"}"
               (abbreviate-file-name file) script))))

(use-package agent-shell
  :defer t
  :custom
  (agent-shell-header-style 'text)
  (agent-shell-session-strategy 'prompt)
  (agent-shell-session-restore-verbosity 'full)
  (agent-shell-context-sources '(region))
  (agent-shell-dot-subdir-function #'jgy/agent-shell-dot-subdir))

(use-package jgy-agent-shell
  :ensure nil
  :autoload (jgy/agent-shell-start jgy/agent-shell-dot-subdir))

(use-package jgy-agent-update
  :ensure nil
  :commands jgy/agent-update-check
  :init
  (run-with-idle-timer 30 nil #'jgy/agent-update-check))

(use-package agents
  :ensure nil
  :commands (agents-start agents-toggle agents-switch agents-send agents-dashboard)
  :autoload (agents-buffer-p agents-project-root)
  :custom
  (agents-root-function #'jgy/agent-root)
  (agents-start-function #'jgy/agent-shell-start)
  :config
  (require 'agents-usage)
  (require 'agents-deepseek)
  (agents-mode 1))

;; desktop 恢复的、或回退后新开的 Ghostel 里的 CLI 仍由它跟踪。
(use-package agents-ghostel
  :ensure nil
  :after (agents ghostel)
  :autoload agents-ghostel-start
  :config
  (when (executable-find "claude") (jgy/claude-check-statusline))
  (agents-ghostel-mode 1))

(dolist (name '("claude" "codex" "pi"))
  (defalias (intern (concat "jgy/agent-start-" name))
    (lambda (&optional fresh)
      (interactive "P")
      (agents-start name fresh))
    (format "Start or show %s for the current project." name)))

(provide 'jgy-ai)
;;; jgy-ai.el ends here
