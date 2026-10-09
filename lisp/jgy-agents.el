;;; jgy-agents.el --- Agents tracked per project and tab -*- lexical-binding: t; -*-

;;; Commentary:
;; 按项目复用 agent，按启动时的 tab 归属；`jgy-agents-mode' 跟踪状态，并让 bufferlo 只列出本 tab 的 agent。
;; 前端（agent-shell）设 `jgy-agents-start-function' 来启动 agent，
;; 在其 buffer 里设 `jgy-agents-identity'，状态经 `jgy-agents-report' 上报。
;; 前端可在 identity 里给出 `files'（本轮改过的文件）和 `brief'（正在做什么），由看板显示。
;;
;; 其他部分只经这里的公开函数和钩子接入：
;; - `jgy-agents-changed-hook'：agent 的状态、文件或 brief 变了，由 `jgy-agents-refresh' 触发；
;; - `jgy-agents-turn-start-hook'：agent 开始新一轮，在它的 buffer 里运行；
;; - `jgy-agents-tick-hook'：`jgy-agents-mode' 开着时每 `jgy-agents-tick-interval' 秒运行。
;; 看板在 jgy-agents-dashboard.el，diff 跟随窗口在 jgy-agents-follow.el。

;;; Code:

(require 'cl-lib)

(require 'project)

(require 'seq)

(require 'subr-x)

(require 'tab-bar)

(declare-function consult--read "consult")

(declare-function consult--buffer-preview "consult")

(defgroup jgy-agents nil
  "Agents tracked per project and tab."
  :group 'tools)

(defcustom jgy-agents-names '("claude" "codex" "pi")
  "Agent names offered by `jgy-agents-start'."
  :type '(repeat string))

(defcustom jgy-agents-status-glyphs
  '((working "◐" warning)
    (waiting "⚠" error)
    (done "●" success)
    (idle "○" shadow))
  "Glyph and face for each `jgy-agents-status'."
  :type '(alist :key-type symbol :value-type (list string face)))

(defvar jgy-agents--last nil
  "Name of the agent most recently started or shown.")

