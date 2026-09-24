;;; ghostel-agents.el --- Agent CLIs in Ghostel, tracked per project and tab -*- lexical-binding: t; -*-

;;; Commentary:
;; 在 Ghostel 终端里跑 claude、codex、pi 等 agent CLI，按项目复用，按启动时的 tab 归属。
;; `ghostel-agents-mode' 把各 agent 的状态图标挂到 tab 名前，并让 bufferlo 只列出本 tab 的 agent。
;; 状态来自 CLI 自己发出的 OSC 9;4 进度和 OSC 9/777 通知；
;; Pi 需要在 ~/.pi/agent/settings.json 里打开 terminal.showTerminalProgress。

;;; Code:

(require 'cl-lib)
(require 'consult)
(require 'ghostel)
(require 'project)
(require 'seq)
(require 'tab-bar)

(declare-function evil-local-set-key "evil-core")

(defgroup ghostel-agents nil
  "Agent CLIs running in Ghostel."
  :group 'ghostel)

(defcustom ghostel-agents-programs
  '(("claude" "claude")
    ("codex" "codex")
    ("pi" "pi"))
  "Agent name to the argv of its CLI."
  :type '(alist :key-type string :value-type (repeat string)))

(defcustom ghostel-agents-status-glyphs
  '((working "◐" warning)
    (waiting "⚠" error)
    (done "●" success)
    (idle "○" shadow))
  "Glyph and face for each `ghostel-agents-status'."
  :type '(alist :key-type symbol :value-type (list string face)))

(defvar ghostel-agents--last nil
  "Name of the agent most recently started or shown.")

