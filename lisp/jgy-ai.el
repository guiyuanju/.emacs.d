;;; jgy-ai.el --- Agent CLIs and gptel -*- lexical-binding: t; -*-

;;; Commentary:
;; Agent CLI 跑在 ghostel-agents 里；gptel 走 DeepSeek。

;;; Code:

(declare-function jgy/worktree--visit "jgy-worktree")
(declare-function jgy/worktree--main-repo "jgy-worktree")

(defvar jgy/deepseek-api-key nil
  "DeepSeek API key, set in local.el.")

(use-package ghostel-agents
  :ensure nil
  :commands (ghostel-agents-start ghostel-agents-toggle ghostel-agents-switch
             ghostel-agents-send)
  :autoload ghostel-agents-buffer-p
  :config (ghostel-agents-mode 1))

(dolist (name '("claude" "codex" "pi"))
  (defalias (intern (concat "jgy/agent-start-" name))
    (lambda (&optional fresh)
      (interactive "P")
      (ghostel-agents-start name fresh))
    (format "Start or show %s for the current project." name)))

(use-package gptel
  :commands (gptel gptel-send gptel-menu gptel-rewrite gptel-abort
                   gptel-add gptel-add-file)
  :init
  ;; `gptel' 本身只负责创建/切换，这里补一个开关式的显示与隐藏。
  (defun jgy/gptel-toggle ()
    "显示最近的 gptel 会话；已经在其窗口中则隐藏它。"
    (interactive)
    (require 'gptel)
    (if-let* ((win (get-window-with-predicate
                    (lambda (w) (buffer-local-value 'gptel-mode (window-buffer w))))))
        (if (eq win (selected-window))
            (quit-window nil win)
          (select-window win))
      (if-let* ((buf (seq-find (lambda (b) (buffer-local-value 'gptel-mode b))
                               (buffer-list))))
          (display-buffer buf gptel-display-buffer-action)
        (gptel (format "*%s*" (gptel-backend-name gptel-backend)) nil nil t))))
  :config
  (setq-default gptel-backend
                (gptel-make-openai "DeepSeek"
                  :host "api.deepseek.com"
                  :endpoint "/chat/completions"
                  :stream t
                  :key (lambda () jgy/deepseek-api-key)
                  :models '(deepseek-flash deepseek-v4-pro))))

(defun jgy/worktree-agent (agent branch)
  "Start AGENT on BRANCH of the current repository in a new worktree and tab."
  (interactive
   (list (progn (require 'ghostel-agents)
                (completing-read "Agent: " ghostel-agents-programs nil t nil nil
                                 (or ghostel-agents--last "claude")))
         (string-trim
          (read-string "Branch: " (format-time-string "agent/%m%d-%H%M")))))
  (require 'jgy-worktree)
  (jgy/worktree--visit (jgy/worktree--main-repo) branch)
  (ghostel-agents-start agent))

(provide 'jgy-ai)
;;; jgy-ai.el ends here