(defvar-local jgy-agents-status 'idle
  "One of `working', `waiting', `done' or `idle'.
`waiting' means the agent asked for attention; `done' means it finished unseen.")

(put 'jgy-agents-status 'permanent-local t)

(defvar-local jgy-agents-tab nil
  "Id of the tab the agent was started in.")
(put 'jgy-agents-tab 'permanent-local t)

(defvar jgy-agents--tab-id-counter 0)

(defvar-local jgy-agents-turn nil
  "Times the agent's latest turn started and finished, as (START . END).
END is nil while the turn runs.")
(put 'jgy-agents-turn 'permanent-local t)

(defvar-local jgy-agents-context nil
  "Percentage of the agent's context window in use, or nil when unknown.")

(put 'jgy-agents-context 'permanent-local t)

(defcustom jgy-agents-tick-interval 5
  "Seconds between runs of `jgy-agents-tick-hook'."
  :type 'number)

(defvar jgy-agents--tick-timer nil)

(defvar jgy-agents-changed-hook nil
  "Hook run by `jgy-agents-refresh' when some agent's state changed.")

(defvar jgy-agents-turn-start-hook nil
  "Hook run in an agent's buffer when it starts a turn.")

(defvar jgy-agents-tick-hook nil
  "Hook run every `jgy-agents-tick-interval' seconds while `jgy-agents-mode' is on.")

(defun jgy-agents-refresh ()
  "Tell the views that some agent's state changed.
For frontends whose agent's files or brief changed."
  (run-hooks 'jgy-agents-changed-hook))

;;; Buffers

(defvar-local jgy-agents-identity nil
  "Alist describing the agent in this buffer.
Keys: `agent' is its name; `root' its directory; `insert' a
function inserting a string into its input; `context' a function returning
its context usage percentage or nil; `files' a function returning the files
it edited this turn, in provider edit order, as alists with keys `file'
\(absolute), `added', `removed', `active' (still being written) and `line';
`diff' may hold a cached turn patch (an empty string means no net change);
`directory' is the base directory for paths in that patch.
`brief' a function returning a line on what it is doing, or nil.")

(put 'jgy-agents-identity 'permanent-local t)

(defun jgy-agents-buffer-p (buffer)
  "Non-nil when BUFFER runs an agent."
  (and (buffer-local-value 'jgy-agents-identity buffer) t))

(defun jgy-agents-get (buffer key)
  "Value of KEY in agent BUFFER's `jgy-agents-identity'."
  (alist-get key (buffer-local-value 'jgy-agents-identity buffer)))

(defun jgy-agents-project-root ()
  "Return the current project's root, or `default-directory' outside a project."
  (if-let* ((project (project-current))) (project-root project) default-directory))

(defcustom jgy-agents-root-function #'jgy-agents-project-root
  "Function returning the directory agents of the current buffer run in."
  :type 'function)

(defun jgy-agents--root ()
  (funcall jgy-agents-root-function))

(defcustom jgy-agents-start-function nil
  "Function of NAME and ROOT that starts agent NAME in ROOT and returns its buffer."
  :type 'function)

(defun jgy-agents-buffers (&optional pred)
  "Live agent buffers, restricted to those satisfying PRED when given."
  (seq-filter (lambda (buffer)
                (and (jgy-agents-buffer-p buffer)
                     (or (null pred) (funcall pred buffer))))
              (buffer-list)))

(defun jgy-agents--project-buffers (&optional name)
  "Agent buffers of the current project, restricted to agent NAME when given."
  (let ((root (expand-file-name (jgy-agents--root))))
    (jgy-agents-buffers
     (lambda (buffer)
       (and (equal (jgy-agents-get buffer 'root) root)
            (or (null name) (equal (jgy-agents-get buffer 'agent) name)))))))

(defun jgy-agents--current ()
  "This project's agent, preferring the last used one."
  (or (car (jgy-agents--project-buffers jgy-agents--last))
      (car (jgy-agents--project-buffers))))

(defun jgy-agents-show (buffer-or-name)
  "Select BUFFER-OR-NAME in its window, or in the selected window."
  (pop-to-buffer buffer-or-name
                 '((display-buffer-reuse-window display-buffer-same-window))))

(defun jgy-agents-files (buffer)
  "Files agent BUFFER edited this turn, as its `files' identity returns them."
  (when-let* ((files (jgy-agents-get buffer 'files)))
    (with-current-buffer buffer (ignore-errors (funcall files)))))

;;; Tabs

(defun jgy-agents--tab-id ()
  "Return the stable id of the current tab, assigning one when it has none."
  (let ((tab (tab-bar--current-tab-find)))
    (or (alist-get 'jgy-agents-id (cdr tab))
        ;; 进程号入 id，desktop 恢复回来的旧 id 不会和新 id 撞车。
        (setf (alist-get 'jgy-agents-id (cdr tab))
              (format "%d-%d" (emacs-pid) (cl-incf jgy-agents--tab-id-counter))))))

(defun jgy-agents-tab-index (buffer)
  "Index of the tab BUFFER was started in, or nil when that tab is gone."
  (when-let* ((id (buffer-local-value 'jgy-agents-tab buffer)))
    (cl-position id (funcall tab-bar-tabs-function)
                 :key (lambda (tab) (alist-get 'jgy-agents-id (cdr tab)))
                 :test #'equal)))

(defun jgy-agents-select-tab (buffer)
  "Switch to the tab agent BUFFER belongs to, when it still exists."
  (jgy-agents-select-tab buffer))

(defun jgy-agents--filter-tab-buffers (fn &rest args)
  "Around advice for `bufferlo-buffer-list' dropping agents owned by other tabs."
  (let ((buffers (apply fn args)))
    (pcase-let ((`(,frame ,tabnum) args))
      (if (eq tabnum 'all)
          buffers
        (let* ((tabs (funcall tab-bar-tabs-function frame))
               (tab (if tabnum (nth tabnum tabs) (assq 'current-tab tabs)))
               (id (alist-get 'jgy-agents-id (cdr tab))))
          (seq-remove (lambda (buffer)
                        (and (jgy-agents-buffer-p buffer)
                             (let ((owner (buffer-local-value 'jgy-agents-tab buffer)))
                               (and owner (not (equal owner id))))))
                      buffers))))))

;;; Commands

(defun jgy-agents-register (buffer name &optional tab)
  "Track BUFFER as agent NAME, owned by TAB or else the current tab.
Its frontend has set `jgy-agents-identity' there already."
  (with-current-buffer buffer
    (setq jgy-agents-tab (or tab (jgy-agents--tab-id)))
    (add-hook 'kill-buffer-hook #'jgy-agents-refresh nil t))
  (setq jgy-agents--last name)
  (jgy-agents-refresh))

;;;###autoload
(defun jgy-agents-start (name &optional fresh)
  "Show agent NAME for the current project, starting it when needed.
With prefix arg FRESH, always start another instance."
  (interactive
   (list (completing-read "Agent: " jgy-agents-names nil t nil nil
                          jgy-agents--last)
         current-prefix-arg))
  (let* ((default-directory (jgy-agents--root))
         (buffer (and (not fresh) (car (jgy-agents--project-buffers name)))))
    (unless buffer
      (unless jgy-agents-start-function (user-error "Set `jgy-agents-start-function' first"))
      (setq buffer (funcall jgy-agents-start-function name
                            (expand-file-name default-directory)))
      (jgy-agents-register buffer name))
    (setq jgy-agents--last name)
    (jgy-agents-show buffer)))

;;;###autoload
(defun jgy-agents-toggle ()
  "Hide the agent in the selected window, or show this project's agent.
Prompts for an agent to start when none is running."
  (interactive)
  (cond ((jgy-agents-buffer-p (current-buffer)) (quit-window))
        ((jgy-agents--current) (jgy-agents-show (jgy-agents--current)))
        (t (call-interactively #'jgy-agents-start))))

;;;###autoload
(defun jgy-agents-switch ()
  "Pick any running agent buffer with preview, across all projects."
  (interactive)
  (require 'consult)
  (let* ((names (or (mapcar #'buffer-name (jgy-agents-buffers))
                    (user-error "No agent running")))
         (buffer (get-buffer (consult--read names
                                            :prompt "Agent buffer: "
                                            :require-match t
                                            :category 'agent-buffer
                                            :sort nil
                                            :annotate (jgy-agents--annotator names)
                                            :state (consult--buffer-preview)))))
    (when-let* ((index (jgy-agents-tab-index buffer)))
      (tab-bar-select-tab (1+ index)))
    (jgy-agents-show buffer)))

;;;###autoload
(defun jgy-agents-send (&optional beg end)
  "Paste the region, or an @ reference to the file, into this project's agent."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (let* ((file (buffer-file-name (buffer-base-buffer)))
         (path (if file (file-relative-name file (jgy-agents--root)) (buffer-name)))
         (text (if beg
                   (format "%s:%d-%d\n```\n%s\n```\n" path
                           (line-number-at-pos beg) (line-number-at-pos (max beg (1- end)))
                           (buffer-substring-no-properties beg end))
                 (if file (format "@%s " path) (user-error "Buffer has no file"))))
         (buffer (or (jgy-agents--current)
                     (user-error "No agent running in this project"))))
    (deactivate-mark)
    (with-current-buffer buffer
      (funcall (or (jgy-agents-get buffer 'insert)
                   (user-error "%s cannot receive text" (buffer-name)))
               text))
    (jgy-agents-show buffer)))

;;; Status

(defun jgy-agents-glyph (buffer)
  "Status glyph of agent BUFFER, in its face from `jgy-agents-status-glyphs'."
  (let ((glyph (alist-get (buffer-local-value 'jgy-agents-status buffer)
                          jgy-agents-status-glyphs)))
    (propertize (car glyph) 'face (cadr glyph))))

(defun jgy-agents--annotator (names)
  "Annotation function for agent buffer NAMES: status, then the tab it belongs to."
  (let* ((status-col (+ 2 (apply #'max (mapcar #'string-width names))))
         (tab-col (+ status-col 12)))
    (lambda (name)
      (let* ((buffer (get-buffer name))
             (index (jgy-agents-tab-index buffer)))
        (concat (propertize " " 'display `(space :align-to ,status-col))
                (jgy-agents-glyph buffer) " "
                (symbol-name (buffer-local-value 'jgy-agents-status buffer))
                (propertize " " 'display `(space :align-to ,tab-col))
                (if index
                    (alist-get 'name (nth index (funcall tab-bar-tabs-function)))
                  (propertize "(tab closed)" 'face 'shadow)))))))

(defun jgy-agents--set-status (status)
  (unless (eq status jgy-agents-status)
    (setq jgy-agents-status status)
    (jgy-agents-refresh)))

(defun jgy-agents--seen-p ()
  (eq (window-buffer (selected-window)) (current-buffer)))

(defun jgy-agents-report (event)
  "Update the current agent buffer's status for EVENT.
EVENT is `working', `finished' or `attention'; what it becomes depends on
whether the agent is shown in the selected window.
`working' after `finished' starts a turn, which `jgy-agents-turn' times
and `jgy-agents-turn-start-hook' announces."
  ;; 按事件而不是状态分轮：等批准时看一眼会把 waiting 清成 idle，批准后不算新一轮。
  (pcase event
    ('working (when (or (null jgy-agents-turn) (cdr jgy-agents-turn))
                (setq jgy-agents-turn (list (float-time)))
                (run-hooks 'jgy-agents-turn-start-hook)))
    ('finished (when (and jgy-agents-turn (null (cdr jgy-agents-turn)))
                 (setcdr jgy-agents-turn (float-time)))))
  (pcase event
    ('finished (jgy-agents--set-status (if (jgy-agents--seen-p) 'idle 'done)))
    ('working (unless (eq jgy-agents-status 'waiting)
                (jgy-agents--set-status 'working)))
    ('attention (unless (jgy-agents--seen-p)
                  (jgy-agents--set-status 'waiting)))))

(defun jgy-agents--acknowledge (&rest _)
  "Reset `done' and `waiting' once the agent is shown in the selected window."
  ;; 切 tab 也会走到这里，借机刷新看板里的 tab 列表。
  (jgy-agents-refresh)
  (let ((buffer (window-buffer (selected-window))))
    (when (and (jgy-agents-buffer-p buffer)
               (memq (buffer-local-value 'jgy-agents-status buffer) '(done waiting)))
      (with-current-buffer buffer (jgy-agents--set-status 'idle)))))

(defun jgy-agents--tick ()
  "Update each agent's context usage, then run `jgy-agents-tick-hook'.
An unknown context value keeps the last one."
  (dolist (buffer (jgy-agents-buffers))
    (with-current-buffer buffer
      (let ((used (when-let* ((context (jgy-agents-get buffer 'context)))
                    (ignore-errors (funcall context)))))
        (when (and used (not (equal used jgy-agents-context)))
          (setq jgy-agents-context used)
          (jgy-agents-refresh)))))
  (run-hooks 'jgy-agents-tick-hook))

(defun jgy-agents-format-duration (seconds)
  "Format SECONDS compactly with its two largest units, like 2h10m or 3d4h."
  (let ((m (/ (max 0 (floor seconds)) 60)))
    (cond ((< m 60) (format "%dm" m))
          ((< m 1440) (format "%dh%dm" (/ m 60) (% m 60)))
          (t (format "%dd%dh" (/ m 1440) (% (/ m 60) 24))))))

(defun jgy-agents--embark-transform (_type target)
  (cons 'buffer target))

(defvar embark-transformer-alist)

(with-eval-after-load 'embark
  (add-to-list 'embark-transformer-alist '(agent-buffer . jgy-agents--embark-transform)))

;;;###autoload
(define-minor-mode jgy-agents-mode
  "Track agent status and keep agents with their tab."
  :global t
  (if jgy-agents-mode
      (progn
        (advice-add 'bufferlo-buffer-list :around #'jgy-agents--filter-tab-buffers)
        (add-hook 'window-selection-change-functions #'jgy-agents--acknowledge)
        (add-hook 'window-buffer-change-functions #'jgy-agents--acknowledge)
        (unless jgy-agents--tick-timer
          (setq jgy-agents--tick-timer
                (run-with-timer 0 jgy-agents-tick-interval #'jgy-agents--tick))))
    (advice-remove 'bufferlo-buffer-list #'jgy-agents--filter-tab-buffers)
    (remove-hook 'window-selection-change-functions #'jgy-agents--acknowledge)
    (remove-hook 'window-buffer-change-functions #'jgy-agents--acknowledge)
    (when jgy-agents--tick-timer
      (cancel-timer jgy-agents--tick-timer)
      (setq jgy-agents--tick-timer nil))))

(provide 'jgy-agents)
;;; jgy-agents.el ends here
