;;; iuiw-commands.el --- Personal editing and window commands -*- lexical-binding: t; -*-

;;; Commentary:
;; 绑在 leader 键上的通用命令：文件与路径、搜索、行号、终端开关、启动 agent。

;;; Code:

(require 'cl-lib)
(require 'project)
(declare-function consult-ripgrep "consult")
(declare-function ghostel "ghostel")
(declare-function ghostel-project "ghostel")
(declare-function ghostel-project-buffer-list "ghostel")
(declare-function ediff-recenter "ediff-util")
(defvar ediff-mode-map)
(defvar ghostel-buffer-name)

(defun iuiw-delete-this-file (&optional force)
  "Delete the current file and kill its buffer.
With FORCE, do not ask for confirmation."
  (interactive "P")
  (let ((file (buffer-file-name (buffer-base-buffer))))
    (unless file (user-error "Buffer is not visiting a file"))
    (when (or force (yes-or-no-p (format "Delete %s? "
                                        (abbreviate-file-name file))))
      (delete-file file delete-by-moving-to-trash)
      (when-let* ((buffer (get-file-buffer file)))
        (kill-buffer buffer)))))

(defun iuiw-buffer-path (&optional relative)
  "Return the current path, optionally RELATIVE to its project."
  (let ((path (or (buffer-file-name (buffer-base-buffer)) default-directory)))
    (if-let* ((relative)
              (project (project-current nil (file-name-directory path))))
        (file-relative-name path (project-root project))
      (abbreviate-file-name path))))

(defun iuiw-yank-buffer-path (&optional relative)
  "Copy the current path; with RELATIVE, use the project root."
  (interactive "P")
  (message "Copied: %s" (kill-new (iuiw-buffer-path relative))))

(defun iuiw-insert-buffer-path ()
  "Insert the current buffer path."
  (interactive)
  (insert (iuiw-buffer-path)))

(defun iuiw-reload-config ()
  "Reload init.el.  Restart when changing package declarations."
  (interactive)
  (load user-init-file nil 'nomessage)
  (message "Reloaded %s" (abbreviate-file-name user-init-file)))

(defun iuiw-search-directory ()
  "Run ripgrep in `default-directory'."
  (interactive)
  (consult-ripgrep default-directory))

(defun iuiw-search-symbol-at-point ()
  "Run project ripgrep for the symbol at point."
  (interactive)
  (consult-ripgrep nil (thing-at-point 'symbol t)))

(defun iuiw-toggle-line-numbers ()
  "Cycle absolute, relative, and hidden line numbers."
  (interactive)
  (let ((next (pcase display-line-numbers
                ('t 'relative)
                ('relative nil)
                (_ t))))
    (if next
        (progn
          (display-line-numbers-mode 1)
          (setq display-line-numbers next))
      (display-line-numbers-mode -1))
    (message "Line numbers: %s" (or next "off"))))

(defun iuiw-reveal-in-finder ()
  "Reveal the current path in Finder."
  (interactive)
  (unless (eq system-type 'darwin) (user-error "Finder is only available on macOS"))
  (call-process "open" nil 0 nil "-R"
                (or (buffer-file-name (buffer-base-buffer)) default-directory)))

(defun iuiw-toggle-buffer (buffer create-function)
  "Hide BUFFER if visible, show it if live, otherwise call CREATE-FUNCTION."
  (if-let* ((window (and buffer (get-buffer-window buffer t))))
      (quit-window nil window)
    (let ((buf (if (buffer-live-p buffer)
                   buffer
                 (save-window-excursion (funcall create-function)))))
      (select-window (display-buffer buf)))))

(defun iuiw-eshell-toggle ()
  "Toggle the current project's Eshell, or the global one outside projects.
Called from inside an Eshell it hides that buffer, whatever its `cd'
history has done to `default-directory'."
  (interactive)
  (if (derived-mode-p 'eshell-mode)
      (quit-window)
    (let* ((project (project-current))
           (name (if project (project-prefixed-buffer-name "eshell") "*eshell*")))
      (iuiw-toggle-buffer (get-buffer name)
                         (if project #'project-eshell #'eshell)))))

(defun iuiw-ghostel-toggle ()
  "Toggle the current project's Ghostel, or the global terminal outside projects.
Called from inside a Ghostel it hides that buffer, whatever its `cd'
history has done to `default-directory'."
  (interactive)
  (cond
   ((derived-mode-p 'ghostel-mode) (quit-window))
   ((project-current)
    (iuiw-toggle-buffer (car (ghostel-project-buffer-list)) #'ghostel-project))
   (t (iuiw-toggle-buffer
       (get-buffer (or (bound-and-true-p ghostel-buffer-name) "*ghostel*"))
       #'ghostel))))

(defun iuiw-ediff-quit-without-asking (quit &rest args)
  "Call QUIT with ARGS, answering yes to its \"Quit this Ediff session\" prompt.
Other prompts during quitting are still asked."
  (let ((ask (symbol-function 'y-or-n-p)))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (prompt)
                 (or (string-prefix-p "Quit this Ediff session" prompt)
                     (funcall ask prompt)))))
      (apply quit args))))

(defun iuiw-ediff-bind-recenter ()
  "Bind zz in the Ediff control panel to restore the windows and current diff."
  (define-key ediff-mode-map "zz" #'ediff-recenter))

(provide 'iuiw-commands)
;;; iuiw-commands.el ends here
