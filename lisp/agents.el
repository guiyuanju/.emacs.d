;;; agents.el --- Agents tracked per project and tab, with a dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;; 按项目复用 agent，按启动时的 tab 归属；`agents-mode' 跟踪状态，并让 bufferlo 只列出本 tab 的 agent。
;; 前端（Ghostel 里的 CLI、agent-shell 等）设 `agents-start-function' 来启动 agent，
;; 在其 buffer 里设 `agents-identity'，状态经 `agents-report' 上报。
;; 套餐用量（5 小时、7 天）从 bin/claude-statusline 写下的 `agents-usage-file' 读出。
;; 前端可在 identity 里给出 `files'，看板就在 agent 下面列出它本轮改过的文件；
;; 给出 `brief'，看板就在 agent 那行末尾写它正在做什么。

;;; Code:

(require 'cl-lib)
(require 'consult)
(require 'diff-mode)
(require 'project)
(require 'seq)
(require 'tab-bar)

(declare-function evil-define-key* "evil-core")


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

(defcustom agents-usage-file
  (expand-file-name "claude-usage.json" (or (getenv "XDG_CACHE_HOME") "~/.cache"))
  "File where bin/claude-statusline saves Claude's plan usage."
  :type 'file)

(defcustom agents-usage-warning 80
  "Plan usage percentage from which the dashboard highlights it."
  :type 'natnum)

(defvar agents--usage nil
  "Plan usage windows as read from `agents-usage-file'.")

(defvar agents--usage-minute nil
  "Minute the reset countdowns were last drawn in.")

;;; Buffers

