;;; jgy-agent-shell.el --- Personal agent-shell look and data location -*- lexical-binding: t; -*-

;;; Commentary:
;; agent-shell 的个人设置：极简 header，以及把会话数据放在 ~/.emacs.d/agent-shell/<项目>/。
;; agent 的管理与看板在 overlook 包里。

;;; Code:

(require 'agent-shell)

(declare-function overlook-agent-perspective "overlook-agent")
(declare-function overlook-agent-show "overlook-agent")
(declare-function overlook-current-perspective "overlook")

(defun jgy-agent-shell-toggle (&optional arg)
  "Show the most recently used agent in the current perspective.
Inside an agent, with prefix ARG, or without a perspective agent,
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
                           (equal perspective (overlook-agent-perspective buffer)))
                         (agent-shell-buffers)))))
    (if buffer
        (overlook-agent-show buffer)
      (agent-shell arg))))

(defcustom jgy-agent-shell-header-separator "·"
  "Glyph separating fields in the agent-shell header line.
agent-shell hardcodes a heavy arrowhead (➤); this replaces it.  Other
candidates: ›, /, │."
  :type 'string
  :group 'agent-shell)

(defface jgy-agent-shell-header-separator '((t :inherit shadow))
  "Face of the separator between agent-shell header fields."
  :group 'agent-shell)

(defun jgy-agent-shell--minimal-header (header)
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
       " ➤ " (concat " " (propertize jgy-agent-shell-header-separator
                                     'face 'jgy-agent-shell-header-separator)
                     " ")
       header t t))))

(advice-add 'agent-shell--render-header-model-uncached :filter-return
            #'jgy-agent-shell--minimal-header
            '((name . jgy-agent-shell-minimal-header)))

(defun jgy-agent-shell--permission-arguments (orig &rest args)
  "Call ORIG with ARGS, then append every argument of a multi-argument tool call.
agent-shell shows `rawInput' only when it has a single field, so a
multi-argument MCP call asked for permission showing only its tool name."
  (let* ((title (apply orig args))
         (tool-call (plist-get args :tool-call))
         (raw-input (map-elt tool-call :raw-input)))
    (if (and (member (map-elt tool-call :kind) '(nil "other"))
             (> (length raw-input) 1)
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
            #'jgy-agent-shell--permission-arguments
            '((name . jgy-agent-shell-permission-arguments)))

(defun jgy-agent-shell--quiet-header-line ()
  "Draw this buffer's header line on the buffer background, with breathing room."
  (let* ((bg (face-background 'default nil t))
         (spec `(:background ,bg :box (:line-width (1 . 4) :color ,bg))))
    (face-remap-add-relative 'header-line spec)
    (face-remap-add-relative 'header-line-inactive spec)))

(add-hook 'agent-shell-mode-hook #'jgy-agent-shell--quiet-header-line)

(defun jgy-agent-shell-dot-subdir (subdir)
  "Return SUBDIR of this project's agent-shell data, kept out of the repository."
  (expand-file-name
   subdir
   (expand-file-name (file-name-nondirectory (directory-file-name (agent-shell-cwd)))
                     (locate-user-emacs-file "agent-shell/"))))

(provide 'jgy-agent-shell)
;;; jgy-agent-shell.el ends here
