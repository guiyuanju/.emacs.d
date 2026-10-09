;;; jgy-agents-dashboard.el --- Side window listing agents under their tab -*- lexical-binding: t; -*-

;;; Commentary:
;; 看板：每个 tab 一个标题，下面是它的 agent、本轮改过的文件和 brief；agent 那行写着本轮跑了多久。
;; 看板上按 d 看文件或整个项目还没提交的改动；按 D 让 agent 所在 tab 开一个 diff 窗口跟着它。
;; 分区由 `jgy-agents-dashboard-functions' 插入，按钩子深度排序：用量在上，agent 居中，待办在下。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'jgy-agents)
(require 'jgy-agents-follow)

(declare-function evil-define-key* "evil-core")

(defcustom jgy-agents-dashboard-context-warning 70
  "Context usage percentage from which the dashboard highlights an agent."
  :type 'natnum
  :group 'jgy-agents)

(defcustom jgy-agents-dashboard-attention-statuses '(waiting done)
  "Statuses that `jgy-agents-dashboard-next-attention' stops at."
  :type '(repeat symbol)
  :group 'jgy-agents)

(defcustom jgy-agents-dashboard-width 65
  "Width of the dashboard side window."
  :type 'natnum
  :group 'jgy-agents)

(defcustom jgy-agents-dashboard-files 5
  "Edited files listed under an agent before the rest fold into one line."
  :type 'natnum
  :group 'jgy-agents)

(defconst jgy-agents-dashboard-indent "   "
  "Indent of agent lines and section contents.")

(defconst jgy-agents-dashboard--file-indent "      "
  "Indent of the files under an agent, lining up with its name.")

(defconst jgy-agents-dashboard--name " *agents*"
  "Leading space keeps the dashboard out of `other-buffer' and buffer lists.")

(defvar jgy-agents-dashboard--shown nil
  "Non-nil while the dashboard is toggled on; every tab then shows it.")

(defvar jgy-agents-dashboard--timer nil)

(defvar jgy-agents-dashboard-functions nil
  "Functions inserting the dashboard's sections, in hook depth order.
Each is called with the dashboard's frame and usually inserts through
`jgy-agents-dashboard-insert-section'.  The agents themselves are at
depth 0.  A line whose text has the property `jgy-agents-action' runs
that function on visit.")

(defconst jgy-agents-dashboard--keys
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

(pcase-dolist (`(,key . ,command) jgy-agents-dashboard--keys)
  (jgy-agents-dashboard-define-key key command))

(define-derived-mode jgy-agents-dashboard-mode special-mode "Agents"
  "Agents grouped under the tab they were started in."
  (setq-local revert-buffer-function (lambda (&rest _) (jgy-agents-dashboard--render))
              truncate-lines nil
              truncate-partial-width-windows nil
              word-wrap t
              word-wrap-by-category t
              left-margin-width 1
              right-margin-width 1
              ;; mode line 和别的窗口一样，写看板名和 agent 数目。
              mode-line-format '(:eval (jgy-agents-dashboard--mode-line)))
  ;; brief 按窗口宽度截断，宽度一变就得重画。
  (add-hook 'window-size-change-functions #'jgy-agents-dashboard--resized nil t)
  (display-line-numbers-mode -1)
  (hl-line-mode 1))

(with-eval-after-load 'evil
  ;; normal state 下另加 gr 刷新。
  (evil-define-key* 'normal jgy-agents-dashboard-mode-map (kbd "gr") #'revert-buffer))

(defun jgy-agents-dashboard-live-p ()
  "Non-nil when the dashboard buffer exists."
  (and (get-buffer jgy-agents-dashboard--name) t))

(defun jgy-agents-dashboard--schedule ()
  "Re-render the dashboard soon, coalescing bursts of changes."
  (when (and (get-buffer jgy-agents-dashboard--name)
             (not (timerp jgy-agents-dashboard--timer)))
    (setq jgy-agents-dashboard--timer
          (run-with-timer 0.1 nil
                          (lambda ()
                            (setq jgy-agents-dashboard--timer nil)
                            (jgy-agents-dashboard--render))))))

(defun jgy-agents-dashboard--resized (_window)
  (jgy-agents-dashboard--schedule))

(defface jgy-agents-dashboard-section
  '((t :inherit (font-lock-keyword-face bold)))
  "Face for dashboard section titles."
  :group 'jgy-agents)

(defface jgy-agents-dashboard-waiting
  '((((background dark)) :background "#3d1c20" :extend t)
    (t :background "#fbe4e4" :extend t))
  "Face added to the dashboard line of an agent waiting for you."
  :group 'jgy-agents)

(defface jgy-agents-dashboard-done
  '((((background dark)) :background "#1b3324" :extend t)
    (t :background "#e2f5e6" :extend t))
  "Face added to the dashboard line of an agent that finished unseen."
  :group 'jgy-agents)

(defun jgy-agents-dashboard-heading (name &optional current)
  "NAME as a dashboard heading, highlighted when CURRENT."
  (propertize name 'face (if current '(success bold) 'bold)))

(defun jgy-agents-dashboard--section-title (title)
  "Line for section TITLE, carrying TITLE's text properties to its end."
  (let ((line (concat title "\n")))
    (add-face-text-property 0 (length title) 'jgy-agents-dashboard-section t line)
    ;; 在标题行哪里按 RET 都算，比如 Todo 标题上的 `jgy-agents-action'。
    (cl-loop for (prop value) on (text-properties-at 0 title) by #'cddr
             unless (eq prop 'face)
             do (put-text-property 0 (length line) prop value line))
    line))

(defun jgy-agents-dashboard--mode-line ()
  "Mode line of the dashboard: its name, then a count of agents by state."
  (concat " " (propertize "Agents" 'face 'mode-line-buffer-id)
          "   " (string-replace "%" "%%" (jgy-agents-dashboard--counts))))

(defun jgy-agents-dashboard-insert-section (title body)
  "Insert section TITLE followed by what BODY inserts.
BODY is a function of no arguments; the title is dropped when it
inserts nothing."
  (let ((start (point)))
    (unless (bobp) (insert "\n"))
    (insert (jgy-agents-dashboard--section-title title))
    (let ((after-title (point)))
      (funcall body)
      (when (= (point) after-title)
        (delete-region start (point))))))

(defun jgy-agents-dashboard--line (buffer &optional tab-name)
  "Insert the line for agent BUFFER, then the files it edited this turn.
The agent's project is named only when it differs from TAB-NAME.  Its turn
duration and context usage sit in columns at the right edge."
  (let* ((head (concat jgy-agents-dashboard-indent (jgy-agents-dashboard--glyph-cell buffer)
                       (or (jgy-agents-get buffer 'agent) "agent")
                       (if (buffer-local-value 'jgy-agents-follow--state buffer)
                           (propertize " ±" 'face `(:foreground ,(face-foreground 'diff-indicator-added nil t))
                                       'help-echo "Its diff window follows its edits")
                         "")
                       (jgy-agents-dashboard--project-label buffer tab-name)))
         (meta (jgy-agents-dashboard--meta buffer))
         (brief (jgy-agents-dashboard--brief buffer))
         (line (concat head
                       (if brief (jgy-agents-dashboard--brief-label buffer brief head (cdr meta)) "")
                       (car meta)
                       "\n"))
         (highlight (pcase (buffer-local-value 'jgy-agents-status buffer)
                      ('waiting 'jgy-agents-dashboard-waiting)
                      ('done 'jgy-agents-dashboard-done))))
    (when highlight
      (add-face-text-property (length jgy-agents-dashboard-indent) (length line) highlight t line))
    (insert (propertize line
                        'jgy-agents-buffer buffer
                        'help-echo (if brief
                                       (concat (buffer-name buffer) "\n" brief)
                                     (buffer-name buffer))
                        'wrap-prefix jgy-agents-dashboard--file-indent))
    (jgy-agents-dashboard--files buffer)))

(defun jgy-agents-dashboard--glyph-cell (buffer)
  "Status glyph of agent BUFFER padded to three columns, so names line up.
Fonts draw ◐ ○ ● two columns wide but ⚠ one."
  (let* ((glyph (jgy-agents-glyph buffer))
         (pad (- (* 3 (frame-char-width)) (string-pixel-width glyph (current-buffer)))))
    (concat glyph (propertize " " 'display `(space :width (,(max 1 pad)))))))

(defun jgy-agents-dashboard--context-label (buffer)
  "Context usage of agent BUFFER, or nil.
Highlighted from `jgy-agents-dashboard-context-warning'."
  (when-let* ((used (buffer-local-value 'jgy-agents-context buffer)))
    (propertize (format "%3d%%" used)
                'face (if (>= used jgy-agents-dashboard-context-warning) 'warning 'shadow))))

(defun jgy-agents-dashboard--turn-label (buffer)
  "How long agent BUFFER's latest turn has run, or ran, once past a minute; or nil."
  (pcase (buffer-local-value 'jgy-agents-turn buffer)
    (`(,start . ,end)
     (let ((seconds (- (or end (float-time)) start)))
       (when (>= seconds 60)
         (propertize (jgy-agents-format-duration seconds) 'face 'shadow))))))

(defun jgy-agents-dashboard--meta (buffer)
  "Turn duration and context usage of agent BUFFER, aligned to the right edge.
Returns (TEXT . COLUMNS), COLUMNS being how far from the edge TEXT starts.
Context takes the last four columns but one, left free for the wrap mark;
the duration ends a column before it, so both line up across agents."
  (let ((turn (jgy-agents-dashboard--turn-label buffer))
        (context (jgy-agents-dashboard--context-label buffer)))
    (cl-flet ((align (columns) (propertize " " 'display `(space :align-to (- right ,columns)))))
      (cons (concat (if turn (concat (align (+ 6 (string-width turn))) turn) "")
                    (if context (concat (align 5) context) ""))
            (cond (turn (+ 6 (string-width turn)))
                  (context 5)
                  (t 0))))))

(defun jgy-agents-dashboard--project-label (buffer tab-name)
  "Name of agent BUFFER's project, dimmed, unless it is TAB-NAME."
  (let* ((root (jgy-agents-get buffer 'root))
         (project (and root (file-name-nondirectory (directory-file-name root)))))
    (if (and project (not (equal project tab-name)))
        (propertize (concat " " project) 'face 'shadow)
      "")))

(defun jgy-agents-dashboard--brief (buffer)
  "What agent BUFFER says it is doing, on one line, or nil."
  (when-let* ((brief (jgy-agents-get buffer 'brief))
              (text (with-current-buffer buffer (ignore-errors (funcall brief))))
              (text (string-trim (replace-regexp-in-string "[ \t\n]+" " " text)))
              ((not (string-empty-p text))))
    text))

(defun jgy-agents-dashboard--brief-label (buffer brief head meta)
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

(defun jgy-agents-dashboard--file-relative (file root)
  "FILE relative to ROOT, or abbreviated when outside it."
  (if (string-prefix-p (file-name-as-directory (expand-file-name root)) file)
      (file-relative-name file root)
    (abbreviate-file-name file)))

(defun jgy-agents-dashboard--file-counts (added removed)
  "Return \" +ADDED −REMOVED\" in diff colors, leaving out a zero."
  (cl-flet ((count (n sign face)
              (if (> n 0)
                  (propertize (format " %s%d" sign n)
                              'face `(:foreground ,(face-foreground face nil t)))
                "")))
    (concat (count added "+" 'diff-indicator-added)
            (count removed "−" 'diff-indicator-removed))))

(defun jgy-agents-dashboard--file-label (file root)
  "FILE's name, its line counts, then its directory relative to ROOT, dimmed."
  (let-alist file
    (let ((dir (file-name-directory (jgy-agents-dashboard--file-relative .file root))))
      (concat (propertize (file-name-nondirectory .file) 'face (if .active 'warning 'default))
              (jgy-agents-dashboard--file-counts .added .removed)
              (if dir (propertize (concat " " dir) 'face 'shadow) "")))))

(defun jgy-agents-dashboard--files (buffer)
  "Insert the files agent BUFFER edited this turn, under its name.
Past `jgy-agents-dashboard-files' the rest fold into one line with their totals."
  (let* ((prefix jgy-agents-dashboard--file-indent)
         (files (jgy-agents-files buffer))
         (root (or (jgy-agents-get buffer 'root) default-directory))
         (rest (nthcdr jgy-agents-dashboard-files files)))
    (dolist (file (seq-take files jgy-agents-dashboard-files))
      (insert (propertize (concat prefix (jgy-agents-dashboard--file-label file root) "\n")
                          'jgy-agents-buffer buffer
                          'jgy-agents-file (alist-get 'file file)
                          'jgy-agents-action (lambda () (jgy-agents-dashboard--visit-file buffer file))
                          'wrap-prefix prefix)))
    (when rest
      (insert (propertize
               (concat prefix
                       (propertize (format "…+%d" (length rest)) 'face 'shadow)
                       (jgy-agents-dashboard--file-counts
                        (apply #'+ (mapcar (lambda (file) (alist-get 'added file)) rest))
                        (apply #'+ (mapcar (lambda (file) (alist-get 'removed file)) rest)))
                       "\n")
               'jgy-agents-buffer buffer
               'jgy-agents-action (lambda () (jgy-agents-dashboard--pick-file buffer files))
               'help-echo (mapconcat (lambda (file)
                                       (jgy-agents-dashboard--file-relative (alist-get 'file file) root))
                                     files "\n")
               'wrap-prefix prefix)))))

(defun jgy-agents-dashboard--counts ()
  "A count of agents by state, like \"3 total · 1 working\"."
  (let* ((statuses (mapcar (lambda (buffer) (buffer-local-value 'jgy-agents-status buffer))
                           (jgy-agents-buffers)))
         (working (seq-count (lambda (status) (eq status 'working)) statuses))
         (attention (seq-count (lambda (status) (memq status jgy-agents-dashboard-attention-statuses))
                               statuses)))
    (string-join
     (delq nil (list (format "%d total" (length statuses))
                     (and (> working 0) (format "%d working" working))
                     (and (> attention 0)
                          (propertize (format "%d need you" attention) 'face 'error))))
     " · ")))

(defun jgy-agents-dashboard--agents (tabs)
  "Insert the agents under the TABS they belong to, then those of closed tabs."
  (let ((agents (jgy-agents-buffers)))
    (cl-loop
     for tab in tabs
     for first = t then nil
     for id = (alist-get 'jgy-agents-id (cdr tab))
     for owned = (and id (seq-filter
                          (lambda (buffer)
                            (equal id (buffer-local-value 'jgy-agents-tab buffer)))
                          agents))
     do (unless first (insert "\n"))
     (insert (propertize (jgy-agents-dashboard-heading (alist-get 'name tab)
                                                   (eq (car tab) 'current-tab))
                         'jgy-agents-tab (or id (alist-get 'name tab)))
             "\n")
     (setq agents (seq-difference agents owned))
     (dolist (buffer owned)
       (jgy-agents-dashboard--line buffer (alist-get 'name tab))))
    (when agents
      (when tabs (insert "\n"))
      (insert (propertize "tab closed" 'face 'shadow 'jgy-agents-tab 'closed) "\n")
      (dolist (buffer agents)
        (jgy-agents-dashboard--line buffer)))))

(defun jgy-agents-dashboard--agents-section (frame)
  "Insert the Agents section, grouped under FRAME's tabs."
  (jgy-agents-dashboard-insert-section
   "Agents" (lambda () (jgy-agents-dashboard--agents (funcall tab-bar-tabs-function frame)))))

(defun jgy-agents-dashboard--render ()
  "Redraw the dashboard, keeping point on the same agent."
  (when-let* ((dashboard (get-buffer jgy-agents-dashboard--name)))
    (with-current-buffer dashboard
      (let* ((window (get-buffer-window dashboard t))
             (frame (if window (window-frame window) (selected-frame)))
             ;; 光标所在的 agent 或 tab，及在它下面第几行、第几列；重画后回到原处。
             (anchor (seq-some (lambda (prop)
                                 (when-let* ((value (get-text-property (line-beginning-position)
                                                                       prop)))
                                   (cons prop value)))
                               '(jgy-agents-buffer jgy-agents-tab)))
             (offset (and anchor (count-lines (jgy-agents-dashboard--find anchor)
                                              (line-beginning-position))))
             (line (line-number-at-pos))
             (column (current-column))
             (inhibit-read-only t))
        (erase-buffer)
        (run-hook-with-args 'jgy-agents-dashboard-functions frame)
        (goto-char (point-min))
        (if-let* ((pos (and anchor (jgy-agents-dashboard--find anchor))))
            (progn
              (goto-char pos)
              (forward-line offset)
              (unless (equal (get-text-property (point) (car anchor)) (cdr anchor))
                (goto-char pos)))
          (forward-line (1- line)))
        (move-to-column column)
        (when window (set-window-point window (point)))))))

(defun jgy-agents-dashboard--find (anchor)
  "Start of the first dashboard text whose property (car ANCHOR) is (cdr ANCHOR)."
  (save-excursion
    (goto-char (point-min))
    (when-let* ((match (text-property-search-forward (car anchor) (cdr anchor) t)))
      (prop-match-beginning match))))

(defun jgy-agents-dashboard--attention-p (pos)
  "Non-nil when POS starts the first line of an agent needing attention."
  (when-let* ((buffer (get-text-property pos 'jgy-agents-buffer)))
    (and (not (and (> pos (point-min))
                   (eq buffer (get-text-property (1- pos) 'jgy-agents-buffer))))
         (buffer-live-p buffer)
         (memq (buffer-local-value 'jgy-agents-status buffer)
               jgy-agents-dashboard-attention-statuses))))

(defun jgy-agents-dashboard--tab-p (pos)
  "Non-nil when POS is on a tab heading."
  (get-text-property pos 'jgy-agents-tab))

(defun jgy-agents-dashboard--step (forward match what)
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
  (jgy-agents-dashboard--step t #'jgy-agents-dashboard--attention-p
                                  "agent needing attention"))

(defun jgy-agents-dashboard-previous-attention ()
  "Move to the previous agent that is waiting or finished unseen."
  (interactive)
  (jgy-agents-dashboard--step nil #'jgy-agents-dashboard--attention-p
                                  "agent needing attention"))

(defun jgy-agents-dashboard-next-tab ()
  "Move to the next tab heading."
  (interactive)
  (jgy-agents-dashboard--step t #'jgy-agents-dashboard--tab-p "tab"))

(defun jgy-agents-dashboard-previous-tab ()
  "Move to the previous tab heading."
  (interactive)
  (jgy-agents-dashboard--step nil #'jgy-agents-dashboard--tab-p "tab"))

(defun jgy-agents-dashboard--tab-target ()
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
                                 jgy-agents-dashboard-attention-statuses)))
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
  (let* ((tab (jgy-agents-dashboard--tab-p (line-beginning-position)))
         (buffer (or (get-text-property (point) 'jgy-agents-buffer)
                     (and tab (jgy-agents-dashboard--tab-target)))))
    (cond (buffer (jgy-agents-dashboard--visit buffer (lambda () (jgy-agents-show buffer))))
          ((stringp tab) (jgy-agents-dashboard--select-tab tab))
          (t (user-error "No agent on this line")))))

(defun jgy-agents-dashboard--select-tab (key)
  "Switch to the tab whose id, or name when it has none, is KEY.
Point stays in the dashboard, shown in that tab too."
  (let ((index (cl-position-if (lambda (tab)
                                 (equal key (or (alist-get 'jgy-agents-id (cdr tab))
                                                (alist-get 'name (cdr tab)))))
                               (funcall tab-bar-tabs-function))))
    (unless index (user-error "Tab is gone"))
    (tab-bar-select-tab (1+ index))
    (select-window (jgy-agents-dashboard--display))))

(defun jgy-agents-dashboard--visit (buffer show)
  "Switch to agent BUFFER's tab and call SHOW in a regular window there."
  (unless (buffer-live-p buffer) (user-error "Agent buffer is gone"))
  (jgy-agents-select-tab buffer)
  (when (window-parameter (selected-window) 'window-side)
    (select-window (get-mru-window nil nil t)))
  (funcall show)
  ;; 看板是当前 tab 的侧窗，跟着到新 tab 里再开一份。
  (setq jgy-agents-dashboard--shown t)
  (jgy-agents-dashboard--follow))

(defun jgy-agents-dashboard-diff ()
  "Show the uncommitted changes to the file on this line in the agent's tab.
On any other line of an agent, show those of its whole project."
  (interactive)
  (let* ((pos (line-beginning-position))
         (buffer (or (get-text-property pos 'jgy-agents-buffer)
                     (user-error "No agent on this line")))
         (file (get-text-property pos 'jgy-agents-file))
         (root (or (jgy-agents-get buffer 'root) (user-error "Agent has no project"))))
    (jgy-agents-dashboard--visit buffer
                   (lambda ()
                     ;; git 在 default-directory 里跑；文件可能在项目里嵌套的另一个仓库。
                     (let ((default-directory (if file (file-name-directory file) root)))
                       (cond ((null file) (vc-root-diff nil t))
                             ((vc-backend file) (vc-diff nil t (list (vc-backend file) (list file))))
                             (t (find-file file)
                                (message "%s is not under version control"
                                         (file-name-nondirectory file)))))))))

(defun jgy-agents-dashboard-buffer-at-point ()
  "The agent on the dashboard line at point, or nil."
  (get-text-property (line-beginning-position) 'jgy-agents-buffer))

(defun jgy-agents-dashboard-follow-diff ()
  "Toggle a window in the agent's tab showing the diff of the file it last wrote.
It follows each file the agent writes from then on."
  (interactive)
  (let ((buffer (or (jgy-agents-dashboard-buffer-at-point)
                    (user-error "No agent on this line"))))
    (cond ((jgy-agents-follow-p buffer)
           (jgy-agents-follow-stop buffer)
           (message "Stopped following %s's diffs" (buffer-name buffer)))
          ((jgy-agents-follow-latest buffer)
           (jgy-agents-dashboard--visit buffer (lambda () (jgy-agents-follow-start buffer))))
          (t (jgy-agents-follow-start buffer)
             (message "Following %s's diffs from its next edit" (buffer-name buffer))))))

(defun jgy-agents-dashboard--visit-file (buffer file)
  "Open FILE, edited by agent BUFFER, at its line in the agent's tab."
  (jgy-agents-dashboard--visit buffer
                 (lambda ()
                   (find-file (alist-get 'file file))
                   (when-let* ((line (alist-get 'line file)))
                     (goto-char (point-min))
                     (forward-line (1- line))))))

(defun jgy-agents-dashboard--pick-file (buffer files)
  "Pick one of FILES edited by agent BUFFER and visit it."
  (let* ((root (or (jgy-agents-get buffer 'root) default-directory))
         (names (mapcar (lambda (file)
                          (cons (jgy-agents-dashboard--file-relative (alist-get 'file file) root) file))
                        files))
         (choice (completing-read
                  "Edited file: "
                  (lambda (string pred action)
                    (if (eq action 'metadata)
                        `(metadata (display-sort-function . identity)
                                   (annotation-function
                                    . ,(lambda (name)
                                         (let-alist (cdr (assoc name names))
                                           (jgy-agents-dashboard--file-counts .added .removed)))))
                      (complete-with-action action names string pred)))
                  nil t)))
    (jgy-agents-dashboard--visit-file buffer (cdr (assoc choice names)))))

(defun jgy-agents-dashboard--follow (&rest _)
  "Show the dashboard in the current tab when it is toggled on.
For `tab-bar-tab-post-select-functions' and `tab-bar-tab-post-open-functions'."
  (when (and jgy-agents-dashboard--shown
             (get-buffer jgy-agents-dashboard--name)
             (not (get-buffer-window jgy-agents-dashboard--name)))
    (jgy-agents-dashboard--display)))

(defun jgy-agents-dashboard--display ()
  "Show the dashboard in a right side window and return that window."
  (display-buffer-in-side-window
   (get-buffer jgy-agents-dashboard--name)
   `((side . right) (slot . -1) (window-width . ,jgy-agents-dashboard-width)
     (window-parameters (no-delete-other-windows . t)))))

;;;###autoload
(defun jgy-agents-dashboard ()
  "Toggle a side window listing every agent under the tab it belongs to."
  (interactive)
  (setq jgy-agents-dashboard--shown (not (get-buffer-window jgy-agents-dashboard--name)))
  (if-let* ((window (get-buffer-window jgy-agents-dashboard--name)))
      (delete-window window)
    (with-current-buffer (get-buffer-create jgy-agents-dashboard--name)
      (unless (derived-mode-p 'jgy-agents-dashboard-mode)
        (jgy-agents-dashboard-mode)))
    (jgy-agents-dashboard--render)
    (select-window (jgy-agents-dashboard--display))))

(defvar jgy-agents-dashboard--turn-labels nil
  "Turn durations as last drawn, to redraw when a running one ticks over.")

(defun jgy-agents-dashboard--tick ()
  "Redraw the dashboard when a turn's duration ticked over."
  (let ((labels (mapcar #'jgy-agents-dashboard--turn-label (jgy-agents-buffers))))
    (unless (equal labels jgy-agents-dashboard--turn-labels)
      (setq jgy-agents-dashboard--turn-labels labels)
      (jgy-agents-dashboard--schedule))))

(add-hook 'jgy-agents-dashboard-functions #'jgy-agents-dashboard--agents-section)
(add-hook 'jgy-agents-changed-hook #'jgy-agents-dashboard--schedule)
(add-hook 'jgy-agents-tick-hook #'jgy-agents-dashboard--tick)
(add-hook 'tab-bar-tab-post-select-functions #'jgy-agents-dashboard--follow)
(add-hook 'tab-bar-tab-post-open-functions #'jgy-agents-dashboard--follow)

(provide 'jgy-agents-dashboard)
;;; jgy-agents-dashboard.el ends here
