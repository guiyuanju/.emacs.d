;;; init.el --- Personal Emacs configuration -*- lexical-binding: t; -*-

;;; Commentary:
;; A compact, project-oriented configuration built around Evil, Vertico,
;; tab-bar workspaces, Eglot, Magit, and agent CLIs in Ghostel.

;;; Code:

;;; Core

(setq inhibit-startup-message t
      ring-bell-function #'ignore
      use-dialog-box nil
      enable-recursive-minibuffers t
      read-extended-command-predicate #'command-completion-default-include-p
      delete-by-moving-to-trash t
      global-auto-revert-non-file-buffers t)

(setq-default indent-tabs-mode nil
              tab-width 2)

(dolist (mode '(menu-bar-mode tool-bar-mode scroll-bar-mode tooltip-mode
                blink-cursor-mode))
  (when (fboundp mode) (funcall mode -1)))

(global-auto-revert-mode 1)
(electric-pair-mode 1)
(winner-mode 1)
(fringe-mode 0)
(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(add-hook 'text-mode-hook #'display-line-numbers-mode)

(defvar my-font-size 14 "Default font size, overridable from local.el.")
(defvar jgy/font-family "Iosevka Nerd Font Mono")
(defvar jgy/notes-directory "~/Documents/Garden/"
  "Root directory for notes.")

(add-to-list 'load-path (locate-user-emacs-file "lisp"))

;; Machine-specific values belong in this ignored file.
(load (locate-user-emacs-file "local.el") 'noerror 'nomessage)

(add-to-list 'default-frame-alist '(undecorated-round . t))
(add-to-list 'default-frame-alist
             `(font . ,(format "%s %d" jgy/font-family my-font-size)))
(when (display-graphic-p)
  (set-face-attribute 'default nil :family jgy/font-family :height (* my-font-size 10)))

;; Keep generated state out of the configuration root without another package.
(defconst jgy/state-directory (locate-user-emacs-file "var/"))
(defconst jgy/backup-directory (expand-file-name "backup/" jgy/state-directory))
(defconst jgy/auto-save-directory (expand-file-name "auto-save/" jgy/state-directory))
(dolist (directory (list jgy/state-directory jgy/backup-directory
                         jgy/auto-save-directory))
  (make-directory directory t))

(setq custom-file (expand-file-name "custom.el" jgy/state-directory)
      backup-directory-alist `(("." . ,jgy/backup-directory))
      auto-save-file-name-transforms `((".*" ,jgy/auto-save-directory t))
      auto-save-list-file-prefix (expand-file-name ".saves-" jgy/auto-save-directory)
      recentf-save-file (expand-file-name "recentf.el" jgy/state-directory)
      save-place-file (expand-file-name "save-place.el" jgy/state-directory)
      savehist-file (expand-file-name "savehist.el" jgy/state-directory)
      project-list-file (expand-file-name "project-list.el" jgy/state-directory)
      recentf-max-saved-items 200
      history-length 1000)
(load custom-file 'noerror 'nomessage)
(recentf-mode 1)
(save-place-mode 1)
(savehist-mode 1)

;; Tabs are lightweight workspaces; desktop.el restores files and window state.
;; Use the Custom setter so reloading init.el also refreshes every frame.
(customize-set-variable 'tab-bar-show t)
(setq tab-bar-close-button-show nil
      tab-bar-format '(tab-bar-format-history tab-bar-format-tabs tab-bar-separator)
      ;; A new workspace starts empty rather than inheriting the current buffer.
      tab-bar-new-tab-choice "*scratch*"
      desktop-dirname jgy/state-directory
      desktop-path (list jgy/state-directory)
      desktop-base-file-name "desktop.el"
      desktop-save t
      desktop-restore-eager 5)
(tab-bar-mode 1)
(tab-bar-history-mode 1)
(desktop-save-mode 1)

(load-theme 'modus-vivendi t)

;;; Package manager

;; Keep this in sync with elpaca/sources/elpaca/doc/installer.el.
(defvar elpaca-installer-version 0.12)
(defvar elpaca-directory (expand-file-name "elpaca/" user-emacs-directory))
(defvar elpaca-builds-directory (expand-file-name "builds/" elpaca-directory))
(defvar elpaca-sources-directory (expand-file-name "sources/" elpaca-directory))
(defvar elpaca-order '(elpaca :repo "https://github.com/progfolio/elpaca.git"
                              :ref nil :depth 1 :inherit ignore
                              :files (:defaults "elpaca-test.el" (:exclude "extensions"))
                              :build (:not elpaca-activate)))
(let* ((repo (expand-file-name "elpaca/" elpaca-sources-directory))
       (build (expand-file-name "elpaca/" elpaca-builds-directory))
       (order (cdr elpaca-order))
       (default-directory repo))
  (add-to-list 'load-path (if (file-exists-p build) build repo))
  (unless (file-exists-p repo)
    (make-directory repo t)
    (when (<= emacs-major-version 28) (require 'subr-x))
    (condition-case-unless-debug err
        (if-let* ((buffer (pop-to-buffer-same-window "*elpaca-bootstrap*"))
                  ((zerop (apply #'call-process
                                 `("git" nil ,buffer t "clone"
                                   ,@(when-let* ((depth (plist-get order :depth)))
                                       (list (format "--depth=%d" depth)
                                             "--no-single-branch"))
                                   ,(plist-get order :repo) ,repo))))
                  ((zerop (call-process "git" nil buffer t "checkout"
                                        (or (plist-get order :ref) "--"))))
                  (emacs (concat invocation-directory invocation-name))
                  ((zerop (call-process emacs nil buffer nil "-Q" "-L" "."
                                        "--batch" "--eval"
                                        "(byte-recompile-directory \".\" 0 'force)")))
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
(elpaca elpaca-use-package
  (setq use-package-always-ensure t)
  (elpaca-use-package-mode))
