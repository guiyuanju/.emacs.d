;;; iuiw-agent-rules.el --- Let every agent read the workspace rules -*- lexical-binding: t; -*-

;;; Commentary:
;; Claude Code 和 pi 读祖先目录的 CLAUDE.md；Codex 只读 AGENTS.md，且只从 git 根往下找。
;; 本机的 Codex 配置不随 git 同步，所以 overlook 第一次打开时查一遍，缺了就问是否补上：
;; config.toml 里让 Codex 找不到 AGENTS.md 时读 CLAUDE.md，全局 AGENTS.md 链接到 workspace 规则。

;;; Code:

(require 'seq)

(defcustom iuiw-agent-rules-file "~/workspace/CLAUDE.md"
  "Workspace rules every agent should read."
  :type 'file
  :group 'agent-shell)

(defconst iuiw-agent-rules--fallback-line "project_doc_fallback_filenames = [\"CLAUDE.md\"]"
  "Codex setting that makes it read CLAUDE.md where there is no AGENTS.md.")

(defun iuiw-agent-rules--codex-home ()
  "Codex's configuration directory."
  (file-name-as-directory (or (getenv "CODEX_HOME") "~/.codex")))

(defun iuiw-agent-rules--codex-config ()
  (expand-file-name "config.toml" (iuiw-agent-rules--codex-home)))

(defun iuiw-agent-rules--codex-agents ()
  (expand-file-name "AGENTS.md" (iuiw-agent-rules--codex-home)))

(defun iuiw-agent-rules--codex-p ()
  "Non-nil when Codex is installed on this machine."
  (or (executable-find "codex-acp") (executable-find "codex")
      (file-directory-p (iuiw-agent-rules--codex-home))))

(defun iuiw-agent-rules--config-setting ()
  "The fallback setting line in Codex's config.toml, or nil."
  (let ((file (iuiw-agent-rules--codex-config)))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (when (re-search-forward "^[ \t]*project_doc_fallback_filenames[ \t]*=.*$" nil t)
          (match-string 0))))))

(defun iuiw-agent-rules--fallback-ok-p ()
  (when-let* ((line (iuiw-agent-rules--config-setting)))
    (string-match-p "\"CLAUDE\\.md\"" line)))

(defun iuiw-agent-rules--fallback-fix ()
  "Put the fallback setting at the top of config.toml, outside any table."
  (when (iuiw-agent-rules--config-setting)
    (user-error "%s 已设 project_doc_fallback_filenames，请手动加入 \"CLAUDE.md\""
                (iuiw-agent-rules--codex-config)))
  (let ((file (iuiw-agent-rules--codex-config)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (when (file-exists-p file)
        (insert-file-contents file))
      (goto-char (point-min))
      (insert iuiw-agent-rules--fallback-line "\n"))))

(defun iuiw-agent-rules--agents-ok-p ()
  (let ((link (iuiw-agent-rules--codex-agents)))
    (and (file-symlink-p link)
         (file-equal-p link iuiw-agent-rules-file))))

(defun iuiw-agent-rules--agents-fix ()
  (let ((link (iuiw-agent-rules--codex-agents)))
    (when (or (file-symlink-p link) (file-exists-p link))
      (user-error "%s 已存在且不指向 %s，请手动处理" link iuiw-agent-rules-file))
    (make-directory (file-name-directory link) t)
    (make-symbolic-link (expand-file-name iuiw-agent-rules-file) link)))

(defconst iuiw-agent-rules-checks
  '(("Codex 读 CLAUDE.md" iuiw-agent-rules--fallback-ok-p iuiw-agent-rules--fallback-fix)
    ("Codex 全局 AGENTS.md 链到 workspace 规则" iuiw-agent-rules--agents-ok-p iuiw-agent-rules--agents-fix))
  "Codex settings as (DESCRIPTION OK-P FIX).")

(defun iuiw-agent-rules-check (&optional verbose)
  "Offer to set up agents that cannot read the workspace rules.
With VERBOSE, also report when nothing is missing."
  (interactive (list t))
  (let ((missing (and (iuiw-agent-rules--codex-p)
                      (file-exists-p iuiw-agent-rules-file)
                      (seq-remove (lambda (check) (funcall (nth 1 check)))
                                  iuiw-agent-rules-checks))))
    (cond
     ((null missing)
      (when verbose (message "Agent 规则配置齐全")))
     ((y-or-n-p (format "Agent 读不到 workspace 规则，缺：%s。现在补上？"
                        (mapconcat #'car missing "；")))
      (dolist (check missing)
        (funcall (nth 2 check)))
      (message "已补上：%s" (mapconcat #'car missing "；"))))))

(defun iuiw-agent-rules-check-once ()
  "Run `iuiw-agent-rules-check' once, when Emacs is next idle."
  (remove-hook 'overlook-mode-hook #'iuiw-agent-rules-check-once)
  (run-with-idle-timer 1 nil #'iuiw-agent-rules-check))

(provide 'iuiw-agent-rules)
;;; iuiw-agent-rules.el ends here
