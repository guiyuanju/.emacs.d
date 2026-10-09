;;; jgy-agent-shell.el --- Run agents.el's agents through agent-shell -*- lexical-binding: t; -*-

;;; Commentary:
;; 用 agent-shell（ACP）代替 Ghostel 里的 CLI；tab 归属、看板和快捷键由 agents.el 负责。
;; 套餐用量取自 claude-agent-acp 在 usage_update 的 _meta 里转发的 rate limit，
;; 按 bin/claude-statusline 的格式写进 `agents-usage-file'。
;; 本轮写盘的工具调用经 identity 的 `files' 交给看板，行数由 oldText/newText 算出。
;; identity 的 `brief' 依次取等待批准的工具调用、plan 里进行中的一项、最近一次工具调用。
;; shell 命令改的文件不经编辑工具：每条命令跑完对比项目里 git 仓库的改动，新变的文件也交给看板。

;;; Code:

(require 'acp)
(require 'cl-lib)
(require 'agent-shell)
(require 'agents)
(require 'map)

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

(defconst jgy/agent-shell--edit-kinds '("edit" "delete" "move")
  "Tool call kinds that write to disk.")

(defvar-local jgy/agent-shell--edits nil
  "This turn's tool calls writing to disk, newest first, as (ID . TOOL-CALL).")

(defvar-local jgy/agent-shell--changes-cache nil
  "Changes of this turn's completed tool calls, keyed by tool call id.")

(defun jgy/agent-shell--track-edit (data)
  "Remember the tool call in DATA when it writes to disk."
  (let ((id (map-elt data :tool-call-id))
        (call (map-elt data :tool-call)))
    (when (member (map-elt call :kind) jgy/agent-shell--edit-kinds)
      (setf (alist-get id jgy/agent-shell--edits nil nil #'equal) call)
      (jgy/agent-shell--cached-changes id call)
      (agents-dashboard-refresh))))

(defun jgy/agent-shell--lines (text)
  (unless (or (null text) (string-empty-p text))
    (split-string (string-remove-suffix "\n" text) "\n")))

(defun jgy/agent-shell--line-counts (old new)
  "Return (ADDED REMOVED SKIPPED) between OLD and NEW text.
Counts the lines left after dropping those both share at the start and end;
SKIPPED is how many were dropped at the start."
  (let ((old (jgy/agent-shell--lines old))
        (new (jgy/agent-shell--lines new))
        (skipped 0))
    (while (and old new (equal (car old) (car new)))
      (pop old)
      (pop new)
      (cl-incf skipped))
    (setq old (nreverse old)
          new (nreverse new))
    (while (and old new (equal (car old) (car new)))
      (pop old)
      (pop new))
    (list (length new) (length old) skipped)))

(defun jgy/agent-shell--change-line (file new skipped)
  "Line of FILE where the change begins: NEW's place in it, SKIPPED lines on.
NEW may be the whole file or a fragment; nil when FILE no longer contains it."
  (when (and new (not (string-empty-p new)) (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (when (search-forward new nil t)
        (+ (line-number-at-pos (match-beginning 0)) skipped)))))

(defun jgy/agent-shell--changes (call)
  "List of (PATH ADDED REMOVED LINE) for each file tool CALL writes."
  (or (mapcar (lambda (diff)
                (pcase-let ((`(,added ,removed ,skipped)
                             (jgy/agent-shell--line-counts (map-elt diff :old)
                                                           (map-elt diff :new))))
                  (list (map-elt diff :file) added removed
                        (or (and (equal (map-elt call :status) "completed")
                                 (jgy/agent-shell--change-line
                                  (map-elt diff :file) (map-elt diff :new) skipped))
                            (map-elt diff :line)))))
              (map-elt call :diffs))
      (mapcar (lambda (location)
                (list (map-elt location 'path) 0 0 (map-elt location 'line)))
              (map-elt call :locations))))