(elpaca-wait)

;;; Environment

(use-package exec-path-from-shell
  :if (eq system-type 'darwin)
  :custom
  (exec-path-from-shell-variables '("PATH" "GOPATH" "JAVA_HOME"))
  :config
  (exec-path-from-shell-initialize))

;;; Completion

(use-package vertico
  :demand t
  :custom
  (vertico-cycle t)
  :bind (:map vertico-map
              ("C-j" . vertico-next)
              ("C-k" . vertico-previous))
  :config
  (vertico-mode 1))

(use-package vertico-directory
  :ensure nil
  :after vertico
  :bind (:map vertico-map
              ("DEL" . vertico-directory-delete-char))
  :hook (rfn-eshadow-update-overlay . vertico-directory-tidy))

(use-package vertico-repeat
  :ensure nil
  :after vertico
  :bind (:map vertico-map
              ("M-p" . vertico-repeat-previous)
              ("M-n" . vertico-repeat-next))
  :hook (minibuffer-setup . vertico-repeat-save))

(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion)))))

(use-package marginalia
  :init
  (marginalia-mode 1))

(use-package consult)

(use-package embark
  :bind (("C-;" . embark-act)
         ("C-c C-;" . embark-export))
  :init
  (setq prefix-help-command #'embark-prefix-help-command))

(use-package embark-consult
  :after (embark consult))

(use-package which-key
  :ensure nil
  :custom
  (which-key-idle-delay 0.5)
  (which-key-sort-order #'which-key-prefix-then-key-order)
  :config
  (which-key-mode 1))

(use-package corfu
  :custom
  (corfu-auto t)
  (tab-always-indent 'complete)
  :config
  (global-corfu-mode 1))

(use-package cape
  :init
  (dolist (function '(cape-file cape-dabbrev cape-elisp-block))
    (add-hook 'completion-at-point-functions function t)))

;;; Workspaces

;; Each tab keeps its own buffer list.

(use-package bufferlo
  :demand t
  :init
  ;; Read when the mode turns on, so it must be set first.
  (setq bufferlo-prefer-local-buffers 'tabs)
  :config
  (bufferlo-mode 1)
  ;; Every consult buffer source reads the tab-local list; this also switches
  ;; on `consult-source-other-buffer' (narrow "o") for the remaining buffers.
  (with-eval-after-load 'consult
    (setq consult-buffer-list-function #'bufferlo-local-buffers)))

;;; Modal editing

(use-package evil
  :init
  (setq evil-want-keybinding nil
        evil-want-C-u-scroll t
        evil-want-C-i-jump nil
        evil-want-Y-yank-to-eol t
        evil-undo-system 'undo-redo
        evil-split-window-below t
        evil-vsplit-window-right t
        evil-symbol-word-search t
        evil-search-module 'evil-search
        evil-ex-search-vim-style-regexp t
        evil-kill-on-visual-paste nil
        evil-respect-visual-line-mode t
        evil-disable-insert-state-bindings t)
  :config
  (evil-mode 1)
  (define-key evil-insert-state-map (kbd "C-g") #'evil-normal-state)
  ;; 图形界面里 C-[ 与 ESC 键是不同事件；拆开后 agent 把 ESC 留给终端，C-[ 仍回 normal。
  (defun jgy/decode-control-bracket (&optional frame)
    (when (display-graphic-p frame)
      (with-selected-frame (or frame (selected-frame))
        (define-key input-decode-map [?\C-\[] [control-bracketleft]))))
  (jgy/decode-control-bracket)
  (add-hook 'after-make-frame-functions #'jgy/decode-control-bracket)
  (define-key function-key-map [control-bracketleft] [escape])
  (define-key evil-insert-state-map [control-bracketleft] #'evil-normal-state)
  (define-key evil-insert-state-map (kbd "C-h")
              #'evil-delete-backward-char-and-join)
  (evil-global-set-key 'motion "j" #'evil-next-visual-line)
  (evil-global-set-key 'motion "k" #'evil-previous-visual-line)
  (dolist (state '(normal visual insert))
    (evil-global-set-key state (kbd "C-j") #'evil-window-next)
    (evil-global-set-key state (kbd "C-k") #'evil-window-prev)))

(use-package evil-collection
  :after evil
  :init
  (setq evil-collection-repl-submit-state 'insert)
  ;; 让出 dired 中的 ";"，evil-collection 的 epa 绑定会与之冲突。
  (setq evil-collection-key-blacklist '(";d" ";v" ";s" ";e"))
  :config
  (evil-collection-init))

(use-package evil-commentary
  :after evil
  :config
  (evil-commentary-mode 1))

;;; Commands

(defun jgy/delete-this-file (&optional force)
  "Delete the current file and kill its buffer.
With FORCE, do not ask for confirmation."
  (interactive "P")
  (let ((file (buffer-file-name (buffer-base-buffer))))
    (unless file (user-error "Buffer is not visiting a file"))
    (when (or force (yes-or-no-p (format "Delete %s? "
                                        (abbreviate-file-name file))))
      (delete-file file delete-by-moving-to-trash)
      (when-let* ((buffer (get-file-buffer file)))
        (kill-buffer buffer)))))

(defun jgy/buffer-path (&optional relative)
  "Return the current path, optionally RELATIVE to its project."
  (let ((path (or (buffer-file-name (buffer-base-buffer)) default-directory)))
    (if-let* ((relative)
              (project (project-current nil (file-name-directory path))))
        (file-relative-name path (project-root project))
      (abbreviate-file-name path))))

(defun jgy/yank-buffer-path (&optional relative)
  "Copy the current path; with RELATIVE, use the project root."
  (interactive "P")
  (message "Copied: %s" (kill-new (jgy/buffer-path relative))))

(defun jgy/insert-buffer-path ()
  "Insert the current buffer path."
  (interactive)
  (insert (jgy/buffer-path)))

(defun jgy/reload-config ()
  "Reload init.el.  Restart when changing package declarations."
  (interactive)
  (load user-init-file nil 'nomessage)
  (message "Reloaded %s" (abbreviate-file-name user-init-file)))

(defun jgy/search-directory ()
  "Run ripgrep in `default-directory'."
  (interactive)
  (consult-ripgrep default-directory))

(defun jgy/search-symbol-at-point ()
  "Run project ripgrep for the symbol at point."
  (interactive)
  (consult-ripgrep nil (thing-at-point 'symbol t)))

(defun jgy/toggle-line-numbers ()
  "Cycle absolute, relative, and hidden line numbers."
  (interactive)
  (setq display-line-numbers
        (pcase display-line-numbers
          ('t 'relative)
          ('relative nil)
          (_ t)))
  (message "Line numbers: %s" (or display-line-numbers "off")))

(defun jgy/reveal-in-finder ()
  "Reveal the current path in Finder."
  (interactive)
  (unless (eq system-type 'darwin) (user-error "Finder is only available on macOS"))
  (call-process "open" nil 0 nil "-R"
                (or (buffer-file-name (buffer-base-buffer)) default-directory)))

(defun jgy/toggle-buffer (buffer create-function)
  "Hide BUFFER if visible, show it if live, otherwise call CREATE-FUNCTION."
  (if-let* ((window (and buffer (get-buffer-window buffer t))))
      (quit-window nil window)
    (let ((buf (if (buffer-live-p buffer)
                   buffer
                 (save-window-excursion (funcall create-function)))))
      (select-window (display-buffer buf)))))

(defun jgy/eshell-toggle ()
  "Toggle the current project's Eshell, or the global one outside projects.
Called from inside an Eshell it hides that buffer, whatever its `cd'
history has done to `default-directory'."
  (interactive)
  (if (derived-mode-p 'eshell-mode)
      (quit-window)
    (let* ((project (project-current))
           (name (if project (project-prefixed-buffer-name "eshell") "*eshell*")))
      (jgy/toggle-buffer (get-buffer name)
                         (if project #'project-eshell #'eshell)))))

(defun jgy/ghostel-toggle ()
  "Toggle the current project's Ghostel, or the global terminal outside projects.
Called from inside a Ghostel it hides that buffer, whatever its `cd'
history has done to `default-directory'."
  (interactive)
  (if (derived-mode-p 'ghostel-mode)
      (quit-window)
    (if (project-current)
        (jgy/toggle-buffer (seq-find (lambda (buffer) (not (ghostel-agents-buffer-p buffer)))
                                     (ghostel-project-buffer-list))
                           #'ghostel-project)
      (jgy/toggle-buffer
       (get-buffer (or (bound-and-true-p ghostel-buffer-name) "*ghostel*"))
       #'ghostel))))

(defun jgy/popper-terminal-p (buffer)
  "Non-nil for ghostel BUFFERs other than agents, which get regular windows."
  (and (eq (buffer-local-value 'major-mode buffer) 'ghostel-mode)
       (not (ghostel-agents-buffer-p buffer))))

(defun jgy/notes-find ()
  "Find a file below `jgy/notes-directory'."
  (interactive)
  (consult-find (expand-file-name jgy/notes-directory)))

(defun jgy/notes-search ()
  "Search `jgy/notes-directory' with ripgrep."
  (interactive)
  (consult-ripgrep (expand-file-name jgy/notes-directory)))

(defun jgy/notes-new ()
  "Create or open a note in the notes inbox."
  (interactive)
  (let ((directory (expand-file-name "notes/" jgy/notes-directory)))
    (make-directory directory t)
    (find-file (read-file-name "Note: " directory nil nil nil))))

(defun jgy/notes-daily ()
  "Open today's journal note."
  (interactive)
  (let ((directory (expand-file-name "journals/" jgy/notes-directory)))
    (make-directory directory t)
    (find-file (expand-file-name (format-time-string "%Y-%m-%d.md") directory))))

;;; Keybindings

(use-package general
  :after evil
  :config
  (general-evil-setup t)
  (general-create-definer jgy/leader-keys
    :states '(normal insert visual emacs motion)
    :keymaps 'override
    :prefix "SPC"
    :global-prefix "C-SPC")

  (jgy/leader-keys
    "SPC" '(project-find-file :which-key "project file")
    "."   '(find-file :which-key "find file")
    ","   '(consult-buffer :which-key "switch buffer")
    "/"   '(consult-ripgrep :which-key "search project")
    "*"   '(jgy/search-symbol-at-point :which-key "search symbol")
    ":"   '(execute-extended-command :which-key "M-x")
    "'"   '(vertico-repeat :which-key "resume completion")
    "`"   '(mode-line-other-buffer :which-key "last buffer")
    "\\"  '(jgy/ghostel-toggle :which-key "terminal")
    "h"   '(:keymap help-map :which-key "help")
    "w"   '(:keymap evil-window-map :package evil :which-key "window")
    "x"   '((lambda () (interactive) (switch-to-buffer "*scratch*")) :which-key "scratch")

    "TAB"     '(:ignore t :which-key "workspace")
    "TAB TAB" '(tab-bar-switch-to-tab :which-key "switch")
    "TAB ["   '(tab-bar-switch-to-prev-tab :which-key "previous")
    "TAB ]"   '(tab-bar-switch-to-next-tab :which-key "next")
    "TAB d"   '(tab-bar-close-tab :which-key "close")
    "TAB n"   '(tab-bar-new-tab :which-key "new")
    "TAB r"   '(tab-bar-rename-tab :which-key "rename")
    "TAB u"   '(tab-bar-history-back :which-key "history back")
    "TAB U"   '(tab-bar-history-forward :which-key "history forward")

    "a"  '(:ignore t :which-key "AI")
    "aa" '(ghostel-agents-toggle :which-key "agent toggle")
    "aA" '(ghostel-agents-start :which-key "start agent")
    "ac" '(jgy/agent-start-claude :which-key "Claude Code")
    "ax" '(jgy/agent-start-codex :which-key "Codex")
    "ai" '(jgy/agent-start-pi :which-key "Pi agent")
    "al" '(ghostel-agents-switch :which-key "list agents")
    "aw" '(jgy/worktree-agent :which-key "agent in worktree")
    "ae" '(ghostel-agents-send :which-key "send to agent")
    "a+" '(gptel-add :which-key "add context")
    "af" '(gptel-add-file :which-key "add file")
    "ag" '(jgy/gptel-toggle :which-key "gptel toggle")
    "aG" '(gptel :which-key "gptel session")
    "ak" '(gptel-abort :which-key "abort")
    "am" '(gptel-menu :which-key "menu")
    "ar" '(gptel-rewrite :which-key "rewrite")
    "as" '(gptel-send :which-key "send")

    "b"  '(:ignore t :which-key "buffer")
    "bb" '(consult-buffer :which-key "switch")
    "bd" '(kill-current-buffer :which-key "kill")
    "bi" '(ibuffer :which-key "ibuffer (all)")
    "bn" '(next-buffer :which-key "next")
    "bp" '(previous-buffer :which-key "previous")
    "br" '(revert-buffer :which-key "revert")
    "bs" '(save-buffer :which-key "save")

    "c"  '(:ignore t :which-key "code")
    "ca" '(eglot-code-actions :which-key "action")
    "cc" '(compile :which-key "compile")
    "cC" '(recompile :which-key "recompile")
    "cd" '(xref-find-definitions :which-key "definition")
    "cD" '(xref-find-references :which-key "references")
    "cf" '(apheleia-format-buffer :which-key "format")
    "ci" '(eglot-find-implementation :which-key "implementation")
    "ck" '(eldoc-doc-buffer :which-key "documentation")
    "cl" '(:ignore t :which-key "LSP")
    "cle" '(eglot-events-buffer :which-key "events")
    "cll" '(eglot :which-key "start")
    "clq" '(eglot-shutdown :which-key "shutdown")
    "clr" '(eglot-reconnect :which-key "reconnect")
    "co" '(eglot-code-action-organize-imports :which-key "organize imports")
    "cr" '(eglot-rename :which-key "rename")
    "cx" '(consult-flymake :which-key "diagnostics")

    "d"  '(:ignore t :which-key "debug")
    "db" '(dape-breakpoint-toggle :which-key "breakpoint")
    "dB" '(dape-breakpoint-remove-all :which-key "clear breakpoints")
    "dc" '(dape-continue :which-key "continue")
    "dd" '(dape :which-key "start")
    "de" '(dape-evaluate-expression :which-key "evaluate")
    "di" '(dape-step-in :which-key "step in")
    "dn" '(dape-next :which-key "next")
    "do" '(dape-step-out :which-key "step out")
    "dq" '(dape-quit :which-key "quit")
    "dr" '(dape-restart :which-key "restart")

    "f"  '(:ignore t :which-key "file")
    "fD" '(jgy/delete-this-file :which-key "delete")
    "fe" '((lambda () (interactive) (find-file user-emacs-directory))
            :which-key "emacs directory")
    "ff" '(find-file :which-key "find")
    "fP" '((lambda () (interactive) (find-file user-init-file))
            :which-key "open init.el")
    "fr" '(consult-recent-file :which-key "recent")
    "fR" '(rename-visited-file :which-key "rename")
    "fs" '(save-buffer :which-key "save")
    "fy" '(jgy/yank-buffer-path :which-key "copy path")
    "fY" '((lambda () (interactive) (jgy/yank-buffer-path t))
            :which-key "copy project path")
    "fd" '(dired-jump :which-key "dired here")
    "fo" '(jgy/reveal-in-finder :which-key "reveal in Finder")

    "g"  '(:ignore t :which-key "Git")
    "g/" '(magit-dispatch :which-key "dispatch")
    "gb" '(magit-branch-checkout :which-key "branch")
    "gB" '(magit-blame-addition :which-key "blame")
    "gc" '(magit-commit :which-key "commit")
    "gf" '(magit-fetch :which-key "fetch")
    "gg" '(magit-status :which-key "status")
    "gl" '(magit-log-current :which-key "log")
    "go" '(git-link-homepage :which-key "repository URL")
    "gr" '(diff-hl-revert-hunk :which-key "revert hunk")
    "gs" '(diff-hl-stage-dwim :which-key "stage hunk")
    "gw" '(jgy/worktree-open :which-key "worktree")
    "gy" '(git-link :which-key "copy link")

    "i"  '(:ignore t :which-key "insert")
    "if" '(jgy/insert-buffer-path :which-key "path")
    "ir" '(consult-register :which-key "register")
    "iu" '(insert-char :which-key "character")
    "iy" '(consult-yank-pop :which-key "kill ring")

    "n"  '(:ignore t :which-key "notes")
    "nc" '(jgy/notes-new :which-key "new")
    "nd" '(jgy/notes-daily :which-key "daily")
    "nn" '(jgy/notes-find :which-key "find")
    "ns" '(jgy/notes-search :which-key "search")

    "p"  '(:ignore t :which-key "project")
    "p!" '(project-shell-command :which-key "command")
    "p&" '(project-async-shell-command :which-key "async command")
    "pb" '(project-switch-to-buffer :which-key "buffer")
    "pc" '(project-compile :which-key "compile")
    "pd" '(project-dired :which-key "root")
    "pf" '(project-find-file :which-key "file")
    "pk" '(project-kill-buffers :which-key "kill buffers")
    "pp" '(project-switch-project :which-key "switch")
    "pr" '(project-query-replace-regexp :which-key "replace")

    "q"  '(:ignore t :which-key "quit")
    "qq" '(save-buffers-kill-terminal :which-key "quit")
    "qQ" '(save-buffers-kill-emacs :which-key "quit all")
    "qr" '(restart-emacs :which-key "restart")

    "s"  '(:ignore t :which-key "search")
    "sd" '(jgy/search-directory :which-key "directory")
    "si" '(consult-imenu :which-key "symbols")
    "sI" '(consult-imenu-multi :which-key "project symbols")
    "sp" '(consult-ripgrep :which-key "project")
    "ss" '(consult-line :which-key "buffer")
    "sS" '(consult-line-multi :which-key "buffers")

    "t"  '(:ignore t :which-key "toggle")
    "tc" '(display-fill-column-indicator-mode :which-key "fill column")
    "td" '(toggle-debug-on-error :which-key "debug on error")
    "te" '(jgy/eshell-toggle :which-key "Eshell")
    "tf" '(toggle-frame-fullscreen :which-key "fullscreen")
    "tl" '(jgy/toggle-line-numbers :which-key "line numbers")
    "tn" '(popper-cycle :which-key "next popup")
    "tp" '(popper-toggle :which-key "popup")
    "tr" '(read-only-mode :which-key "read only")
    "tt" '(jgy/ghostel-toggle :which-key "terminal")
    "tT" '(consult-theme :which-key "theme")
    "tw" '(visual-line-mode :which-key "wrap"))

  (keymap-unset help-map "r" t)
  (keymap-set help-map "r r" #'jgy/reload-config)
  (which-key-add-key-based-replacements "SPC h r" "reload")
  (general-def evil-window-map
    "d" #'evil-window-delete
    "u" #'winner-undo
    "U" #'winner-redo
    "m" #'delete-other-windows)
  (general-def
    :states '(normal motion visual)
    :keymaps 'override
    "]d" #'flymake-goto-next-error
    "[d" #'flymake-goto-prev-error
    "]h" #'diff-hl-next-hunk
    "[h" #'diff-hl-previous-hunk
    "zx" #'kill-current-buffer))

;;; Popups and terminal

(use-package popper
  :demand t
  :bind (("C-`" . popper-toggle)
         ("M-`" . popper-cycle))
  :custom
  (popper-reference-buffers
   '("\\*Messages\\*" "\\*Warnings\\*" "\\*Backtrace\\*"
     "\\*Async Shell Command\\*" "\\*eldoc\\*" "Output\\*$"
     help-mode eshell-mode compilation-mode xref--xref-buffer-mode
     flymake-diagnostics-buffer-mode jgy/popper-terminal-p))
  (popper-window-height 0.35)
  :init
  (require 'project)
  (setq popper-group-function #'popper-group-by-project)
  :config
  (popper-mode 1)
  (popper-echo-mode 1))

(use-package ghostel
  :commands (ghostel ghostel-project ghostel-project-buffer-list))

;;; Worktrees

(use-package jgy-worktree
  :ensure nil
  :commands jgy/worktree-open)

;;; Files and Git

(use-package dired
  :ensure nil
  :hook (dired-mode . (lambda () (display-line-numbers-mode -1)))
  :config
  (with-eval-after-load 'evil
    (evil-define-key* 'normal dired-mode-map ";" #'dired-up-directory))
  (if-let* ((gls (executable-find "gls")))
      (setq insert-directory-program gls
            dired-listing-switches
            "-l --almost-all --human-readable --group-directories-first --no-group")
    (setq dired-listing-switches "-alh")))

(use-package transient
  :ensure t
  :demand t)

(use-package magit
  :custom
  (magit-ediff-dwim-show-on-hunks t)
  :config
  (setq magit-display-buffer-function
        #'magit-display-buffer-fullframe-status-topleft-v1
        magit-bury-buffer-function #'magit-restore-window-configuration)
  (add-to-list 'magit-process-password-prompt-regexps
               "^.*Verification code: ?$")
  (magit-add-section-hook 'magit-status-sections-hook
                          #'magit-insert-worktrees nil t))

(use-package git-link
  :commands (git-link git-link-homepage)
  :custom
  (git-link-use-commit t)
  (git-link-open-in-browser t))

(use-package diff-hl
  :demand t
  :config
  (diff-hl-margin-mode 1)
  (diff-hl-flydiff-mode 1)
  (global-diff-hl-mode 1)
  (add-hook 'magit-pre-refresh-hook #'diff-hl-magit-pre-refresh)
  (add-hook 'magit-post-refresh-hook #'diff-hl-magit-post-refresh))

;;; Programming

(use-package yasnippet
  :hook (eglot-managed-mode . yas-minor-mode))

(use-package treesit-auto
  :demand t
  :custom
  (treesit-auto-langs '(bash dockerfile go gomod java json lua python rust toml yaml))
  (treesit-auto-install 'prompt)
  :config
  (global-treesit-auto-mode 1)
  (treesit-auto-add-to-auto-mode-alist))

(declare-function eglot--project "eglot")
(declare-function eglot-find-implementation "eglot")
(declare-function eglot-format-buffer "eglot")

(defun jgy/eglot-python-configuration (server)
  "Return basedpyright settings for SERVER's project virtualenv."
  (when-let* ((root (project-root (eglot--project server)))
              (python (expand-file-name ".venv/bin/python" root))
              ((file-executable-p python)))
    `(:python (:pythonPath ,python)
      :basedpyright (:analysis
                     (:typeCheckingMode "standard"
                      :diagnosticSeverityOverrides
                      (:reportPrivateImportUsage "none"))))))

(defun jgy/java-indent-setup ()
  "Use four-space indentation in Java buffers."
  (setq-local indent-tabs-mode nil tab-width 4)
  (when (boundp 'c-basic-offset) (setq-local c-basic-offset 4))
  (when (boundp 'java-ts-mode-indent-offset)
    (setq-local java-ts-mode-indent-offset 4)))

(dolist (hook '(java-mode-hook java-ts-mode-hook))
  (add-hook hook #'jgy/java-indent-setup))

(defun jgy/sqlmesh-project-p ()
  "Return non-nil when point is inside a SQLMesh project."
  (locate-dominating-file
   default-directory
   (lambda (directory)
     (and (file-exists-p (expand-file-name "config.yaml" directory))
          (file-directory-p (expand-file-name "models" directory))))))

(defun jgy/sqlmesh-setup ()
  "Enable SQLMesh's language server in SQLMesh projects."
  (when (and buffer-file-name (jgy/sqlmesh-project-p))
    (setq-local sql-product 'postgres
                apheleia-inhibit t)
    (local-set-key [remap apheleia-format-buffer] #'eglot-format-buffer)
    (eglot-ensure)))

(defvar jgy/sql-dialects '("mysql" "postgres" "redshift")
  "sqlfluff dialects offered when formatting SQL.")

(defvar-local jgy/sql-dialect "redshift"
  "sqlfluff dialect used to format this buffer.")

(defun jgy/sql-read-dialect (&rest _)
  "Ask which dialect to format this SQL buffer with."
  (interactive)
  (when (derived-mode-p 'sql-mode)
    (setq jgy/sql-dialect
          (completing-read (format-prompt "SQL dialect" jgy/sql-dialect)
                           jgy/sql-dialects nil t nil nil jgy/sql-dialect))))

(defun jgy/sql-inhibit-format-on-save ()
  "Format SQL buffers only on demand."
  (derived-mode-p 'sql-mode))

(use-package eglot
  :ensure nil
  :commands (eglot eglot-ensure)
  :hook ((go-ts-mode haskell-mode lua-mode lua-ts-mode rust-ts-mode
          swift-mode java-mode java-ts-mode python-mode python-ts-mode)
         . eglot-ensure)
  :init
  (setq read-process-output-max (* 1024 1024))
  :config
  (setq-default eglot-workspace-configuration #'jgy/eglot-python-configuration)
  (add-to-list 'eglot-server-programs
               '((python-mode python-ts-mode)
                 . ("uvx" "--from" "basedpyright"
                    "basedpyright-langserver" "--stdio")))
  (add-to-list 'eglot-server-programs
               '((sql-mode :language-id "sql")
                 . ("uv" "run" "--with" "pygls<2" "sqlmesh_lsp")))
  (add-to-list 'eglot-server-programs
               '(swift-mode . ("xcrun" "sourcekit-lsp")))
  (with-eval-after-load 'evil
    (evil-define-minor-mode-key 'normal 'eglot--managed-mode
      (kbd "K") #'eldoc-doc-buffer
      (kbd "gD") #'xref-find-references
      (kbd "gI") #'eglot-find-implementation)))

(use-package apheleia
  :demand t
  :config
  (setf (alist-get 'haskell-mode apheleia-mode-alist) 'ormolu)
  (setf (alist-get 'sqlfluff apheleia-formatters)
        '("sqlfluff" "format" "--dialect" jgy/sql-dialect
          "--disable-progress-bar" "-"))
  (setf (alist-get 'sql-mode apheleia-mode-alist) 'sqlfluff)
  (setf (alist-get 'swift-format apheleia-formatters)
        '("xcrun" "swift-format" "format" "-"))
  (setf (alist-get 'swift-mode apheleia-mode-alist) 'swift-format)
  (dolist (mode '(java-mode java-ts-mode emacs-lisp-mode))
    (setf (alist-get mode apheleia-mode-alist nil t) nil))
  (advice-add 'apheleia-format-buffer :before #'jgy/sql-read-dialect)
  (add-hook 'apheleia-inhibit-functions #'jgy/sql-inhibit-format-on-save)
  (apheleia-global-mode 1))

(use-package dape
  :commands (dape dape-breakpoint-toggle dape-breakpoint-remove-all
             dape-continue dape-next dape-step-in dape-step-out dape-quit
             dape-restart dape-evaluate-expression)
  :custom
  (dape-buffer-window-arrangement 'right)
  :config
  (dape-breakpoint-global-mode 1))

;;; Languages and notes

(use-package haskell-mode
  :mode ("\\.hs\\'" "\\.lhs\\'")
  :custom
  (haskell-process-type 'cabal-repl))

(use-package swift-mode
  :mode "\\.swift\\'"
  :custom
  ;; Match swift-format's default indentation, which apheleia applies on save.
  (swift-mode:basic-offset 2))

(use-package sql
  :ensure nil
  :hook (sql-mode . jgy/sqlmesh-setup))

(use-package csv-mode
  :mode "\\.[ct]sv\\'")

(use-package beancount
  :mode (("\\.beancount\\'" . beancount-mode)
         ("\\.bean\\'" . beancount-mode))
  :custom
  (beancount-use-ido nil)
  :hook (beancount-mode . outline-minor-mode))

(defconst jgy/markdown-preview-head
  (let ((gh "https://cdn.jsdelivr.net/npm/github-markdown-css@5/github-markdown.css")
        (hl "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11"))
    (concat
     "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>\n"
     (format "<link rel=\"stylesheet\" href=\"%s\"/>\n" gh)
     (format "<link rel=\"stylesheet\" href=\"%s/styles/github.min.css\" media=\"(prefers-color-scheme: light)\"/>\n" hl)
     (format "<link rel=\"stylesheet\" href=\"%s/styles/github-dark.min.css\" media=\"(prefers-color-scheme: dark)\"/>\n" hl)
     ;; github-markdown-css scopes its palette to .markdown-body, so the page
     ;; canvas and the reading column need setting separately.
     "<style>\n"
     "html { color-scheme: light dark; }\n"
     "body { margin: 0; background: #ffffff; }\n"
     "@media (prefers-color-scheme: dark) { body { background: #0d1117; } }\n"
     ".markdown-body { box-sizing: border-box; max-width: 980px; margin: 0 auto; padding: 2.5rem 1.5rem 6rem; }\n"
     "@media (max-width: 767px) { .markdown-body { padding: 1.25rem; } }\n"
     "</style>\n"
     (format "<script src=\"%s/highlight.min.js\"></script>\n" hl)
     ;; Pandoc names task-list elements differently than GitHub's stylesheet
     ;; expects, so relabel them instead of restyling them.
     "<script>addEventListener(\"DOMContentLoaded\", function () {\n"
     "  hljs.highlightAll();\n"
     "  document.querySelectorAll(\"ul.task-list > li\").forEach(function (li) {\n"
     "    li.classList.add(\"task-list-item\");\n"
     "    li.querySelectorAll(\"input[type=checkbox]\").forEach(function (box) {\n"
     "      box.classList.add(\"task-list-item-checkbox\");\n"
     "    });\n"
     "  });\n"
     "});</script>\n"))
  "Head markup giving `markdown-preview' GitHub styling and highlight.js.")

(use-package edit-indirect)

(use-package markdown-mode
  :mode "\\.md\\'"
  :custom
  (markdown-fontify-code-blocks-natively t)
  (markdown-enable-wiki-links t)
  (markdown-content-type "text/html")
  ;; highlight.js colours the blocks, so pandoc must not pre-tokenise them.
  (markdown-command "pandoc --from=gfm --to=html5 --syntax-highlighting=none")
  (markdown-xhtml-header-content jgy/markdown-preview-head)
  (markdown-xhtml-body-preamble "<article class=\"markdown-body\">")
  (markdown-xhtml-body-epilogue "</article>"))

(add-to-list 'auto-mode-alist '("uv\\.lock\\'" . conf-toml-mode))

;;; AI

(use-package jgy-ai
  :ensure nil
  :demand t)

;;; Tools

(use-package sdkman
  :ensure (:host github :repo "systemhalted/sdkman.el")
  :init
  (global-sdkman-mode 1))

(defun jgy/elfeed-evil-keys (mode _keymaps)
  "Restore elfeed's own keys that evil-collection leaves to evil in MODE."
  (when (eq mode 'elfeed)
    (evil-define-key* 'normal elfeed-search-mode-map
      "G" #'elfeed-search-fetch
      "b" #'elfeed-search-browse-url
      "B" #'elfeed-search-browse-url-secondary
      "m" #'elfeed-search-mark
      "M" #'elfeed-search-unmark
      "r" #'elfeed-search-untag-unread
      "u" #'elfeed-search-tag-unread
      "t" #'elfeed-search-set-entry-title
      "T" #'elfeed-search-set-feed-title
      "o" #'elfeed-search-cycle-order
      "O" #'elfeed-search-reverse-order
      "@" #'elfeed-search-date-filter
      "=" #'elfeed-search-feed-filter
      "~" #'elfeed-search-exclude-feed-filter
      "<" #'elfeed-search-first-entry
      ">" #'elfeed-search-last-entry)
    (evil-define-key* 'normal elfeed-show-mode-map
      "b" #'elfeed-show-visit
      "B" #'elfeed-show-visit-secondary
      "R" #'elfeed-show-readable
      "c" #'elfeed-show-copy-url-at-point
      "u" #'elfeed-show-tag-unread
      "n" #'elfeed-show-next
      "p" #'elfeed-show-prev)))

(defun jgy/elfeed-show-set-referer (&rest _)
  "Send the entry's own URL as Referer so hotlink-protected images load."
  (when-let* ((entry (bound-and-true-p elfeed-show-entry))
              (link (elfeed-entry-link entry)))
    (setq-local url-current-lastloc (url-generic-parse-url link))))

(use-package elfeed
  :ensure t
  :init
  (add-hook 'evil-collection-setup-hook #'jgy/elfeed-evil-keys)
  (advice-add 'elfeed-show-refresh :before #'jgy/elfeed-show-set-referer)
  (setq elfeed-feeds
      '(("https://catcoding.me/atom.xml" cat)
        ("https://news.ycombinator.com/rss" hacker)
        ("https://www.nhk.or.jp/rss/news/cat0.xml" nhk)
        ("https://sspai.com/feed" :fetch-link t :readable t sspai))))

;;; init.el ends here
