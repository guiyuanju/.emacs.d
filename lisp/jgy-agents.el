;;; jgy-agents.el --- Agents tracked per project and tab, with a dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;; 按项目复用 agent，按启动时的 tab 归属；`agents-mode' 跟踪状态，并让 bufferlo 只列出本 tab 的 agent。
;; 前端（Ghostel 里的 CLI、agent-shell 等）设 `agents-start-function' 来启动 agent，
;; 在其 buffer 里设 `agents-identity'，状态经 `agents-report' 上报。
;; 套餐用量（5 小时、7 天）由 jgy-agents-usage.el 的 `agents-usage-functions' 读出，
;; 经 `agents-usage-scan' 定期刷新。
;; 前端可在 identity 里给出 `files'，看板就在 agent 下面列出它本轮改过的文件；
;; 给出 `brief'，看板就在 agent 那行末尾写它正在做什么。
;; 看板上按 d 看文件或整个项目还没提交的改动；agent 那行写着本轮跑了多久。
;; 按 D 让 agent 所在 tab 开一个 diff 窗口，跟着它最近写的文件刷新。

;;; Code:

(require 'cl-lib)
(require 'consult)
(require 'diff-mode)
(require 'project)
(require 'seq)
(require 'subr-x)
(require 'tab-bar)

(declare-function evil-define-key* "evil-core")

(declare-function agents--usage-insert "jgy-agents-usage")
(declare-function agents-usage-scan "jgy-agents-usage")


(defgroup agents nil
  "Agents tracked per project and tab."
  :group 'tools)

(defcustom agents-names '("claude" "codex" "pi")
  "Agent names offered by `agents-start'."
  :type '(repeat string))

(defcustom agents-status-glyphs
  '((working "◐" warning)
    (waiting "⚠" error)
    (done "●" success)
    (idle "○" shadow))
  "Glyph and face for each `agents-status'."
  :type '(alist :key-type symbol :value-type (list string face)))

(defvar agents--last nil
  "Name of the agent most recently started or shown.")

(defvar-local agents-status 'idle
  "One of `working', `waiting', `done' or `idle'.
`waiting' means the agent asked for attention; `done' means it finished unseen.")
(put 'agents-status 'permanent-local t)

(defvar-local agents--tab nil
  "Id of the tab the agent was started in.")
(put 'agents--tab 'permanent-local t)

(defvar agents--tab-id-counter 0)

(defvar-local agents--turn nil
  "Times the agent's latest turn started and finished, as (START . END).
END is nil while the turn runs.")
(put 'agents--turn 'permanent-local t)

(defvar-local agents--diff-follow nil
  "Non-nil while this agent's diff window follows its edits.
It is a plist: :files the `files' identity last seen, :file the file shown,
:pending non-nil when that file changed while the agent's tab was not current.")

(defcustom agents-context-warning 70
  "Context usage percentage from which the dashboard highlights an agent."
  :type 'natnum)

(defvar-local agents-context nil
  "Percentage of the agent's context window in use, or nil when unknown.")
(put 'agents-context 'permanent-local t)

(defcustom agents-context-interval 5
  "Seconds between reads of the agents' context usage."
  :type 'number)

(defvar agents--context-timer nil)

;;; Buffers

(defvar-local agents-identity nil
  "Alist describing the agent in this buffer.
Keys: `kind' is `agent'; `agent' its name; `root' its directory; `insert' a
function inserting a string into its input; `context' a function returning
its context usage percentage or nil; `files' a function returning the files
it edited this turn, in provider edit order, as alists with keys `file'
\(absolute), `added', `removed', `active' (still being written) and `line';
`diff' may hold a cached turn patch (an empty string means no net change);
`directory' is the base directory for paths in that patch.
`brief' a function returning a line on what it is doing, or nil.")
(put 'agents-identity 'permanent-local t)

(defvar agents-identity-functions nil
  "Functions of a buffer returning its identity when `agents-identity' is unset.")

(defun agents--identity-alist (buffer)
  (or (buffer-local-value 'agents-identity buffer)
      (run-hook-with-args-until-success 'agents-identity-functions buffer)))

(defun agents-buffer-p (buffer)
  "Non-nil when BUFFER runs an agent."
  (eq (alist-get 'kind (agents--identity-alist buffer)) 'agent))

(defun agents--identity (buffer key)
  (alist-get key (agents--identity-alist buffer)))

(defun agents-project-root ()
  "Return the current project's root, or `default-directory' outside a project."
  (if-let* ((project (project-current))) (project-root project) default-directory))

(defcustom agents-root-function #'agents-project-root
  "Function returning the directory agents of the current buffer run in."
  :type 'function)

(defun agents--root ()
  (funcall agents-root-function))

(defcustom agents-start-function nil
  "Function of NAME and ROOT that starts agent NAME in ROOT and returns its buffer."
  :type 'function)


(defun agents--buffers (&optional pred)
  "Live agent buffers, restricted to those satisfying PRED when given."
  (seq-filter (lambda (buffer)
                (and (agents-buffer-p buffer)
                     (or (null pred) (funcall pred buffer))))
              (buffer-list)))

(defun agents--project-buffers (&optional name)
  "Agent buffers of the current project, restricted to agent NAME when given."
  (let ((root (expand-file-name (agents--root))))
    (agents--buffers
     (lambda (buffer)
       (and (equal (agents--identity buffer 'root) root)
            (or (null name) (equal (agents--identity buffer 'agent) name)))))))

(defun agents--current ()
  "This project's agent, preferring the last used one."
  (or (car (agents--project-buffers agents--last))
      (car (agents--project-buffers))))

(defun agents--show (buffer-or-name)
  "Select BUFFER-OR-NAME in its window, or in the selected window."
  (pop-to-buffer buffer-or-name
                 '((display-buffer-reuse-window display-buffer-same-window))))

;;; Tabs

(defun agents--tab-id ()
  "Return the stable id of the current tab, assigning one when it has none."
  (let ((tab (tab-bar--current-tab-find)))
    (or (alist-get 'agents-id (cdr tab))
        ;; 进程号入 id，desktop 恢复回来的旧 id 不会和新 id 撞车。
        (setf (alist-get 'agents-id (cdr tab))
              (format "%d-%d" (emacs-pid) (cl-incf agents--tab-id-counter))))))

(defun agents--tab-index (buffer)
  "Index of the tab BUFFER was started in, or nil when that tab is gone."
  (when-let* ((id (buffer-local-value 'agents--tab buffer)))
    (cl-position id (funcall tab-bar-tabs-function)
                 :key (lambda (tab) (alist-get 'agents-id (cdr tab)))
                 :test #'equal)))

;;; Commands

;;;###autoload
(defun agents-start (name &optional fresh)
  "Show agent NAME for the current project, starting it when needed.
With prefix arg FRESH, always start another instance."
  (interactive
   (list (completing-read "Agent: " agents-names nil t nil nil
                          agents--last)
         current-prefix-arg))
  (let* ((default-directory (agents--root))
         (buffer (and (not fresh) (car (agents--project-buffers name)))))
    (unless buffer
      (unless agents-start-function (user-error "Set `agents-start-function' first"))
      (setq buffer (funcall agents-start-function name
                            (expand-file-name default-directory)))
      (with-current-buffer buffer
        (setq agents--tab (agents--tab-id))
        (add-hook 'kill-buffer-hook #'agents--dashboard-schedule nil t))
      (agents--dashboard-schedule))
    (setq agents--last name)
    (agents--show buffer)))

;;;###autoload
(defun agents-toggle ()
  "Hide the agent in the selected window, or show this project's agent.
Prompts for an agent to start when none is running."
  (interactive)
  (cond ((agents-buffer-p (current-buffer)) (quit-window))
        ((agents--current) (agents--show (agents--current)))
        (t (call-interactively #'agents-start))))

;;;###autoload
(defun agents-switch ()
  "Pick any running agent buffer with preview, across all projects."
  (interactive)
  (let* ((names (or (mapcar #'buffer-name (agents--buffers))
                    (user-error "No agent running")))
         (buffer (get-buffer (consult--read names
                                            :prompt "Agent buffer: "
                                            :require-match t
                                            :category 'agent-buffer
                                            :sort nil
                                            :annotate (agents--annotator names)
                                            :state (consult--buffer-preview)))))
    (when-let* ((index (agents--tab-index buffer)))
      (tab-bar-select-tab (1+ index)))
    (agents--show buffer)))

;;;###autoload
(defun agents-send (&optional beg end)
  "Paste the region, or an @ reference to the file, into this project's agent."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (let* ((file (buffer-file-name (buffer-base-buffer)))
         (path (if file (file-relative-name file (agents--root)) (buffer-name)))
         (text (if beg
                   (format "%s:%d-%d\n```\n%s\n```\n" path
                           (line-number-at-pos beg) (line-number-at-pos (max beg (1- end)))
                           (buffer-substring-no-properties beg end))
                 (if file (format "@%s " path) (user-error "Buffer has no file"))))
         (buffer (or (agents--current)
                     (user-error "No agent running in this project"))))
    (deactivate-mark)
    (with-current-buffer buffer
      (funcall (or (agents--identity buffer 'insert)
                   (user-error "%s cannot receive text" (buffer-name)))
               text))
    (agents--show buffer)))

;;; Status

(defun agents--glyph (buffer)
  (let ((glyph (alist-get (buffer-local-value 'agents-status buffer)
                          agents-status-glyphs)))
    (propertize (car glyph) 'face (cadr glyph))))

(defun agents--annotator (names)
  "Annotation function for agent buffer NAMES: status, then the tab it belongs to."
  (let* ((status-col (+ 2 (apply #'max (mapcar #'string-width names))))
         (tab-col (+ status-col 12)))
    (lambda (name)
      (let* ((buffer (get-buffer name))
             (index (agents--tab-index buffer)))
        (concat (propertize " " 'display `(space :align-to ,status-col))
                (agents--glyph buffer) " "
                (symbol-name (buffer-local-value 'agents-status buffer))
                (propertize " " 'display `(space :align-to ,tab-col))
                (if index
                    (alist-get 'name (nth index (funcall tab-bar-tabs-function)))
                  (propertize "(tab closed)" 'face 'shadow)))))))

(defun agents--set-status (status)
  (unless (eq status agents-status)
    (setq agents-status status)
    (agents--dashboard-schedule)))

(defun agents--seen-p ()
  (eq (window-buffer (selected-window)) (current-buffer)))

(defun agents-report (event)
  "Update the current agent buffer's status for EVENT.
EVENT is `working', `finished' or `attention'; what it becomes depends on
whether the agent is shown in the selected window.
`working' after `finished' starts a turn, which `agents--turn' times."
  ;; 按事件而不是状态分轮：等批准时看一眼会把 waiting 清成 idle，批准后不算新一轮。
  (pcase event
    ('working (when (or (null agents--turn) (cdr agents--turn))
                (setq agents--turn (list (float-time)))))
    ('finished (when (and agents--turn (null (cdr agents--turn)))
                 (setcdr agents--turn (float-time)))))
  (pcase event
    ('finished (agents--set-status (if (agents--seen-p) 'idle 'done)))
    ('working (unless (eq agents-status 'waiting)
                (agents--set-status 'working)))
    ('attention (unless (agents--seen-p)
                  (agents--set-status 'waiting)))))

(defun agents--acknowledge (&rest _)
  "Reset `done' and `waiting' once the agent is shown in the selected window."
  ;; 切 tab 也会走到这里，借机刷新看板里的 tab 列表。
  (agents--dashboard-schedule)
  (let ((buffer (window-buffer (selected-window))))
    (when (and (agents-buffer-p buffer)
               (memq (buffer-local-value 'agents-status buffer) '(done waiting)))
      (with-current-buffer buffer (agents--set-status 'idle)))))

(defvar agents--turn-labels nil
  "Turn durations as last drawn, to redraw when a running one ticks over.")

(defun agents--context-scan ()
  "Update each agent's context usage; an unknown value keeps the last one.
Also redraws the dashboard when plan usage or a turn's duration changed."
  (let ((labels (mapcar #'agents--turn-label (agents--buffers))))
    (unless (equal labels agents--turn-labels)
      (setq agents--turn-labels labels)
      (agents--dashboard-schedule)))
  (dolist (buffer (agents--buffers))
    (with-current-buffer buffer
      (let ((used (when-let* ((context (agents--identity buffer 'context)))
                    (ignore-errors (funcall context)))))
        (when (and used (not (equal used agents-context)))
          (setq agents-context used)
          (agents--dashboard-schedule)))))
  (when (fboundp 'agents-usage-scan)
    (agents-usage-scan)))

(defun agents--duration (seconds)
  "Format SECONDS compactly with its two largest units, like 2h10m or 3d4h."
  (let ((m (/ (max 0 (floor seconds)) 60)))
    (cond ((< m 60) (format "%dm" m))
          ((< m 1440) (format "%dh%dm" (/ m 60) (% m 60)))
          (t (format "%dd%dh" (/ m 1440) (% (/ m 60) 24))))))

(defconst agents--indent "   "
  "Indent of agent lines and section contents.")

(defconst agents--file-indent "      "
  "Indent of the files under an agent, lining up with its name.")

(defun agents--filter-tab-buffers (fn &rest args)
  "Around advice for `bufferlo-buffer-list' dropping agents owned by other tabs."
  (let ((buffers (apply fn args)))
    (pcase-let ((`(,frame ,tabnum) args))
      (if (eq tabnum 'all)
          buffers
        (let* ((tabs (funcall tab-bar-tabs-function frame))
               (tab (if tabnum (nth tabnum tabs) (assq 'current-tab tabs)))
               (id (alist-get 'agents-id (cdr tab))))
          (seq-remove (lambda (buffer)
                        (and (agents-buffer-p buffer)
                             (let ((owner (buffer-local-value 'agents--tab buffer)))
                               (and owner (not (equal owner id))))))
                      buffers))))))

;;; Dashboard

(defcustom agents-attention-statuses '(waiting done)
  "Statuses that `agents-dashboard-next-attention' stops at."
  :type '(repeat symbol))

(defcustom agents-dashboard-width 65
  "Width of the dashboard side window."
  :type 'natnum)

(defcustom agents-dashboard-files 5
  "Edited files listed under an agent before the rest fold into one line."
  :type 'natnum)

(defconst agents--dashboard-name " *agents*"
  "Leading space keeps the dashboard out of `other-buffer' and buffer lists.")

(defvar agents--dashboard-shown nil
  "Non-nil while the dashboard is toggled on; every tab then shows it.")

(defvar agents--dashboard-timer nil)

(defvar agents-dashboard-functions nil
  "Functions inserting extra sections at the end of the dashboard.
Each is called with the dashboard's frame and usually inserts through
`agents-dashboard-insert-section'.  A line whose text has the
property `agents-action' runs that function on visit.")

(defconst agents--dashboard-keys
  '(("RET" . agents-dashboard-visit)
    ("o" . agents-dashboard-visit)
    ("d" . agents-dashboard-diff)
    ("D" . agents-dashboard-follow-diff)
    ("C-j" . agents-dashboard-next-tab)
    ("C-k" . agents-dashboard-previous-tab)
    ("C-S-j" . agents-dashboard-next-attention)
    ("C-S-k" . agents-dashboard-previous-attention)
    ("] a" . agents-dashboard-next-attention)
    ("[ a" . agents-dashboard-previous-attention)
    ("q" . agents-dashboard))
  "Dashboard bindings in `keymap-set' syntax, for Emacs and evil's normal state.")

(defvar-keymap agents-dashboard-mode-map
  :parent special-mode-map)

(defun agents-dashboard-define-key (key command)
  "Bind KEY, in `keymap-set' syntax, to COMMAND on the dashboard.
Binds it in evil's normal state too."
  (keymap-set agents-dashboard-mode-map key command)
  (with-eval-after-load 'evil
    (evil-define-key* 'normal agents-dashboard-mode-map (key-parse key) command)))

(pcase-dolist (`(,key . ,command) agents--dashboard-keys)
  (agents-dashboard-define-key key command))

(define-derived-mode agents-dashboard-mode special-mode "Agents"
  "Agents grouped under the tab they were started in."
  (setq-local revert-buffer-function (lambda (&rest _) (agents--dashboard-render))
              truncate-lines nil
              truncate-partial-width-windows nil
              word-wrap t
              word-wrap-by-category t
              ;; 没有左右边距，整行底色才能顶到窗口两边。
              left-margin-width 0
              right-margin-width 0
              ;; mode line 和别的窗口一样，写看板名和 agent 数目。
              mode-line-format '(:eval (agents--dashboard-mode-line)))
  ;; brief 按窗口宽度截断，宽度一变就得重画。
  (add-hook 'window-size-change-functions #'agents--dashboard-resized nil t)
  (display-line-numbers-mode -1)
  (hl-line-mode 1))

(with-eval-after-load 'evil
  ;; normal state 下另加 gr 刷新。
  (evil-define-key* 'normal agents-dashboard-mode-map (kbd "gr") #'revert-buffer))

(defun agents--dashboard-schedule ()
  "Re-render the dashboard soon, coalescing bursts of changes."
  (when (and (get-buffer agents--dashboard-name)
             (not (timerp agents--dashboard-timer)))
    (setq agents--dashboard-timer
          (run-with-timer 0.1 nil
                          (lambda ()
                            (setq agents--dashboard-timer nil)
                            (agents--dashboard-render))))))

(defun agents--dashboard-resized (_window)
  (agents--dashboard-schedule))

(defun agents-dashboard-refresh ()
  "Re-render the dashboard soon; for frontends whose agent changed."
  (agents--dashboard-schedule)
  (agents--diff-schedule))

(defface agents-section
  '((((background dark)) :inherit (font-lock-keyword-face bold)
     :background "#2f3540" :extend t)
    (t :inherit (font-lock-keyword-face bold)
       :background "#dce1e8" :extend t))
  "Face for dashboard section titles.")

(defface agents-waiting-line
  '((((background dark)) :background "#3d1c20" :extend t)
    (t :background "#fbe4e4" :extend t))
  "Face added to the dashboard line of an agent waiting for you.")

(defface agents-done-line
  '((((background dark)) :background "#1b3324" :extend t)
    (t :background "#e2f5e6" :extend t))
  "Face added to the dashboard line of an agent that finished unseen.")

(defface agents-tab-heading
  '((t :inherit shadow))
  "Face of an inactive tab heading in the agents dashboard.")

(defface agents-tab-heading-current
  '((((background dark)) :inherit bold :background "#3b4a5c" :extend t)
    (t :inherit bold :background "#ccd9e8" :extend t))
  "Face of the current tab's heading in the agents dashboard.")

(defun agents-dashboard-heading (name &optional current)
  "NAME as a dashboard heading, highlighted when CURRENT."
  (propertize name 'face (if current '(success bold) 'bold)))

(defconst agents--tab-prefix "│ "
  "Prefix of a tab heading in the agents dashboard.")

(defun agents--dashboard-columns ()
  "Columns a full-width dashboard line may fill, leaving the wrap column free."
  (let ((window (get-buffer-window (current-buffer) t)))
    (1- (if window (window-body-width window) agents-dashboard-width))))

(defun agents--pad-line (text)
  "TEXT filled with spaces to `agents--dashboard-columns'.
Lets a background cover the whole row, since `:extend' only paints the
space after the last character."
  (concat text (make-string (max 0 (- (agents--dashboard-columns) (string-width text))) ?\s)))

(defun agents--tab-heading (text current)
  "TEXT prefixed as a tab heading, filled and banded when CURRENT."
  (let ((heading (agents--pad-line (concat agents--tab-prefix text))))
    (add-face-text-property 0 (length heading)
                            (if current 'agents-tab-heading-current 'agents-tab-heading)
                            t heading)
    heading))

(defun agents--section-title (title)
  "Line for section TITLE, filled to the window, keeping TITLE's properties."
  (let ((line (concat (agents--pad-line title) "\n")))
    (add-face-text-property 0 (1- (length line)) 'agents-section t line)
    ;; 在标题行哪里按 RET 都算，比如 Todo 标题上的 `agents-action'。
    (cl-loop for (prop value) on (text-properties-at 0 title) by #'cddr
             unless (eq prop 'face)
             do (put-text-property 0 (length line) prop value line))
    line))

(defun agents--dashboard-mode-line ()
  "Mode line of the dashboard: its name, then a count of agents by state."
  (concat " " (propertize "Agents" 'face 'mode-line-buffer-id)
          "   " (string-replace "%" "%%" (agents--dashboard-counts))))

(defun agents-dashboard-insert-section (title body)
  "Insert section TITLE followed by what BODY inserts.
BODY is a function of no arguments; the title is dropped when it
inserts nothing."
  (let ((start (point)))
    (unless (bobp) (insert "\n"))
    (insert (agents--section-title title))
    (let ((after-title (point)))
      (funcall body)
      (when (= (point) after-title)
        (delete-region start (point))))))

(defun agents--dashboard-line (buffer &optional tab-name)
  "Insert the line for agent BUFFER, then the files it edited this turn.
The agent's project is named only when it differs from TAB-NAME.  Its turn
duration and context usage sit in columns at the right edge."
  (let* ((head (concat agents--indent (agents--glyph-cell buffer)
                       (or (agents--identity buffer 'agent) "agent")
                       (if (buffer-local-value 'agents--diff-follow buffer)
                           (propertize " ±" 'face `(:foreground ,(face-foreground 'diff-indicator-added nil t))
                                       'help-echo "Its diff window follows its edits")
                         "")
                       (agents--project-label buffer tab-name)))
         (meta (agents--meta buffer))
         (brief (agents--brief buffer))
         (line (concat head
                       (if brief (agents--brief-label buffer brief head (cdr meta)) "")
                       (car meta)
                       "\n"))
         (highlight (pcase (buffer-local-value 'agents-status buffer)
                      ('waiting 'agents-waiting-line)
                      ('done 'agents-done-line))))
    (when highlight
      (add-face-text-property (length agents--indent) (length line) highlight t line))
    (insert (propertize line
                        'agents-buffer buffer
                        'help-echo (if brief
                                       (concat (buffer-name buffer) "\n" brief)
                                     (buffer-name buffer))
                        'wrap-prefix agents--file-indent))
    (agents--dashboard-files buffer)))

(defun agents--glyph-cell (buffer)
  "Status glyph of agent BUFFER padded to three columns, so names line up.
Fonts draw ◐ ○ ● two columns wide but ⚠ one."
  (let* ((glyph (agents--glyph buffer))
         (pad (- (* 3 (frame-char-width)) (string-pixel-width glyph (current-buffer)))))
    (concat glyph (propertize " " 'display `(space :width (,(max 1 pad)))))))

(defun agents--context-label (buffer)
  "Context usage of agent BUFFER, or nil.
Highlighted from `agents-context-warning'."
  (when-let* ((used (buffer-local-value 'agents-context buffer)))
    (propertize (format "%3d%%" used)
                'face (if (>= used agents-context-warning) 'warning 'shadow))))

(defun agents--turn-label (buffer)
  "How long agent BUFFER's latest turn has run, or ran, once past a minute; or nil."
  (pcase (buffer-local-value 'agents--turn buffer)
    (`(,start . ,end)
     (let ((seconds (- (or end (float-time)) start)))
       (when (>= seconds 60)
         (propertize (agents--duration seconds) 'face 'shadow))))))

(defun agents--meta (buffer)
  "Turn duration and context usage of agent BUFFER, aligned to the right edge.
Returns (TEXT . COLUMNS), COLUMNS being how far from the edge TEXT starts.
Context takes the last four columns but one, left free for the wrap mark;
the duration ends a column before it, so both line up across agents."
  (let ((turn (agents--turn-label buffer))
        (context (agents--context-label buffer)))
    (cl-flet ((align (columns) (propertize " " 'display `(space :align-to (- right ,columns)))))
      (cons (concat (if turn (concat (align (+ 6 (string-width turn))) turn) "")
                    (if context (concat (align 5) context) ""))
            (cond (turn (+ 6 (string-width turn)))
                  (context 5)
                  (t 0))))))

(defun agents--project-label (buffer tab-name)
  "Name of agent BUFFER's project, dimmed, unless it is TAB-NAME."
  (let* ((root (agents--identity buffer 'root))
         (project (and root (file-name-nondirectory (directory-file-name root)))))
    (if (and project (not (equal project tab-name)))
        (propertize (concat " " project) 'face 'shadow)
      "")))

(defun agents--brief (buffer)
  "What agent BUFFER says it is doing, on one line, or nil."
  (when-let* ((brief (agents--identity buffer 'brief))
              (text (with-current-buffer buffer (ignore-errors (funcall brief))))
              (text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
              ((not (string-empty-p text))))
    text))

(defun agents--brief-label (buffer brief head meta)
  "BRIEF cut to the dashboard width between HEAD and META.
META is how many columns the right-aligned text after it takes.  Measured
in pixels, as fonts draw glyphs like ◐ and … wider than `string-width'
says.  Highlighted while agent BUFFER waits, set apart from its name
while it works, dimmed otherwise."
  (let* ((window (get-buffer-window (current-buffer) t))
         (char (frame-char-width (if window (window-frame window) (selected-frame))))
         (gap "  ")
         (face (pcase (buffer-local-value 'agents-status buffer)
                 ('waiting 'warning)
                 ;; 和 agent 名字区分开，像补全候选后面的注解。
                 ('working 'font-lock-doc-face)
                 (_ 'shadow)))
         (width (lambda (text)
                  (string-pixel-width (propertize text 'face face) (current-buffer))))
         ;; 右边的对齐文字前空一列，没有时也留一列给折行标记；
         ;; `window-max-chars-per-line' 会选中窗口，把看板的 point 拽到窗口 point。
         (room (- (if window (window-body-width window t) (* agents-dashboard-width char))
                  (string-pixel-width (concat head gap) (current-buffer))
                  (* (1+ meta) char)))
         (text (truncate-string-to-width brief (/ room (max 1 (funcall width "x")))
                                         nil nil "…")))
    (while (and (> (string-width text) 1) (> (funcall width text) room))
      (setq text (truncate-string-to-width brief (1- (string-width text)) nil nil "…")))
    (if (< room (* 4 char))
        ""
      (concat gap (propertize text 'face face)))))

(defun agents--files (buffer)
  "Files agent BUFFER edited this turn, as its `files' identity returns them."
  (when-let* ((files (agents--identity buffer 'files)))
    (with-current-buffer buffer (ignore-errors (funcall files)))))

(defun agents--file-relative (file root)
  "FILE relative to ROOT, or abbreviated when outside it."
  (if (string-prefix-p (file-name-as-directory (expand-file-name root)) file)
      (file-relative-name file root)
    (abbreviate-file-name file)))

(defun agents--file-counts (added removed)
  "Return \" +ADDED −REMOVED\" in diff colors, leaving out a zero."
  (cl-flet ((count (n sign face)
              (if (> n 0)
                  (propertize (format " %s%d" sign n)
                              'face `(:foreground ,(face-foreground face nil t)))
                "")))
    (concat (count added "+" 'diff-indicator-added)
            (count removed "−" 'diff-indicator-removed))))

(defun agents--file-label (file root)
  "FILE's name, its line counts, then its directory relative to ROOT, dimmed."
  (let-alist file
    (let ((dir (file-name-directory (agents--file-relative .file root))))
      (concat (propertize (file-name-nondirectory .file) 'face (if .active 'warning 'default))
              (agents--file-counts .added .removed)
              (if dir (propertize (concat " " dir) 'face 'shadow) "")))))

(defun agents--dashboard-files (buffer)
  "Insert the files agent BUFFER edited this turn, under its name.
Past `agents-dashboard-files' the rest fold into one line with their totals."
  (let* ((prefix agents--file-indent)
         (files (agents--files buffer))
         (root (or (agents--identity buffer 'root) default-directory))
         (rest (nthcdr agents-dashboard-files files)))
    (dolist (file (seq-take files agents-dashboard-files))
      (insert (propertize (concat prefix (agents--file-label file root) "\n")
                          'agents-buffer buffer
                          'agents-file (alist-get 'file file)
                          'agents-action (lambda () (agents--visit-file buffer file))
                          'wrap-prefix prefix)))
    (when rest
      (insert (propertize
               (concat prefix
                       (propertize (format "…+%d" (length rest)) 'face 'shadow)
                       (agents--file-counts
                        (apply #'+ (mapcar (lambda (file) (alist-get 'added file)) rest))
                        (apply #'+ (mapcar (lambda (file) (alist-get 'removed file)) rest)))
                       "\n")
               'agents-buffer buffer
               'agents-action (lambda () (agents--pick-file buffer files))
               'help-echo (mapconcat (lambda (file)
                                       (agents--file-relative (alist-get 'file file) root))
                                     files "\n")
               'wrap-prefix prefix)))))

(defun agents--dashboard-counts ()
  "A count of agents by state, like \"3 total · 1 working\"."
  (let* ((statuses (mapcar (lambda (buffer) (buffer-local-value 'agents-status buffer))
                           (agents--buffers)))
         (working (seq-count (lambda (status) (eq status 'working)) statuses))
         (attention (seq-count (lambda (status) (memq status agents-attention-statuses))
                               statuses)))
    (string-join
     (delq nil (list (format "%d total" (length statuses))
                     (and (> working 0) (format "%d working" working))
                     (and (> attention 0)
                          (propertize (format "%d need you" attention) 'face 'error))))
     " · ")))

(defun agents--dashboard-agents (tabs)
  "Insert the agents under the TABS they belong to, then those of closed tabs."
  (let ((agents (agents--buffers)))
    (cl-loop
     for tab in tabs
     for first = t then nil
     for id = (alist-get 'agents-id (cdr tab))
     for owned = (and id (seq-filter
                          (lambda (buffer)
                            (equal id (buffer-local-value 'agents--tab buffer)))
                          agents))
     do (unless first (insert "\n"))
     (insert (propertize (agents--tab-heading (alist-get 'name tab)
                                              (eq (car tab) 'current-tab))
                         'agents-tab (or id (alist-get 'name tab)))
             "\n")
     (setq agents (seq-difference agents owned))
     (dolist (buffer owned)
       (agents--dashboard-line buffer (alist-get 'name tab))))
    (when agents
      (when tabs (insert "\n"))
      (insert (propertize (agents--tab-heading "tab closed" nil)
                          'agents-tab 'closed)
              "\n")
      (dolist (buffer agents)
        (agents--dashboard-line buffer)))))

(defun agents--dashboard-render ()
  "Redraw the dashboard, keeping point on the same agent."
  (when-let* ((dashboard (get-buffer agents--dashboard-name)))
    (with-current-buffer dashboard
      (let* ((window (get-buffer-window dashboard t))
             (frame (if window (window-frame window) (selected-frame)))
             (tabs (funcall tab-bar-tabs-function frame))
             ;; 光标所在的 agent 或 tab，及在它下面第几行、第几列；重画后回到原处。
             (anchor (seq-some (lambda (prop)
                                 (when-let* ((value (get-text-property (line-beginning-position)
                                                                       prop)))
                                   (cons prop value)))
                               '(agents-buffer agents-tab)))
             (offset (and anchor (count-lines (agents--dashboard-find anchor)
                                              (line-beginning-position))))
             (line (line-number-at-pos))
             (column (current-column))
             (inhibit-read-only t))
        (erase-buffer)
        (agents-dashboard-insert-section "Usage" #'agents--usage-insert)
        (agents-dashboard-insert-section "Agents" (lambda () (agents--dashboard-agents tabs)))
        (run-hook-with-args 'agents-dashboard-functions frame)
        (goto-char (point-min))
        (if-let* ((pos (and anchor (agents--dashboard-find anchor))))
            (progn
              (goto-char pos)
              (forward-line offset)
              (unless (equal (get-text-property (point) (car anchor)) (cdr anchor))
                (goto-char pos)))
          (forward-line (1- line)))
        (move-to-column column)
        (when window (set-window-point window (point)))))))

(defun agents--dashboard-find (anchor)
  "Start of the first dashboard text whose property (car ANCHOR) is (cdr ANCHOR)."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward (car anchor) (cdr anchor) t)))
      (prop-match-beginning match))))

(defun agents--dashboard-attention-p (pos)
  "Non-nil when POS starts the first line of an agent needing attention."
  (when-let* ((buffer (get-text-property pos 'agents-buffer)))
    (and (not (and (> pos (point-min))
                   (eq buffer (get-text-property (1- pos) 'agents-buffer))))
         (buffer-live-p buffer)
         (memq (buffer-local-value 'agents-status buffer)
               agents-attention-statuses))))

(defun agents--dashboard-tab-p (pos)
  "Non-nil when POS is on a tab heading."
  (get-text-property pos 'agents-tab))

(defun agents--dashboard-step (forward match what)
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

(defun agents-dashboard-next-attention ()
  "Move to the next agent that is waiting or finished unseen."
  (interactive)
  (agents--dashboard-step t #'agents--dashboard-attention-p
                                  "agent needing attention"))

(defun agents-dashboard-previous-attention ()
  "Move to the previous agent that is waiting or finished unseen."
  (interactive)
  (agents--dashboard-step nil #'agents--dashboard-attention-p
                                  "agent needing attention"))

(defun agents-dashboard-next-tab ()
  "Move to the next tab heading."
  (interactive)
  (agents--dashboard-step t #'agents--dashboard-tab-p "tab"))

(defun agents-dashboard-previous-tab ()
  "Move to the previous tab heading."
  (interactive)
  (agents--dashboard-step nil #'agents--dashboard-tab-p "tab"))

(defun agents--dashboard-tab-target ()
  "Return the agent to visit for the tab heading on the current line."
  (save-excursion
    (let (agents)
      (while (and (zerop (forward-line 1))
                  (get-text-property (point) 'agents-buffer))
        (push (get-text-property (point) 'agents-buffer) agents))
      (setq agents (nreverse agents))
      (or (seq-find (lambda (buffer)
                      (and (buffer-live-p buffer)
                           (memq (buffer-local-value 'agents-status buffer)
                                 agents-attention-statuses)))
                    agents)
          (car agents)))))

(cl-defun agents-dashboard-visit ()
  "Switch to the agent's tab and show it there.
On a line carrying `agents-action', run that instead.  On a tab heading,
visit the first agent under it that needs attention, or else
the first one."
  (interactive)
  (when-let* ((action (get-text-property (line-beginning-position) 'agents-action)))
    (funcall action)
    (cl-return-from agents-dashboard-visit))
  (let* ((tab (agents--dashboard-tab-p (line-beginning-position)))
         (buffer (or (get-text-property (point) 'agents-buffer)
                     (and tab (agents--dashboard-tab-target)))))
    (cond (buffer (agents--visit buffer (lambda () (agents--show buffer))))
          ((stringp tab) (agents--dashboard-select-tab tab))
          (t (user-error "No agent on this line")))))

(defun agents--dashboard-select-tab (key)
  "Switch to the tab whose id, or name when it has none, is KEY.
Point stays in the dashboard, shown in that tab too."
  (let ((index (cl-position-if (lambda (tab)
                                 (equal key (or (alist-get 'agents-id (cdr tab))
                                                (alist-get 'name (cdr tab)))))
                               (funcall tab-bar-tabs-function))))
    (unless index (user-error "Tab is gone"))
    (tab-bar-select-tab (1+ index))
    (select-window (agents--dashboard-display))))

(defun agents--visit (buffer show)
  "Switch to agent BUFFER's tab and call SHOW in a regular window there."
  (unless (buffer-live-p buffer) (user-error "Agent buffer is gone"))
  (when-let* ((index (agents--tab-index buffer)))
    (tab-bar-select-tab (1+ index)))
  (when (window-parameter (selected-window) 'window-side)
    (select-window (get-mru-window nil nil t)))
  (funcall show)
  ;; 看板是当前 tab 的侧窗，跟着到新 tab 里再开一份。
  (setq agents--dashboard-shown t)
  (agents--dashboard-follow))

(defun agents-dashboard-diff ()
  "Show the uncommitted changes to the file on this line in the agent's tab.
On any other line of an agent, show those of its whole project."
  (interactive)
  (let* ((pos (line-beginning-position))
         (buffer (or (get-text-property pos 'agents-buffer)
                     (user-error "No agent on this line")))
         (file (get-text-property pos 'agents-file))
         (root (or (agents--identity buffer 'root) (user-error "Agent has no project"))))
    (agents--visit buffer
                   (lambda ()
                     ;; git 在 default-directory 里跑；文件可能在项目里嵌套的另一个仓库。
                     (let ((default-directory (if file (file-name-directory file) root)))
                       (cond ((null file) (vc-root-diff nil t))
                             ((vc-backend file) (vc-diff nil t (list (vc-backend file) (list file))))
                             (t (find-file file)
                                (message "%s is not under version control"
                                         (file-name-nondirectory file)))))))))

;;; Following diffs

(defvar agents--diff-timer nil)

(defun agents--diff-buffer-name (buffer)
  (format "*agent diff: %s*" (buffer-name buffer)))

(defun agents--diff-schedule ()
  "Update the diff windows soon, coalescing bursts of edits."
  (unless (timerp agents--diff-timer)
    (setq agents--diff-timer
          (run-with-timer 0.3 nil
                          (lambda ()
                            (setq agents--diff-timer nil)
                            (agents--diff-update))))))

(defun agents--diff-latest (old new &optional current)
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

(defun agents--diff-insert (file)
  "Insert FILE's uncommitted changes, or the whole file when git does not track it."
  ;; git 在文件所在目录里跑；文件可能在项目里嵌套的另一个仓库。
  (let ((default-directory (file-name-directory file))
        (name (file-name-nondirectory file)))
    (erase-buffer)
    (if (eq 0 (process-file "git" nil nil nil "ls-files" "--error-unmatch" "--" name))
        (process-file "git" nil t nil "diff" "--no-color" "HEAD" "--" name)
      (process-file "git" nil t nil "diff" "--no-color" "--no-index" "--" "/dev/null" name))))

(defun agents--diff-hunk (line)
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

(defun agents--diff-show (buffer file)
  "Show FILE's changes for agent BUFFER in a window of the current tab.
FILE is an entry of its `files' identity; point goes to the hunk at its line."
  (let ((diff (get-buffer-create (agents--diff-buffer-name buffer)))
        (path (alist-get 'file file)))
    (with-current-buffer diff
      (let ((inhibit-read-only t))
        (if (assq 'diff file)
            (progn
              (erase-buffer)
              (insert (or (alist-get 'diff file) ""))
              (when (zerop (buffer-size)) (insert "No net changes this turn.\n")))
          (agents--diff-insert path))
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
          (let ((pos (agents--diff-hunk (alist-get 'line file))))
            ;; 从头显示，留着文件名；改动不在第一屏时 redisplay 自己滚过去。
            (set-window-start window (point-min))
            (set-window-point window pos)))))))

(defun agents--diff-current-tab-p (buffer)
  "Non-nil when agent BUFFER's tab is the current one, or is gone."
  (let ((index (agents--tab-index buffer)))
    (or (null index) (= index (tab-bar--current-tab-index)))))

(defun agents--diff-update (&rest _)
  "Show the latest edit of each agent following its diffs.
Agents in other tabs catch up when their tab is selected."
  (dolist (buffer (agents--buffers))
    (when-let* ((state (buffer-local-value 'agents--diff-follow buffer)))
      (let* ((files (agents--files buffer))
             (latest (agents--diff-latest (plist-get state :files) files (plist-get state :file)))
             (file (or latest
                       (and (plist-get state :pending)
                            (seq-find (lambda (file)
                                        (equal (alist-get 'file file) (plist-get state :file)))
                                      files)))))
        (with-current-buffer buffer
          (setq agents--diff-follow (list :files files
                                          :file (if file (alist-get 'file file) (plist-get state :file))
                                          :pending (and file t))))
        (when (and file (agents--diff-current-tab-p buffer))
          (agents--diff-show buffer file)
          (with-current-buffer buffer
            (setq agents--diff-follow (plist-put agents--diff-follow :pending nil))))))))

(defun agents-dashboard-follow-diff ()
  "Toggle a window in the agent's tab showing the diff of the file it last wrote.
It follows each file the agent writes from then on."
  (interactive)
  (let ((buffer (or (get-text-property (line-beginning-position) 'agents-buffer)
                    (user-error "No agent on this line"))))
    (if (buffer-local-value 'agents--diff-follow buffer)
        (progn
          (with-current-buffer buffer (setq agents--diff-follow nil))
          (when-let* ((diff (get-buffer (agents--diff-buffer-name buffer))))
            (dolist (window (get-buffer-window-list diff nil t))
              (ignore-errors (delete-window window)))
            (kill-buffer diff))
          (agents--dashboard-schedule)
          (message "Stopped following %s's diffs" (buffer-name buffer)))
      (let* ((files (agents--files buffer))
             (file (or (seq-find (lambda (file) (alist-get 'active file)) files)
                       (car (last files)))))
        (with-current-buffer buffer
          (setq agents--diff-follow (list :files files)))
        (agents--dashboard-schedule)
        (if (not file)
            (message "Following %s's diffs from its next edit" (buffer-name buffer))
          (agents--visit buffer (lambda ()))
          (with-current-buffer buffer
            (setq agents--diff-follow (plist-put agents--diff-follow :file (alist-get 'file file))))
          (agents--diff-show buffer file))))))

(defun agents--visit-file (buffer file)
  "Open FILE, edited by agent BUFFER, at its line in the agent's tab."
  (agents--visit buffer
                 (lambda ()
                   (find-file (alist-get 'file file))
                   (when-let* ((line (alist-get 'line file)))
                     (goto-char (point-min))
                     (forward-line (1- line))))))

(defun agents--pick-file (buffer files)
  "Pick one of FILES edited by agent BUFFER and visit it."
  (let* ((root (or (agents--identity buffer 'root) default-directory))
         (names (mapcar (lambda (file)
                          (cons (agents--file-relative (alist-get 'file file) root) file))
                        files))
         (choice (completing-read
                  "Edited file: "
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        `(metadata (display-sort-function . identity)
                                   (annotation-function
                                    . ,(lambda (name)
                                         (let-alist (cdr (assoc name names))
                                           (agents--file-counts .added .removed)))))
                      (complete-with-action action names string pred)))
                  nil t)))
    (agents--visit-file buffer (cdr (assoc choice names)))))

(defun agents--dashboard-follow (&rest _)
  "Show the dashboard in the current tab when it is toggled on.
For `tab-bar-tab-post-select-functions' and `tab-bar-tab-post-open-functions'."
  (when (and agents--dashboard-shown
             (get-buffer agents--dashboard-name)
             (not (get-buffer-window agents--dashboard-name)))
    (agents--dashboard-display)))

(defun agents--dashboard-display ()
  "Show the dashboard in a right side window and return that window."
  (display-buffer-in-side-window
   (get-buffer agents--dashboard-name)
   `((side . right) (slot . -1) (window-width . ,agents-dashboard-width)
     (window-parameters (no-delete-other-windows . t)))))

;;;###autoload
(defun agents-dashboard ()
  "Toggle a side window listing every agent under the tab it belongs to."
  (interactive)
  (setq agents--dashboard-shown (not (get-buffer-window agents--dashboard-name)))
  (if-let* ((window (get-buffer-window agents--dashboard-name)))
      (delete-window window)
    (with-current-buffer (get-buffer-create agents--dashboard-name)
      (unless (derived-mode-p 'agents-dashboard-mode)
        (agents-dashboard-mode)))
    (agents--dashboard-render)
    (select-window (agents--dashboard-display))))

(defun agents--embark-transform (_type target)
  (cons 'buffer target))

;;;###autoload
(define-minor-mode agents-mode
  "Track agent status for the dashboard and keep agents with their tab."
  :global t
  (if agents-mode
      (progn
        (advice-add 'bufferlo-buffer-list :around #'agents--filter-tab-buffers)
        (add-hook 'window-selection-change-functions #'agents--acknowledge)
        (add-hook 'window-buffer-change-functions #'agents--acknowledge)
        (add-hook 'tab-bar-tab-post-select-functions #'agents--dashboard-follow)
        (add-hook 'tab-bar-tab-post-select-functions #'agents--diff-update)
        (add-hook 'tab-bar-tab-post-open-functions #'agents--dashboard-follow)
        (unless agents--context-timer
          (setq agents--context-timer
                (run-with-timer 0 agents-context-interval
                                #'agents--context-scan)))
        (with-eval-after-load 'embark
          (defvar embark-transformer-alist)
          (add-to-list 'embark-transformer-alist
                       '(agent-buffer . agents--embark-transform))))
    (advice-remove 'bufferlo-buffer-list #'agents--filter-tab-buffers)
    (remove-hook 'window-selection-change-functions #'agents--acknowledge)
    (remove-hook 'window-buffer-change-functions #'agents--acknowledge)
    (remove-hook 'tab-bar-tab-post-select-functions #'agents--dashboard-follow)
    (remove-hook 'tab-bar-tab-post-select-functions #'agents--diff-update)
    (remove-hook 'tab-bar-tab-post-open-functions #'agents--dashboard-follow)
    (when agents--context-timer
      (cancel-timer agents--context-timer)
      (setq agents--context-timer nil))
    (when (boundp 'embark-transformer-alist)
      (setq embark-transformer-alist
            (assq-delete-all 'agent-buffer embark-transformer-alist)))))

(provide 'jgy-agents)
;;; jgy-agents.el ends here

