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
(declare-function evil-define-key* "evil-core")

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
        (add-hook 'kill-buffer-hook
                  (lambda ()
                    (force-mode-line-update t)
                    (ghostel-agents--dashboard-schedule))
                  nil t))
      (force-mode-line-update t)
      (ghostel-agents--dashboard-schedule))
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
    (force-mode-line-update t)
    (ghostel-agents--dashboard-schedule)))

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
  ;; 切 tab 也会走到这里，借机刷新看板里的 tab 列表。
  (ghostel-agents--dashboard-schedule)
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
      ;; `tab-bar-auto-width' only resizes tabs whose first char has a bare tab face.
      (concat " "
              (mapconcat (lambda (buffer)
                           (propertize (ghostel-agents--glyph buffer)
                                       'help-echo (format "%s: %s" (buffer-name buffer)
                                                          (buffer-local-value 'ghostel-agents-status buffer))))
                         agents " ")
              "  " name))))

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

;;; Dashboard

(defcustom ghostel-agents-attention-statuses '(waiting done)
  "Statuses that `ghostel-agents-dashboard-next-attention' stops at."
  :type '(repeat symbol))

(defcustom ghostel-agents-dashboard-width 42
  "Width of the dashboard side window."
  :type 'natnum)

(defconst ghostel-agents--dashboard-name " *agents*"
  "Leading space keeps the dashboard out of `other-buffer' and buffer lists.")

(defvar ghostel-agents--dashboard-timer nil)

(defvar-keymap ghostel-agents-dashboard-mode-map
  :parent special-mode-map
  "RET" #'ghostel-agents-dashboard-visit
  "o" #'ghostel-agents-dashboard-visit
  "C-j" #'ghostel-agents-dashboard-next-attention
  "C-k" #'ghostel-agents-dashboard-previous-attention
  "q" #'ghostel-agents-dashboard)

(define-derived-mode ghostel-agents-dashboard-mode special-mode "Agents"
  "Agents grouped under the tab they were started in."
  (setq-local revert-buffer-function (lambda (&rest _) (ghostel-agents--dashboard-render))
              truncate-lines t)
  (display-line-numbers-mode -1)
  (hl-line-mode 1))

(with-eval-after-load 'evil
  (evil-define-key* 'normal ghostel-agents-dashboard-mode-map
    (kbd "RET") #'ghostel-agents-dashboard-visit
    "o" #'ghostel-agents-dashboard-visit
    (kbd "C-j") #'ghostel-agents-dashboard-next-attention
    (kbd "C-k") #'ghostel-agents-dashboard-previous-attention
    "gr" #'revert-buffer
    "q" #'ghostel-agents-dashboard))

(defun ghostel-agents--dashboard-schedule ()
  "Re-render the dashboard soon, coalescing bursts of changes."
  (when (and (get-buffer ghostel-agents--dashboard-name)
             (not (timerp ghostel-agents--dashboard-timer)))
    (setq ghostel-agents--dashboard-timer
          (run-with-timer 0.1 nil
                          (lambda ()
                            (setq ghostel-agents--dashboard-timer nil)
                            (ghostel-agents--dashboard-render))))))

(defun ghostel-agents--dashboard-line (buffer last)
  "Insert the tree line for agent BUFFER; LAST picks the closing branch."
  (let ((status (buffer-local-value 'ghostel-agents-status buffer))
        (root (ghostel-agents--identity buffer 'root)))
    (insert (propertize (concat "  " (if last "└─ " "├─ ")
                                (ghostel-agents--glyph buffer) " "
                                (or (ghostel-agents--identity buffer 'agent) "agent")
                                (propertize (format " %s" status) 'face
                                            (cadr (alist-get status ghostel-agents-status-glyphs)))
                                (if root
                                    (propertize (format "  %s" (file-name-nondirectory
                                                                (directory-file-name root)))
                                                'face 'shadow)
                                  ""))
                        'ghostel-agents-buffer buffer
                        'help-echo (buffer-name buffer))
            "\n")))

(defun ghostel-agents--dashboard-render ()
  "Redraw the dashboard, keeping point on the same agent."
  (when-let* ((dashboard (get-buffer ghostel-agents--dashboard-name)))
    (with-current-buffer dashboard
      (let* ((window (get-buffer-window dashboard t))
             (frame (if window (window-frame window) (selected-frame)))
             (tabs (funcall tab-bar-tabs-function frame))
             (agents (ghostel-agents--buffers))
             (here (get-text-property (point) 'ghostel-agents-buffer))
             (line (line-number-at-pos))
             (inhibit-read-only t)
             (attention 0))
        (erase-buffer)
        (cl-loop
         for tab in tabs
         for id = (alist-get 'ghostel-agents-id (cdr tab))
         for owned = (and id (seq-filter
                              (lambda (buffer)
                                (equal id (buffer-local-value 'ghostel-agents--tab buffer)))
                              agents))
         do (insert (propertize (alist-get 'name tab) 'face
                                (if (eq (car tab) 'current-tab) '(bold success) 'bold))
                    "\n")
         (setq agents (seq-difference agents owned))
         (cl-loop for (buffer . rest) on owned
                  do (ghostel-agents--dashboard-line buffer (null rest))))
        (when agents
          (insert (propertize "(tab closed)" 'face 'shadow) "\n")
          (cl-loop for (buffer . rest) on agents
                   do (ghostel-agents--dashboard-line buffer (null rest))))
        (dolist (buffer (ghostel-agents--buffers))
          (when (memq (buffer-local-value 'ghostel-agents-status buffer)
                      ghostel-agents-attention-statuses)
            (cl-incf attention)))
        (setq header-line-format
              (format " Agents  %s" (if (zerop attention)
                                        (propertize "all quiet" 'face 'shadow)
                                      (propertize (format "%d need you" attention)
                                                  'face 'error))))
        (goto-char (point-min))
        (if-let* ((pos (and here (text-property-any (point-min) (point-max)
                                                    'ghostel-agents-buffer here))))
            (goto-char pos)
          (forward-line (1- line)))
        (when window (set-window-point window (point)))))))

(defun ghostel-agents--dashboard-attention-p (pos)
  (when-let* ((buffer (get-text-property pos 'ghostel-agents-buffer)))
    (and (buffer-live-p buffer)
         (memq (buffer-local-value 'ghostel-agents-status buffer)
               ghostel-agents-attention-statuses))))

(defun ghostel-agents--dashboard-step (forward)
  "Move to the next agent needing attention, wrapping; FORWARD picks direction."
  (let ((start (line-beginning-position))
        (pos nil))
    (save-excursion
      (catch 'found
        (dotimes (_ (count-lines (point-min) (point-max)))
          (if forward
              (when (or (/= 0 (forward-line 1)) (eobp)) (goto-char (point-min)))
            (when (/= 0 (forward-line -1)) (goto-char (point-max)) (forward-line -1)))
          (when (= (point) start) (throw 'found nil))
          (when (ghostel-agents--dashboard-attention-p (point))
            (throw 'found (setq pos (point)))))))
    (if pos
        (goto-char pos)
      (message (if (ghostel-agents--dashboard-attention-p start)
                   "No other agent needs attention"
                 "No agent needs attention")))))

(defun ghostel-agents-dashboard-next-attention ()
  "Move to the next agent that is waiting or finished unseen."
  (interactive)
  (ghostel-agents--dashboard-step t))

(defun ghostel-agents-dashboard-previous-attention ()
  "Move to the previous agent that is waiting or finished unseen."
  (interactive)
  (ghostel-agents--dashboard-step nil))

(defun ghostel-agents-dashboard-visit ()
  "Switch to the agent's tab and show it there."
  (interactive)
  (let ((buffer (or (get-text-property (point) 'ghostel-agents-buffer)
                    (user-error "No agent on this line"))))
    (unless (buffer-live-p buffer) (user-error "Agent buffer is gone"))
    (when-let* ((index (ghostel-agents--tab-index buffer)))
      (tab-bar-select-tab (1+ index)))
    (when (window-parameter (selected-window) 'window-side)
      (select-window (get-mru-window nil nil t)))
    (ghostel-agents--show buffer)
    ;; 看板是当前 tab 的侧窗，跟着到新 tab 里再开一份。
    (unless (get-buffer-window ghostel-agents--dashboard-name)
      (ghostel-agents--dashboard-display))))

(defun ghostel-agents--dashboard-display ()
  "Show the dashboard in a right side window and return that window."
  (display-buffer-in-side-window
   (get-buffer ghostel-agents--dashboard-name)
   `((side . right) (slot . -1) (window-width . ,ghostel-agents-dashboard-width)
     (window-parameters (no-delete-other-windows . t)))))

;;;###autoload
(defun ghostel-agents-dashboard ()
  "Toggle a side window listing every agent under the tab it belongs to."
  (interactive)
  (if-let* ((window (get-buffer-window ghostel-agents--dashboard-name)))
      (delete-window window)
    (with-current-buffer (get-buffer-create ghostel-agents--dashboard-name)
      (unless (derived-mode-p 'ghostel-agents-dashboard-mode)
        (ghostel-agents-dashboard-mode)))
    (ghostel-agents--dashboard-render)
    (select-window (ghostel-agents--dashboard-display))))

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
