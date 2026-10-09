;;; jgy-agent-shell.el --- Run agents.el's agents through agent-shell -*- lexical-binding: t; -*-

;;; Commentary:
;; 用 agent-shell（ACP）代替 Ghostel 里的 CLI；tab 归属、看板和快捷键由 agents.el 负责。
;; 套餐用量取自 claude-agent-acp 在 usage_update 的 _meta 里转发的 rate limit，
;; 按 bin/claude-statusline 的格式写进 `agents-usage-file'。
;; 本轮文件变化以开始时的 Git commit 与已有未提交内容为基准，缓存 diff 交给看板。
;; identity 的 `brief' 依次取等待批准的工具调用、plan 里进行中的一项、最近一次工具调用。
;; 工具调用结束后按内容检测变化，提交不会清空本轮 diff。

;;; Code:

(require 'acp)
(require 'cl-lib)
(require 'agent-shell)
(require 'agents)
(require 'map)
(require 'jgy-agent-diff)
(add-hook 'jgy-agent-diff-update-hook #'agents-dashboard-refresh)

(defvar no-littering-var-directory)

(defconst jgy/agent-shell-configs
  '(("claude" . agent-shell-anthropic-make-claude-code-config)
    ("codex" . agent-shell-openai-make-codex-config)
    ("pi" . agent-shell-pi-make-agent-config))
  "Agent name to the function making its agent-shell config.")

(defun jgy/agent-shell-dot-subdir (subdir)
  "Return SUBDIR of this project's agent-shell data, kept out of the repository."
  (expand-file-name
   subdir
   (expand-file-name (file-name-nondirectory (directory-file-name (agent-shell-cwd)))
                     (expand-file-name "agent-shell"
                                       (or (bound-and-true-p no-littering-var-directory)
                                           user-emacs-directory)))))

(defvar-local jgy/agent-shell--edited-files nil
  "Files reported by editing tools this turn, without filesystem scans.")

(defun jgy/agent-shell--files ()
  "Return scanned changes plus files reported directly by editing tools."
  (append jgy-agent-diff--files
          (cl-remove-if
           (lambda (entry)
             (assoc (alist-get 'file entry)
                    (mapcar (lambda (file) (cons (alist-get 'file file) t))
                            jgy-agent-diff--files)))
           jgy/agent-shell--edited-files)))

(defun jgy/agent-shell--track-files (tool)
  "Remember explicit edits from TOOL without Git, file reads or copies."
  (let* ((diffs (map-elt tool :diffs))
         (editing (or diffs (member (map-elt tool :kind) '("edit" "delete" "move"))))
         (root (alist-get 'root agents-identity))
         (active (not (member (map-elt tool :status) '("completed" "failed"))))
         hints)
    (when (and editing root)
      (dolist (diff (append diffs nil))
        (when-let* ((path (map-elt diff :file)))
          (push (cons path (map-elt diff :line)) hints)))
      (dolist (location (append (map-elt tool :locations) nil))
        (when-let* ((path (map-elt location 'path)))
          (push (cons path (map-elt location 'line)) hints)))
      (dolist (hint hints)
        (let* ((path (expand-file-name (car hint) root))
               (entry (seq-find (lambda (file) (equal (alist-get 'file file) path))
                                jgy/agent-shell--edited-files)))
          (unless entry
            (setq entry `((file . ,path) (directory . ,root) (added . 0) (removed . 0)
                          (active . nil) (line . nil)))
            (setq jgy/agent-shell--edited-files
                  (append jgy/agent-shell--edited-files (list entry))))
          (setf (alist-get 'active entry) active)
          (when (cdr hint) (setf (alist-get 'line entry) (cdr hint)))))
      (when hints (agents-dashboard-refresh)))))

(defvar-local jgy/agent-shell--asking nil
  "Title of the tool call waiting for permission, or nil.")

(defvar-local jgy/agent-shell--plan-step nil
  "This turn's plan entry in progress, or nil.")

(defvar-local jgy/agent-shell--last-tool nil
  "Title of this turn's latest tool call, or nil.")

(defun jgy/agent-shell--set-brief (var value)
  "Set brief source VAR to VALUE, re-rendering the dashboard when it changes."
  (unless (equal (symbol-value var) value)
    (set var value)
    (agents-dashboard-refresh)))

(defun jgy/agent-shell--brief ()
  "What the agent is doing, for the `brief' identity of agents.el."
  (if jgy/agent-shell--asking
      (concat "? " jgy/agent-shell--asking)
    (or jgy/agent-shell--plan-step jgy/agent-shell--last-tool)))

(defun jgy/agent-shell--track-plan (notification)
  "Remember the plan entry in progress carried by NOTIFICATION."
  (when (equal (map-nested-elt notification '(params update sessionUpdate)) "plan")
    (let ((entries (map-nested-elt notification '(params update entries))))
      (jgy/agent-shell--set-brief
       'jgy/agent-shell--plan-step
       (when-let* (((sequencep entries))
                   (entry (seq-find (lambda (entry)
                                      (equal (map-elt entry 'status) "in_progress"))
                                    entries)))
         (or (map-elt entry 'content) (map-elt entry 'step)))))))

(defun jgy/agent-shell--tool-title (data)
  "What the tool call in event DATA does, or nil when it does not say.
Prefers its description, as the title of a shell command is the command."
  (seq-find (lambda (text) (and (stringp text) (not (string-empty-p text))))
            (list (map-nested-elt data '(:tool-call :description))
                  (map-nested-elt data '(:tool-call :title)))))

(defun jgy/agent-shell--follow-diff (enabled)
  "Start tracking at enable time, or cancel all work when ENABLED is nil."
  (if enabled
      (jgy-agent-diff-begin (alist-get 'root agents-identity))
    (jgy-agent-diff-cancel)
    (setq jgy-agent-diff--repos nil
          jgy-agent-diff--seen nil
          jgy-agent-diff--finished t)))

(defun jgy/agent-shell--on-event (event)
  "Report agent-shell EVENT to `agents-report'; track this turn's edits and brief."
  (pcase (map-elt event :event)
    ('input-submitted
     (setq jgy/agent-shell--asking nil
           jgy/agent-shell--plan-step nil
           jgy/agent-shell--last-tool nil)
     (jgy/agent-shell--follow-diff agents--diff-follow)
     (setq jgy-agent-diff--files nil
           jgy/agent-shell--edited-files nil)
     (when agents--diff-follow
       (setq agents--diff-follow (plist-put agents--diff-follow :files nil)))
     (when-let* ((diff (get-buffer (agents--diff-buffer-name (current-buffer)))))
       (with-current-buffer diff
         (setq header-line-format "Previous turn · waiting for changes")))
     (agents-dashboard-refresh))
    ('tool-call-update
     (jgy/agent-shell--track-files (map-nested-elt event '(:data :tool-call)))
     (when agents--diff-follow
       (jgy-agent-diff-tool (map-nested-elt event '(:data :tool-call-id))
                            (map-nested-elt event '(:data :tool-call))))
     (when-let* ((title (jgy/agent-shell--tool-title (map-elt event :data))))
       (jgy/agent-shell--set-brief 'jgy/agent-shell--last-tool title)))
    ((or 'turn-complete 'error)
     (dolist (file jgy/agent-shell--edited-files)
       (setf (alist-get 'active file) nil))
     (when agents--diff-follow (jgy-agent-diff-request nil nil t)))
    ('clean-up (jgy-agent-diff-cancel))
    ('permission-request
     (jgy/agent-shell--set-brief 'jgy/agent-shell--asking
                                 (or (jgy/agent-shell--tool-title (map-elt event :data))
                                     "permission")))
    ('permission-response
     (jgy/agent-shell--set-brief 'jgy/agent-shell--asking nil)))
  (pcase (map-elt event :event)
    ((or 'input-submitted 'permission-response 'tool-call-update 'agent-message-chunk)
     (agents-report 'working))
    ('permission-request (agents-report 'attention))
    ((or 'turn-complete 'error) (agents-report 'finished))))

(defun jgy/agent-shell--context ()
  "Return the context window percentage in use from the shell's usage state."
  (let* ((usage (map-elt agent-shell--state :usage))
         (used (map-elt usage :context-used))
         (size (map-elt usage :context-size)))
    (when (and used size (> size 0))
      (round (* 100.0 used) size))))

(defun jgy/agent-shell--save-usage (notification)
  "Write the plan usage windows carried by NOTIFICATION to `agents-usage-file'."
  (when-let* ((windows (map-nested-elt notification
                                       '(params update _meta _claude/rateLimit unifiedWindows))))
    (let ((usage (mapcar (pcase-lambda (`(,key . ,window))
                           `(,key (used_percentage . ,(round (* 100 (or (map-elt window 'utilization) 0))))
                                  (resets_at . ,(map-elt window 'resetsAt))))
                         windows))
          (temp (make-temp-file (expand-file-name "claude-usage"
                                                  (file-name-directory agents-usage-file)))))
      (with-temp-file temp (insert (json-encode usage)))
      (rename-file temp agents-usage-file t))))

(defun jgy/agent-shell--insert (text)
  "Insert TEXT at this shell's prompt without submitting it."
  (agent-shell-insert :text text :shell-buffer (current-buffer) :no-focus t))

(defun jgy/agent-shell-start (name root)
  "Start agent NAME in ROOT with agent-shell and return its buffer."
  (let* ((make-config (or (alist-get name jgy/agent-shell-configs nil nil #'equal)
                          (user-error "No agent-shell config for %s" name)))
         (default-directory root)
         (agent-shell-cwd-function (lambda () root))
         (buffer (agent-shell--start :config (funcall make-config)
                                     :no-focus t :new-session t)))
    (with-current-buffer buffer
      (setq agents-identity `((kind . agent) (agent . ,name) (root . ,root)
                              (insert . jgy/agent-shell--insert)
                              (context . jgy/agent-shell--context)
                              (files . jgy/agent-shell--files)
                              (follow-diff . jgy/agent-shell--follow-diff)
                              (brief . jgy/agent-shell--brief)))
      (agent-shell-subscribe-to :shell-buffer buffer :on-event #'jgy/agent-shell--on-event)
      (acp-subscribe-to-notifications :client (map-elt agent-shell--state :client)
                                      :buffer buffer
                                      :on-notification #'jgy/agent-shell--save-usage)
      (acp-subscribe-to-notifications :client (map-elt agent-shell--state :client)
                                      :buffer buffer
                                      :on-notification #'jgy/agent-shell--track-plan))
    buffer))

(provide 'jgy-agent-shell)
;;; jgy-agent-shell.el ends here
