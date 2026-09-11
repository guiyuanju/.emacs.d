;;; init.el --- Emacs configuration -*- lexical-binding: t; -*-

;; * UI
(setq inhibit-startup-message t) ; don't show the splash screen
(setq ring-bell-function 'ignore) ; disable bell sound
(setq use-dialog-box nil) ; don't use ui dialogs for prompting
(add-to-list 'default-frame-alist '(undecorated-round . t)) ; disable title bar, rounded corner
(menu-bar-mode -1) ; disable menu bar on the top, the same line as apple icon
(tool-bar-mode -1) ; disable tool bar, the same line as close, maximize buttons
(scroll-bar-mode -1) ; disable visible scrollbar
(tooltip-mode -1) ; disable tooltips
(blink-cursor-mode -1) ; disable cursor blinking
(global-hl-line-mode 1) ; highlight current line
(global-display-line-numbers-mode 1) ; enable line numbers in every buffer
(defvar my-font-size 14) ; default shared across machines
(load (locate-user-emacs-file "local.el") 'noerror 'nomessage)
(set-frame-font (format "Iosevka Nerd Font Mono %d" my-font-size) nil t)
(setq-default tab-width 2)

;; * Editor
(setq global-auto-revert-non-file-buffers t) ; also revert Dired and other non-file buffers
(global-auto-revert-mode 1) ; revert buffers when underlying files has changed
(setq enable-recursive-minibuffers t) ; support opening new minibuffers from inside existing minibuffers.
(setq read-extended-command-predicate #'command-completion-default-include-p) ; hide commands in M-x which do not work in the current mode
(winner-mode 1) ; window layout undo/redo, bound to SPC w u / SPC w U
(electric-pair-mode 1) ; 自动配对括号引号，`electric-pair-preserve-balance' 会避开已配对的
(setq delete-by-moving-to-trash t)

;; * Packages
;; Elpaca Elisp Package Manager
(defvar elpaca-installer-version 0.12)
(defvar elpaca-directory (expand-file-name "elpaca/" user-emacs-directory))
(defvar elpaca-builds-directory (expand-file-name "builds/" elpaca-directory))
(defvar elpaca-sources-directory (expand-file-name "sources/" elpaca-directory))
(defvar elpaca-order '(elpaca :repo "https://github.com/progfolio/elpaca.git"
                              :ref nil :depth 1 :inherit ignore
                              :files (:defaults "elpaca-test.el" (:exclude "extensions"))
                              :build (:not elpaca-activate)))
(let* ((repo  (expand-file-name "elpaca/" elpaca-sources-directory))
       (build (expand-file-name "elpaca/" elpaca-builds-directory))
       (order (cdr elpaca-order))
       (default-directory repo))
  (add-to-list 'load-path (if (file-exists-p build) build repo))
  (unless (file-exists-p repo)
    (make-directory repo t)
    (when (<= emacs-major-version 28) (require 'subr-x))
    (condition-case-unless-debug err
        (if-let* ((buffer (pop-to-buffer-same-window "*elpaca-bootstrap*"))
                  ((zerop (apply #'call-process `("git" nil ,buffer t "clone"
                                                  ,@(when-let* ((depth (plist-get order :depth)))
                                                      (list (format "--depth=%d" depth) "--no-single-branch"))
                                                  ,(plist-get order :repo) ,repo))))
                  ((zerop (call-process "git" nil buffer t "checkout"
                                        (or (plist-get order :ref) "--"))))
                  (emacs (concat invocation-directory invocation-name))
                  ((zerop (call-process emacs nil buffer nil "-Q" "-L" "." "--batch"
                                        "--eval" "(byte-recompile-directory \".\" 0 'force)")))
                  ((require 'elpaca))
                  ((elpaca-generate-autoloads "elpaca" repo)))
            (progn (message "%s" (buffer-string)) (kill-buffer buffer))
          (error "%s" (with-current-buffer buffer (buffer-string))))
      ((error) (warn "%s" err) (delete-directory repo 'recursive))))
  (unless (require 'elpaca-autoloads nil t)
    (require 'elpaca)
    (elpaca-generate-autoloads "elpaca" repo)
    (let ((load-source-file-function nil)) (load "./elpaca-autoloads"))))
(add-hook 'after-init-hook #'elpaca-process-queues)
(elpaca `(,@elpaca-order))
;; Install use-package support
(elpaca elpaca-use-package
  (elpaca-use-package-mode))

;; 备份、自动保存、各种历史文件统一收进 etc/ 和 var/
(use-package no-littering
  :ensure t
  :demand t
  :config
  (no-littering-theme-backups)
  (setq custom-file (no-littering-expand-etc-file-name "custom.el"))
  (load custom-file 'noerror 'nomessage))
;; recentf/save-place/savehist 一启用就会读写自己的文件，必须等 no-littering 改完路径
(elpaca-wait)

(setq recentf-max-saved-items 200)
(recentf-mode 1) ; use recentf-open-files to open recent files
(save-place-mode 1) ; restore cursor location
(setq history-length 1000)
(savehist-mode 1) ; save what you enter into minibuffer prompts, M-p / M-n 翻

;; * Theme
(use-package doom-themes
  :ensure t
  :custom
  (doom-themes-enable-bold t)
  (doom-themes-enable-italic t) ; if nil, italics is universally disabled
  :config
  (load-theme 'doom-one t)

  (doom-themes-org-config))

;; * Environment
;; GUI 和 daemon 起的 Emacs 都不继承登录 shell 的环境，
;; jdtls / rg / gls / npm 装的那些 agent 全靠它才找得到
(use-package exec-path-from-shell
  :ensure t
  :if (eq system-type 'darwin)
  :config
  (setq exec-path-from-shell-variables '("PATH" "GOPATH" "JAVA_HOME"))
  (exec-path-from-shell-initialize))

;; * Completion
(use-package vertico
  :ensure t
  :demand t ; :bind alone would defer the package and never run `vertico-mode'
  :custom
  (vertico-cycle t)
  :bind (:map vertico-map
              ("C-j" . vertico-next)
              ("C-k" . vertico-previous))
  :config
  (vertico-mode))

(use-package vertico-directory
  :after vertico
  :ensure nil
  :bind (:map vertico-map
              ("DEL" . vertico-directory-delete-char))
  ;; 输入 ~/ 或 /ssh: 时把前面被遮蔽的路径一起删掉
  :hook (rfn-eshadow-update-overlay . vertico-directory-tidy))

;; remembers the last minibuffer session for SPC '
(use-package vertico-repeat
  :after vertico
  :ensure nil
  :bind (:map vertico-map
              ("M-p" . vertico-repeat-previous)
              ("M-n" . vertico-repeat-next))
  :hook (minibuffer-setup . vertico-repeat-save))

;; 候选按 workspace 收窄的部分见下面 persp-mode 那节
(use-package consult
  :ensure t)

;; Optionally use the `orderless' completion style.
(use-package orderless
  :ensure t
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion)))))

;; annotations (docstrings, file size/mtime) next to minibuffer candidates
(use-package marginalia
  :ensure t
  :bind (:map minibuffer-local-map
              ("M-A" . marginalia-cycle))
  ;; in `:init' because `:bind' defers the package
  :init
  (marginalia-mode 1))

;; act on the candidate at point in the minibuffer (or on the thing at point)
(use-package embark
  :ensure t
  :bind (("C-;" . embark-act)
         ("C-c C-;" . embark-export))
  :init
  ;; 任何前缀键后按 C-h 走 completing-read，比 which-key 的分页好翻
  (setq prefix-help-command #'embark-prefix-help-command))

(use-package helpful
  :ensure t
  :bind (([remap describe-function] . helpful-callable)
         ([remap describe-variable] . helpful-variable)
         ([remap describe-symbol]   . helpful-symbol)
         ([remap describe-command]  . helpful-command)
         ([remap describe-key]      . helpful-key)))

(use-package embark-consult
  :ensure t
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))

(use-package nerd-icons
  :ensure t
  :defer t)

(use-package nerd-icons-completion
  :ensure t
  :after marginalia
  :config
  (nerd-icons-completion-mode)
  (add-hook 'marginalia-mode-hook #'nerd-icons-completion-marginalia-setup))

;; built into Emacs 30
(use-package which-key
  :ensure nil
  :custom
  (which-key-idle-delay 0.5)
  ;; 子分组排在散键前面，leader 弹窗按 SPC 一层层往下读
  (which-key-sort-order #'which-key-prefix-then-key-order)
  (which-key-max-description-length 40)
  :config
  (which-key-mode 1))

;; in-buffer completion popup
(use-package corfu
  :ensure t
  :custom
  (corfu-auto t)
  (tab-always-indent 'complete)
  :config
  (global-corfu-mode 1))

;; Add extensions
(use-package cape
  :ensure t
  :init
  (add-hook 'completion-at-point-functions #'cape-dabbrev)
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-elisp-block))

;; * Evil
(use-package evil
  :ensure t
  :init
  (setq evil-want-integration t)
  (setq evil-want-keybinding nil)
  (setq evil-want-C-u-scroll t)
  (setq evil-want-C-i-jump nil)
  (setq evil-want-Y-yank-to-eol t)
  (setq evil-undo-system 'undo-redo) ; 没有它 C-r 不会重做
  ;; 新开的 split 直接获得焦点
  (setq evil-split-window-below t)
  (setq evil-vsplit-window-right t)
  (setq evil-symbol-word-search t) ; * 和 # 匹配符号而不是单词
  (setq evil-kill-on-visual-paste nil)
  (setq evil-respect-visual-line-mode t)
  ;; insert state 用 Emacs 默认键位（C-a/C-e/C-p/C-n/C-k/C-y ...）
  (setq evil-disable-insert-state-bindings t)
  :config
  (evil-mode 1)
  (define-key evil-insert-state-map (kbd "C-g") 'evil-normal-state)
  (define-key evil-insert-state-map (kbd "C-h") 'evil-delete-backward-char-and-join)
  (evil-global-set-key 'motion "j" 'evil-next-visual-line)
  (evil-global-set-key 'motion "k" 'evil-previous-visual-line)
  ;; 窗口循环切换；insert state 留给 Emacs 的 C-j/C-k
  (evil-global-set-key 'normal (kbd "C-j") 'evil-window-next)
  (evil-global-set-key 'normal (kbd "C-k") 'evil-window-prev)
  (evil-global-set-key 'visual (kbd "C-j") 'evil-window-next)
  (evil-global-set-key 'visual (kbd "C-k") 'evil-window-prev)
  (evil-set-initial-state 'messages-buffer-mode 'normal))

(use-package evil-collection
  :after evil
  :ensure t
  :init
  ;; eshell 等 REPL buffer 里 RET 提交命令，默认是 normal state 才提交
  (setq evil-collection-repl-submit-state 'insert)
  :config
  (evil-collection-init))

(use-package evil-commentary
  :ensure t
  :config
  (evil-commentary-mode 1))

;; * Commands
;; 下面 leader map 用到的自定义命令
(defun jgy/delete-this-file (&optional path force-p)
  "Delete PATH, defaulting to the current buffer's file, and kill its buffer."
  (interactive (list (buffer-file-name (buffer-base-buffer)) current-prefix-arg))
  (unless path (user-error "Buffer is not visiting a file"))
  (when (or force-p (yes-or-no-p (format "Delete %s? " (abbreviate-file-name path))))
    (delete-file path delete-by-moving-to-trash)
    (kill-buffer (get-file-buffer path))))

(defun jgy/yank-buffer-path (&optional root)
  "Copy the current buffer's path to the kill ring, relative to ROOT if given."
  (interactive)
  (let ((path (or (buffer-file-name (buffer-base-buffer)) default-directory)))
    (message "Copied: %s"
             (kill-new (if root
                           (file-relative-name path root)
                         (abbreviate-file-name path))))))

(defun jgy/yank-buffer-path-relative ()
  "Copy the current buffer's path relative to the project root."
  (interactive)
  (jgy/yank-buffer-path (when-let ((pr (project-current))) (project-root pr))))

(defun jgy/insert-buffer-path ()
  "Insert the current buffer's path at point."
  (interactive)
  (insert (or (buffer-file-name (buffer-base-buffer)) default-directory)))

(defun jgy/find-file-in-emacsd ()
  (interactive)
  (find-file (read-file-name "Find file in emacs.d: " user-emacs-directory)))

(defun jgy/find-config-file ()
  (interactive)
  (find-file user-init-file))

(defun jgy/reload-config ()
  "Re-evaluate init.el; newly added packages still need a restart to build."
  (interactive)
  (load user-init-file nil 'nomessage)
  (message "Reloaded %s" (abbreviate-file-name user-init-file)))

(defun jgy/search-cwd ()
  "Ripgrep from `default-directory' instead of the project root."
  (interactive)
  (consult-ripgrep default-directory))

(defun jgy/obsidian-search ()
  "Ripgrep the Obsidian vault."
  (interactive)
  ;; obsidian-directory 是 defcustom，包没加载时未 bound
  (require 'obsidian)
  (consult-ripgrep obsidian-directory))

(defun jgy/search-symbol-at-point ()
  (interactive)
  (consult-ripgrep nil (thing-at-point 'symbol t)))

(defun jgy/toggle-line-numbers ()
  "Cycle absolute -> relative -> off."
  (interactive)
  (setq display-line-numbers
        (pcase display-line-numbers
          ('t 'relative)
          ('relative nil)
          (_ t)))
  (message "Line numbers: %s" (or display-line-numbers "off")))

(defun jgy/reveal-in-finder ()
  "Reveal the current file in Finder."
  (interactive)
  (call-process "open" nil 0 nil "-R"
                (or (buffer-file-name (buffer-base-buffer)) default-directory)))

(defun jgy/ibuffer-workspace ()
  "ibuffer 只列当前 workspace 的 buffer。"
  (interactive)
  (ibuffer nil "*Ibuffer*"
           '((predicate . (or (persp-contain-buffer-p (current-buffer))
                              (persp-buffer-free-p (current-buffer)))))))

(defun jgy/toggle-popup-buffer (buffer create-fn)
  "Hide BUFFER when it has a window, show it when it exists, else call CREATE-FN.
Showing goes through `display-buffer', so popper picks the window."
  (cond
   ((not (buffer-live-p buffer)) (funcall create-fn))
   ((get-buffer-window buffer) (popper--delete-popup (get-buffer-window buffer)))
   (t (display-buffer buffer))))

(defun jgy/eshell-buffer-name ()
  "Name `project-eshell' would use here, or the plain one outside a project."
  (if (project-current)
      (project-prefixed-buffer-name "eshell")
    (or (bound-and-true-p eshell-buffer-name) "*eshell*")))

(defun jgy/eshell-toggle ()
  "Toggle this project's eshell popup, creating it on first use."
  (interactive)
  (jgy/toggle-popup-buffer (get-buffer (jgy/eshell-buffer-name))
                           (if (project-current) #'project-eshell #'eshell)))

(defun jgy/ghostel-toggle-global ()
  "Toggle the project-independent ghostel popup."
  (interactive)
  (jgy/toggle-popup-buffer
   (get-buffer (or (bound-and-true-p ghostel-buffer-name) "*ghostel*")) #'ghostel))

(defun jgy/ghostel-toggle ()
  "Toggle this project's ghostel popup, creating it on first use."
  (interactive)
  (if (project-current)
      ;; buffer 列表而不是拼名字：`ghostel-project-buffer-scope' 还会认 cd 进来的终端
      (jgy/toggle-popup-buffer (car (ghostel-project-buffer-list)) #'ghostel-project)
    (jgy/ghostel-toggle-global)))

;; * Keybindings
(use-package general
  :ensure t
  :config
  (general-evil-setup t)

  (general-create-definer jgy/leader-keys
    :states '(normal insert visual emacs motion)
    :keymaps 'override
    :prefix "SPC"
    :global-prefix "C-SPC")

  (jgy/leader-keys
    "`"   '(evil-switch-to-windows-last-buffer :which-key "last buffer")
    "SPC" '(project-find-file :which-key "find project file")
    "."   '(find-file :which-key "find file")
    ","   '(consult-buffer :which-key "switch buffer")
    "<"   '(consult-project-buffer :which-key "switch project buffer")
    ":"   '(execute-extended-command :which-key "M-x")
    ";"   '(eval-expression :which-key "eval expression")
    "/"   '(consult-ripgrep :which-key "search project")
    "*"   '(jgy/search-symbol-at-point :which-key "search symbol at point")
    "x"   '(scratch-buffer :which-key "scratch buffer")
    "u"   '(universal-argument :which-key "universal argument")
    "RET" '(consult-bookmark :which-key "bookmark")
    "'"   '(vertico-repeat :which-key "resume last completion")
    "\\"   '(jgy/ghostel-toggle :which-key "terminal")
    "h"   '(:keymap help-map :which-key "help")
    "w"   '(:keymap evil-window-map :package evil :which-key "window")

    "TAB"     '(:ignore t :which-key "workspace")
    "TAB TAB" '(persp-switch :which-key "switch workspace")
    "TAB ["   '(persp-prev :which-key "previous workspace")
    "TAB ]"   '(persp-next :which-key "next workspace")
    "TAB a"   '(persp-add-buffer :which-key "add buffer")
    "TAB b"   '(persp-switch-to-buffer :which-key "workspace buffer")
    "TAB d"   '(persp-kill :which-key "kill workspace")
    "TAB i"   '(persp-import-buffers :which-key "import buffers")
    "TAB l"   '(persp-load-state-from-file :which-key "load workspaces")
    "TAB n"   '(persp-add-new :which-key "new workspace")
    "TAB r"   '(persp-rename :which-key "rename workspace")
    "TAB s"   '(persp-save-state-to-file :which-key "save workspaces")
    "TAB x"   '(persp-remove-buffer :which-key "remove buffer")

    "a"  '(:ignore t :which-key "ai")
    "aa" '(agent-shell :which-key "agent shell")
    "ac" '(agent-shell-anthropic-start-claude-code :which-key "claude code")
    "ad" '(agent-shell-manager-toggle :which-key "agent shell manager")
    "ah" '(agent-shell-hq-toggle :which-key "agent sidebar")
    "ai" '(agent-shell-pi-start-agent :which-key "pi agent")
    "aP" '(agent-shell-hq-peek :which-key "peek agent")

    "a+" '(gptel-add :which-key "add to context")
    "af" '(gptel-add-file :which-key "add file to context")
    "ag" '(gptel :which-key "gptel chat")
    "ak" '(gptel-abort :which-key "abort request")
    "am" '(gptel-menu :which-key "gptel menu")
    "ap" '(gptel-system-prompt :which-key "system prompt")
    "ar" '(gptel-rewrite :which-key "rewrite region")
    "as" '(gptel-send :which-key "send")

    "b"  '(:ignore t :which-key "buffer")
    "bb" '(consult-buffer :which-key "switch buffer")
    "bB" '(consult-project-buffer :which-key "switch project buffer")
    "bd" '(kill-current-buffer :which-key "kill buffer")
    "bi" '(jgy/ibuffer-workspace :which-key "ibuffer")
    "bl" '(evil-switch-to-windows-last-buffer :which-key "last buffer")
    "bm" '(bookmark-set :which-key "set bookmark")
    "bn" '(next-buffer :which-key "next buffer")
    "bp" '(previous-buffer :which-key "previous buffer")
    "br" '(revert-buffer :which-key "revert buffer")
    "bs" '(save-buffer :which-key "save buffer")
    "bS" '(save-some-buffers :which-key "save all buffers")
    "bx" '(scratch-buffer :which-key "scratch buffer")
    "bz" '(bury-buffer :which-key "bury buffer")

    "c"  '(:ignore t :which-key "code")
    "ca" '(eglot-code-actions :which-key "code action")
    "cc" '(compile :which-key "compile")
    "cC" '(recompile :which-key "recompile")
    "cd" '(xref-find-definitions :which-key "definition")
    "cD" '(xref-find-references :which-key "references")
    "ce" '(elisp-eval-region-or-buffer :which-key "eval buffer/region")
    "cf" '(apheleia-format-buffer :which-key "format buffer")
    "ci" '(eglot-find-implementation :which-key "implementations")
    "ck" '(eldoc-doc-buffer :which-key "documentation")
    "cl" '(:ignore t :which-key "lsp")
    "cle" '(eglot-events-buffer :which-key "events buffer")
    "cll" '(eglot :which-key "start server")
    "clq" '(eglot-shutdown :which-key "shutdown server")
    "clr" '(eglot-reconnect :which-key "reconnect server")
    "co" '(eglot-code-action-organize-imports :which-key "organize imports")
    "cr" '(eglot-rename :which-key "rename")
    "ct" '(eglot-find-typeDefinition :which-key "type definition")
    "cw" '(delete-trailing-whitespace :which-key "delete trailing whitespace")
    "cx" '(consult-flymake :which-key "list diagnostics")

    "d"  '(:ignore t :which-key "debug")
    "db" '(dape-breakpoint-toggle :which-key "toggle breakpoint")
    "dB" '(dape-breakpoint-remove-all :which-key "clear breakpoints")
    "dc" '(dape-continue :which-key "continue")
    "dd" '(dape :which-key "start debugger")
    "de" '(dape-evaluate-expression :which-key "eval expression")
    "di" '(dape-step-in :which-key "step in")
    "dn" '(dape-next :which-key "next")
    "do" '(dape-step-out :which-key "step out")
    "dq" '(dape-quit :which-key "stop debugger")
    "dr" '(dape-restart :which-key "restart")
    "ds" '(dape-select-stack :which-key "switch stack frame")
    "dS" '(dape-info :which-key "sessions")

    "f"  '(:ignore t :which-key "file")
    "fD" '(jgy/delete-this-file :which-key "delete this file")
    "fe" '(jgy/find-file-in-emacsd :which-key "find file in emacs.d")
    "ff" '(find-file :which-key "find file")
    "fl" '(locate :which-key "locate file")
    "fP" '(jgy/find-config-file :which-key "open init.el")
    "fr" '(consult-recent-file :which-key "recent files")
    "fR" '(rename-visited-file :which-key "rename this file")
    "fs" '(save-buffer :which-key "save")
    "fS" '(write-file :which-key "save as...")
    "fy" '(jgy/yank-buffer-path :which-key "yank file path")
    "fY" '(jgy/yank-buffer-path-relative :which-key "yank project path")

    "g"  '(:ignore t :which-key "git")
    "g/" '(magit-dispatch :which-key "magit dispatch")
    "gb" '(magit-branch-checkout :which-key "switch branch")
    "gB" '(magit-blame-addition :which-key "blame")
    "gc" '(magit-commit :which-key "commit")
    "gf" '(magit-fetch :which-key "fetch")
    "gF" '(magit-file-dispatch :which-key "file dispatch")
    "gg" '(magit-status :which-key "status")
    "gl" '(magit-log-current :which-key "log")
    "gL" '(magit-log-buffer-file :which-key "buffer log")
    "go" '(git-link-homepage :which-key "open repo homepage")
    "gr" '(diff-hl-revert-hunk :which-key "revert hunk")
    "gR" '(vc-revert :which-key "revert file")
    "gs" '(diff-hl-stage-dwim :which-key "stage hunk")
    "gt" '(git-timemachine :which-key "file time machine")
    "gw" '(jgy/worktree-open :which-key "worktree workspace")
    "gy" '(git-link :which-key "yank link to line")
    "gY" '(git-link-commit :which-key "yank link to commit")

    "i"  '(:ignore t :which-key "insert")
    "if" '(jgy/insert-buffer-path :which-key "file path")
    "ir" '(consult-register :which-key "register")
    "iu" '(insert-char :which-key "unicode char")
    "iy" '(consult-yank-pop :which-key "from kill ring")

    "n"  '(:ignore t :which-key "notes")
    "nb" '(obsidian-backlink-jump :which-key "backlinks")
    "nB" '(obsidian-backlinks-mode :which-key "backlinks panel")
    "nc" '(obsidian-capture :which-key "new note")
    "nd" '(obsidian-daily-note :which-key "daily note")
    "nl" '(obsidian-insert-wikilink :which-key "insert wikilink")
    "nn" '(obsidian-jump :which-key "find note")
    "ns" '(jgy/obsidian-search :which-key "search vault")
    "nt" '(obsidian-find-tag :which-key "find by tag")
    "nT" '(obsidian-insert-tag :which-key "insert tag")
    "nu" '(obsidian-update :which-key "rescan vault")

    "o"  '(:ignore t :which-key "open")
    "o-" '(dired-jump :which-key "dired here")
    "od" '(dirvish :which-key "dirvish")
    "oo" '(jgy/reveal-in-finder :which-key "reveal in finder")
    "op" '(dirvish-side :which-key "project sidebar")
    "ou" '(vundo :which-key "undo tree")

    "p"  '(:ignore t :which-key "project")
    "p!" '(project-shell-command :which-key "run command")
    "p&" '(project-async-shell-command :which-key "run command async")
    "pb" '(project-switch-to-buffer :which-key "project buffer")
    "pc" '(project-compile :which-key "compile project")
    "pd" '(project-dired :which-key "project root")
    "pf" '(project-find-file :which-key "find project file")
    "pk" '(project-kill-buffers :which-key "kill project buffers")
    "pp" '(project-switch-project :which-key "switch project")
    "pr" '(project-query-replace-regexp :which-key "replace in project")

    "q"  '(:ignore t :which-key "quit")
    "qq" '(save-buffers-kill-terminal :which-key "quit emacs")
    "qQ" '(save-buffers-kill-emacs :which-key "quit emacs (all frames)")
    "qr" '(restart-emacs :which-key "restart emacs")

    "s"  '(:ignore t :which-key "search")
    "sd" '(jgy/search-cwd :which-key "search this directory")
    ;; eglot feeds imenu, so this lists LSP document symbols in code buffers
    "si" '(consult-imenu :which-key "symbols in buffer")
    "sI" '(consult-imenu-multi :which-key "symbols in project")
    "sj" '(evil-show-jumps :which-key "jump list")
    "sm" '(evil-show-marks :which-key "marks")
    "sp" '(consult-ripgrep :which-key "search project")
    "ss" '(consult-line :which-key "search buffer")
    "sS" '(consult-line-multi :which-key "search open buffers")
    "st" '(consult-todo :which-key "todos in buffer")
    "sT" '(consult-todo-all :which-key "todos in all buffers")

    "t"  '(:ignore t :which-key "toggle")
    "tc" '(display-fill-column-indicator-mode :which-key "fill column indicator")
    "td" '(toggle-debug-on-error :which-key "debug on error")
    "te" '(jgy/eshell-toggle :which-key "eshell")
    "tf" '(toggle-frame-fullscreen :which-key "fullscreen")
    "tI" '(indent-tabs-mode :which-key "indent with tabs")
    "tl" '(jgy/toggle-line-numbers :which-key "line numbers")
    "tn" '(popper-cycle :which-key "next popup")
    "tp" '(popper-toggle :which-key "popup")
    "tP" '(popper-toggle-type :which-key "popup <-> normal window")
    "tr" '(read-only-mode :which-key "read-only")
    "tt" '(jgy/ghostel-toggle :which-key "terminal")
    "tT" '(consult-theme :which-key "choose theme")
    "tw" '(visual-line-mode :which-key "soft line wrapping"))

  ;; SPC h is `help-map', so "r" has to stop being info-emacs-manual first
  (keymap-unset help-map "r" t)
  (keymap-set help-map "r r" #'jgy/reload-config)
  (which-key-add-key-based-replacements "SPC h r" "reload")
  (keymap-set help-map "." #'helpful-at-point)

  ;; window layout history, next to evil's own C-w bindings
  (general-def evil-window-map
    "d" #'evil-window-delete
    "u" #'winner-undo
    "U" #'winner-redo
    "m" #'delete-other-windows)

  ;; Doom-style bracket motions; ]b / [b already come from evil. A sequence
  ;; missing here still falls through to evil's own ] / [ bindings
  (general-def
    :states '(normal motion visual)
    :keymaps 'override
    "]d" #'flymake-goto-next-error
    "[d" #'flymake-goto-prev-error
    "]h" #'diff-hl-next-hunk
    "[h" #'diff-hl-previous-hunk
    "]t" #'hl-todo-next
    "[t" #'hl-todo-previous
    "zx" #'kill-current-buffer))

;; * Popups
;; 把辅助 buffer 收进底部可切换的 popup 窗口
(use-package popper
  :ensure t
  ;; leader 上另有 SPC t p / SPC t n
  :bind (("C-`" . popper-toggle)
         ("M-`" . popper-cycle))
  :init
  ;; popper-mode 启动时就会调用分组函数，此时 project.el 还没加载，project-root 不存在
  (require 'project)
  ;; popup 按项目分组，分组名取自 popup buffer 自己的 default-directory，
  ;; 所以 SPC t p 切出来的总是当前项目的终端
  (setq popper-group-function #'popper-group-by-project)
  (setq popper-reference-buffers
        '("\\*Messages\\*"
          "\\*Warnings\\*"
          "\\*Backtrace\\*"
          "\\*Async Shell Command\\*"
          "\\*eldoc\\*"
          "Output\\*$"
          help-mode
          "eshell\\*\\(<[0-9]+>\\)?$"
          eshell-mode
          compilation-mode
          xref--xref-buffer-mode
          flymake-diagnostics-buffer-mode
          ghostel-mode))
  (setq popper-window-height 0.33)
  (popper-mode 1)
  (popper-echo-mode 1))

;; libghostty-vt terminal; the native module is a prebuilt binary fetched on first use
(use-package ghostel
  :ensure t
  :commands (ghostel ghostel-project ghostel-project-next ghostel-project-previous
             ghostel-project-buffer-list))

;; * Workspaces
;; workspace = 一组 buffer + 窗口布局，切走再切回来整套还原。
;; agent-shell-hq 本来就会自己 `(persp-mode 1)'，这里先配好再让它用
(defun jgy/persp-recentf-track (file &rest _)
  "FILE 确实进了 `recentf-list' 就记到当前 workspace 名下。"
  (when (bound-and-true-p persp-mode)
    (let ((file (recentf-expand-file-name file))
          (persp (persp-get-current)))
      (when (and (not (persp-nil-p persp)) (member file recentf-list))
        (persp-set-parameter
         'jgy/recentf
         (seq-take (cons file (delete file (persp-parameter 'jgy/recentf persp)))
                   recentf-max-saved-items)
         persp)))))

(defun jgy/persp-recentf-list ()
  "当前 workspace 打开过的最近文件，顺序仍按全局的新旧排。
main 和还没记录过任何文件的 workspace 给完整列表。"
  (if-let* (((bound-and-true-p persp-mode))
            (files (persp-parameter 'jgy/recentf)))
      (seq-filter (lambda (file) (member file files)) recentf-list)
    recentf-list))

(defvar jgy/consult-recent-file-items nil
  "consult 原来的 recent file `:items'，包一层之前先存下来。")

(defun jgy/persp-recentf-scoped (fn &rest args)
  "调 FN 时把 `recentf-list' 收窄到当前 workspace。"
  (let ((recentf-list (jgy/persp-recentf-list)))
    (apply fn args)))

(defun jgy/persp-consult-recent-file-items ()
  "把当前 workspace 的最近文件喂给 consult 原来的 `:items'。"
  (jgy/persp-recentf-scoped jgy/consult-recent-file-items))

(defvar jgy/persp-transient-names '("*agent-shell*")
  "这些 workspace 只是临时选择器，不写进自动保存文件。")

(defun jgy/persp-mark-transient (persp _phash)
  "PERSP 名字在 `jgy/persp-transient-names' 里就打上不保存标记。"
  (when (and persp (member (persp-name persp) jgy/persp-transient-names))
    (persp-set-parameter 'dont-save-to-file t persp)))

(defun jgy/persp-save-quietly ()
  "空闲时静默落盘，被 kill 或崩溃也不至于丢掉整套布局。"
  (when (bound-and-true-p persp-mode)
    (let ((inhibit-message t))
      (ignore-errors (persp-save-state-to-file)))))

;; agent-shell buffer 里的 process/timer 存不下来，只留重开会话要的三样
(defun jgy/persp-agent-shell-save (buffer tag _vars)
  "把 BUFFER 存成 TAG 开头的 savelist：agent 类型、会话 id、工作目录。"
  (with-current-buffer buffer
    (list tag (buffer-name buffer)
          (list (cons 'default-directory default-directory)
                (cons 'identifier (map-nested-elt agent-shell--state
                                                  '(:agent-config :identifier)))
                (cons 'session-id (map-nested-elt agent-shell--state
                                                  '(:session :id)))))))

(defun jgy/persp-agent-shell-load (savelist &rest _)
  "照 SAVELIST 重开 agent shell 并 resume 原会话；出错就跳过这个 buffer。"
  (condition-case err
      (cl-destructuring-bind (_tag bname vars) savelist
        (let* ((default-directory (or (alist-get 'default-directory vars)
                                      default-directory))
               (identifier (alist-get 'identifier vars))
               (session-id (alist-get 'session-id vars))
               (config (and identifier session-id
                            (require 'agent-shell nil t)
                            (seq-find (lambda (config)
                                        (eq (map-elt config :identifier) identifier))
                                      (agent-shell--resolved-agent-configs)))))
          (or (get-buffer bname)
              (when config
                (agent-shell--start :config config
                                    :session-id session-id
                                    :session-strategy 'new
                                    :new-session t
                                    :no-focus t)))))
    (error
     (message "[persp-mode] agent shell 恢复失败：%S" err)
     nil)))

;; 恢复布局用的隐藏 frame 会被排进 lighter 的 1 秒延时更新队列，
;; 到点时 frame 已经删了，upstream 不查存活就报 frame-live-p
(defun jgy/persp-skip-temp-frame-lighter (&optional frame)
  "FRAME 是 persp-mode 的临时 frame 就跳过 lighter 更新。"
  (not (equal "*persp-temp-frame*"
              (frame-parameter (or frame (selected-frame)) 'name))))

(defvar jgy/persp-untracked-name-regexps
  '("\\` \\*SIDE :: " "\\`PREVIEW :: " "\\`\\*preview-temp\\*" "\\` \\*dirvish")
  "名字匹配这些正则的 buffer 不进任何 workspace。")

(defun jgy/persp-untracked-buffer-p (buffer)
  "BUFFER 的名字是否匹配 `jgy/persp-untracked-name-regexps'。"
  (let ((name (buffer-name buffer)))
    (and name (seq-some (lambda (re) (string-match-p re name))
                        jgy/persp-untracked-name-regexps))))

(defun jgy/persp-untrack-buffer (&optional buffer)
  "把 BUFFER 从所有 workspace 里摘掉，让它变回游离 buffer。"
  (when (bound-and-true-p persp-mode)
    (let ((buffer (or buffer (current-buffer)))
          persp-autokill-buffer-on-remove
          persp-autokill-persp-when-removed-last-buffer
          persp-when-remove-buffer-switch-to-other-buffer)
      (dolist (persp (persp--buffer-in-persps buffer))
        (persp-remove-buffer buffer persp nil nil nil nil)))))

;; dirvish 先建 dired buffer 再改名成 " *SIDE :: ..."，改名前已经被当前 workspace 收走，
;; 于是在别的 workspace 里按 q 会被当成外来 buffer 追问
(defun jgy/dirvish-side-untrack (buffer &rest _)
  "BUFFER 改成侧边栏的隐藏名字之后，从所有 workspace 里摘掉。"
  (jgy/persp-untrack-buffer buffer))

(defun jgy/persp-free-buffers ()
  "不属于任何 workspace 的 buffer，比如 *Messages*、*scratch*。"
  (seq-filter (lambda (buffer)
                (and (persp-buffer-free-p buffer)
                     (not (persp-buffer-filtered-out-p buffer))))
              (funcall persp-buffer-list-function)))

(defun jgy/persp-buffer-list-with-free (fn &optional frame option &rest args)
  "OPTION 是「只看当前 workspace」那档时，把游离 buffer 也算进来。"
  (let ((buffers (apply fn frame option args)))
    (if (eql (or option *persp-restrict-buffers-to*) 0)
        (append buffers (seq-difference (jgy/persp-free-buffers) buffers))
      buffers)))

(use-package persp-mode
  :ensure t
  :init
  (setq persp-nil-name "main")
  ;; 启动 2 秒后自动恢复上次会话；dashboard 会被恢复的布局盖掉，要看它得 M-x agent-shell-dashboard
  (setq persp-auto-resume-time 2.0)
  ;; 退出、关 persp-mode、关最后一个 frame 都落盘，另外多留几份备份
  (setq persp-auto-save-opt 3)
  (setq persp-auto-save-num-of-backups 10)
  ;; 只收还没归属任何 workspace 的 buffer，magit/help 之类才会跟着当前 workspace 走
  (setq persp-add-buffer-on-after-change-major-mode 'free)
  ;; 从 main 里移除 buffer 时不再追问「要不要从所有 workspace 移除」
  (setq persp-remove-buffers-from-nil-persp-behaviour nil)
  ;; switch-to-buffer 之类的 `read-buffer' 也只提示当前 workspace 的 buffer；
  ;; next/previous-buffer 由默认的 `persp-set-frame-buffer-predicate' 管
  (setq persp-set-read-buffer-function t)
  :config
  (add-hook 'persp-created-functions #'jgy/persp-mark-transient)
  ;; dirvish 的侧边栏/预览 buffer 全程游离，免得跨 workspace 关它时被追问
  (add-to-list 'persp-add-buffer-on-after-change-major-mode-filter-functions
               #'jgy/persp-untracked-buffer-p)
  (with-eval-after-load 'dirvish-side
    (advice-add 'dirvish-side-root-conf :after #'jgy/dirvish-side-untrack))
  ;; *Messages*、*scratch* 这类不属于任何 workspace 的 buffer 在哪个 workspace 都能看到
  (advice-add 'persp-buffer-list-restricted :around #'jgy/persp-buffer-list-with-free)
  ;; 无文件 buffer 默认按 "*" 前缀被丢掉，这里补上存取规则，得挂在 persp-mode 启用前
  (persp-def-buffer-save/load
   :mode 'eshell-mode :tag-symbol 'def-eshell-buffer
   :save-vars '(major-mode default-directory))
  (persp-def-buffer-save/load
   :mode 'agent-shell-mode :tag-symbol 'def-agent-shell-buffer
   :save-vars '(major-mode default-directory)
   :save-function #'jgy/persp-agent-shell-save
   :load-function #'jgy/persp-agent-shell-load)
  (advice-add 'recentf-add-file :after #'jgy/persp-recentf-track)
  ;; consult 候选按 workspace 收窄。`consult-recent-file' 直接读 recentf-list，
  ;; `consult-buffer' 的 File 源读自己的 `:items'，两个入口得分别包
  (with-eval-after-load 'consult
    ;; 别的 workspace 的 buffer 按 o narrow 还能翻出来
    (setq consult-buffer-list-function #'persp-buffer-list-restricted)
    (advice-add 'consult-recent-file :around #'jgy/persp-recentf-scoped)
    (unless jgy/consult-recent-file-items
      (setq jgy/consult-recent-file-items
            (plist-get consult-source-recent-file :items))
      (setq consult-source-recent-file
            (plist-put (copy-sequence consult-source-recent-file)
                       :items #'jgy/persp-consult-recent-file-items))))
  (run-with-idle-timer 300 t #'jgy/persp-save-quietly)
  (advice-add 'persp-update-frame-lighter :before-while
              #'jgy/persp-skip-temp-frame-lighter)
  (persp-mode 1))

;; * Worktrees
;; worktree workspace：选 repo -> 选/建分支 -> 建 worktree -> 进对应 workspace
(defvar jgy/code-directory "~/Code/okj/"
  "各个 repo 所在的目录。")

(defvar jgy/worktree-directory "~/Code/okj/worktree/"
  "所有 worktree 的存放目录，它本身不是 repo。")

(defun jgy/worktree--slug (branch)
  "BRANCH 里的斜杠换成横线，用来拼目录名和 workspace 名。"
  (replace-regexp-in-string "/" "-" branch))

(defun jgy/worktree--repos ()
  "`jgy/code-directory' 下除 `jgy/worktree-directory' 以外的 repo 名字。"
  (let ((root (expand-file-name jgy/code-directory))
        (worktree-root (file-name-as-directory
                        (expand-file-name jgy/worktree-directory))))
    (seq-filter
     (lambda (name)
       (let ((dir (file-name-as-directory (expand-file-name name root))))
         ;; .git 在普通 repo 里是目录，在 worktree 里是文件
         (and (not (equal dir worktree-root))
              (file-exists-p (expand-file-name ".git" dir)))))
     (directory-files root nil directory-files-no-dot-files-regexp))))

(defun jgy/worktree--branches (repo-dir)
  "REPO-DIR 的本地分支加远端分支，远端的去掉 remote 前缀后与本地去重。"
  (let ((locals (process-lines "git" "-C" repo-dir "for-each-ref"
                               "--format=%(refname:short)" "refs/heads"))
        (remotes (seq-keep
                  (lambda (ref)
                    ;; origin/HEAD 和 remote 本身的那条 ref 都不是分支
                    (when (string-match "\\`[^/]+/\\(.+\\)\\'" ref)
                      (let ((branch (match-string 1 ref)))
                        (unless (equal branch "HEAD") branch))))
                  (process-lines "git" "-C" repo-dir "for-each-ref"
                                 "--format=%(refname:short)" "refs/remotes"))))
    (seq-uniq (append locals remotes))))

(defun jgy/worktree--git (repo-dir &rest args)
  "在 REPO-DIR 里跑 git ARGS，失败就把 git 自己的输出报出来。"
  (with-temp-buffer
    (unless (zerop (apply #'call-process "git" nil t nil "-C" repo-dir args))
      (user-error "git %s: %s" (string-join args " ")
                  (string-trim (buffer-string))))))

(defun jgy/worktree--ref-p (repo-dir ref)
  (zerop (call-process "git" nil nil nil "-C" repo-dir
                       "show-ref" "--verify" "--quiet" ref)))

(defun jgy/worktree--checkout-of (repo-dir branch)
  "REPO-DIR 里已经 checkout 了 BRANCH 的目录，主 checkout 也算，没有就返回 nil。"
  (with-temp-buffer
    (when (zerop (call-process "git" nil t nil "-C" repo-dir
                               "worktree" "list" "--porcelain"))
      (goto-char (point-min))
      (let ((target (concat "branch refs/heads/" branch))
            path found)
        (while (and (not found) (not (eobp)))
          (let ((line (buffer-substring (line-beginning-position)
                                        (line-end-position))))
            (cond ((string-prefix-p "worktree " line)
                   (setq path (string-remove-prefix "worktree " line)))
                  ((equal line target) (setq found path))))
          (forward-line 1))
        found))))

(defun jgy/worktree--ensure (repo-dir branch path)
  "返回 BRANCH 的工作目录：已经 checkout 过就用那个，否则在 PATH 上建 worktree。
本地分支直接用，只在远端的跟踪它，都不存在的从 HEAD 新建。"
  (let ((existing (or (jgy/worktree--checkout-of repo-dir branch)
                      (and (file-directory-p path) path))))
    (if existing
        (progn (message "Worktree exists: %s" (abbreviate-file-name existing))
               existing)
      (apply #'jgy/worktree--git repo-dir
             (cond
              ((jgy/worktree--ref-p repo-dir (concat "refs/heads/" branch))
               (list "worktree" "add" path branch))
              ((jgy/worktree--ref-p repo-dir (concat "refs/remotes/origin/" branch))
               (list "worktree" "add" "-b" branch path (concat "origin/" branch)))
              (t (list "worktree" "add" "-b" branch path))))
      (message "Created worktree: %s" (abbreviate-file-name path))
      path)))

(defun jgy/worktree-open ()
  "选一个 repo 和分支，按需建 worktree，再切到该分支的 workspace 打开它。
workspace 按分支命名，所以不同 repo 的同名分支落在同一个 workspace 里。
分支列表里没有的名字用 M-RET 直接输入，本地分支和 worktree 都会新建。"
  (interactive)
  (let* ((repos (or (jgy/worktree--repos)
                    (user-error "No repo under %s" jgy/code-directory)))
         (repo (completing-read "Repo: " repos nil t))
         (repo-dir (expand-file-name repo (expand-file-name jgy/code-directory)))
         (branch (string-trim (completing-read "Branch: "
                                               (jgy/worktree--branches repo-dir))))
         (path (expand-file-name (concat repo "_" (jgy/worktree--slug branch))
                                 (expand-file-name jgy/worktree-directory))))
    (when (string-empty-p branch) (user-error "Empty branch name"))
    (let ((dir (jgy/worktree--ensure repo-dir branch path)))
      (persp-switch (jgy/worktree--slug branch))
      (persp-add-buffer (dired dir)))))

;; * Files
(when (eq system-type 'darwin)
  (setq insert-directory-program "/opt/homebrew/bin/gls"))

(use-package dired
  :ensure nil
  :config
  (setq dired-listing-switches
        "-l --almost-all --human-readable --group-directories-first --no-group")
  ;; this command is useful when you want to close the window of `dirvish-side'
  ;; automatically when opening a file
  (put 'dired-find-alternate-file 'disabled nil)

  ;; dirvish 的右侧属性会把长行挤出窗口右沿，行尾被截断后 `dired-next-line'
  ;; 末段的 `vertical-motion' 会多跳一行；置 nil 让它退回 `forward-line'
  (add-hook 'dired-mode-hook
            (lambda () (setq-local line-move-ignore-invisible nil))))

(use-package dirvish
  :ensure t
  :init
  (dirvish-override-dired-mode)
  :custom
  (dirvish-quick-access-entries ; It's a custom option, `setq' won't work
   '(("h" "~/"                          "Home")
     ("d" "~/Downloads/"                "Downloads")))
  ;; git 集成：vc-state 是左 fringe 位图，只在图形界面可见；
  ;; git-msg 在文件名后接 commit message，vc-info 在 mode line 显示分支
  (dirvish-attributes '(vc-state subtree-state nerd-icons collapse git-msg file-size))
  (dirvish-side-attributes '(vc-state subtree-state nerd-icons collapse file-size)) ; 侧边栏只 35 列，不放 git-msg
  (dirvish-mode-line-format '(:left (sort omit symlink) :right (vc-info index)))
  ;; 带修饰键的不会被 evil 抢走，普通字母键的见下面的 general-def
  :bind (:map dirvish-mode-map
              ("TAB" . dirvish-subtree-toggle)
              ("M-f" . dirvish-history-go-forward)
              ("M-b" . dirvish-history-go-backward)
              ("M-e" . dirvish-emerge-menu))
  :config
  ;; 侧边栏跟随当前 buffer：切 project 时换根目录，并展开到该文件
  (dirvish-side-follow-mode 1)

  ;; dirvish 用 `use-local-map' 装 `dirvish-mode-map'，major-mode 还是 dired-mode。
  ;; local map 的优先级低于 evil 所在的 `emulation-mode-map-alists'，所以 q/y/f/l...
  ;; 全被 evil-collection 的 dired 绑定盖掉了；挂进 evil 的 normal 辅助 keymap 才生效
  (general-def
    :states 'normal
    :keymaps 'dirvish-mode-map
    "q"   #'dirvish-quit
    ";"   #'dired-up-directory
    "?"   #'dirvish-dispatch          ; cheatsheet
    "f"   #'dirvish-file-info-menu
    "o"   #'dirvish-quick-access
    "s"   #'dirvish-quicksort
    "r"   #'dirvish-history-jump
    "l"   #'dirvish-ls-switches-menu
    "v"   #'dirvish-vc-menu
    "*"   #'dirvish-mark-menu
    "y"   #'dirvish-yank-menu
    "N"   #'dirvish-narrow
    "^"   #'dirvish-history-last))

;; * Git
;; magit needs transient >= 0.13; Emacs 30 bundles 0.7.2.2, so shadow it early
(elpaca transient)

(use-package magit
  :ensure t
  :after transient
  :init
  (setq magit-process-connection-type t)
  :custom
  (magit-ediff-dwim-show-on-hunks t)
  :config
  (setq magit-display-buffer-function 'magit-display-buffer-fullframe-status-topleft-v1)
  (setq magit-bury-buffer-function 'magit-restore-window-configuration)
  ;; magit only forwards prompts it recognizes; anything else silently
  ;; stalls in *magit-process*
  (add-to-list 'magit-process-password-prompt-regexps
               "^.*Verification code: ?$")
  (magit-add-section-hook 'magit-status-sections-hook
                        #'magit-insert-worktrees
                        nil t))

(use-package hl-todo
  :ensure t
  :demand t
  :config
  (global-hl-todo-mode 1))

(use-package consult-todo
  :ensure t
  :commands (consult-todo consult-todo-all))

(use-package git-timemachine
  :ensure t
  :commands (git-timemachine git-timemachine-toggle))

(use-package vundo
  :ensure t
  :commands vundo
  :config
  (setq vundo-glyph-alist vundo-unicode-symbols))

(use-package git-link
  :ensure t
  :commands (git-link git-link-commit git-link-homepage)
  :custom
  ;; 链接钉在当前 commit 上，行号不会随分支后续改动跑偏；C-u C-u 临时换回分支名
  (git-link-use-commit t)
  (git-link-open-in-browser t))

;; gutter diffs feed SPC g s/r and ]h/[h
(use-package diff-hl
  :ensure t
  :demand t
  :config
  ;; margin 画的是 +/-/! 字符，比 fringe 位图能多说明一点；想换回 fringe 删掉这行
  (diff-hl-margin-mode 1)
  (diff-hl-flydiff-mode 1)
  (global-diff-hl-mode 1)
  (add-hook 'magit-pre-refresh-hook #'diff-hl-magit-pre-refresh)
  (add-hook 'magit-post-refresh-hook #'diff-hl-magit-post-refresh))

;; * Code
;; eglot advertises `snippetSupport' only when `yas-minor-mode' is fbound, which the
;; `:hook' autoload satisfies from startup; servers then send parameter placeholders
(use-package yasnippet
  :ensure t
  :hook (eglot-managed-mode . yas-minor-mode))

;; xxx-mode -> xxx-ts-mode 的 remap。只列 Emacs 30 自带 ts-mode 的语言：
;; haskell/markdown 的 ts-mode 要等 31 或第三方包，`treesit-auto--ready-p' 会跳过它们
(use-package treesit-auto
  :ensure t
  :demand t
  :custom
  (treesit-auto-langs '(bash dockerfile go gomod java json lua rust toml yaml))
  (treesit-auto-install 'prompt)
  :config
  (global-treesit-auto-mode)
  ;; remap 只能改已有的 mode；yaml/toml/dockerfile 这些 Emacs 本来没有基础 mode，
  ;; 得把 ts-mode 直接注册进 `auto-mode-alist'（只注册 grammar 已装好的）
  (treesit-auto-add-to-auto-mode-alist))

(use-package eglot
  :ensure nil
  :ensure-system-package (jdtls . "brew install jdtls")
  :init
  ;; jdt.ls 这种消息量大的 server，64K 的默认管道缓冲会成为瓶颈
  (setq read-process-output-max (* 1024 1024))
  ;; treesit-auto 会把 go/lua/java 换成 ts-mode，那时只有 ts-mode 的 hook 会跑；
  ;; grammar 没装时又退回旧 mode，所以两边都挂
  :hook ((go-mode . eglot-ensure)
         (go-ts-mode . eglot-ensure)
         (haskell-mode . eglot-ensure)
         (lua-mode . eglot-ensure)
         (lua-ts-mode . eglot-ensure)
         (java-mode . eglot-ensure)
         (java-ts-mode . eglot-ensure))
  :commands (eglot eglot-ensure)
  :config
  (with-eval-after-load 'evil
    (evil-define-minor-mode-key 'normal 'eglot--managed-mode
      (kbd "K")  #'eldoc-doc-buffer
      (kbd "gD") #'xref-find-references
      (kbd "gI") #'eglot-find-implementation)))

;; async format-on-save for every language; the RCS-patch apply keeps point put
(use-package apheleia
  :ensure t
  :demand t
  :config
  (setf (alist-get 'haskell-mode apheleia-mode-alist) 'ormolu)
  ;; java formatting belongs to jdt.ls
  (setf (alist-get 'java-mode apheleia-mode-alist nil t) nil)
  (setf (alist-get 'java-ts-mode apheleia-mode-alist nil t) nil)
  (setf (alist-get 'emacs-lisp-mode apheleia-mode-alist nil t) nil)
  (apheleia-global-mode 1))

;; DAP client；dap-mode 硬依赖 lsp-mode，所以换成 dape
(use-package dape
  :ensure t
  :commands (dape dape-breakpoint-toggle dape-breakpoint-remove-all
             dape-continue dape-next dape-step-in dape-step-out
             dape-quit dape-restart dape-evaluate-expression
             dape-select-stack dape-info)
  :custom
  (dape-buffer-window-arrangement 'right)
  :config
  ;; 断点跟着文件走，不必先起 session 再打
  (dape-breakpoint-global-mode 1))

;; * Languages
(use-package haskell-mode
  :ensure t
  :mode ("\\.hs\\'" "\\.lhs\\'")
  :custom
  (haskell-process-type 'cabal-repl))

(use-package lua-mode
  :ensure t
  :mode "\\.lua\\'")

(use-package go-mode
  :ensure t
  :mode "\\.go\\'")

(use-package rust-mode
  :ensure t
  :mode "\\.rs\\'")

;; Java
(defvar jgy/sdkman-java-dir (expand-file-name "~/.sdkman/candidates/java/"))

;; global tab-width is 2; jdt.ls derives its formatter settings from
;; `c-basic-offset' and `indent-tabs-mode', so these cover both sides
(defun jgy/java-indent-setup ()
  (setq-local indent-tabs-mode nil
              tab-width 4)
  (when (boundp 'c-basic-offset)
    (setq-local c-basic-offset 4))
  (when (boundp 'java-ts-mode-indent-offset)
    (setq-local java-ts-mode-indent-offset 4)))

(add-hook 'java-mode-hook #'jgy/java-indent-setup)
(add-hook 'java-ts-mode-hook #'jgy/java-indent-setup)

(with-eval-after-load 'eglot
  ;; eclipse.jdt.ls 自己要 JDK 21+，跟项目 target 无关；jdtls 包装脚本默认认 JAVA_HOME，
  ;; 而 shell 里那个是 17，所以显式指过去。
  ;; 另外 jdt.ls 没有注解处理，Lombok 生成的成员（@Slf4j 的 `log'、@Data 的 accessor）
  ;; 要靠这个 agent 去 patch ecj
  (add-to-list 'eglot-server-programs
               `((java-mode java-ts-mode)
                 . ("jdtls"
                    "--java-executable"
                    ,(expand-file-name "25.0.3-tem/bin/java" jgy/sdkman-java-dir)
                    ,(concat "--jvm-arg=-javaagent:"
                             (no-littering-expand-var-file-name "lombok.jar")))))

  ;; 供项目选用的 JDK，项目没声明 release 时用 :default 那个。
  ;; eglot 是在 temp buffer 里读这个变量的，挂 mode hook 里 setq-local 它看不见，只能设全局值
  (setq-default eglot-workspace-configuration
                `(:java
                  (:configuration
                   (:runtimes
                    [(:name "JavaSE-1.8"
                      :path ,(expand-file-name "8.0.492-zulu" jgy/sdkman-java-dir))
                     (:name "JavaSE-17"
                      :path ,(expand-file-name "17.0.19-tem" jgy/sdkman-java-dir)
                      :default t)
                     (:name "JavaSE-25"
                      :path ,(expand-file-name "25.0.3-tem" jgy/sdkman-java-dir))])))))

(use-package csv-mode
  :ensure t
  :mode "\\.[ct]sv\\'")

;; * Notes
;; C-c C-c p / v 的浏览器预览：pandoc 出片段，markdown-mode 套上 <head>，
;; 样式用 github-markdown-css + highlight.js，明暗跟随系统
(defconst jgy/markdown-preview-head "
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
<link rel=\"stylesheet\" media=\"(prefers-color-scheme: light)\"
      href=\"https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github.min.css\" />
<link rel=\"stylesheet\" media=\"(prefers-color-scheme: dark)\"
      href=\"https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/styles/github-dark.min.css\" />
<style>
  html { color-scheme: light dark; }
  body { margin: 0; background: #ffffff; }
  @media (prefers-color-scheme: dark) { body { background: #0d1117; } }
  .markdown-body { box-sizing: border-box; max-width: 900px; margin: 0 auto; padding: 48px; }
  @media (max-width: 767px) { .markdown-body { padding: 16px; } }
</style>")

(defconst jgy/markdown-preview-tail "
<script src=\"https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11/build/highlight.min.js\"></script>
<script>
  // pandoc 把语言标在 <pre> 上，highlight.js 认的是 <code> 的 class
  document.querySelectorAll('pre[class] > code:not([class])').forEach(
    function (c) { c.className = 'language-' + c.parentNode.className.split(/\\s+/)[0]; });
  hljs.highlightAll();
</script>")

(use-package markdown-mode
  :ensure t
  :mode "\\.md\\'"
  :custom
  (markdown-fontify-code-blocks-natively t)
  ;; obsidian.el 的链接跳转不依赖它，但 [[...]] 的高亮和 `markdown-wiki-link-p' 依赖
  (markdown-enable-wiki-links t)
  ;; gfm 才有表格/任务列表/删除线；代码高亮交给 highlight.js，省得和它的 class 打架
  (markdown-command "pandoc --from=gfm --to=html5 --no-highlight")
  (markdown-css-paths
   '("https://cdn.jsdelivr.net/npm/github-markdown-css@5/github-markdown.min.css"))
  (markdown-xhtml-header-content jgy/markdown-preview-head)
  (markdown-xhtml-body-preamble "<article class=\"markdown-body\">")
  (markdown-xhtml-body-epilogue (concat "</article>" jgy/markdown-preview-tail)))

;; ~/Documents/Garden，目录约定跟 .obsidian/app.json 保持一致
(use-package obsidian
  :ensure t
  ;; `obsidian-enable-minor-mode' 只在 vault 内的 .md 里开 `obsidian-mode'
  :hook (markdown-mode . obsidian-enable-minor-mode)
  :custom
  (obsidian-directory "~/Documents/Garden") ; 有 :set 校验路径，`setq' 不生效
  (obsidian-inbox-directory "notes")        ; `obsidian-capture' 和未命中的链接落在这里
  (obsidian-daily-notes-directory "journals")
  (obsidian-backlinks-panel-width 50)
  :config
  ;; `obsidian-mode' 自带的 keymap 是空的，且 minor mode map 会被 evil 的 normal state 盖掉
  (general-def
    :states 'normal
    :keymaps 'obsidian-mode-map
    "RET" #'obsidian-follow-link-at-point
    "gd"  #'obsidian-follow-link-at-point
    "gb"  #'obsidian-jump-back))

;; * AI
;; ACP client; needs `npm install -g @agentclientprotocol/claude-agent-acp'
(use-package agent-shell
  :ensure t
  :ensure-system-package
  ((claude . "brew install claude-code")
   (claude-agent-acp . "npm install -g @agentclientprotocol/claude-agent-acp")
   (pi . "npm install -g @earendil-works/pi-coding-agent")
   (pi-acp . "npm install -g pi-acp")
   (codex-acp . "npm install -g @agentclientprotocol/codex-acp")
   (copilot . "npm install -g @github/copilot"))
  ;; 几个 start 命令上游没写 autoload cookie，这里补桩；
  ;; 它们分散在子模块里，但 agent-shell.el 自己 require 了全部子模块
  :commands (agent-shell
             agent-shell-anthropic-start-claude-code
             agent-shell-openai-start-codex
             agent-shell-github-start-copilot
             agent-shell-pi-start-agent)
  :custom
  (agent-shell-context-sources '(region))
  (agent-shell-session-restore-verbosity 'full))

(use-package agent-shell-manager
  :ensure (:host github :repo "jethrokuan/agent-shell-manager")
  :commands (agent-shell-manager-toggle)
  :config
  ;; 包只绑了 emacs state，normal state 下这些单键全被 evil 吃掉。
  ;; 刷新按 evil 惯例挪到 gr，kill/logging 改大写，留着 k/l 当移动键。
  (with-eval-after-load 'evil
    (evil-set-initial-state 'agent-shell-manager-mode 'normal)
    (evil-define-key* 'normal agent-shell-manager-mode-map
      (kbd "RET") #'agent-shell-manager-goto
      "gr" #'agent-shell-manager-refresh
      "K"  #'agent-shell-manager-kill
      "c"  #'agent-shell-manager-new
      "r"  #'agent-shell-manager-restart
      "d"  #'agent-shell-manager-delete-killed
      "m"  #'agent-shell-manager-set-mode
      "M"  #'agent-shell-manager-set-model
      "t"  #'agent-shell-manager-view-traffic
      "L"  #'agent-shell-manager-toggle-logging
      "q"  #'quit-window)))

(use-package gptel
  :ensure t
  :commands (gptel gptel-send gptel-menu gptel-rewrite gptel-abort
             gptel-system-prompt gptel-add gptel-add-file))

(use-package agent-shell-dashboard
  :ensure (:host github :repo "wandersoncferreira/agent-shell-dashboard")
  :commands (agent-shell-dashboard)
  :init
  (setq initial-buffer-choice #'agent-shell-dashboard)
  :config
  (add-hook 'agent-shell-dashboard-mode-hook
            ;; dashboard 的 g 是刷新，本地覆盖掉 evil-commentary 的 gc/gy 前缀
            (lambda ()
              (evil-local-set-key 'normal "g" #'agent-shell-dashboard-refresh))))

;; agent-shell-hq-peek 要 posframe，但主文件的 Package-Requires 没写，elpaca 不会自动拉，先声明占好 load-path
(use-package posframe
  :ensure t
  :defer t)

(use-package agent-shell-hq
  :ensure (:host nil :repo "https://github.com/sreenivasvrao/agent-shell-hq"
                 :files ("*.el"))
  :after agent-shell
  :init
  ;; sidebar/peek 是 `use-local-map' 装的只读选择器，自带 `suppress-keymap' 全键位；
  ;; 让 evil 在这两个 buffer 里进 emacs state，否则 j/k/n/p/RET 全被 normal state 抢走
  (with-eval-after-load 'evil
    (add-to-list 'evil-buffer-regexps
                 '("\\` \\*agent-shell-hq-" . emacs))))

(use-package mood-line
	:ensure t
  :config
  (mood-line-mode)
  :custom
  ;; (mood-line-glyph-alist mood-line-glyphs-fira-code)
	;; (mood-line-glyph-alist mood-line-glyphs-unicode)
	(mood-line-glyph-alist mood-line-glyphs-ascii))

