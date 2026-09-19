;;; agent-shell-lens.el --- Tab-aware status and panel for agent-shell -*- lexical-binding: t; -*-

;;; Commentary:
;; 在 tab 名称后显示其中 agent-shell 会话的状态图标，并按所属 tab 把会话折成一棵树。
;; 面板跟着 tab 走，RET 切到 agent 所在的 tab 再显示它。状态只读 agent-shell 自身的 API。
;;
;; init.el 在 agent-shell 加载后 require 本文件：tab 归属必须在 shell 创建的那一刻
;; 就记下来，晚于此就丢了。

;;; Code:

(require 'agent-shell)
(require 'map)
(require 'tab-bar)
(require 'magit-section)

(defvar agent-shell-lens-buffer-name "*Agent Shell Lens*")

(defvar agent-shell-lens-side 'bottom
  "Frame side the panel is docked to: `left', `right', `top' or `bottom'.")

(defvar agent-shell-lens-size 0.3
  "Fraction of the frame taken by the panel.")

(defvar agent-shell-lens-refresh-interval 2)

(defvar agent-shell-lens--follow nil
  "Non-nil while the panel should reappear in every tab.")

(defvar agent-shell-lens--timer nil)

(defvar agent-shell-lens--tab-status-snapshot nil
  "Agent ownership and status at the last tab-bar refresh.")

(defvar-local agent-shell-lens--snapshot nil
  "Last rendered content, used to skip redundant redraws.")

;;; Tab ownership

(defvar agent-shell-lens--tab-id-counter 0)

(defun agent-shell-lens--tab-id (&optional tab)
  "Return the stable id of TAB, assigning one when it has none."
  (let ((tab (or tab (tab-bar--current-tab-find))))
    (or (alist-get 'agent-shell-lens-id (cdr tab))
        ;; 进程号入 id，desktop 恢复回来的旧 id 不会和新 id 撞车。
        (setf (alist-get 'agent-shell-lens-id (cdr tab))
              (format "%d-%d" (emacs-pid)
                      (setq agent-shell-lens--tab-id-counter (1+ agent-shell-lens--tab-id-counter)))))))

(defvar-local agent-shell-lens-tab-id nil
  "Id of the tab this agent shell belongs to.")

(defun agent-shell-lens-claim-tab ()
  "Make the current tab the owner of this agent shell."
  (setq agent-shell-lens-tab-id (agent-shell-lens--tab-id))
  (agent-shell-lens--start-timer)
  (agent-shell-lens--refresh-tab-bar t))

(add-hook 'agent-shell-mode-hook #'agent-shell-lens-claim-tab)

(defun agent-shell-lens-tab-index (buffer)
  "Index of the tab owning BUFFER, or nil when it has no home tab."
  (let ((id (buffer-local-value 'agent-shell-lens-tab-id buffer)))
    (or (and id (seq-position (funcall tab-bar-tabs-function nil) id
                              (lambda (tab tab-id)
                                (equal (alist-get 'agent-shell-lens-id (cdr tab)) tab-id))))
        ;; 归属丢失时退回窗口扫描，只能找到仍显示着的 buffer。
        (alist-get 'index (tab-bar-get-buffer-tab buffer)))))

(defun agent-shell-lens--agent-window ()
  "A window of the selected tab already showing an agent shell."
  (seq-find (lambda (window)
              (and (not (window-dedicated-p window))
                   (provided-mode-derived-p
                    (buffer-local-value 'major-mode (window-buffer window))
                    'agent-shell-mode)))
            (window-list nil 'no-minibuf)))

(defun agent-shell-lens--display-in-tab (buffer)
  "Show BUFFER in the selected tab, taking over a window rather than splitting.
The panel itself is dedicated, so it never gets picked."
  (if-let* ((window (or (agent-shell-lens--agent-window)
                        (and (not (window-dedicated-p (selected-window)))
                             (selected-window))
                        (get-largest-window nil nil))))
      (progn (set-window-buffer window buffer)
             (select-window window))
    (when-let* ((window (display-buffer buffer agent-shell-display-action)))
      (select-window window))))

(defun agent-shell-lens-goto-buffer (buffer)
  "Select BUFFER inside the tab that owns it."
  (unless (buffer-live-p buffer)
    (user-error "Buffer no longer exists"))
  (let ((index (agent-shell-lens-tab-index buffer)))
    (when (and index (/= index (tab-bar--current-tab-index)))
      (tab-bar-select-tab (1+ index))))
  (if-let* ((window (get-buffer-window buffer)))
      (select-window window)
    (agent-shell-lens--display-in-tab buffer)))

;;; Content

(defun agent-shell-lens--groups ()
  "Agent shells grouped by owning tab, orphans last."
  (let ((tabs (funcall tab-bar-tabs-function nil))
        (groups nil)
        (orphans nil))
    (dolist (shell (agent-shell-buffers))
      (if-let* ((index (agent-shell-lens-tab-index shell)))
          (push shell (alist-get index groups))
        (push shell orphans)))
    (append (mapcar (lambda (group)
                      (cons (alist-get 'name (nth (car group) tabs))
                            (nreverse (cdr group))))
                    (sort groups #'car-less-than-car))
            (and orphans (list (cons "orphan" (nreverse orphans)))))))

(defvar agent-shell-lens-glyphs
  '((ready . "●") (busy . "◐") (blocked . "⚠") (starting . "○") (killed . "✗"))
  "Glyph shown for each agent status.")

(defun agent-shell-lens--status (shell)
  "Status of SHELL: `killed', `starting', `blocked', `busy' or `ready'."
  (let* ((state (buffer-local-value 'agent-shell--state shell))
         (client (map-nested-elt state '(:client :process))))
    (cond
     ((not (and (process-live-p (get-buffer-process shell))
                (or (null (map-elt state :client)) (process-live-p client))))
      'killed)
     ((not (map-elt state :initialized)) 'starting)
     (t (agent-shell-status :shell-buffer shell)))))

(defun agent-shell-lens--status-face (status)
  "Face for STATUS."
  (pcase status
    ('ready 'success)
    ('busy 'warning)
    ('blocked 'font-lock-keyword-face)
    ('killed 'error)
    (_ 'font-lock-comment-face)))

(defun agent-shell-lens--tab-shells (tab)
  "Return agent shells owned by TAB."
  (when-let* ((id (alist-get 'agent-shell-lens-id (cdr tab))))
    (seq-filter
     (lambda (shell)
       (equal id (buffer-local-value 'agent-shell-lens-tab-id shell)))
     (agent-shell-buffers))))

(defun agent-shell-lens-tab-name-format-status (name tab _index)
  "Prepend status icons for the agent shells in TAB to tab NAME."
  (if-let* ((shells (agent-shell-lens--tab-shells tab)))
      (concat
       (mapconcat
        (lambda (shell)
          (let ((status (agent-shell-lens--status shell)))
            (propertize (alist-get status agent-shell-lens-glyphs "?")
                        'face (agent-shell-lens--status-face status)
                        'help-echo (format "%s: %s"
                                           (agent-shell-lens--kind shell) status)
                        'rear-nonsticky t)))
        shells " ")
       " " name)
    name))

(defun agent-shell-lens--install-tab-name-formatter ()
  "Install the agent status formatter before the tab close button."
  (let* ((formatter #'agent-shell-lens-tab-name-format-status)
         (formatters (delq formatter
                           (copy-sequence tab-bar-tab-name-format-functions)))
         (close-index
          (seq-position formatters 'tab-bar-tab-name-format-close-button)))
    (setq tab-bar-tab-name-format-functions
          (if close-index
              (append (seq-take formatters close-index)
                      (list formatter)
                      (nthcdr close-index formatters))
            (append formatters (list formatter))))))

(defun agent-shell-lens--tab-status-snapshot ()
  "Return current shell ownership and status for tab-bar invalidation."
  (mapcar (lambda (shell)
            (list shell
                  (buffer-local-value 'agent-shell-lens-tab-id shell)
                  (agent-shell-lens--status shell)))
          (agent-shell-buffers)))

(defvar agent-shell-lens-notify-statuses '(ready blocked)
  "Statuses that trigger a desktop notification when an agent enters them.")

(defvar agent-shell-lens--last-statuses nil
  "Alist of (SHELL . STATUS), used to detect status transitions to notify on.")

(defun agent-shell-lens-notify (shell status)
  "Show a desktop notification that SHELL's agent reached STATUS."
  (let ((title (format "%s Agent" (agent-shell-lens--kind shell)))
        (body (format "%s: %s" (buffer-name shell) status)))
    (cond
     ((executable-find "terminal-notifier")
      (call-process "terminal-notifier" nil 0 nil
                    "-title" title "-message" body))
     ((executable-find "osascript")
      (call-process "osascript" nil 0 nil "-e"
                    (format "display notification %s with title %s"
                            (prin1-to-string body) (prin1-to-string title))))
     (t (message "%s: %s" title body)))))

(defvar agent-shell-lens-notify-function #'agent-shell-lens-notify
  "Function called with (SHELL STATUS) when an agent enters a notifiable status.")

(defun agent-shell-lens--notify-transitions (snapshot)
  "Notify for shells in SNAPSHOT whose status just entered a notifiable one."
  (pcase-dolist (`(,shell ,_tab-id ,status) snapshot)
    (let ((last (alist-get shell agent-shell-lens--last-statuses)))
      (when (and last (not (eq last status))
                 (memq status agent-shell-lens-notify-statuses))
        (funcall agent-shell-lens-notify-function shell status))))
  (setq agent-shell-lens--last-statuses
        (mapcar (pcase-lambda (`(,shell ,_tab-id ,status)) (cons shell status))
                snapshot)))

(defun agent-shell-lens--refresh-tab-bar (&optional force)
  "Refresh tab status icons when their state changed, or always when FORCE."
  (let ((snapshot (agent-shell-lens--tab-status-snapshot)))
    (agent-shell-lens--notify-transitions snapshot)
    (when (or force (not (equal snapshot agent-shell-lens--tab-status-snapshot)))
      (setq agent-shell-lens--tab-status-snapshot snapshot)
      (force-mode-line-update t))))

(defun agent-shell-lens--kind (shell)
  "Agent name SHELL was started as, taken from its buffer name."
  (let ((name (buffer-name shell)))
    (if (string-match "\\`\\(.*?\\) Agent @ " name)
        (match-string 1 name)
      name)))

(defun agent-shell-lens--config (shell)
  "The `agent-shell-agent-configs' entry SHELL was started from, if identifiable."
  (let ((prefix (replace-regexp-in-string " Agent @ .*\\'" "" (buffer-name shell))))
    (seq-find (lambda (config) (equal prefix (map-elt config :buffer-name)))
              agent-shell-agent-configs)))

(defun agent-shell-lens--line (shell)
  "One-line description of SHELL."
  (let* ((status (agent-shell-lens--status shell))
         (face (agent-shell-lens--status-face status))
         (state (buffer-local-value 'agent-shell--state shell)))
    (concat "  "
            (propertize (format "%-2s" (alist-get status agent-shell-lens-glyphs "?"))
                        'face face)
            (format "%-16s" (agent-shell-lens--kind shell))
            (propertize (format "%-10s" status) 'face face)
            (format "%-12s" (or (agent-shell-get-mode-name state) "-"))
            (format "%-16s" (or (agent-shell-get-model-name state) "-"))
            (propertize (abbreviate-file-name
                         (buffer-local-value 'default-directory shell))
                        'face 'font-lock-comment-face))))

(defun agent-shell-lens--snapshot ()
  "Groups paired with their rendered lines: list of (TAB (SHELL . LINE)...)."
  (mapcar (lambda (group)
            (cons (car group)
                  (mapcar (lambda (shell) (cons shell (agent-shell-lens--line shell)))
                          (cdr group))))
          (agent-shell-lens--groups)))

(defun agent-shell-lens-refresh ()
  "Refresh tab status icons and redraw the panel when its content changed."
  (interactive)
  (agent-shell-lens--refresh-tab-bar)
  (when-let* ((buffer (get-buffer agent-shell-lens-buffer-name)))
    (with-current-buffer buffer
      (let ((snapshot (agent-shell-lens--snapshot)))
        (unless (equal snapshot agent-shell-lens--snapshot)
          (setq agent-shell-lens--snapshot snapshot)
          (let ((inhibit-read-only t)
                (ident (when-let* ((section (magit-current-section)))
                         (magit-section-ident section))))
            (erase-buffer)
            (magit-insert-section (agent-shell-lens-root)
              (if (null snapshot)
                  (insert (propertize "No agent shells\n" 'face 'font-lock-comment-face))
                (dolist (group snapshot)
                  (magit-insert-section (agent-shell-lens-tab (car group))
                    (magit-insert-heading
                      (propertize (format "%s (%d)" (car group) (length (cdr group)))
                                  'face 'magit-section-heading))
                    (pcase-dolist (`(,shell . ,line) (cdr group))
                      (magit-insert-section (agent-shell-lens-agent shell)
                        (insert line "\n")))))))
            (goto-char (or (when-let* ((section (and ident (magit-get-section ident))))
                             (oref section start))
                           (point-min)))))))))

;;; Actions

(defun agent-shell-lens--shell-at-point ()
  "The agent shell on the current line."
  (let ((section (magit-current-section)))
    (unless (and section (eq (oref section type) 'agent-shell-lens-agent))
      (user-error "No agent on this line"))
    (let ((shell (oref section value)))
      (unless (buffer-live-p shell)
        (user-error "Buffer no longer exists"))
      shell)))

(defmacro agent-shell-lens--with-shell (&rest body)
  "Run BODY in the agent shell at point, then refresh the panel."
  (declare (indent 0))
  `(progn
     (with-current-buffer (agent-shell-lens--shell-at-point) ,@body)
     (agent-shell-lens-refresh)))

(defun agent-shell-lens-goto ()
  "Select the agent at point inside its own tab."
  (interactive)
  (agent-shell-lens-goto-buffer (agent-shell-lens--shell-at-point)))

(defun agent-shell-lens-claim ()
  "Hand the agent at point over to the current tab."
  (interactive)
  (let ((shell (agent-shell-lens--shell-at-point)))
    (with-current-buffer shell (agent-shell-lens-claim-tab))
    (agent-shell-lens-refresh)
    (message "%s now belongs to tab %s" (buffer-name shell)
             (alist-get 'name (tab-bar--current-tab-find)))))

(defun agent-shell-lens-new ()
  "Start a new agent shell in the current tab."
  (interactive)
  (agent-shell t)
  (agent-shell-lens-refresh))

(defun agent-shell-lens-kill ()
  "Stop the agent at point."
  (interactive)
  (let ((shell (agent-shell-lens--shell-at-point)))
    (when (yes-or-no-p (format "Kill agent in %s? " (buffer-name shell)))
      (with-current-buffer shell
        (when (process-live-p (map-nested-elt agent-shell--state '(:client :process)))
          (comint-send-eof)))
      (run-with-timer 0.1 nil #'agent-shell-lens-refresh))))

(defun agent-shell-lens-delete-killed ()
  "Bury every dead agent buffer."
  (interactive)
  (let ((dead (seq-filter (lambda (shell)
                            (eq (agent-shell-lens--status shell) 'killed))
                          (agent-shell-buffers))))
    (if (null dead)
        (message "No killed agents")
      (when (yes-or-no-p (format "Delete %d killed agent%s? "
                                 (length dead) (if (= (length dead) 1) "" "s")))
        (mapc #'kill-buffer dead)
        (agent-shell-lens-refresh)))))

(defun agent-shell-lens-restart ()
  "Restart the agent at point."
  (interactive)
  (let* ((shell (agent-shell-lens--shell-at-point))
         (config (agent-shell-lens--config shell))
         (name (buffer-name shell)))
    (when (yes-or-no-p (format "Restart %s? " name))
      (with-current-buffer shell
        (when-let* ((process (map-nested-elt agent-shell--state '(:client :process)))
                    ((process-live-p process)))
          (kill-process process)))
      (kill-buffer shell)
      (if config (agent-shell-start :config config) (agent-shell t))
      (agent-shell-lens-refresh))))

(defun agent-shell-lens-set-mode ()
  "Set the session mode of the agent at point."
  (interactive)
  (agent-shell-lens--with-shell (agent-shell-set-session-mode)))

(defun agent-shell-lens-set-model ()
  "Set the session model of the agent at point."
  (interactive)
  (agent-shell-lens--with-shell (agent-shell-set-session-model)))

(defun agent-shell-lens-interrupt ()
  "Interrupt the agent at point."
  (interactive)
  (agent-shell-lens--with-shell (agent-shell-interrupt)))

(defun agent-shell-lens-view-traffic ()
  "Show the ACP traffic log of the agent at point."
  (interactive)
  (with-current-buffer (agent-shell-lens--shell-at-point)
    (agent-shell-view-traffic)))

(defun agent-shell-lens-toggle-logging ()
  "Toggle ACP logging."
  (interactive)
  (agent-shell-toggle-logging)
  (agent-shell-lens-refresh))

;;; Display

(defun agent-shell-lens--show ()
  "Dock the panel in the selected tab and return its window."
  (let* ((horizontal (memq agent-shell-lens-side '(left right)))
         (window (display-buffer-in-side-window
                  (agent-shell-lens--buffer)
                  `((side . ,agent-shell-lens-side)
                    (slot . 0)
                    (,(if horizontal 'window-width 'window-height) . ,agent-shell-lens-size)
                    (preserve-size . ,(if horizontal '(t . nil) '(nil . t)))
                    (window-parameters . ((no-delete-other-windows . t)))))))
    (set-window-dedicated-p window t)
    (agent-shell-lens--start-timer)
    window))

(defun agent-shell-lens--buffer ()
  "The panel buffer, created and filled on demand."
  (let ((buffer (get-buffer-create agent-shell-lens-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-shell-lens-mode)
        (agent-shell-lens-mode))
      (agent-shell-lens-refresh))
    buffer))

(defun agent-shell-lens--follow-tab (&rest _)
  "Sync the panel's presence after a tab switch.
Tabs keep their own window configuration, so the panel has to be docked or
removed again in every tab it is switched to."
  (let ((window (get-buffer-window agent-shell-lens-buffer-name)))
    (cond ((and agent-shell-lens--follow (not window))
           (save-selected-window (agent-shell-lens--show)))
          ((and (not agent-shell-lens--follow) window)
           (delete-window window)))))

(defun agent-shell-lens--start-timer ()
  (unless (timerp agent-shell-lens--timer)
    (setq agent-shell-lens--timer
          (run-with-timer agent-shell-lens-refresh-interval
                          agent-shell-lens-refresh-interval
                          #'agent-shell-lens--tick))))

(defun agent-shell-lens--tick ()
  "Refresh agent statuses and stop when no shell or panel remains."
  (let ((shells (agent-shell-buffers))
        (panel-visible (get-buffer-window agent-shell-lens-buffer-name t)))
    (agent-shell-lens--refresh-tab-bar)
    (when panel-visible
      (agent-shell-lens-refresh))
    (unless (or shells panel-visible)
      (when (timerp agent-shell-lens--timer)
        (cancel-timer agent-shell-lens--timer)
        (setq agent-shell-lens--timer nil)))))

(defun agent-shell-lens-quit ()
  "Hide the panel in every tab."
  (interactive)
  (setq agent-shell-lens--follow nil)
  (when-let* ((window (get-buffer-window agent-shell-lens-buffer-name)))
    (delete-window window)))

;;;###autoload
(defun agent-shell-lens-toggle ()
  "Toggle the agent panel, which then follows every tab switch."
  (interactive)
  (if (get-buffer-window agent-shell-lens-buffer-name)
      (agent-shell-lens-quit)
    (setq agent-shell-lens--follow t)
    (select-window (agent-shell-lens--show))))

(agent-shell-lens--install-tab-name-formatter)
(add-hook 'tab-bar-tab-post-select-functions #'agent-shell-lens--follow-tab)
(add-hook 'tab-bar-tab-post-open-functions #'agent-shell-lens--follow-tab)

;;; Mode

(defvar-keymap agent-shell-lens-mode-map
  :doc "Keymap for `agent-shell-lens-mode'."
  :parent magit-section-mode-map
  "RET"     #'agent-shell-lens-goto
  "g"       #'agent-shell-lens-refresh
  "T"       #'agent-shell-lens-claim
  "c"       #'agent-shell-lens-new
  "k"       #'agent-shell-lens-kill
  "d"       #'agent-shell-lens-delete-killed
  "r"       #'agent-shell-lens-restart
  "m"       #'agent-shell-lens-set-mode
  "M"       #'agent-shell-lens-set-model
  "t"       #'agent-shell-lens-view-traffic
  "l"       #'agent-shell-lens-toggle-logging
  "C-c C-c" #'agent-shell-lens-interrupt
  "q"       #'agent-shell-lens-quit)

(define-derived-mode agent-shell-lens-mode magit-section-mode "Agents"
  "Major mode for the tab-grouped agent-shell panel."
  :interactive nil
  (setq-local agent-shell-lens--snapshot nil))

(with-eval-after-load 'evil
  (evil-set-initial-state 'agent-shell-lens-mode 'normal)
  (evil-define-key* 'normal agent-shell-lens-mode-map
    (kbd "RET") #'agent-shell-lens-goto
    (kbd "TAB") #'magit-section-toggle
    ;; evil-collection 把 C-j/C-k 接管成 magit-section 翻页，这里放行回全局的窗口切换。
    (kbd "C-j") nil
    (kbd "C-k") nil
    "gr" #'agent-shell-lens-refresh
    "T"  #'agent-shell-lens-claim
    "c"  #'agent-shell-lens-new
    "K"  #'agent-shell-lens-kill
    "d"  #'agent-shell-lens-delete-killed
    "r"  #'agent-shell-lens-restart
    "m"  #'agent-shell-lens-set-mode
    "M"  #'agent-shell-lens-set-model
    "t"  #'agent-shell-lens-view-traffic
    "L"  #'agent-shell-lens-toggle-logging
    (kbd "C-c C-c") #'agent-shell-lens-interrupt
    "q"  #'agent-shell-lens-quit))

(provide 'agent-shell-lens)
;;; agent-shell-lens.el ends here
