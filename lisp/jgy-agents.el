;;; jgy-agents.el --- Agents tracked per project and tab, with a dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;; 按项目复用 agent，按启动时的 tab 归属；`jgy-agents-mode' 跟踪状态，并让 bufferlo 只列出本 tab 的 agent。
;; 前端（agent-shell）设 `jgy-agents-start-function' 来启动 agent，
;; 在其 buffer 里设 `jgy-agents-identity'，状态经 `jgy-agents-report' 上报。
;; 套餐用量（5 小时、7 天）由 jgy-agents-usage.el 的 `jgy-agents-usage-functions' 读出，
;; 经 `jgy-agents-usage-scan' 定期刷新。
;; 前端可在 identity 里给出 `files'，看板就在 agent 下面列出它本轮改过的文件；
;; 给出 `brief'，看板就在 agent 那行末尾写它正在做什么。
;; 看板上按 d 看文件或整个项目还没提交的改动；agent 那行写着本轮跑了多久。
;; 按 D 让 agent 所在 tab 开一个 diff 窗口，跟着它最近写的文件刷新。

;;; Code:

(require 'cl-lib)
(require 'diff-mode)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'tab-bar)

(declare-function evil-define-key* "evil-core")
(declare-function consult--read "consult")
(declare-function consult--buffer-preview "consult")

(declare-function jgy-agents--usage-insert "jgy-agents-usage")
(declare-function jgy-agents-usage-scan "jgy-agents-usage")


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

(defvar-local jgy-agents--tab nil
  "Id of the tab the agent was started in.")
(put 'jgy-agents--tab 'permanent-local t)

(defvar jgy-agents--tab-id-counter 0)

(defvar-local jgy-agents--turn nil
  "Times the agent's latest turn started and finished, as (START . END).
END is nil while the turn runs.")
(put 'jgy-agents--turn 'permanent-local t)

(defvar-local jgy-agents--diff-follow nil
  "Non-nil while this agent's diff window follows its edits.
It is a plist: :files the `files' identity last seen, :file the file shown,
:pending non-nil when that file changed while the agent's tab was not current.")

(defcustom jgy-agents-context-warning 70
  "Context usage percentage from which the dashboard highlights an agent."
  :type 'natnum)

(defvar-local jgy-agents-context nil
  "Percentage of the agent's context window in use, or nil when unknown.")
(put 'jgy-agents-context 'permanent-local t)

(defcustom jgy-agents-context-interval 5
  "Seconds between reads of the agents' context usage."
  :type 'number)

(defvar jgy-agents--context-timer nil)

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

(defun jgy-agents--identity (buffer key)
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


(defun jgy-agents--buffers (&optional pred)
  "Live agent buffers, restricted to those satisfying PRED when given."
  (seq-filter (lambda (buffer)
                (and (jgy-agents-buffer-p buffer)
                     (or (null pred) (funcall pred buffer))))
              (buffer-list)))

(defun jgy-agents--project-buffers (&optional name)
  "Agent buffers of the current project, restricted to agent NAME when given."
  (let ((root (expand-file-name (jgy-agents--root))))
    (jgy-agents--buffers
     (lambda (buffer)
       (and (equal (jgy-agents--identity buffer 'root) root)
            (or (null name) (equal (jgy-agents--identity buffer 'agent) name)))))))

(defun jgy-agents--current ()
  "This project's agent, preferring the last used one."
  (or (car (jgy-agents--project-buffers jgy-agents--last))
      (car (jgy-agents--project-buffers))))

(defun jgy-agents--show (buffer-or-name)
  "Select BUFFER-OR-NAME in its window, or in the selected window."
  (pop-to-buffer buffer-or-name
                 '((display-buffer-reuse-window display-buffer-same-window))))

;;; Tabs

(defun jgy-agents--tab-id ()
  "Return the stable id of the current tab, assigning one when it has none."
  (let ((tab (tab-bar--current-tab-find)))
    (or (alist-get 'jgy-agents-id (cdr tab))
        ;; 进程号入 id，desktop 恢复回来的旧 id 不会和新 id 撞车。
        (setf (alist-get 'jgy-agents-id (cdr tab))
              (format "%d-%d" (emacs-pid) (cl-incf jgy-agents--tab-id-counter))))))

(defun jgy-agents--tab-index (buffer)
  "Index of the tab BUFFER was started in, or nil when that tab is gone."
  (when-let* ((id (buffer-local-value 'jgy-agents--tab buffer)))
    (cl-position id (funcall tab-bar-tabs-function)
                 :key (lambda (tab) (alist-get 'jgy-agents-id (cdr tab)))
                 :test #'equal)))

;;; Commands

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
      (with-current-buffer buffer
        (setq jgy-agents--tab (jgy-agents--tab-id))
        (add-hook 'kill-buffer-hook #'jgy-agents--dashboard-schedule nil t))
      (jgy-agents--dashboard-schedule))
    (setq jgy-agents--last name)
    (jgy-agents--show buffer)))

;;;###autoload
(defun jgy-agents-toggle ()
  "Hide the agent in the selected window, or show this project's agent.
Prompts for an agent to start when none is running."
  (interactive)
  (cond ((jgy-agents-buffer-p (current-buffer)) (quit-window))
        ((jgy-agents--current) (jgy-agents--show (jgy-agents--current)))
        (t (call-interactively #'jgy-agents-start))))

;;;###autoload
(defun jgy-agents-switch ()
  "Pick any running agent buffer with preview, across all projects."
  (interactive)
  (require 'consult)
  (let* ((names (or (mapcar #'buffer-name (jgy-agents--buffers))
                    (user-error "No agent running")))
         (buffer (get-buffer (consult--read names
                                            :prompt "Agent buffer: "
                                            :require-match t
                                            :category 'agent-buffer
                                            :sort nil
                                            :annotate (jgy-agents--annotator names)
                                            :state (consult--buffer-preview)))))
    (when-let* ((index (jgy-agents--tab-index buffer)))
      (tab-bar-select-tab (1+ index)))
    (jgy-agents--show buffer)))

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
      (funcall (or (jgy-agents--identity buffer 'insert)
                   (user-error "%s cannot receive text" (buffer-name)))
               text))
    (jgy-agents--show buffer)))

;;; Status

(defun jgy-agents--glyph (buffer)
  (let ((glyph (alist-get (buffer-local-value 'jgy-agents-status buffer)
                          jgy-agents-status-glyphs)))
    (propertize (car glyph) 'face (cadr glyph))))

(defun jgy-agents--annotator (names)
  "Annotation function for agent buffer NAMES: status, then the tab it belongs to."
  (let* ((status-col (+ 2 (apply #'max (mapcar #'string-width names))))
         (tab-col (+ status-col 12)))
    (lambda (name)
      (let* ((buffer (get-buffer name))
             (index (jgy-agents--tab-index buffer)))
        (concat (propertize " " 'display `(space :align-to ,status-col))
                (jgy-agents--glyph buffer) " "
                (symbol-name (buffer-local-value 'jgy-agents-status buffer))
                (propertize " " 'display `(space :align-to ,tab-col))
                (if index
                    (alist-get 'name (nth index (funcall tab-bar-tabs-function)))
                  (propertize "(tab closed)" 'face 'shadow)))))))

(defun jgy-agents--set-status (status)
  (unless (eq status jgy-agents-status)
    (setq jgy-agents-status status)
    (jgy-agents--dashboard-schedule)))

(defun jgy-agents--seen-p ()
  (eq (window-buffer (selected-window)) (current-buffer)))

(defun jgy-agents-report (event)
  "Update the current agent buffer's status for EVENT.
EVENT is `working', `finished' or `attention'; what it becomes depends on
whether the agent is shown in the selected window.
`working' after `finished' starts a turn, which `jgy-agents--turn' times."
  ;; 按事件而不是状态分轮：等批准时看一眼会把 waiting 清成 idle，批准后不算新一轮。
  (pcase event
    ('working (when (or (null jgy-agents--turn) (cdr jgy-agents--turn))
                (setq jgy-agents--turn (list (float-time)))))
    ('finished (when (and jgy-agents--turn (null (cdr jgy-agents--turn)))
                 (setcdr jgy-agents--turn (float-time)))))
  (pcase event
    ('finished (jgy-agents--set-status (if (jgy-agents--seen-p) 'idle 'done)))
    ('working (unless (eq jgy-agents-status 'waiting)
                (jgy-agents--set-status 'working)))
    ('attention (unless (jgy-agents--seen-p)
                  (jgy-agents--set-status 'waiting)))))

(defun jgy-agents--acknowledge (&rest _)
  "Reset `done' and `waiting' once the agent is shown in the selected window."
  ;; 切 tab 也会走到这里，借机刷新看板里的 tab 列表。
  (jgy-agents--dashboard-schedule)
  (let ((buffer (window-buffer (selected-window))))
    (when (and (jgy-agents-buffer-p buffer)
               (memq (buffer-local-value 'jgy-agents-status buffer) '(done waiting)))
      (with-current-buffer buffer (jgy-agents--set-status 'idle)))))

(defvar jgy-agents--turn-labels nil
  "Turn durations as last drawn, to redraw when a running one ticks over.")

(defun jgy-agents--context-scan ()
  "Update each agent's context usage; an unknown value keeps the last one.
Also redraws the dashboard when plan usage or a turn's duration changed."
  (let ((labels (mapcar #'jgy-agents--turn-label (jgy-agents--buffers))))
    (unless (equal labels jgy-agents--turn-labels)
      (setq jgy-agents--turn-labels labels)
      (jgy-agents--dashboard-schedule)))
  (dolist (buffer (jgy-agents--buffers))
    (with-current-buffer buffer
      (let ((used (when-let* ((context (jgy-agents--identity buffer 'context)))
                    (ignore-errors (funcall context)))))
        (when (and used (not (equal used jgy-agents-context)))
          (setq jgy-agents-context used)
          (jgy-agents--dashboard-schedule)))))
  (when (fboundp 'jgy-agents-usage-scan)
    (jgy-agents-usage-scan)))

(defun jgy-agents--duration (seconds)
  "Format SECONDS compactly with its two largest units, like 2h10m or 3d4h."
  (let ((m (/ (max 0 (floor seconds)) 60)))
    (cond ((< m 60) (format "%dm" m))
          ((< m 1440) (format "%dh%dm" (/ m 60) (% m 60)))
          (t (format "%dd%dh" (/ m 1440) (% (/ m 60) 24))))))

(defconst jgy-agents--indent "   "
  "Indent of agent lines and section contents.")

(defconst jgy-agents--file-indent "      "
  "Indent of the files under an agent, lining up with its name.")

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
                             (let ((owner (buffer-local-value 'jgy-agents--tab buffer)))
                               (and owner (not (equal owner id))))))
                      buffers))))))

;;; Dashboard

(defcustom jgy-agents-attention-statuses '(waiting done)
  "Statuses that `jgy-agents-dashboard-next-attention' stops at."
  :type '(repeat symbol))

(defcustom jgy-agents-dashboard-width 65
  "Width of the dashboard side window."
  :type 'natnum)

(defcustom jgy-agents-dashboard-files 5
  "Edited files listed under an agent before the rest fold into one line."
  :type 'natnum)

(defconst jgy-agents--dashboard-name " *agents*"
  "Leading space keeps the dashboard out of `other-buffer' and buffer lists.")

(defvar jgy-agents--dashboard-shown nil
  "Non-nil while the dashboard is toggled on; every tab then shows it.")

(defvar jgy-agents--dashboard-timer nil)

(defvar jgy-agents-dashboard-functions nil
  "Functions inserting extra sections at the end of the dashboard.
Each is called with the dashboard's frame and usually inserts through
`jgy-agents-dashboard-insert-section'.  A line whose text has the
property `jgy-agents-action' runs that function on visit.")

(defconst jgy-agents--dashboard-keys
  '(("RET" . jgy-agents-dashboard-visit)
    ("o" . jgy-agents-dashboard-visit)
    ("d" . jgy-agents-dashboard-diff)
    ("D" . jgy-agents-dashboard-follow-diff)
    ("C-j" . jgy-agents-dashboard-next-tab)
    ("C-k" . jgy-agents-dashboard-previous-tab)
    ("C-S-j" . jgy-agents-dashboard-next-attention)
    ("C-S-k" . jgy-agents-dashboard-previous-attention)
    ("] a" . jgy-agents-dashboard-next-attention)
    ("[ a" . jgy-agents-dashboard-previous-attention)
    ("q" . jgy-agents-dashboard))
  "Dashboard bindings in `keymap-set' syntax, for Emacs and evil's normal state.")

(defvar-keymap jgy-agents-dashboard-mode-map
  :parent special-mode-map)

(defun jgy-agents-dashboard-define-key (key command)
  "Bind KEY, in `keymap-set' syntax, to COMMAND on the dashboard.
Binds it in evil's normal state too."
  (keymap-set jgy-agents-dashboard-mode-map key command)
  (with-eval-after-load 'evil
    (evil-define-key* 'normal jgy-agents-dashboard-mode-map (key-parse key) command)))

(pcase-dolist (`(,key . ,command) jgy-agents--dashboard-keys)
  (jgy-agents-dashboard-define-key key command))

(define-derived-mode jgy-agents-dashboard-mode special-mode "Agents"
  "Agents grouped under the tab they were started in."
  (setq-local revert-buffer-function (lambda (&rest _) (jgy-agents--dashboard-render))
              truncate-lines nil
              truncate-partial-width-windows nil
              word-wrap t
              word-wrap-by-category t
              left-margin-width 1
              right-margin-width 1
              ;; mode line 和别的窗口一样，写看板名和 agent 数目。
              mode-line-format '(:eval (jgy-agents--dashboard-mode-line)))
  ;; brief 按窗口宽度截断，宽度一变就得重画。
  (add-hook 'window-size-change-functions #'jgy-agents--dashboard-resized nil t)
  (display-line-numbers-mode -1)
  (hl-line-mode 1))

(with-eval-after-load 'evil
  ;; normal state 下另加 gr 刷新。
  (evil-define-key* 'normal jgy-agents-dashboard-mode-map (kbd "gr") #'revert-buffer))

(defun jgy-agents--dashboard-schedule ()
  "Re-render the dashboard soon, coalescing bursts of changes."
  (when (and (get-buffer jgy-agents--dashboard-name)
             (not (timerp jgy-agents--dashboard-timer)))
    (setq jgy-agents--dashboard-timer
          (run-with-timer 0.1 nil
                          (lambda ()
                            (setq jgy-agents--dashboard-timer nil)
                            (jgy-agents--dashboard-render))))))

(defun jgy-agents--dashboard-resized (_window)
  (jgy-agents--dashboard-schedule))

(defun jgy-agents-dashboard-refresh ()
  "Re-render the dashboard soon; for frontends whose agent changed."
  (jgy-agents--dashboard-schedule)
  (jgy-agents--diff-schedule))

(defface jgy-agents-section
  '((t :inherit (font-lock-keyword-face bold)))
  "Face for dashboard section titles.")

(defface jgy-agents-waiting-line
  '((((background dark)) :background "#3d1c20" :extend t)
    (t :background "#fbe4e4" :extend t))
  "Face added to the dashboard line of an agent waiting for you.")

(defface jgy-agents-done-line
  '((((background dark)) :background "#1b3324" :extend t)
    (t :background "#e2f5e6" :extend t))
  "Face added to the dashboard line of an agent that finished unseen.")

(defun jgy-agents-dashboard-heading (name &optional current)
  "NAME as a dashboard heading, highlighted when CURRENT."
  (propertize name 'face (if current '(success bold) 'bold)))

(defun jgy-agents--section-title (title)
  "Line for section TITLE, carrying TITLE's text properties to its end."
  (let ((line (concat title "\n")))
    (add-face-text-property 0 (length title) 'jgy-agents-section t line)
    ;; 在标题行哪里按 RET 都算，比如 Todo 标题上的 `jgy-agents-action'。
    (cl-loop for (prop value) on (text-properties-at 0 title) by #'cddr
             unless (eq prop 'face)
             do (put-text-property 0 (length line) prop value line))
    line))

(defun jgy-agents--dashboard-mode-line ()
  "Mode line of the dashboard: its name, then a count of agents by state."
  (concat " " (propertize "Agents" 'face 'mode-line-buffer-id)
          "   " (string-replace "%" "%%" (jgy-agents--dashboard-counts))))

(defun jgy-agents-dashboard-insert-section (title body)
  "Insert section TITLE followed by what BODY inserts.
BODY is a function of no arguments; the title is dropped when it
inserts nothing."
  (let ((start (point)))
    (unless (bobp) (insert "\n"))
    (insert (jgy-agents--section-title title))
    (let ((after-title (point)))
      (funcall body)
      (when (= (point) after-title)
        (delete-region start (point))))))

(defun jgy-agents--dashboard-line (buffer &optional tab-name)
  "Insert the line for agent BUFFER, then the files it edited this turn.
The agent's project is named only when it differs from TAB-NAME.  Its turn
duration and context usage sit in columns at the right edge."
  (let* ((head (concat jgy-agents--indent (jgy-agents--glyph-cell buffer)
                       (or (jgy-agents--identity buffer 'agent) "agent")
                       (if (buffer-local-value 'jgy-agents--diff-follow buffer)
                           (propertize " ±" 'face `(:foreground ,(face-foreground 'diff-indicator-added nil t))
                                       'help-echo "Its diff window follows its edits")
                         "")
                       (jgy-agents--project-label buffer tab-name)))
         (meta (jgy-agents--meta buffer))
         (brief (jgy-agents--brief buffer))
         (line (concat head
                       (if brief (jgy-agents--brief-label buffer brief head (cdr meta)) "")
                       (car meta)
                       "\n"))
         (highlight (pcase (buffer-local-value 'jgy-agents-status buffer)
                      ('waiting 'jgy-agents-waiting-line)
                      ('done 'jgy-agents-done-line))))
    (when highlight
      (add-face-text-property (length jgy-agents--indent) (length line) highlight t line))
    (insert (propertize line
                        'jgy-agents-buffer buffer
                        'help-echo (if brief
                                       (concat (buffer-name buffer) "\n" brief)
                                     (buffer-name buffer))
                        'wrap-prefix jgy-agents--file-indent))
    (jgy-agents--dashboard-files buffer)))

(defun jgy-agents--glyph-cell (buffer)
  "Status glyph of agent BUFFER padded to three columns, so names line up.
Fonts draw ◐ ○ ● two columns wide but ⚠ one."
  (let* ((glyph (jgy-agents--glyph buffer))
         (pad (- (* 3 (frame-char-width)) (string-pixel-width glyph (current-buffer)))))
    (concat glyph (propertize " " 'display `(space :width (,(max 1 pad)))))))

(defun jgy-agents--context-label (buffer)
  "Context usage of agent BUFFER, or nil.
Highlighted from `jgy-agents-context-warning'."
  (when-let* ((used (buffer-local-value 'jgy-agents-context buffer)))
    (propertize (format "%3d%%" used)
                'face (if (>= used jgy-agents-context-warning) 'warning 'shadow))))

(defun jgy-agents--turn-label (buffer)
  "How long agent BUFFER's latest turn has run, or ran, once past a minute; or nil."
  (pcase (buffer-local-value 'jgy-agents--turn buffer)
    (`(,start . ,end)
     (let ((seconds (- (or end (float-time)) start)))
       (when (>= seconds 60)
         (propertize (jgy-agents--duration seconds) 'face 'shadow))))))

(defun jgy-agents--meta (buffer)
  "Turn duration and context usage of agent BUFFER, aligned to the right edge.
Returns (TEXT . COLUMNS), COLUMNS being how far from the edge TEXT starts.
Context takes the last four columns but one, left free for the wrap mark;
the duration ends a column before it, so both line up across agents."
  (let ((turn (jgy-agents--turn-label buffer))
        (context (jgy-agents--context-label buffer)))
    (cl-flet ((align (columns) (propertize " " 'display `(space :align-to (- right ,columns)))))
      (cons (concat (if turn (concat (align (+ 6 (string-width turn))) turn) "")
                    (if context (concat (align 5) context) ""))
            (cond (turn (+ 6 (string-width turn)))
                  (context 5)
                  (t 0))))))

(defun jgy-agents--project-label (buffer tab-name)
  "Name of agent BUFFER's project, dimmed, unless it is TAB-NAME."
  (let* ((root (jgy-agents--identity buffer 'root))
         (project (and root (file-name-nondirectory (directory-file-name root)))))
    (if (and project (not (equal project tab-name)))
        (propertize (concat " " project) 'face 'shadow)
      "")))

(defun jgy-agents--brief (buffer)
  "What agent BUFFER says it is doing, on one line, or nil."
  (when-let* ((brief (jgy-agents--identity buffer 'brief))
              (text (with-current-buffer buffer (ignore-errors (funcall brief))))
              (text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
              ((not (string-empty-p text))))
    text))

(defun jgy-agents--brief-label (buffer brief head meta)
  "BRIEF cut to the dashboard width between HEAD and META.
META is how many columns the right-aligned text after it takes.  Measured
in pixels, as fonts draw glyphs like ◐ and … wider than `string-width'
says.  Highlighted while agent BUFFER waits, set apart from its name
while it works, dimmed otherwise."
  (let* ((window (get-buffer-window (current-buffer) t))
         (char (frame-char-width (if window (window-frame window) (selected-frame))))
         (gap "  ")
         (face (pcase (buffer-local-value 'jgy-agents-status buffer)
                 ('waiting 'warning)
                 ;; 和 agent 名字区分开，像补全候选后面的注解。
                 ('working 'font-lock-doc-face)
                 (_ 'shadow)))
         (width (lambda (text)
                  (string-pixel-width (propertize text 'face face) (current-buffer))))
         ;; 右边的对齐文字前空一列，没有时也留一列给折行标记；
         ;; `window-max-chars-per-line' 会选中窗口，把看板的 point 拽到窗口 point。
         (room (- (if window (window-body-width window t) (* jgy-agents-dashboard-width char))
                  (string-pixel-width (concat head gap) (current-buffer))
                  (* (1+ meta) char)))
         (text (truncate-string-to-width brief (/ room (max 1 (funcall width "x")))
                                         nil nil "…")))
    (while (and (> (string-width text) 1) (> (funcall width text) room))
      (setq text (truncate-string-to-width brief (1- (string-width text)) nil nil "…")))
    (if (< room (* 4 char))
        ""
      (concat gap (propertize text 'face face)))))

(defun jgy-agents--files (buffer)
  "Files agent BUFFER edited this turn, as its `files' identity returns them."
  (when-let* ((files (jgy-agents--identity buffer 'files)))
    (with-current-buffer buffer (ignore-errors (funcall files)))))

(defun jgy-agents--file-relative (file root)
  "FILE relative to ROOT, or abbreviated when outside it."
  (if (string-prefix-p (file-name-as-directory (expand-file-name root)) file)
      (file-relative-name file root)
    (abbreviate-file-name file)))

(defun jgy-agents--file-counts (added removed)
  "Return \" +ADDED −REMOVED\" in diff colors, leaving out a zero."
  (cl-flet ((count (n sign face)
              (if (> n 0)
                  (propertize (format " %s%d" sign n)
                              'face `(:foreground ,(face-foreground face nil t)))
                "")))
    (concat (count added "+" 'diff-indicator-added)
            (count removed "−" 'diff-indicator-removed))))

(defun jgy-agents--file-label (file root)
  "FILE's name, its line counts, then its directory relative to ROOT, dimmed."
  (let-alist file
    (let ((dir (file-name-directory (jgy-agents--file-relative .file root))))
      (concat (propertize (file-name-nondirectory .file) 'face (if .active 'warning 'default))
              (jgy-agents--file-counts .added .removed)
              (if dir (propertize (concat " " dir) 'face 'shadow) "")))))

(defun jgy-agents--dashboard-files (buffer)
  "Insert the files agent BUFFER edited this turn, under its name.
Past `jgy-agents-dashboard-files' the rest fold into one line with their totals."
  (let* ((prefix jgy-agents--file-indent)
         (files (jgy-agents--files buffer))
         (root (or (jgy-agents--identity buffer 'root) default-directory))
         (rest (nthcdr jgy-agents-dashboard-files files)))
    (dolist (file (seq-take files jgy-agents-dashboard-files))
      (insert (propertize (concat prefix (jgy-agents--file-label file root) "\n")
                          'jgy-agents-buffer buffer
                          'jgy-agents-file (alist-get 'file file)
                          'jgy-agents-action (lambda () (jgy-agents--visit-file buffer file))
                          'wrap-prefix prefix)))
    (when rest
      (insert (propertize
               (concat prefix
                       (propertize (format "…+%d" (length rest)) 'face 'shadow)
                       (jgy-agents--file-counts
                        (apply #'+ (mapcar (lambda (file) (alist-get 'added file)) rest))
                        (apply #'+ (mapcar (lambda (file) (alist-get 'removed file)) rest)))
                       "\n")
               'jgy-agents-buffer buffer
               'jgy-agents-action (lambda () (jgy-agents--pick-file buffer files))
               'help-echo (mapconcat (lambda (file)
                                       (jgy-agents--file-relative (alist-get 'file file) root))
                                     files "\n")
               'wrap-prefix prefix)))))

(defun jgy-agents--dashboard-counts ()
  "A count of agents by state, like \"3 total · 1 working\"."
  (let* ((statuses (mapcar (lambda (buffer) (buffer-local-value 'jgy-agents-status buffer))
                           (jgy-agents--buffers)))
         (working (seq-count (lambda (status) (eq status 'working)) statuses))
         (attention (seq-count (lambda (status) (memq status jgy-agents-attention-statuses))
                               statuses)))
    (string-join
     (delq nil (list (format "%d total" (length statuses))
                     (and (> working 0) (format "%d working" working))
                     (and (> attention 0)
                          (propertize (format "%d need you" attention) 'face 'error))))
     " · ")))

(defun jgy-agents--dashboard-agents (tabs)
  "Insert the agents under the TABS they belong to, then those of closed tabs."
  (let ((agents (jgy-agents--buffers)))
    (cl-loop
     for tab in tabs
     for first = t then nil
     for id = (alist-get 'jgy-agents-id (cdr tab))
     for owned = (and id (seq-filter
                          (lambda (buffer)
                            (equal id (buffer-local-value 'jgy-agents--tab buffer)))
                          agents))
     do (unless first (insert "\n"))
     (insert (propertize (jgy-agents-dashboard-heading (alist-get 'name tab)
                                                   (eq (car tab) 'current-tab))
                         'jgy-agents-tab (or id (alist-get 'name tab)))
             "\n")
     (setq agents (seq-difference agents owned))
     (dolist (buffer owned)
       (jgy-agents--dashboard-line buffer (alist-get 'name tab))))
    (when agents
      (when tabs (insert "\n"))
      (insert (propertize "tab closed" 'face 'shadow 'jgy-agents-tab 'closed) "\n")
      (dolist (buffer agents)
        (jgy-agents--dashboard-line buffer)))))

(defun jgy-agents--dashboard-render ()
  "Redraw the dashboard, keeping point on the same agent."
  (when-let* ((dashboard (get-buffer jgy-agents--dashboard-name)))
    (with-current-buffer dashboard
      (let* ((window (get-buffer-window dashboard t))
             (frame (if window (window-frame window) (selected-frame)))
             (tabs (funcall tab-bar-tabs-function frame))
             ;; 光标所在的 agent 或 tab，及在它下面第几行、第几列；重画后回到原处。
             (anchor (seq-some (lambda (prop)
                                 (when-let* ((value (get-text-property (line-beginning-position)
                                                                       prop)))
                                   (cons prop value)))
                               '(jgy-agents-buffer jgy-agents-tab)))
             (offset (and anchor (count-lines (jgy-agents--dashboard-find anchor)
                                              (line-beginning-position))))
             (line (line-number-at-pos))
             (column (current-column))
             (inhibit-read-only t))
        (erase-buffer)
        (jgy-agents-dashboard-insert-section "Usage" #'jgy-agents--usage-insert)
        (jgy-agents-dashboard-insert-section "Agents" (lambda () (jgy-agents--dashboard-agents tabs)))
        (run-hook-with-args 'jgy-agents-dashboard-functions frame)
        (goto-char (point-min))
        (if-let* ((pos (and anchor (jgy-agents--dashboard-find anchor))))
            (progn
              (goto-char pos)
              (forward-line offset)
              (unless (equal (get-text-property (point) (car anchor)) (cdr anchor))
                (goto-char pos)))
          (forward-line (1- line)))
        (move-to-column column)
        (when window (set-window-point window (point)))))))

(defun jgy-agents--dashboard-find (anchor)
  "Start of the first dashboard text whose property (car ANCHOR) is (cdr ANCHOR)."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward (car anchor) (cdr anchor) t)))
      (prop-match-beginning match))))

(defun jgy-agents--dashboard-attention-p (pos)
  "Non-nil when POS starts the first line of an agent needing attention."
  (when-let* ((buffer (get-text-property pos 'jgy-agents-buffer)))
    (and (not (and (> pos (point-min))
                   (eq buffer (get-text-property (1- pos) 'jgy-agents-buffer))))
         (buffer-live-p buffer)
         (memq (buffer-local-value 'jgy-agents-status buffer)
               jgy-agents-attention-statuses))))

(defun jgy-agents--dashboard-tab-p (pos)
  "Non-nil when POS is on a tab heading."
  (get-text-property pos 'jgy-agents-tab))

(defun jgy-agents--dashboard-step (forward match what)
  "Move to the next line whose start satisfies MATCH, wrapping.
FORWARD picks the direction; WHAT names those lines when there is none."
  (let ((start (line-beginning-position))
        (pos nil))
    (save-excursion
      (catch 'found
        (dotimes (_ (count-lines (point-min) (point-max)))
          (if forward
              (when (or (/= 0 (forward-line 1)) (eobp)) (goto-char (point-min)))
            (when (/= 0 (forward-line -1)) (goto-char (point-max)) (forward-line -1)))
          (when (= (point) start) (throw 'found nil))
          (when (funcall match (point))
            (throw 'found (setq pos (point)))))))
    (if pos
        (goto-char pos)
      (message "No %s%s" (if (funcall match start) "other " "") what))))

(defun jgy-agents-dashboard-next-attention ()
  "Move to the next agent that is waiting or finished unseen."
  (interactive)
  (jgy-agents--dashboard-step t #'jgy-agents--dashboard-attention-p
                                  "agent needing attention"))

(defun jgy-agents-dashboard-previous-attention ()
  "Move to the previous agent that is waiting or finished unseen."
  (interactive)
  (jgy-agents--dashboard-step nil #'jgy-agents--dashboard-attention-p
                                  "agent needing attention"))

(defun jgy-agents-dashboard-next-tab ()
  "Move to the next tab heading."
  (interactive)
  (jgy-agents--dashboard-step t #'jgy-agents--dashboard-tab-p "tab"))

(defun jgy-agents-dashboard-previous-tab ()
  "Move to the previous tab heading."
  (interactive)
  (jgy-agents--dashboard-step nil #'jgy-agents--dashboard-tab-p "tab"))

(defun jgy-agents--dashboard-tab-target ()
  "Return the agent to visit for the tab heading on the current line."
  (save-excursion
    (let (agents)
      (while (and (zerop (forward-line 1))
                  (get-text-property (point) 'jgy-agents-buffer))
        (push (get-text-property (point) 'jgy-agents-buffer) agents))
      (setq agents (nreverse agents))
      (or (seq-find (lambda (buffer)
                      (and (buffer-live-p buffer)
                           (memq (buffer-local-value 'jgy-agents-status buffer)
                                 jgy-agents-attention-statuses)))
                    agents)
          (car agents)))))

(cl-defun jgy-agents-dashboard-visit ()
  "Switch to the agent's tab and show it there.
On a line carrying `jgy-agents-action', run that instead.  On a tab heading,
visit the first agent under it that needs attention, or else
the first one."
  (interactive)
  (when-let* ((action (get-text-property (line-beginning-position) 'jgy-agents-action)))
    (funcall action)
    (cl-return-from jgy-agents-dashboard-visit))
  (let* ((tab (jgy-agents--dashboard-tab-p (line-beginning-position)))
         (buffer (or (get-text-property (point) 'jgy-agents-buffer)
                     (and tab (jgy-agents--dashboard-tab-target)))))
    (cond (buffer (jgy-agents--visit buffer (lambda () (jgy-agents--show buffer))))
          ((stringp tab) (jgy-agents--dashboard-select-tab tab))
          (t (user-error "No agent on this line")))))

(defun jgy-agents--dashboard-select-tab (key)
  "Switch to the tab whose id, or name when it has none, is KEY.
Point stays in the dashboard, shown in that tab too."
  (let ((index (cl-position-if (lambda (tab)
                                 (equal key (or (alist-get 'jgy-agents-id (cdr tab))
                                                (alist-get 'name (cdr tab)))))
                               (funcall tab-bar-tabs-function))))
    (unless index (user-error "Tab is gone"))
    (tab-bar-select-tab (1+ index))
    (select-window (jgy-agents--dashboard-display))))

(defun jgy-agents--visit (buffer show)
  "Switch to agent BUFFER's tab and call SHOW in a regular window there."
  (unless (buffer-live-p buffer) (user-error "Agent buffer is gone"))
  (when-let* ((index (jgy-agents--tab-index buffer)))
    (tab-bar-select-tab (1+ index)))
  (when (window-parameter (selected-window) 'window-side)
    (select-window (get-mru-window nil nil t)))
  (funcall show)
  ;; 看板是当前 tab 的侧窗，跟着到新 tab 里再开一份。
  (setq jgy-agents--dashboard-shown t)
  (jgy-agents--dashboard-follow))

(defun jgy-agents-dashboard-diff ()
  "Show the uncommitted changes to the file on this line in the agent's tab.
On any other line of an agent, show those of its whole project."
  (interactive)
  (let* ((pos (line-beginning-position))
         (buffer (or (get-text-property pos 'jgy-agents-buffer)
                     (user-error "No agent on this line")))
         (file (get-text-property pos 'jgy-agents-file))
         (root (or (jgy-agents--identity buffer 'root) (user-error "Agent has no project"))))
    (jgy-agents--visit buffer
                   (lambda ()
                     ;; git 在 default-directory 里跑；文件可能在项目里嵌套的另一个仓库。
                     (let ((default-directory (if file (file-name-directory file) root)))
                       (cond ((null file) (vc-root-diff nil t))
                             ((vc-backend file) (vc-diff nil t (list (vc-backend file) (list file))))
                             (t (find-file file)
                                (message "%s is not under version control"
                                         (file-name-nondirectory file)))))))))

;;; Following diffs

(defvar jgy-agents--diff-timer nil)

(defun jgy-agents--diff-buffer-name (buffer)
  (format "*agent diff: %s*" (buffer-name buffer)))

(defun jgy-agents--diff-schedule ()
  "Update the diff windows soon, coalescing bursts of edits."
  (unless (timerp jgy-agents--diff-timer)
    (setq jgy-agents--diff-timer
          (run-with-timer 0.3 nil
                          (lambda ()
                            (setq jgy-agents--diff-timer nil)
                            (jgy-agents--diff-update))))))

(defun jgy-agents--diff-latest (old new &optional current)
  "The entry of NEW, a `files' identity, changed since OLD, or nil.
Of several, prefer the active file or CURRENT; keep an unchanged CURRENT."
  (let ((changed
         (seq-remove
          (lambda (file)
            (let ((previous (seq-find (lambda (entry)
                                        (equal (alist-get 'file entry) (alist-get 'file file))) old)))
              ;; Clearing a stale focus marker is not a content change.
              (equal (assq-delete-all 'active (copy-sequence file))
                     (assq-delete-all 'active (copy-sequence previous))))) new)))
    (or (seq-find (lambda (file) (alist-get 'active file)) changed)
        (seq-find (lambda (file) (equal (alist-get 'file file) current)) changed)
        (unless (and (> (length changed) 1)
                     (seq-find (lambda (file) (equal (alist-get 'file file) current)) new))
          (car (last changed))))))

(defun jgy-agents--diff-insert (file)
  "Insert FILE's uncommitted changes, or the whole file when git does not track it."
  ;; git 在文件所在目录里跑；文件可能在项目里嵌套的另一个仓库。
  (let ((default-directory (file-name-directory file))
        (name (file-name-nondirectory file)))
    (erase-buffer)
    (if (eq 0 (process-file "git" nil nil nil "ls-files" "--error-unmatch" "--" name))
        (process-file "git" nil t nil "diff" "--no-color" "HEAD" "--" name)
      (process-file "git" nil t nil "diff" "--no-color" "--no-index" "--" "/dev/null" name))))

(defun jgy-agents--diff-hunk (line)
  "Start of the hunk whose new side holds LINE, else of the first hunk."
  (goto-char (point-min))
  (let (first found)
    (while (and (not found)
                (re-search-forward "^@@ -[0-9,]+ \\+\\([0-9]+\\)\\(?:,\\([0-9]+\\)\\)? @@" nil t))
      (let ((start (string-to-number (match-string 1)))
            (count (if (match-string 2) (string-to-number (match-string 2)) 1)))
        (setq first (or first (match-beginning 0)))
        (when (and line (<= start line) (< line (+ start (max count 1))))
          (setq found (match-beginning 0)))))
    (or found first (point-min))))

(defun jgy-agents--diff-show (buffer file)
  "Show FILE's changes for agent BUFFER in a window of the current tab.
FILE is an entry of its `files' identity; point goes to the hunk at its line."
  (let ((diff (get-buffer-create (jgy-agents--diff-buffer-name buffer)))
        (path (alist-get 'file file)))
    (with-current-buffer diff
      (let ((inhibit-read-only t))
        (if (assq 'diff file)
            (progn
              (erase-buffer)
              (insert (or (alist-get 'diff file) ""))
              (when (zerop (buffer-size)) (insert "No net changes this turn.\n")))
          (jgy-agents--diff-insert path))
        (unless (derived-mode-p 'diff-mode) (diff-mode))
        (setq buffer-read-only t
              header-line-format (and (assq 'diff file) "This turn · file changes")
              default-directory (or (alist-get 'directory file) (file-name-directory path)))))
    (let* ((anchor (or (get-buffer-window buffer)
                       (get-mru-window nil nil t)))
           (window (display-buffer
                    diff `((display-buffer-reuse-window display-buffer-in-direction)
                           (direction . right) (window . ,anchor)
                           (inhibit-same-window . t)))))
      (when window
        (with-current-buffer diff
          (let ((pos (jgy-agents--diff-hunk (alist-get 'line file))))
            ;; 从头显示，留着文件名；改动不在第一屏时 redisplay 自己滚过去。
            (set-window-start window (point-min))
            (set-window-point window pos)))))))

(defun jgy-agents--diff-current-tab-p (buffer)
  "Non-nil when agent BUFFER's tab is the current one, or is gone."
  (let ((index (jgy-agents--tab-index buffer)))
    (or (null index) (= index (tab-bar--current-tab-index)))))

(defun jgy-agents--diff-update (&rest _)
  "Show the latest edit of each agent following its diffs.
Agents in other tabs catch up when their tab is selected."
  (dolist (buffer (jgy-agents--buffers))
    (when-let* ((state (buffer-local-value 'jgy-agents--diff-follow buffer)))
      (let* ((files (jgy-agents--files buffer))
             (latest (jgy-agents--diff-latest (plist-get state :files) files (plist-get state :file)))
             (file (or latest
                       (and (plist-get state :pending)
                            (seq-find (lambda (file)
                                        (equal (alist-get 'file file) (plist-get state :file)))
                                      files)))))
        (with-current-buffer buffer
          (setq jgy-agents--diff-follow (list :files files
                                          :file (if file (alist-get 'file file) (plist-get state :file))
                                          :pending (and file t))))
        (when (and file (jgy-agents--diff-current-tab-p buffer))
          (jgy-agents--diff-show buffer file)
          (with-current-buffer buffer
            (setq jgy-agents--diff-follow (plist-put jgy-agents--diff-follow :pending nil))))))))

(defun jgy-agents-dashboard-follow-diff ()
  "Toggle a window in the agent's tab showing the diff of the file it last wrote.
It follows each file the agent writes from then on."
  (interactive)
  (let ((buffer (or (get-text-property (line-beginning-position) 'jgy-agents-buffer)
                    (user-error "No agent on this line"))))
    (if (buffer-local-value 'jgy-agents--diff-follow buffer)
        (progn
          (with-current-buffer buffer (setq jgy-agents--diff-follow nil))
          (when-let* ((diff (get-buffer (jgy-agents--diff-buffer-name buffer))))
            (dolist (window (get-buffer-window-list diff nil t))
              (ignore-errors (delete-window window)))
            (kill-buffer diff))
          (jgy-agents--dashboard-schedule)
          (message "Stopped following %s's diffs" (buffer-name buffer)))
      (let* ((files (jgy-agents--files buffer))
             (file (or (seq-find (lambda (file) (alist-get 'active file)) files)
                       (car (last files)))))
        (with-current-buffer buffer
          (setq jgy-agents--diff-follow (list :files files)))
        (jgy-agents--dashboard-schedule)
        (if (not file)
            (message "Following %s's diffs from its next edit" (buffer-name buffer))
          (jgy-agents--visit buffer (lambda ()))
          (with-current-buffer buffer
            (setq jgy-agents--diff-follow (plist-put jgy-agents--diff-follow :file (alist-get 'file file))))
          (jgy-agents--diff-show buffer file))))))

(defun jgy-agents--visit-file (buffer file)
  "Open FILE, edited by agent BUFFER, at its line in the agent's tab."
  (jgy-agents--visit buffer
                 (lambda ()
                   (find-file (alist-get 'file file))
                   (when-let* ((line (alist-get 'line file)))
                     (goto-char (point-min))
                     (forward-line (1- line))))))

(defun jgy-agents--pick-file (buffer files)
  "Pick one of FILES edited by agent BUFFER and visit it."
  (let* ((root (or (jgy-agents--identity buffer 'root) default-directory))
         (names (mapcar (lambda (file)
                          (cons (jgy-agents--file-relative (alist-get 'file file) root) file))
                        files))
         (choice (completing-read
                  "Edited file: "
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        `(metadata (display-sort-function . identity)
                                   (annotation-function
                                    . ,(lambda (name)
                                         (let-alist (cdr (assoc name names))
                                           (jgy-agents--file-counts .added .removed)))))
                      (complete-with-action action names string pred)))
                  nil t)))
    (jgy-agents--visit-file buffer (cdr (assoc choice names)))))

(defun jgy-agents--dashboard-follow (&rest _)
  "Show the dashboard in the current tab when it is toggled on.
For `tab-bar-tab-post-select-functions' and `tab-bar-tab-post-open-functions'."
  (when (and jgy-agents--dashboard-shown
             (get-buffer jgy-agents--dashboard-name)
             (not (get-buffer-window jgy-agents--dashboard-name)))
    (jgy-agents--dashboard-display)))

(defun jgy-agents--dashboard-display ()
  "Show the dashboard in a right side window and return that window."
  (display-buffer-in-side-window
   (get-buffer jgy-agents--dashboard-name)
   `((side . right) (slot . -1) (window-width . ,jgy-agents-dashboard-width)
     (window-parameters (no-delete-other-windows . t)))))

;;;###autoload
(defun jgy-agents-dashboard ()
  "Toggle a side window listing every agent under the tab it belongs to."
  (interactive)
  (setq jgy-agents--dashboard-shown (not (get-buffer-window jgy-agents--dashboard-name)))
  (if-let* ((window (get-buffer-window jgy-agents--dashboard-name)))
      (delete-window window)
    (with-current-buffer (get-buffer-create jgy-agents--dashboard-name)
      (unless (derived-mode-p 'jgy-agents-dashboard-mode)
        (jgy-agents-dashboard-mode)))
    (jgy-agents--dashboard-render)
    (select-window (jgy-agents--dashboard-display))))

(defun jgy-agents--embark-transform (_type target)
  (cons 'buffer target))

(defvar embark-transformer-alist)
(with-eval-after-load 'embark
  (add-to-list 'embark-transformer-alist '(agent-buffer . jgy-agents--embark-transform)))

;;;###autoload
(define-minor-mode jgy-agents-mode
  "Track agent status for the dashboard and keep agents with their tab."
  :global t
  (if jgy-agents-mode
      (progn
        (advice-add 'bufferlo-buffer-list :around #'jgy-agents--filter-tab-buffers)
        (add-hook 'window-selection-change-functions #'jgy-agents--acknowledge)
        (add-hook 'window-buffer-change-functions #'jgy-agents--acknowledge)
        (add-hook 'tab-bar-tab-post-select-functions #'jgy-agents--dashboard-follow)
        (add-hook 'tab-bar-tab-post-select-functions #'jgy-agents--diff-update)
        (add-hook 'tab-bar-tab-post-open-functions #'jgy-agents--dashboard-follow)
        (unless jgy-agents--context-timer
          (setq jgy-agents--context-timer
                (run-with-timer 0 jgy-agents-context-interval
                                #'jgy-agents--context-scan))))
    (advice-remove 'bufferlo-buffer-list #'jgy-agents--filter-tab-buffers)
    (remove-hook 'window-selection-change-functions #'jgy-agents--acknowledge)
    (remove-hook 'window-buffer-change-functions #'jgy-agents--acknowledge)
    (remove-hook 'tab-bar-tab-post-select-functions #'jgy-agents--dashboard-follow)
    (remove-hook 'tab-bar-tab-post-select-functions #'jgy-agents--diff-update)
    (remove-hook 'tab-bar-tab-post-open-functions #'jgy-agents--dashboard-follow)
    (when jgy-agents--context-timer
      (cancel-timer jgy-agents--context-timer)
      (setq jgy-agents--context-timer nil))))

(provide 'jgy-agents)
;;; jgy-agents.el ends here

