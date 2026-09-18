;;; jgy-agent-manager.el --- Tab-grouped panel for agent-shell -*- lexical-binding: t; -*-

;;; Commentary:
;; 把 agent-shell 会话按所属 tab 折成一棵树，面板跟着 tab 走，RET 切到 agent 所在的
;; tab 再显示它。状态只读 agent-shell 自身的 API。
;;
;; init.el 在 agent-shell 加载后 require 本文件：tab 归属必须在 shell 创建的那一刻
;; 就记下来，晚于此就丢了。

;;; Code:

(require 'agent-shell)
(require 'map)
(require 'tab-bar)
(require 'magit-section)

(defvar jgy/agent-manager-buffer-name "*Agents*")

(defvar jgy/agent-manager-side 'bottom
  "Frame side the panel is docked to: `left', `right', `top' or `bottom'.")

(defvar jgy/agent-manager-size 0.3
  "Fraction of the frame taken by the panel.")

(defvar jgy/agent-manager-refresh-interval 2)

(defvar jgy/agent-manager--follow nil
  "Non-nil while the panel should reappear in every tab.")

(defvar jgy/agent-manager--timer nil)

(defvar-local jgy/agent-manager--snapshot nil
  "Last rendered content, used to skip redundant redraws.")

;;; Tab ownership

(defvar jgy/tab--id-counter 0)

(defun jgy/tab-id (&optional tab)
  "Return the stable id of TAB, assigning one when it has none."
  (let ((tab (or tab (tab-bar--current-tab-find))))
    (or (alist-get 'jgy-id (cdr tab))
        ;; 进程号入 id，desktop 恢复回来的旧 id 不会和新 id 撞车。
        (setf (alist-get 'jgy-id (cdr tab))
              (format "%d-%d" (emacs-pid)
                      (setq jgy/tab--id-counter (1+ jgy/tab--id-counter)))))))

(defvar-local jgy/agent-shell-tab-id nil
  "Id of the tab this agent shell belongs to.")

(defun jgy/agent-shell-claim-tab ()
  "Make the current tab the owner of this agent shell."
  (setq jgy/agent-shell-tab-id (jgy/tab-id)))

(add-hook 'agent-shell-mode-hook #'jgy/agent-shell-claim-tab)

(defun jgy/agent-shell-tab-index (buffer)
  "Index of the tab owning BUFFER, or nil when it has no home tab."
  (let ((id (buffer-local-value 'jgy/agent-shell-tab-id buffer)))
    (or (and id (seq-position (funcall tab-bar-tabs-function nil) id
                              (lambda (tab tab-id)
                                (equal (alist-get 'jgy-id (cdr tab)) tab-id))))
        ;; 归属丢失时退回窗口扫描，只能找到仍显示着的 buffer。
        (alist-get 'index (tab-bar-get-buffer-tab buffer)))))

(defun jgy/agent-shell--agent-window ()
  "A window of the selected tab already showing an agent shell."
  (seq-find (lambda (window)
              (and (not (window-dedicated-p window))
                   (provided-mode-derived-p
                    (buffer-local-value 'major-mode (window-buffer window))
                    'agent-shell-mode)))
            (window-list nil 'no-minibuf)))

(defun jgy/agent-shell--display-in-tab (buffer)
  "Show BUFFER in the selected tab, taking over a window rather than splitting.
The panel itself is dedicated, so it never gets picked."
  (if-let* ((window (or (jgy/agent-shell--agent-window)
                        (and (not (window-dedicated-p (selected-window)))
                             (selected-window))
                        (get-largest-window nil nil))))
      (progn (set-window-buffer window buffer)
             (select-window window))
    (when-let* ((window (display-buffer buffer agent-shell-display-action)))
      (select-window window))))

(defun jgy/agent-shell-goto-buffer (buffer)
  "Select BUFFER inside the tab that owns it."
  (unless (buffer-live-p buffer)
    (user-error "Buffer no longer exists"))
  (let ((index (jgy/agent-shell-tab-index buffer)))
    (when (and index (/= index (tab-bar--current-tab-index)))
      (tab-bar-select-tab (1+ index))))
  (if-let* ((window (get-buffer-window buffer)))
      (select-window window)
    (jgy/agent-shell--display-in-tab buffer)))

;;; Content

(defun jgy/agent-manager--groups ()
  "Agent shells grouped by owning tab, orphans last."
  (let ((tabs (funcall tab-bar-tabs-function nil))
        (groups nil)
        (orphans nil))
    (dolist (shell (agent-shell-buffers))
      (if-let* ((index (jgy/agent-shell-tab-index shell)))
          (push shell (alist-get index groups))
        (push shell orphans)))
    (append (mapcar (lambda (group)
                      (cons (alist-get 'name (nth (car group) tabs))
                            (nreverse (cdr group))))
                    (sort groups #'car-less-than-car))
            (and orphans (list (cons "orphan" (nreverse orphans)))))))

(defvar jgy/agent-manager-glyphs
  '((ready . "●") (busy . "◐") (blocked . "⚠") (starting . "○") (killed . "✗"))
  "Glyph shown for each agent status.")

(defun jgy/agent-manager--status (shell)
  "Status of SHELL: `killed', `starting', `blocked', `busy' or `ready'."
  (let* ((state (buffer-local-value 'agent-shell--state shell))
         (client (map-nested-elt state '(:client :process))))
    (cond
     ((not (and (process-live-p (get-buffer-process shell))
                (or (null (map-elt state :client)) (process-live-p client))))
      'killed)
     ((not (map-elt state :initialized)) 'starting)
     (t (agent-shell-status :shell-buffer shell)))))

(defun jgy/agent-manager--status-face (status)
  "Face for STATUS."
  (pcase status
    ('ready 'success)
    ('busy 'warning)
    ('blocked 'font-lock-keyword-face)
    ('killed 'error)
    (_ 'font-lock-comment-face)))

(defun jgy/agent-manager--kind (shell)
  "Agent name SHELL was started as, taken from its buffer name."
  (let ((name (buffer-name shell)))
    (if (string-match "\\`\\(.*?\\) Agent @ " name)
        (match-string 1 name)
      name)))

(defun jgy/agent-manager--config (shell)
  "The `agent-shell-agent-configs' entry SHELL was started from, if identifiable."
  (let ((prefix (replace-regexp-in-string " Agent @ .*\\'" "" (buffer-name shell))))
    (seq-find (lambda (config) (equal prefix (map-elt config :buffer-name)))
              agent-shell-agent-configs)))

(defun jgy/agent-manager--line (shell)
  "One-line description of SHELL."
  (let* ((status (jgy/agent-manager--status shell))
         (face (jgy/agent-manager--status-face status))
         (state (buffer-local-value 'agent-shell--state shell)))
    (concat "  "
            (propertize (format "%-2s" (alist-get status jgy/agent-manager-glyphs "?"))
                        'face face)
            (format "%-16s" (jgy/agent-manager--kind shell))
            (propertize (format "%-10s" status) 'face face)
            (format "%-12s" (or (agent-shell-get-mode-name state) "-"))
            (format "%-16s" (or (agent-shell-get-model-name state) "-"))
            (propertize (abbreviate-file-name
                         (buffer-local-value 'default-directory shell))
                        'face 'font-lock-comment-face))))

(defun jgy/agent-manager--snapshot ()
  "Groups paired with their rendered lines: list of (TAB (SHELL . LINE)...)."
  (mapcar (lambda (group)
            (cons (car group)
                  (mapcar (lambda (shell) (cons shell (jgy/agent-manager--line shell)))
                          (cdr group))))
          (jgy/agent-manager--groups)))

(defun jgy/agent-manager-refresh ()
  "Redraw the panel when its content changed."
  (interactive)
  (when-let* ((buffer (get-buffer jgy/agent-manager-buffer-name)))
    (with-current-buffer buffer
      (let ((snapshot (jgy/agent-manager--snapshot)))
        (unless (equal snapshot jgy/agent-manager--snapshot)
          (setq jgy/agent-manager--snapshot snapshot)
          (let ((inhibit-read-only t)
                (ident (when-let* ((section (magit-current-section)))
                         (magit-section-ident section))))
            (erase-buffer)
            (magit-insert-section (jgy-agents)
              (if (null snapshot)
                  (insert (propertize "No agent shells\n" 'face 'font-lock-comment-face))
                (dolist (group snapshot)
                  (magit-insert-section (jgy-agent-tab (car group))
                    (magit-insert-heading
                      (propertize (format "%s (%d)" (car group) (length (cdr group)))
                                  'face 'magit-section-heading))
                    (pcase-dolist (`(,shell . ,line) (cdr group))
                      (magit-insert-section (jgy-agent shell)
                        (insert line "\n")))))))
            (goto-char (or (when-let* ((section (and ident (magit-get-section ident))))
                             (oref section start))
                           (point-min)))))))))

;;; Actions

(defun jgy/agent-manager--shell-at-point ()
  "The agent shell on the current line."
  (let ((section (magit-current-section)))
    (unless (and section (eq (oref section type) 'jgy-agent))
      (user-error "No agent on this line"))
    (let ((shell (oref section value)))
      (unless (buffer-live-p shell)
        (user-error "Buffer no longer exists"))
      shell)))

(defmacro jgy/agent-manager--with-shell (&rest body)
  "Run BODY in the agent shell at point, then refresh the panel."
  (declare (indent 0))
  `(progn
     (with-current-buffer (jgy/agent-manager--shell-at-point) ,@body)
     (jgy/agent-manager-refresh)))

(defun jgy/agent-manager-goto ()
  "Select the agent at point inside its own tab."
  (interactive)
  (jgy/agent-shell-goto-buffer (jgy/agent-manager--shell-at-point)))

(defun jgy/agent-manager-claim ()
  "Hand the agent at point over to the current tab."
  (interactive)
  (let ((shell (jgy/agent-manager--shell-at-point)))
    (with-current-buffer shell (jgy/agent-shell-claim-tab))
    (jgy/agent-manager-refresh)
    (message "%s now belongs to tab %s" (buffer-name shell)
             (alist-get 'name (tab-bar--current-tab-find)))))

(defun jgy/agent-manager-new ()
  "Start a new agent shell in the current tab."
  (interactive)
  (agent-shell t)
  (jgy/agent-manager-refresh))

(defun jgy/agent-manager-kill ()
  "Stop the agent at point."
  (interactive)
  (let ((shell (jgy/agent-manager--shell-at-point)))
    (when (yes-or-no-p (format "Kill agent in %s? " (buffer-name shell)))
      (with-current-buffer shell
        (when (process-live-p (map-nested-elt agent-shell--state '(:client :process)))
          (comint-send-eof)))
      (run-with-timer 0.1 nil #'jgy/agent-manager-refresh))))

(defun jgy/agent-manager-delete-killed ()
  "Bury every dead agent buffer."
  (interactive)
  (let ((dead (seq-filter (lambda (shell)
                            (eq (jgy/agent-manager--status shell) 'killed))
                          (agent-shell-buffers))))
    (if (null dead)
        (message "No killed agents")
      (when (yes-or-no-p (format "Delete %d killed agent%s? "
                                 (length dead) (if (= (length dead) 1) "" "s")))
        (mapc #'kill-buffer dead)
        (jgy/agent-manager-refresh)))))

(defun jgy/agent-manager-restart ()
  "Restart the agent at point."
  (interactive)
  (let* ((shell (jgy/agent-manager--shell-at-point))
         (config (jgy/agent-manager--config shell))
         (name (buffer-name shell)))
    (when (yes-or-no-p (format "Restart %s? " name))
      (with-current-buffer shell
        (when-let* ((process (map-nested-elt agent-shell--state '(:client :process)))
                    ((process-live-p process)))
          (kill-process process)))
      (kill-buffer shell)
      (if config (agent-shell-start :config config) (agent-shell t))
      (jgy/agent-manager-refresh))))

(defun jgy/agent-manager-set-mode ()
  "Set the session mode of the agent at point."
  (interactive)
  (jgy/agent-manager--with-shell (agent-shell-set-session-mode)))

(defun jgy/agent-manager-set-model ()
  "Set the session model of the agent at point."
  (interactive)
  (jgy/agent-manager--with-shell (agent-shell-set-session-model)))

(defun jgy/agent-manager-interrupt ()
  "Interrupt the agent at point."
  (interactive)
  (jgy/agent-manager--with-shell (agent-shell-interrupt)))

(defun jgy/agent-manager-view-traffic ()
  "Show the ACP traffic log of the agent at point."
  (interactive)
  (with-current-buffer (jgy/agent-manager--shell-at-point)
    (agent-shell-view-traffic)))

(defun jgy/agent-manager-toggle-logging ()
  "Toggle ACP logging."
  (interactive)
  (agent-shell-toggle-logging)
  (jgy/agent-manager-refresh))

;;; Display

(defun jgy/agent-manager--show ()
  "Dock the panel in the selected tab and return its window."
  (let* ((horizontal (memq jgy/agent-manager-side '(left right)))
         (window (display-buffer-in-side-window
                  (jgy/agent-manager--buffer)
                  `((side . ,jgy/agent-manager-side)
                    (slot . 0)
                    (,(if horizontal 'window-width 'window-height) . ,jgy/agent-manager-size)
                    (preserve-size . ,(if horizontal '(t . nil) '(nil . t)))
                    (window-parameters . ((no-delete-other-windows . t)))))))
    (set-window-dedicated-p window t)
    (jgy/agent-manager--start-timer)
    window))

(defun jgy/agent-manager--buffer ()
  "The panel buffer, created and filled on demand."
  (let ((buffer (get-buffer-create jgy/agent-manager-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'jgy/agent-manager-mode)
        (jgy/agent-manager-mode))
      (jgy/agent-manager-refresh))
    buffer))

(defun jgy/agent-manager--follow-tab (&rest _)
  "Sync the panel's presence after a tab switch.
Tabs keep their own window configuration, so the panel has to be docked or
removed again in every tab it is switched to."
  (let ((window (get-buffer-window jgy/agent-manager-buffer-name)))
    (cond ((and jgy/agent-manager--follow (not window))
           (save-selected-window (jgy/agent-manager--show)))
          ((and (not jgy/agent-manager--follow) window)
           (delete-window window)))))

(defun jgy/agent-manager--start-timer ()
  (unless (timerp jgy/agent-manager--timer)
    (setq jgy/agent-manager--timer
          (run-with-timer jgy/agent-manager-refresh-interval
                          jgy/agent-manager-refresh-interval
                          #'jgy/agent-manager--tick))))

(defun jgy/agent-manager--tick ()
  "Refresh while the panel is on screen, otherwise stop the timer."
  (if (get-buffer-window jgy/agent-manager-buffer-name t)
      (jgy/agent-manager-refresh)
    (when (timerp jgy/agent-manager--timer)
      (cancel-timer jgy/agent-manager--timer)
      (setq jgy/agent-manager--timer nil))))

(defun jgy/agent-manager-quit ()
  "Hide the panel in every tab."
  (interactive)
  (setq jgy/agent-manager--follow nil)
  (when-let* ((window (get-buffer-window jgy/agent-manager-buffer-name)))
    (delete-window window)))

;;;###autoload
(defun jgy/agent-manager-toggle ()
  "Toggle the agent panel, which then follows every tab switch."
  (interactive)
  (if (get-buffer-window jgy/agent-manager-buffer-name)
      (jgy/agent-manager-quit)
    (setq jgy/agent-manager--follow t)
    (select-window (jgy/agent-manager--show))))

(add-hook 'tab-bar-tab-post-select-functions #'jgy/agent-manager--follow-tab)
(add-hook 'tab-bar-tab-post-open-functions #'jgy/agent-manager--follow-tab)

;;; Mode

(defvar-keymap jgy/agent-manager-mode-map
  :doc "Keymap for `jgy/agent-manager-mode'."
  :parent magit-section-mode-map
  "RET"     #'jgy/agent-manager-goto
  "g"       #'jgy/agent-manager-refresh
  "T"       #'jgy/agent-manager-claim
  "c"       #'jgy/agent-manager-new
  "k"       #'jgy/agent-manager-kill
  "d"       #'jgy/agent-manager-delete-killed
  "r"       #'jgy/agent-manager-restart
  "m"       #'jgy/agent-manager-set-mode
  "M"       #'jgy/agent-manager-set-model
  "t"       #'jgy/agent-manager-view-traffic
  "l"       #'jgy/agent-manager-toggle-logging
  "C-c C-c" #'jgy/agent-manager-interrupt
  "q"       #'jgy/agent-manager-quit)

(define-derived-mode jgy/agent-manager-mode magit-section-mode "Agents"
  "Major mode for the tab-grouped agent-shell panel."
  :interactive nil
  (setq-local jgy/agent-manager--snapshot nil))

(with-eval-after-load 'evil
  (evil-set-initial-state 'jgy/agent-manager-mode 'normal)
  (evil-define-key* 'normal jgy/agent-manager-mode-map
    (kbd "RET") #'jgy/agent-manager-goto
    (kbd "TAB") #'magit-section-toggle
    ;; evil-collection 把 C-j/C-k 接管成 magit-section 翻页，这里放行回全局的窗口切换。
    (kbd "C-j") nil
    (kbd "C-k") nil
    "gr" #'jgy/agent-manager-refresh
    "T"  #'jgy/agent-manager-claim
    "c"  #'jgy/agent-manager-new
    "K"  #'jgy/agent-manager-kill
    "d"  #'jgy/agent-manager-delete-killed
    "r"  #'jgy/agent-manager-restart
    "m"  #'jgy/agent-manager-set-mode
    "M"  #'jgy/agent-manager-set-model
    "t"  #'jgy/agent-manager-view-traffic
    "L"  #'jgy/agent-manager-toggle-logging
    (kbd "C-c C-c") #'jgy/agent-manager-interrupt
    "q"  #'jgy/agent-manager-quit))

(provide 'jgy-agent-manager)
;;; jgy-agent-manager.el ends here
