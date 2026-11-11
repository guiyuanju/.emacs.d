;;; iuiw-agent-shell.el --- Personal agent-shell look and data location -*- lexical-binding: t; -*-

;;; Commentary:
;; agent-shell 的个人设置：极简 header，以及把会话数据放在 ~/.emacs.d/agent-shell/<项目>/。
;; agent 的管理与看板在 overlook 包里。

;;; Code:

(require 'agent-shell)

(declare-function overlook-agent-shell-claude-account-identity "overlook-agent-shell" (account))
(declare-function overlook-agent-project "overlook-agent")
(declare-function overlook-agent-show "overlook-agent")
(declare-function overlook-current-project "overlook")
(declare-function iuiw-assistant-shell-p "iuiw-assistant")
(declare-function modus-themes-get-color-value "modus-themes")

(defun iuiw-agent-shell-toggle (&optional arg)
  "Show the most recently used agent in the current project.
Assistant shells are skipped.  Inside an agent, with prefix ARG, or
without a project agent, delegate to `agent-shell' to keep its toggle
and startup behavior."
  (interactive "P")
  (require 'overlook-agent)
  (let* ((project (overlook-current-project))
         (buffer
          (and (not arg)
               (not (derived-mode-p 'agent-shell-mode
                                    'agent-shell-viewport-view-mode
                                    'agent-shell-viewport-edit-mode))
               project
               (seq-find (lambda (buffer)
                           (and (equal project (overlook-agent-project buffer))
                                (not (with-current-buffer buffer
                                       (iuiw-assistant-shell-p)))))
                         (agent-shell-buffers)))))
    (if buffer
        (overlook-agent-show buffer)
      (agent-shell arg))))

(defcustom iuiw-agent-shell-header-separator "·"
  "Glyph separating fields in the agent-shell header line.
agent-shell hardcodes a heavy arrowhead (➤); this replaces it.  Other
candidates: ›, /, │."
  :type 'string
  :group 'agent-shell)

(defface iuiw-agent-shell-header-separator '((t :inherit shadow))
  "Face of the separator between agent-shell header fields."
  :group 'agent-shell)

(defun iuiw-agent-shell--account-header (model)
  "Add the agent's default account to the name in header MODEL."
  (let* ((id (map-nested-elt (agent-shell--state) '(:agent-config :identifier)))
         (account (if (eq id 'claude-code)
                      (and (fboundp 'overlook-agent-shell-claude-current-account)
                           (overlook-agent-shell-claude-account-identity
                            (or (bound-and-true-p overlook-agent-shell--claude-account)
                                (overlook-agent-shell-claude-current-account))))
                    (and (boundp 'overlook-usage-accounts)
                         (alist-get (symbol-name id) overlook-usage-accounts
                                    nil nil #'equal)))))
    (when account
      (setf (alist-get :buffer-name model)
            (concat (alist-get :buffer-name model) " @" account)))
    model))

(advice-add 'agent-shell--make-header-model :filter-return
            #'iuiw-agent-shell--account-header)

(defun iuiw-agent-shell--refresh-account-headers (&rest _)
  "Refresh all agent headers after the default account changes."
  (dolist (buffer (agent-shell-buffers))
    (with-current-buffer buffer
      (agent-shell--update-header-and-mode-line))))

(advice-add 'overlook-agent-shell-claude-switch-account :after
            #'iuiw-agent-shell--refresh-account-headers)

(defun iuiw-agent-shell--minimal-header (header)
  "Return HEADER with a quiet separator and its field faces made visible.
agent-shell tints fields with `font-lock-face', which header lines ignore,
so copy it to `face' for the agent name to stand out over dimmed fields."
  (if (not (stringp header))
      header
    (let ((header (copy-sequence header))
          (pos 0))
      (while pos
        (let ((next (next-single-property-change pos 'font-lock-face header)))
          (when-let* ((face (get-text-property pos 'font-lock-face header)))
            (put-text-property pos (or next (length header)) 'face face header))
          (setq pos next)))
      (replace-regexp-in-string
       " ➤ " (concat " " (propertize iuiw-agent-shell-header-separator
                                     'face 'iuiw-agent-shell-header-separator)
                     " ")
       header t t))))

(advice-add 'agent-shell--render-header-model-uncached :filter-return
            #'iuiw-agent-shell--minimal-header
            '((name . iuiw-agent-shell-minimal-header)))

(defcustom iuiw-agent-shell-antigravity-session-mode "yolo"
  "Session mode a new Antigravity shell starts in, or nil for its default.
Antigravity offers \"default\", \"auto_edit\" (auto-approve file edits) and
\"yolo\" (auto-approve every tool)."
  :type '(choice (const :tag "Antigravity default" nil) string)
  :group 'agent-shell)

(defcustom iuiw-agent-shell-antigravity-config-options '(("thinking_level" . "low"))
  "Session config options a new Antigravity shell starts with, as (OPTION . VALUE).
Antigravity's \"thinking_level\" is \"low\", \"medium\" or \"high\"."
  :type '(alist :key-type string :value-type string)
  :group 'agent-shell)

(defun iuiw-agent-shell--antigravity-defaults (config)
  "Return Antigravity CONFIG, starting in the session mode.
The mode is `iuiw-agent-shell-antigravity-session-mode'.  It also sets
`iuiw-agent-shell-antigravity-config-options'."
  (setf (map-elt config :default-session-mode-id)
        (lambda () iuiw-agent-shell-antigravity-session-mode))
  (setf (map-elt config :default-config-options)
        (lambda () iuiw-agent-shell-antigravity-config-options))
  config)

(advice-add 'agent-shell-antigravity-make-agent-config :filter-return
            #'iuiw-agent-shell--antigravity-defaults
            '((name . iuiw-agent-shell-antigravity-defaults)))

(defun iuiw-agent-shell--quiet-header-line ()
  "Draw this buffer's header line on the buffer background, with breathing room."
  (let* ((bg (face-background 'default nil t))
         (spec `(:background ,bg :box (:line-width (1 . 4) :color ,bg))))
    (face-remap-add-relative 'header-line spec)
    (face-remap-add-relative 'header-line-inactive spec)))

(add-hook 'agent-shell-mode-hook #'iuiw-agent-shell--quiet-header-line)

;; agent-shell tints its header with font-lock colors; only the agent name stands out.
(defun iuiw-agent-shell-flat-faces ()
  "Match the agent-shell header faces to the flat mode line."
  (let ((fg-main (modus-themes-get-color-value 'fg-main t))
        (fg-dim (modus-themes-get-color-value 'fg-dim t)))
    (set-face-attribute 'agent-shell-buffer-name nil
                        :inherit 'bold :foreground fg-main)
    (dolist (face '(agent-shell-model agent-shell-thought-level
                    agent-shell-session-mode agent-shell-session-directory
                    agent-shell-container-indicator))
      (set-face-attribute face nil :inherit nil :foreground fg-dim))))

(iuiw-agent-shell-flat-faces)
(add-hook 'modus-themes-after-load-theme-hook #'iuiw-agent-shell-flat-faces)

(defcustom iuiw-agent-shell-apple-mcp-server
  '((name . "mobilebuildmcp")
    (command . "mobilebuildmcp")
    (args . ("mcp"))
    (env . (((name . "MOBILEBUILDMCP_ENABLED_WORKFLOWS")
             (value . "simulator,ui-automation"))
            ((name . "MOBILEBUILDMCP_SENTRY_DISABLED") (value . "true")))))
  "MCP server given to agents working on an Xcode or Swift package project."
  :type 'sexp
  :group 'agent-shell)

(defun iuiw-agent-shell--apple-project-p (dir)
  "Return non-nil if DIR or a folder directly under it holds an Apple project."
  (seq-some (lambda (pattern) (file-expand-wildcards (expand-file-name pattern dir)))
            '("*.xcodeproj" "*.xcworkspace" "Package.swift"
              "*/*.xcodeproj" "*/*.xcworkspace" "*/Package.swift")))

(defun iuiw-agent-shell--add-apple-mcp (servers)
  "Append `iuiw-agent-shell-apple-mcp-server' to SERVERS in Apple projects."
  (if (and iuiw-agent-shell-apple-mcp-server
           (iuiw-agent-shell--apple-project-p (agent-shell-cwd)))
      (vconcat servers
               (list (agent-shell--make-mcp-server
                      :overrides iuiw-agent-shell-apple-mcp-server)))
    servers))

(advice-add 'agent-shell--mcp-servers :filter-return
            #'iuiw-agent-shell--add-apple-mcp)

(defun iuiw-agent-shell-dot-subdir (subdir)
  "Return SUBDIR of this project's agent-shell data, kept out of the repository.
The data directory is named after the project's base name and a hash of
its full path; one named after the base name alone is moved into it."
  (let* ((cwd (directory-file-name (expand-file-name (agent-shell-cwd))))
         (name (file-name-nondirectory cwd))
         (parent (locate-user-emacs-file "agent-shell/"))
         (dir (expand-file-name (format "%s-%s" name (substring (sha1 cwd) 0 8)) parent))
         (legacy (expand-file-name name parent)))
    (when (and (not (file-exists-p dir)) (file-directory-p legacy))
      (rename-file legacy dir))
    (expand-file-name subdir dir)))

(provide 'iuiw-agent-shell)
;;; iuiw-agent-shell.el ends here
