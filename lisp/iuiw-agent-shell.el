;;; iuiw-agent-shell.el --- Personal agent-shell look and data location -*- lexical-binding: t; -*-

;;; Commentary:
;; agent-shell 的个人设置：极简 header，以及把会话数据放在 ~/.emacs.d/agent-shell/<项目>/。
;; agent 的管理与看板在 overlook 包里。

;;; Code:

(require 'agent-shell)

(declare-function overlook-agent-perspective "overlook-agent")
(declare-function overlook-agent-show "overlook-agent")
(declare-function overlook-current-perspective "overlook")
(declare-function iuiw-assistant-shell-p "iuiw-assistant")
(declare-function modus-themes-get-color-value "modus-themes")

(defun iuiw-agent-shell-toggle (&optional arg)
  "Show the most recently used agent in the current perspective.
Assistant shells are skipped.  Inside an agent, with prefix ARG, or without a perspective agent,
delegate to `agent-shell' to keep its toggle and startup behavior."
  (interactive "P")
  (require 'overlook-agent)
  (let* ((perspective (overlook-current-perspective))
         (buffer
          (and (not arg)
               (not (derived-mode-p 'agent-shell-mode
                                    'agent-shell-viewport-view-mode
                                    'agent-shell-viewport-edit-mode))
               perspective
               (seq-find (lambda (buffer)
                           (and (equal perspective (overlook-agent-perspective buffer))
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

(defun iuiw-agent-shell--permission-arguments (orig &rest args)
  "Call ORIG with ARGS, then append every argument of the tool call.
agent-shell shows `rawInput' only when it is a single string field, so
other MCP calls asked for permission showing only their tool name."
  (let* ((title (apply orig args))
         (tool-call (plist-get args :tool-call))
         (raw-input (map-elt tool-call :raw-input)))
    (if (and (member (map-elt tool-call :kind) '(nil "other"))
             raw-input
             (not (and (= (length raw-input) 1) (stringp (cdar raw-input))))
             (not (map-elt raw-input 'command)))
        (concat title "\n\n"
                (mapconcat
                 (lambda (pair)
                   (let ((value (cdr pair)))
                     (if (and (stringp value) (string-search "\n" value))
                         (format "%s:\n```\n%s\n```" (car pair) value)
                       (format "- %s: `%s`" (car pair)
                               (if (stringp value) value (json-encode value))))))
                 raw-input "\n"))
      title)))

(advice-add 'agent-shell--permission-title :around
            #'iuiw-agent-shell--permission-arguments
            '((name . iuiw-agent-shell-permission-arguments)))

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
  "Return Antigravity CONFIG starting in `iuiw-agent-shell-antigravity-session-mode'.
It also sets `iuiw-agent-shell-antigravity-config-options'."
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

(defun iuiw-agent-shell-dot-subdir (subdir)
  "Return SUBDIR of this project's agent-shell data, kept out of the repository."
  (expand-file-name
   subdir
   (expand-file-name (file-name-nondirectory (directory-file-name (agent-shell-cwd)))
                     (locate-user-emacs-file "agent-shell/"))))

(provide 'iuiw-agent-shell)
;;; iuiw-agent-shell.el ends here