(defun jgy/agent-shell--cached-changes (id call)
  "`jgy/agent-shell--changes' of CALL, remembered under ID.
Recomputed when CALL's status, diffs or locations change, as comparing
whole files on each dashboard render adds up; never once it completed,
as the file is read only then and later edits would move the text it looks for."
  (let ((key (list (map-elt call :status) (map-elt call :diffs) (map-elt call :locations)))
        (cached (alist-get id jgy/agent-shell--changes-cache nil nil #'equal)))
    (if (and cached (or (equal (caar cached) "completed") (equal (car cached) key)))
        (cdr cached)
      (cdr (setf (alist-get id jgy/agent-shell--changes-cache nil nil #'equal)
                 (cons key (jgy/agent-shell--changes call)))))))

(defvar-local jgy/agent-shell--dirty nil
  "Files git saw changed in the project at the last scan, as (FILE . MTIME).")

(defvar-local jgy/agent-shell--shell-changes nil
  "Files this turn's shell commands changed, newest first.
Each is (FILE ADDED REMOVED MTIME), counted against git's last commit.")

(defun jgy/agent-shell--repos (root)
  "ROOT and the git repositories directly in it.
Projects keep code repositories in subdirectories ROOT's repository ignores."
  (cons root (seq-filter (lambda (dir) (file-exists-p (expand-file-name ".git" dir)))
                         (directory-files root t "\\`[^.]" t))))

(defun jgy/agent-shell--dirty-files (root)
  "Changed and untracked files git sees under ROOT, as (FILE . MTIME)."
  (let (files)
    (dolist (dir (jgy/agent-shell--repos root))
      (let ((default-directory (file-name-as-directory dir)))
        (with-temp-buffer
          (when (eq 0 (process-file "git" nil t nil "ls-files" "-z" "--modified"
                                    "--others" "--exclude-standard" "--" "."))
            (dolist (name (split-string (buffer-string) "\0" t))
              (let ((file (expand-file-name name)))
                (when-let* ((attributes (file-attributes file)))
                  (push (cons file (file-attribute-modification-time attributes)) files))))))))
    files))

(defun jgy/agent-shell--git-counts (file)
  "Lines (ADDED REMOVED) in FILE since git's last commit; all added when untracked."
  (let ((default-directory (file-name-directory file)))
    (with-temp-buffer
      (if (and (eq 0 (process-file "git" nil t nil "diff" "--numstat" "HEAD" "--"
                                   (file-name-nondirectory file)))
               (re-search-backward "^\\([0-9]+\\)\t\\([0-9]+\\)" nil t))
          (list (string-to-number (match-string 1)) (string-to-number (match-string 2)))
        (erase-buffer)
        (insert-file-contents file)
        (list (count-lines (point-min) (point-max)) 0)))))

(defun jgy/agent-shell--scan-shell-changes ()
  "Record files git sees changed since the last scan as shell changes."
  (when-let* ((root (alist-get 'root agents-identity))
              (dirty (jgy/agent-shell--dirty-files root)))
    (let (changed)
      (pcase-dolist (`(,file . ,mtime) dirty)
        (unless (equal mtime (alist-get file jgy/agent-shell--dirty nil nil #'equal))
          (setf (alist-get file jgy/agent-shell--shell-changes nil nil #'equal)
                (append (jgy/agent-shell--git-counts file) (list mtime)))
          (setq changed t)))
      (setq jgy/agent-shell--dirty dirty)
      (when changed (agents-dashboard-refresh)))))

(defun jgy/agent-shell--files ()
  "Files this turn's tool calls wrote, for the `files' identity of agents.el.
Failed calls count only toward files another call already wrote."
  (let (files)
    (pcase-dolist (`(,id . ,call) (reverse jgy/agent-shell--edits))
      (let ((status (map-elt call :status)))
        (unless (equal status "failed")
          (pcase-dolist (`(,path ,added ,removed ,line) (jgy/agent-shell--cached-changes id call))
            (when path
              (let* ((file (expand-file-name path))
                     (entry (seq-find (lambda (entry) (equal (alist-get 'file entry) file))
                                      files)))
                (unless entry
                  (setq entry (list (cons 'file file) (cons 'added 0) (cons 'removed 0)
                                    (cons 'active nil) (cons 'line nil))
                        files (nconc files (list entry))))
                (cl-incf (alist-get 'added entry) added)
                (cl-incf (alist-get 'removed entry) removed)
                (unless (equal status "completed")
                  (setf (alist-get 'active entry) t))
                (when line
                  (setf (alist-get 'line entry) line))))))))
    ;; `setf' 把新文件放在 alist 头上，倒过来才是先改的在前。
    (pcase-dolist (`(,file ,added ,removed ,mtime) (reverse jgy/agent-shell--shell-changes))
      (unless (seq-find (lambda (entry) (equal (alist-get 'file entry) file)) files)
        ;; mtime 让看板分得出同样行数的又一次改动。
        (setq files (nconc files (list (list (cons 'file file) (cons 'added added)
                                             (cons 'removed removed) (cons 'active nil)
                                             (cons 'line nil) (cons 'mtime mtime)))))))
    files))

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

(defun jgy/agent-shell--on-event (event)
  "Report agent-shell EVENT to `agents-report'; track this turn's edits and brief."
  (pcase (map-elt event :event)
    ('input-submitted
     (setq jgy/agent-shell--edits nil
           jgy/agent-shell--changes-cache nil
           jgy/agent-shell--asking nil
           jgy/agent-shell--plan-step nil
           jgy/agent-shell--last-tool nil
           jgy/agent-shell--shell-changes nil
           jgy/agent-shell--dirty (ignore-errors
                                    (jgy/agent-shell--dirty-files (alist-get 'root agents-identity))))
     (agents-dashboard-refresh))
    ('tool-call-update
     (jgy/agent-shell--track-edit (map-elt event :data))
     (when (and (equal (map-nested-elt event '(:data :tool-call :kind)) "execute")
                (member (map-nested-elt event '(:data :tool-call :status)) '("completed" "failed")))
       (ignore-errors (jgy/agent-shell--scan-shell-changes)))
     (when-let* ((title (jgy/agent-shell--tool-title (map-elt event :data))))
       (jgy/agent-shell--set-brief 'jgy/agent-shell--last-tool title)))
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
