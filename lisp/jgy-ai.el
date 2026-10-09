;;; jgy-ai.el --- Agent CLIs -*- lexical-binding: t; -*-

;;; Commentary:
;; Agent CLI 跑在 ghostel-agents 里，在项目文件夹内时以项目根为工作目录。

;;; Code:

(declare-function ghostel-agents-project-root "ghostel-agents")
(declare-function jgy/project-root "jgy-project")

(defun jgy/agent-root ()
  "Return the project folder when inside one, else the version-control root."
  (or (jgy/project-root) (ghostel-agents-project-root)))

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

(use-package ghostel-agents
  :ensure nil
  :commands (ghostel-agents-start ghostel-agents-toggle ghostel-agents-switch
             ghostel-agents-send ghostel-agents-dashboard)
  :autoload ghostel-agents-buffer-p
  :custom
  (ghostel-agents-root-function #'jgy/agent-root)
  :config
  (when (executable-find "claude") (jgy/claude-check-statusline))
  (ghostel-agents-mode 1))

(dolist (name '("claude" "codex" "pi"))
  (defalias (intern (concat "jgy/agent-start-" name))
    (lambda (&optional fresh)
      (interactive "P")
      (ghostel-agents-start name fresh))
    (format "Start or show %s for the current project." name)))

(provide 'jgy-ai)
;;; jgy-ai.el ends here
