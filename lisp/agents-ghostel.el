;;; agents-ghostel.el --- Agent CLIs in Ghostel for agents.el -*- lexical-binding: t; -*-

;;; Commentary:
;; 在 Ghostel 终端里跑 claude、codex、pi 等 agent CLI。
;; 状态来自 CLI 自己发出的 OSC 9;4 进度和 OSC 9/777 通知；
;; Pi 需要在 ~/.pi/agent/settings.json 里打开 terminal.showTerminalProgress。
;; 上下文用量从 Claude Code 状态栏（bin/claude-statusline）里的 "ctx N%" 读出。

;;; Code:

(require 'agents)
(require 'ghostel)

(declare-function evil-ghostel--terminal-live-p "evil-ghostel")
(declare-function evil-local-set-key "evil-core")
(defvar evil-ghostel--escape-mode)

(defcustom agents-ghostel-programs
  '(("claude" "claude")
    ("codex" "codex")
    ("pi" "pi"))
  "Agent name to the argv of its CLI."
  :group 'agents
  :type '(alist :key-type string :value-type (repeat string)))

(defun agents-ghostel--evil-prompt-active-p (orig)
  "Let `evil-ghostel' edit an agent's input although the CLI runs fullscreen.
ORIG is `evil-ghostel--prompt-active-p'."
  (or (funcall orig)
      (and (agents-buffer-p (current-buffer))
           (evil-ghostel--terminal-live-p))))

(defun agents-ghostel--evil-stay-on-row (args)
  "Keep `evil-ghostel' cursor moves in an agent within the input on the cursor row.
Up/down would recall history, and left from the input start opens Claude's
agent list.  ARGS is the target position, as a list."
  (cond
   ((not (agents-buffer-p (current-buffer))) args)
   ((not (ghostel-point-on-cursor-row-p (car args))) (list (ghostel-cursor-point)))
   (t (list (max (car args) (or (ghostel-input-start-point) (car args)))))))

(with-eval-after-load 'evil-ghostel
  (advice-add 'evil-ghostel--prompt-active-p :around
              #'agents-ghostel--evil-prompt-active-p)
  (advice-add 'evil-ghostel-goto-input-position :filter-args
              #'agents-ghostel--evil-stay-on-row))

(defun agents-ghostel--scroll (key mods fallback)
  "Send KEY with MODS so a full-screen agent scrolls its transcript.
Without the alternate screen the history is in the buffer, so call FALLBACK."
  (if (ghostel-alt-screen-p)
      (ghostel-send-key key mods)
    (call-interactively fallback)))

(defun agents-ghostel-scroll-page-up ()
  "Scroll the agent's transcript up a page."
  (interactive)
  (agents-ghostel--scroll "prior" nil 'evil-scroll-up))

(defun agents-ghostel-scroll-page-down ()
  "Scroll the agent's transcript down a page."
  (interactive)
  (agents-ghostel--scroll "next" nil 'evil-scroll-down))

(defun agents-ghostel-scroll-top ()
  "Scroll to the start of the agent's transcript."
  (interactive)
  (agents-ghostel--scroll "home" "ctrl" 'evil-goto-first-line))

(defun agents-ghostel-scroll-bottom ()
  "Scroll to the end of the agent's transcript."
  (interactive)
  (agents-ghostel--scroll "end" "ctrl" 'evil-goto-line))

(defun agents-ghostel--setup-evil ()
  "Send insert-state ESC to the agent, and let normal-state scroll keys reach it."
  (when (bound-and-true-p evil-ghostel-mode)
    (setq evil-ghostel--escape-mode 'terminal)
    (evil-local-set-key 'normal (kbd "C-u") #'agents-ghostel-scroll-page-up)
    (evil-local-set-key 'normal (kbd "C-d") #'agents-ghostel-scroll-page-down)
    (evil-local-set-key 'normal "gg" #'agents-ghostel-scroll-top)
    (evil-local-set-key 'normal "G" #'agents-ghostel-scroll-bottom)))

(defun agents-ghostel-start (name root)
  "Run agent NAME's CLI in a new Ghostel in ROOT.
The command comes from `agents-ghostel-programs'."
  (let* ((argv (or (alist-get name agents-ghostel-programs nil nil #'equal)
                   (user-error "Unknown agent %s" name)))
         (default-directory root)
         (buffer (progn
                   (unless (executable-find (car argv))
                     (user-error "%s is not on exec-path" (car argv)))
                   (generate-new-buffer
                    (if (project-current)
                        (project-prefixed-buffer-name name)
                      (format "*%s*" name))))))
    ;; 先显示再启动，终端才能按窗口尺寸初始化。
    (agents--show buffer)
    (ghostel-exec buffer (car argv) (cdr argv)
                  `((kind . agent) (agent . ,name) (root . ,root) (command . ,argv)))
    (with-current-buffer buffer (agents-ghostel--setup-evil))
    buffer))

(defun agents-ghostel--on-progress (state _progress)
  (when (agents-buffer-p (current-buffer))
    (agents-report (if (memq state '(remove error)) 'finished 'working))))

(defun agents-ghostel--on-notification (orig &rest args)
  "Mark the agent `waiting' and pass the notification on to ORIG with ARGS.
An `idle' agent finished while shown, so its later idle reminder is dropped."
  (if (not (agents-buffer-p (current-buffer)))
      (apply orig args)
    (unless (eq agents-status 'idle)
      (agents-report 'attention)
      (apply orig args))))

(defun agents-ghostel--context ()
  "Read the context usage from the \"ctx N%\" on Claude Code's status line.
Only rows below the last horizontal rule count, so the transcript cannot match."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward "^ *─\\{8\\}" nil t)
      (forward-line 1)
      (when (re-search-forward "\\_<ctx \\([0-9]+\\)%" nil t)
        (string-to-number (match-string 1))))))

(defun agents-ghostel--identity (buffer)
  "Return the agent identity of BUFFER from its `ghostel-identity', if any."
  (let ((identity (buffer-local-value 'ghostel-identity buffer)))
    (when (eq (alist-get 'kind identity) 'agent)
      `((insert . ghostel-paste-string) (context . agents-ghostel--context) ,@identity))))

;;;###autoload
(define-minor-mode agents-ghostel-mode
  "Track agent CLIs running in Ghostel."
  :global t
  :group 'agents
  (if agents-ghostel-mode
      (progn
        (add-hook 'agents-identity-functions #'agents-ghostel--identity)
        (add-function :before ghostel-progress-function #'agents-ghostel--on-progress)
        (add-function :around ghostel-notification-function #'agents-ghostel--on-notification))
    (remove-hook 'agents-identity-functions #'agents-ghostel--identity)
    (remove-function ghostel-progress-function #'agents-ghostel--on-progress)
    (remove-function ghostel-notification-function #'agents-ghostel--on-notification)))

(provide 'agents-ghostel)
;;; agents-ghostel.el ends here
