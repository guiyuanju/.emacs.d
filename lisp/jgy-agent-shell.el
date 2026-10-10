;;; jgy-agent-shell.el --- Personal agent-shell look and data location -*- lexical-binding: t; -*-

;;; Commentary:
;; agent-shell 的个人设置：极简 header，以及把会话数据放在 ~/.emacs.d/agent-shell/<项目>/。
;; agent 的管理与看板在 overlook 包里。

;;; Code:

(require 'agent-shell)

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