(defvar-local agents-identity nil
  "Alist describing the agent in this buffer.
Keys: `kind' is `agent'; `agent' its name; `root' its directory; `insert' a
function inserting a string into its input; `context' a function returning
its context usage percentage or nil; `files' a function returning the files
it edited this turn, in the order first edited, as alists with keys `file'
\(absolute), `added', `removed', `active' (still being written) and `line';
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
whether the agent is shown in the selected window."
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

(defun agents--context-scan ()
  "Update each agent's context usage; an unknown value keeps the last one."
  (dolist (buffer (agents--buffers))
    (with-current-buffer buffer
      (let ((used (when-let* ((context (agents--identity buffer 'context)))
                    (ignore-errors (funcall context)))))
        (when (and used (not (equal used agents-context)))
          (setq agents-context used)
          (agents--dashboard-schedule)))))
  (let ((usage (ignore-errors
                 (with-temp-buffer
                   (insert-file-contents agents-usage-file)
                   (json-parse-buffer :object-type 'alist :null-object nil)))))
    (unless (and (equal usage agents--usage)
                 (or (null usage) (equal agents--usage-minute
                                         (floor (float-time) 60))))
      (setq agents--usage usage
            agents--usage-minute (floor (float-time) 60))
      (agents--dashboard-schedule))))

(defun agents--duration (seconds)
  "Format SECONDS compactly with its two largest units, like 2h10m or 3d4h."
  (let ((m (/ (max 0 (floor seconds)) 60)))
    (cond ((< m 60) (format "%dm" m))
          ((< m 1440) (format "%dh%dm" (/ m 60) (% m 60)))
          (t (format "%dd%dh" (/ m 1440) (% (/ m 60) 24))))))

(defun agents--usage-insert ()
  "Insert a labelled bar per Claude plan usage window that has not reset yet.
Each bar ends with the time left until that window resets."
  (let ((label "claude"))
    (pcase-dolist (`(,key . ,name) '((five_hour . "5h") (seven_day . "7d")))
      (let-alist (alist-get key agents--usage)
        (when (and .used_percentage
                   (or (not (numberp .resets_at)) (> .resets_at (float-time))))
          (let ((filled (min 10 (round .used_percentage 10)))
                (face (if (>= .used_percentage agents-usage-warning) 'warning 'shadow)))
            (insert (propertize (format "%-8s" label) 'face 'bold)
                    name " "
                    (propertize (make-string filled ?█) 'face face)
                    (propertize (make-string (- 10 filled) ?░) 'face 'shadow)
                    (propertize (format " %3d%%" (floor .used_percentage)) 'face face)
                    (if (numberp .resets_at)
                        (propertize (concat " " (agents--duration
                                                 (- .resets_at (float-time))))
                                    'face 'shadow)
                      "")
                    "\n")
            (setq label "")))))))

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

(defvar agents--dashboard-timer nil)

(defvar agents-dashboard-functions nil
  "Functions inserting extra sections at the end of the dashboard.
Each is called with the dashboard's frame and usually inserts through
`agents-dashboard-insert-section'.  A line whose text has the
property `agents-action' runs that function on visit.")

(defvar-keymap agents-dashboard-mode-map
  :parent special-mode-map
  "RET" #'agents-dashboard-visit
  "o" #'agents-dashboard-visit
  "C-j" #'agents-dashboard-next-tab
  "C-k" #'agents-dashboard-previous-tab
  "C-S-j" #'agents-dashboard-next-attention
  "C-S-k" #'agents-dashboard-previous-attention
  "] a" #'agents-dashboard-next-attention
  "[ a" #'agents-dashboard-previous-attention
  "q" #'agents-dashboard)

(define-derived-mode agents-dashboard-mode special-mode "Agents"
  "Agents grouped under the tab they were started in."
  (setq-local revert-buffer-function (lambda (&rest _) (agents--dashboard-render))
              truncate-lines nil
              truncate-partial-width-windows nil
              word-wrap t
              word-wrap-by-category t)
  (display-line-numbers-mode -1)
  (hl-line-mode 1))

(with-eval-after-load 'evil
  (evil-define-key* 'normal agents-dashboard-mode-map
    (kbd "RET") #'agents-dashboard-visit
    "o" #'agents-dashboard-visit
    (kbd "C-j") #'agents-dashboard-next-tab
    (kbd "C-k") #'agents-dashboard-previous-tab
    (kbd "C-S-j") #'agents-dashboard-next-attention
    (kbd "C-S-k") #'agents-dashboard-previous-attention
    "]a" #'agents-dashboard-next-attention
    "[a" #'agents-dashboard-previous-attention
    "gr" #'revert-buffer
    "q" #'agents-dashboard))

(defun agents--dashboard-schedule ()
  "Re-render the dashboard soon, coalescing bursts of changes."
  (when (and (get-buffer agents--dashboard-name)
             (not (timerp agents--dashboard-timer)))
    (setq agents--dashboard-timer
          (run-with-timer 0.1 nil
                          (lambda ()
                            (setq agents--dashboard-timer nil)
                            (agents--dashboard-render))))))

(defun agents-dashboard-refresh ()
  "Re-render the dashboard soon; for frontends whose agent changed."
  (agents--dashboard-schedule))

(defface agents-section
  '((t :inherit (font-lock-keyword-face bold) :overline t :extend t))
  "Face for dashboard section titles.")

(defun agents-dashboard-insert-section (title body)
  "Insert section TITLE followed by what BODY inserts.
BODY is a function of no arguments; the title is dropped when it inserts nothing."
  (let ((start (point)))
    (unless (bobp) (insert "\n"))
    (insert (propertize (concat title "\n") 'face 'agents-section))
    (let ((after-title (point)))
      (funcall body)
      (when (= (point) after-title)
        (delete-region start (point))))))

(defun agents--dashboard-line (buffer last &optional tab-name)
  "Insert the tree line for agent BUFFER; LAST picks the closing branch.
The agent's project is named only when it differs from TAB-NAME."
  (let* ((root (agents--identity buffer 'root))
         (project (and root (file-name-nondirectory (directory-file-name root))))
         (head (concat "  " (if last "└─ " "├─ ") (agents--glyph buffer) " "
                       (or (agents--identity buffer 'agent) "agent")
                       (if-let* ((used (buffer-local-value 'agents-context buffer)))
                           (propertize (format " %d%%" used) 'face
                                       (if (>= used agents-context-warning)
                                           'warning
                                         'shadow))
                         "")
                       (if (and project (not (equal project tab-name)))
                           (propertize (concat " " project)
                                       'face '(:inherit shadow :height 0.85))
                         "")))
         (brief (agents--brief buffer)))
    (insert (propertize (concat head
                                (if brief (agents--brief-label buffer brief head) "")
                                "\n")
                        'agents-buffer buffer
                        'help-echo (if brief
                                       (concat (buffer-name buffer) "\n" brief)
                                     (buffer-name buffer))
                        'wrap-prefix (if last "     " "  │  ")))
    (agents--dashboard-files buffer (if last "       " "  │    "))))

(defun agents--brief (buffer)
  "What agent BUFFER says it is doing, on one line, or nil."
  (when-let* ((brief (agents--identity buffer 'brief))
              (text (with-current-buffer buffer (ignore-errors (funcall brief))))
              (text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
              ((not (string-empty-p text))))
    text))

(defun agents--brief-label (buffer brief head)
  "BRIEF in small type, cut to the dashboard width left after HEAD.
Measured in pixels, as fonts draw glyphs like ◐ and … wider than
`string-width' says.  Dimmed unless agent BUFFER is working or waiting."
  (let* ((window (get-buffer-window (current-buffer) t))
         (char (frame-char-width (if window (window-frame window) (selected-frame))))
         (gap "  ")
         (face `(:inherit ,(if (memq (buffer-local-value 'agents-status buffer) '(working waiting))
                               'default
                             'shadow)
                 :height 0.85))
         (width (lambda (text)
                  (string-pixel-width (propertize text 'face face) (current-buffer))))
         ;; 留一列给折行标记；`window-max-chars-per-line' 会选中窗口，把看板的 point 拽到窗口 point。
         (room (- (if window (window-body-width window t) (* agents-dashboard-width char))
                  (string-pixel-width (concat head gap) (current-buffer))
                  char))
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

(defun agents--dashboard-files (buffer prefix)
  "Insert the files agent BUFFER edited this turn, each line starting with PREFIX.
Past `agents-dashboard-files' the rest fold into one line with their totals."
  (let* ((files (agents--files buffer))
         (root (or (agents--identity buffer 'root) default-directory))
         (rest (nthcdr agents-dashboard-files files)))
    (dolist (file (seq-take files agents-dashboard-files))
      (insert (propertize (concat prefix (agents--file-label file root) "\n")
                          'agents-buffer buffer
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

(defun agents--dashboard-mode-line ()
  "Return the dashboard mode line: its name and a count of agents by state."
  (let* ((statuses (mapcar (lambda (buffer) (buffer-local-value 'agents-status buffer))
                           (agents--buffers)))
         (working (seq-count (lambda (status) (eq status 'working)) statuses))
         (attention (seq-count (lambda (status) (memq status agents-attention-statuses))
                               statuses)))
    (list " " (propertize "Agents" 'face 'mode-line-buffer-id) "  "
          (string-join
           (delq nil (list (format "%d total" (length statuses))
                           (and (> working 0) (format "%d working" working))
                           (and (> attention 0)
                                (propertize (format "%d need you" attention) 'face 'error))))
           " · "))))

(defun agents--dashboard-render ()
  "Redraw the dashboard, keeping point on the same agent."
  (when-let* ((dashboard (get-buffer agents--dashboard-name)))
    (with-current-buffer dashboard
      (let* ((window (get-buffer-window dashboard t))
             (frame (if window (window-frame window) (selected-frame)))
             (tabs (funcall tab-bar-tabs-function frame))
             (agents (agents--buffers))
             (here (get-text-property (point) 'agents-buffer))
             (line (line-number-at-pos))
             (inhibit-read-only t))
        (erase-buffer)
        (agents-dashboard-insert-section "Usage" #'agents--usage-insert)
        (agents-dashboard-insert-section
         "Agents"
         (lambda ()
           (cl-loop
            for tab in tabs
            for first = t then nil
            for id = (alist-get 'agents-id (cdr tab))
            for owned = (and id (seq-filter
                                 (lambda (buffer)
                                   (equal id (buffer-local-value 'agents--tab buffer)))
                                 agents))
            do (unless first (insert "\n"))
            (insert (propertize (format "[%s]" (alist-get 'name tab))
                                'face (if (eq (car tab) 'current-tab) '(bold success) 'bold)
                                'agents-tab t)
                    "\n")
            (setq agents (seq-difference agents owned))
            (cl-loop for (buffer . rest) on owned
                     do (agents--dashboard-line buffer (null rest) (alist-get 'name tab))))
           (when agents
             (when tabs (insert "\n"))
             (insert (propertize "(tab closed)" 'face 'shadow 'agents-tab t) "\n")
             (cl-loop for (buffer . rest) on agents
                      do (agents--dashboard-line buffer (null rest))))))
        (run-hook-with-args 'agents-dashboard-functions frame)
        (setq mode-line-format (agents--dashboard-mode-line))
        (goto-char (point-min))
        (if-let* ((pos (and here (text-property-any (point-min) (point-max)
                                                    'agents-buffer here))))
            (goto-char pos)
          (forward-line (1- line)))
        (when window (set-window-point window (point)))))))

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
  (let ((buffer (or (get-text-property (point) 'agents-buffer)
                    (and (agents--dashboard-tab-p (line-beginning-position))
                         (agents--dashboard-tab-target))
                    (user-error (if (agents--dashboard-tab-p (line-beginning-position))
                                    "No agent in this tab"
                                  "No agent on this line")))))
    (agents--visit buffer (lambda () (agents--show buffer)))))

(defun agents--visit (buffer show)
  "Switch to agent BUFFER's tab and call SHOW in a regular window there."
  (unless (buffer-live-p buffer) (user-error "Agent buffer is gone"))
  (when-let* ((index (agents--tab-index buffer)))
    (tab-bar-select-tab (1+ index)))
  (when (window-parameter (selected-window) 'window-side)
    (select-window (get-mru-window nil nil t)))
  (funcall show)
  ;; 看板是当前 tab 的侧窗，跟着到新 tab 里再开一份。
  (unless (get-buffer-window agents--dashboard-name)
    (agents--dashboard-display)))

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
    (when agents--context-timer
      (cancel-timer agents--context-timer)
      (setq agents--context-timer nil))
    (when (boundp 'embark-transformer-alist)
      (setq embark-transformer-alist
            (assq-delete-all 'agent-buffer embark-transformer-alist)))))

(provide 'agents)
;;; agents.el ends here