(defvar-local ghostel-agents-status 'idle
  "One of `working', `waiting', `done' or `idle'.
`waiting' means the CLI asked for attention; `done' means it finished unseen.")
(put 'ghostel-agents-status 'permanent-local t)

(defvar-local ghostel-agents--tab nil
  "Id of the tab the agent was started in.")
(put 'ghostel-agents--tab 'permanent-local t)

(defvar ghostel-agents--tab-id-counter 0)

;;; Buffers

(defun ghostel-agents-buffer-p (buffer)
  "Non-nil when BUFFER is a ghostel running an agent CLI."
  (eq (alist-get 'kind (buffer-local-value 'ghostel-identity buffer)) 'agent))

(defun ghostel-agents--identity (buffer key)
  (alist-get key (buffer-local-value 'ghostel-identity buffer)))

(defun ghostel-agents--root ()
  (if-let* ((project (project-current))) (project-root project) default-directory))

(defun ghostel-agents--buffers (&optional pred)
  "Live agent buffers, restricted to those satisfying PRED when given."
  (seq-filter (lambda (buffer)
                (and (ghostel-agents-buffer-p buffer)
                     (or (null pred) (funcall pred buffer))))
              (buffer-list)))

(defun ghostel-agents--project-buffers (&optional name)
  "Agent buffers of the current project, restricted to agent NAME when given."
  (let ((root (expand-file-name (ghostel-agents--root))))
    (ghostel-agents--buffers
     (lambda (buffer)
       (and (equal (ghostel-agents--identity buffer 'root) root)
            (or (null name) (equal (ghostel-agents--identity buffer 'agent) name)))))))

(defun ghostel-agents--current ()
  "This project's agent, preferring the last used one."
  (or (car (ghostel-agents--project-buffers ghostel-agents--last))
      (car (ghostel-agents--project-buffers))))

(defun ghostel-agents--show (buffer-or-name)
  "Select BUFFER-OR-NAME in its window, or in the selected window."
  (pop-to-buffer buffer-or-name
                 '((display-buffer-reuse-window display-buffer-same-window))))

;;; Tabs

(defun ghostel-agents--tab-id ()
  "Return the stable id of the current tab, assigning one when it has none."
  (let ((tab (tab-bar--current-tab-find)))
    (or (alist-get 'ghostel-agents-id (cdr tab))
        ;; 进程号入 id，desktop 恢复回来的旧 id 不会和新 id 撞车。
        (setf (alist-get 'ghostel-agents-id (cdr tab))
              (format "%d-%d" (emacs-pid) (cl-incf ghostel-agents--tab-id-counter))))))

(defun ghostel-agents--tab-index (buffer)
  "Index of the tab BUFFER was started in, or nil when that tab is gone."
  (when-let* ((id (buffer-local-value 'ghostel-agents--tab buffer)))
    (cl-position id (funcall tab-bar-tabs-function)
                 :key (lambda (tab) (alist-get 'ghostel-agents-id (cdr tab)))
                 :test #'equal)))

(defun ghostel-agents--bind-terminal-keys ()
  "Send ESC and \\`C-u' to the agent in insert state; \\`C-g' leaves insert state."
  (when (fboundp 'evil-local-set-key)
    (evil-local-set-key 'insert (kbd "<escape>")
                        (lambda () (interactive) (ghostel-send-key "escape")))
    (evil-local-set-key 'insert (kbd "C-u")
                        (lambda () (interactive) (ghostel-send-key "u" "ctrl")))))

;;; Commands

;;;###autoload
(defun ghostel-agents-start (name &optional fresh)
  "Show agent NAME for the current project, starting it when needed.
With prefix arg FRESH, always start another instance."
  (interactive
   (list (completing-read "Agent: " ghostel-agents-programs nil t nil nil
                          ghostel-agents--last)
         current-prefix-arg))
  (let* ((argv (or (alist-get name ghostel-agents-programs nil nil #'equal)
                   (user-error "Unknown agent %s" name)))
         (default-directory (ghostel-agents--root))
         (buffer (and (not fresh) (car (ghostel-agents--project-buffers name)))))
    (unless buffer
      (unless (executable-find (car argv))
        (user-error "%s is not on exec-path" (car argv)))
      (setq buffer (generate-new-buffer
                    (if (project-current)
                        (project-prefixed-buffer-name name)
                      (format "*%s*" name))))
      ;; 先显示再启动，终端才能按窗口尺寸初始化。
      (ghostel-agents--show buffer)
      (ghostel-exec buffer (car argv) (cdr argv)
                    `((kind . agent) (agent . ,name)
                      (root . ,(expand-file-name default-directory))
                      (command . ,argv)))
      (with-current-buffer buffer
        (setq ghostel-agents--tab (ghostel-agents--tab-id))
        (ghostel-agents--bind-terminal-keys)
        (add-hook 'kill-buffer-hook (lambda () (force-mode-line-update t)) nil t))
      (force-mode-line-update t))
    (setq ghostel-agents--last name)
    (ghostel-agents--show buffer)))

;;;###autoload
(defun ghostel-agents-toggle ()
  "Hide the agent in the selected window, or show this project's agent.
Prompts for an agent to start when none is running."
  (interactive)
  (cond ((ghostel-agents-buffer-p (current-buffer)) (quit-window))
        ((ghostel-agents--current) (ghostel-agents--show (ghostel-agents--current)))
        (t (call-interactively #'ghostel-agents-start))))

;;;###autoload
(defun ghostel-agents-switch ()
  "Pick any running agent buffer with preview, across all projects."
  (interactive)
  (let* ((names (or (mapcar #'buffer-name (ghostel-agents--buffers))
                    (user-error "No agent running")))
         (buffer (get-buffer (consult--read names
                                            :prompt "Agent buffer: "
                                            :require-match t
                                            :category 'ghostel-agent
                                            :sort nil
                                            :annotate (ghostel-agents--annotator names)
                                            :state (consult--buffer-preview)))))
    (when-let* ((index (ghostel-agents--tab-index buffer)))
      (tab-bar-select-tab (1+ index)))
    (ghostel-agents--show buffer)))

;;;###autoload
(defun ghostel-agents-send (&optional beg end)
  "Paste the region, or an @ reference to the file, into this project's agent."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (let* ((file (buffer-file-name (buffer-base-buffer)))
         (path (if file (file-relative-name file (ghostel-agents--root)) (buffer-name)))
         (text (if beg
                   (format "%s:%d-%d\n```\n%s\n```\n" path
                           (line-number-at-pos beg) (line-number-at-pos (max beg (1- end)))
                           (buffer-substring-no-properties beg end))
                 (if file (format "@%s " path) (user-error "Buffer has no file"))))
         (buffer (or (ghostel-agents--current)
                     (user-error "No agent running in this project"))))
    (deactivate-mark)
    (with-current-buffer buffer (ghostel-paste-string text))
    (ghostel-agents--show buffer)))

;;; Status

(defun ghostel-agents--glyph (buffer)
  (let ((glyph (alist-get (buffer-local-value 'ghostel-agents-status buffer)
                          ghostel-agents-status-glyphs)))
    (propertize (car glyph) 'face (cadr glyph))))

(defun ghostel-agents--annotator (names)
  "Annotation function for agent buffer NAMES: status, then the tab it belongs to."
  (let* ((status-col (+ 2 (apply #'max (mapcar #'string-width names))))
         (tab-col (+ status-col 12)))
    (lambda (name)
      (let* ((buffer (get-buffer name))
             (index (ghostel-agents--tab-index buffer)))
        (concat (propertize " " 'display `(space :align-to ,status-col))
                (ghostel-agents--glyph buffer) " "
                (symbol-name (buffer-local-value 'ghostel-agents-status buffer))
                (propertize " " 'display `(space :align-to ,tab-col))
                (if index
                    (alist-get 'name (nth index (funcall tab-bar-tabs-function)))
                  (propertize "(tab closed)" 'face 'shadow)))))))

(defun ghostel-agents--set-status (status)
  (unless (eq status ghostel-agents-status)
    (setq ghostel-agents-status status)
    (force-mode-line-update t)))

(defun ghostel-agents--seen-p ()
  (eq (window-buffer (selected-window)) (current-buffer)))

(defun ghostel-agents--on-progress (state _progress)
  (when (ghostel-agents-buffer-p (current-buffer))
    (cond ((memq state '(remove error))
           (ghostel-agents--set-status (if (ghostel-agents--seen-p) 'idle 'done)))
          ((not (eq ghostel-agents-status 'waiting))
           (ghostel-agents--set-status 'working)))))

(defun ghostel-agents--on-notification (&rest _)
  (when (and (ghostel-agents-buffer-p (current-buffer)) (not (ghostel-agents--seen-p)))
    (ghostel-agents--set-status 'waiting)))

(defun ghostel-agents--acknowledge (&rest _)
  "Reset `done' and `waiting' once the agent is shown in the selected window."
  (let ((buffer (window-buffer (selected-window))))
    (when (and (ghostel-agents-buffer-p buffer)
               (memq (buffer-local-value 'ghostel-agents-status buffer) '(done waiting)))
      (with-current-buffer buffer (ghostel-agents--set-status 'idle)))))

(defun ghostel-agents-tab-name-format (name tab _index)
  "Prepend status glyphs of the agents started in TAB to tab NAME."
  (let* ((id (alist-get 'ghostel-agents-id (cdr tab)))
         (agents (and id (ghostel-agents--buffers
                          (lambda (buffer)
                            (equal id (buffer-local-value 'ghostel-agents--tab buffer)))))))
    (if (null agents)
        name
      (concat (mapconcat (lambda (buffer)
                           (propertize (ghostel-agents--glyph buffer)
                                       'help-echo (format "%s: %s" (buffer-name buffer)
                                                          (buffer-local-value 'ghostel-agents-status buffer))))
                         agents " ")
              " " name))))

(defun ghostel-agents--filter-tab-buffers (fn &rest args)
  "Around advice for `bufferlo-buffer-list' dropping agents owned by other tabs."
  (let ((buffers (apply fn args)))
    (pcase-let ((`(,frame ,tabnum) args))
      (if (eq tabnum 'all)
          buffers
        (let* ((tabs (funcall tab-bar-tabs-function frame))
               (tab (if tabnum (nth tabnum tabs) (assq 'current-tab tabs)))
               (id (alist-get 'ghostel-agents-id (cdr tab))))
          (seq-remove (lambda (buffer)
                        (and (ghostel-agents-buffer-p buffer)
                             (let ((owner (buffer-local-value 'ghostel-agents--tab buffer)))
                               (and owner (not (equal owner id))))))
                      buffers))))))

(defun ghostel-agents--embark-transform (_type target)
  (cons 'buffer target))

;;;###autoload
(define-minor-mode ghostel-agents-mode
  "Track agent status in the tab bar and keep agents with their tab."
  :global t
  (if ghostel-agents-mode
      (progn
        (add-function :before ghostel-progress-function #'ghostel-agents--on-progress)
        (add-function :before ghostel-notification-function #'ghostel-agents--on-notification)
        (advice-add 'bufferlo-buffer-list :around #'ghostel-agents--filter-tab-buffers)
        (add-hook 'window-selection-change-functions #'ghostel-agents--acknowledge)
        (add-hook 'window-buffer-change-functions #'ghostel-agents--acknowledge)
        (add-hook 'tab-bar-tab-name-format-functions #'ghostel-agents-tab-name-format)
        (with-eval-after-load 'embark
          (defvar embark-transformer-alist)
          (add-to-list 'embark-transformer-alist
                       '(ghostel-agent . ghostel-agents--embark-transform))))
    (remove-function ghostel-progress-function #'ghostel-agents--on-progress)
    (remove-function ghostel-notification-function #'ghostel-agents--on-notification)
    (advice-remove 'bufferlo-buffer-list #'ghostel-agents--filter-tab-buffers)
    (remove-hook 'window-selection-change-functions #'ghostel-agents--acknowledge)
    (remove-hook 'window-buffer-change-functions #'ghostel-agents--acknowledge)
    (remove-hook 'tab-bar-tab-name-format-functions #'ghostel-agents-tab-name-format)
    (when (boundp 'embark-transformer-alist)
      (setq embark-transformer-alist
            (assq-delete-all 'ghostel-agent embark-transformer-alist))))
  (force-mode-line-update t))

(provide 'ghostel-agents)
;;; ghostel-agents.el ends here
