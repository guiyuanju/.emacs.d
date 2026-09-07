;; * UI
(setq inhibit-startup-message t) ; don't show the splash screen
(setq visible-bell nil) ; flash when the bell rings
(setq ring-bell-function 'ignore) ; disable bell sound
(setq use-dialog-box nil) ; don't use ui dialogs for prompting
(add-to-list 'default-frame-alist '(undecorated-round . t)) ; disable title bar, rounded corner
(menu-bar-mode -1) ; disable menu bar on the top, the same line as apple icon
(tool-bar-mode -1) ; disable tool bar, the same line as close, maximize buttons
(scroll-bar-mode -1) ; disable visible scrollbar
(tooltip-mode -1) ; disable tooltips
(set-fringe-mode 0) ; fringe
(blink-cursor-mode -1) ; disable cursor blinking
(global-hl-line-mode 1) ; highlight current line
(global-display-line-numbers-mode 1) ; enable line numbers in every buffer
(set-frame-font "Iosevka Nerd Font Mono 14" nil t) ; set font and size for all buffers
(setq-default tab-width 2)
;; (load-theme 'modus-vivendi t) ; load theme

;; * Function
(setq recentf-max-saved-items 200)
(recentf-mode 1) ; use recentf-open-files to open recent files
(save-place-mode 1) ; restore cursor location
(global-auto-revert-mode 1) ; revert buffers when underlying files has changed
(xterm-mouse-mode 1) ; enable mouse in terminal emacs
(setq global-auto-revert-non-file-buffers t) ; revert Dired and other buffers
(setq history-length 1000) (savehist-mode 1) ; save what you enter into minibuffer prompts, use M-p, M-n to get previous-history-element or next-history-element
(setq enable-recursive-minibuffers t) ; support opening new minibuffers from inside existing minibuffers.
(setq read-extended-command-predicate #'command-completion-default-include-p) ; hide commands in M-x which do not work in the current mode
(winner-mode 1) ; window layout undo/redo, bound to SPC w u / SPC w U

;; * Unclutter
;; move custom vars to a separate file and load it (custom-set-variables ...)
(setq custom-file (locate-user-emacs-file "custom-vars.el"))
(load custom-file 'noerror 'nomessage)
;; move auto backup file to tmp/backups
(setq backup-directory-alist `(("." . ,(expand-file-name "tmp/backups/" user-emacs-directory))))
(make-directory (expand-file-name "tmp/auto-saves/" user-emacs-directory) t)
(setq auto-save-list-file-prefix (expand-file-name "tmp/auto-saves/sessions/" user-emacs-directory)
      auto-save-file-name-transforms `((".*" ,(expand-file-name "tmp/auto-saves/" user-emacs-directory) t)))
;; lsp mode files clean up
(setq lsp-session-file (expand-file-name "tmp/.lsp-session-v1" user-emacs-directory))
;; eclipse.jdt.ls server and its per-project index
(setq lsp-java-server-install-dir (expand-file-name "tmp/eclipse.jdt.ls/" user-emacs-directory)
      lsp-java-workspace-dir (expand-file-name "tmp/java-workspace/" user-emacs-directory))


;; Elpaca Elisp Packaeg Manager
(defvar elpaca-installer-version 0.12)
(defvar elpaca-directory (expand-file-name "elpaca/" user-emacs-directory))
(defvar elpaca-builds-directory (expand-file-name "builds/" elpaca-directory))
(defvar elpaca-repos-directory (expand-file-name "repos/" elpaca-directory))
(defvar elpaca-order '(elpaca :repo "https://github.com/progfolio/elpaca.git"
                              :ref nil :depth 1
                              :files (:defaults "elpaca-test.el" (:exclude "extensions"))
                              :build (:not elpaca-activate)))
(let* ((repo  (expand-file-name "elpaca/" elpaca-repos-directory))
       (build (expand-file-name "elpaca/" elpaca-builds-directory))
       (order (cdr elpaca-order))
       (default-directory repo))
  (add-to-list 'load-path (if (file-exists-p build) build repo))
  (unless (file-exists-p repo)
    (make-directory repo t)
    (when (< emacs-major-version 28) (require 'subr-x))
    (condition-case-unless-debug err
        (if-let ((buffer (pop-to-buffer-same-window "*elpaca-bootstrap*"))
                 ((zerop (apply #'call-process `("git" nil ,buffer t "clone"
                                                 ,@(when-let ((depth (plist-get order :depth)))
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
    (load "./elpaca-autoloads")))
(add-hook 'after-init-hook #'elpaca-process-queues)
(elpaca `(,@elpaca-order))
;; Install use-package support
(elpaca elpaca-use-package
  ;; Enable use-package :ensure support for Elpaca.
  (elpaca-use-package-mode))

;; Themes
(use-package ayu-theme
  :ensure t)

;; (use-package atom-one-dark-theme
;;   :ensure t)

(use-package doom-themes
  :ensure t
  :custom
  ;; Global settings (defaults)
  (doom-themes-enable-bold t)   ; if nil, bold is universally disabled
  (doom-themes-enable-italic t) ; if nil, italics is universally disabled
  ;; for treemacs users
  (doom-themes-treemacs-theme "doom-atom") ; use "doom-colors" for less minimal icon theme
  :config
  (load-theme 'doom-one t)

  ;; Enable flashing mode-line on errors
  ;; (doom-themes-visual-bell-config)
  (doom-themes-treemacs-config)
  ;; Corrects (and improves) org-mode's native fontification.
  (doom-themes-org-config))

;; Path
(use-package exec-path-from-shell
  :ensure t
  :if (memq window-system '(mac ns x))
  :config
  (setq exec-path-from-shell-variables '("PATH" "GOPATH" "JAVA_HOME"))
  (exec-path-from-shell-initialize))

;; * Clipboard
;; a terminal frame has no clipboard of its own: clipetty pushes kills out over
;; OSC 52 (survives ssh/tmux), pbpaste pulls the other way
(use-package clipetty
  :ensure t
  :config
  (global-clipetty-mode 1))

(defun jgy/pbpaste ()
  (let ((text (with-temp-buffer
                (call-process "pbpaste" nil t nil "-Prefer" "txt")
                (buffer-string))))
    (unless (string-empty-p text) text)))

(unless (display-graphic-p)
  (setq interprogram-paste-function #'jgy/pbpaste))

;; Vertico
(use-package vertico
  :ensure t
  :demand t ; :bind alone would defer the package and never run `vertico-mode'
  :custom
  ;; (vertico-scroll-margin 0) ;; Different scroll margin
  ;; (vertico-count 20) ;; Show more candidates
  ;; (vertico-resize t) ;; Grow and shrink the Vertico minibuffer
  (vertico-cycle t) ;; Enable cycling for `vertico-next/previous'
  :bind (:map vertico-map
              ("C-j" . vertico-next)
              ("C-k" . vertico-previous))
  :config
  (vertico-mode))

(use-package vertico-directory
  :after vertico
  :ensure nil
	:bind (:map vertico-map
							("DEL" . vertico-directory-delete-char)))

;; remembers the last minibuffer session for SPC '
(use-package vertico-repeat
  :after vertico
  :ensure nil
  :hook (minibuffer-setup . vertico-repeat-save))

(use-package consult
  :ensure t)

;; Optionally use the `orderless' completion style.
(use-package orderless
  :ensure t
  :custom
  ;; Configure a custom style dispatcher (see the Consult wiki)
  ;; (orderless-style-dispatchers '(+orderless-consult-dispatch orderless-affix-dispatch))
  ;; (orderless-component-separator #'orderless-escapable-split-on-space)
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
  ;; C-; does not survive most terminals, hence the C-c fallback
  :bind (("C-;" . embark-act)
         ("C-c ;" . embark-act)
         ("C-c C-;" . embark-export)))

(use-package embark-consult
  :ensure t
  :after (embark consult)
  :hook (embark-collect-mode . consult-preview-at-point-mode))

;; built into Emacs 30
(use-package which-key
  :ensure nil
  :custom
  (which-key-idle-delay 0.5)
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
  ;; Bind prefix keymap providing all Cape commands under a mnemonic key.
  ;; Press C-c p ? to for help.
  ;; :bind ("C-c p" . cape-prefix-map) ;; Alternative keys: M-p, M-+, ...
  ;; Alternatively bind Cape commands individually.
  ;; :bind (("C-c p d" . cape-dabbrev)
  ;;        ("C-c p h" . cape-history)
  ;;        ("C-c p f" . cape-file)
  ;;        ...)
  :init
  ;; Add to the global default value of `completion-at-point-functions' which is
  ;; used by `completion-at-point'.  The order of the functions matters, the
  ;; first function returning a result wins.  Note that the list of buffer-local
  ;; completion functions takes precedence over the global list.
  (add-hook 'completion-at-point-functions #'cape-dabbrev)
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-elisp-block)
  ;; (add-hook 'completion-at-point-functions #'cape-history)
	)

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


;; * Commands used by the leader map
(defun jgy/delete-this-file (&optional path force-p)
  "Delete PATH, defaulting to the current buffer's file, and kill its buffer."
  (interactive (list (buffer-file-name (buffer-base-buffer)) current-prefix-arg))
  (unless path (user-error "Buffer is not visiting a file"))
  (when (or force-p (yes-or-no-p (format "Delete %s? " (abbreviate-file-name path))))
    (delete-file path delete-by-moving-to-trash)
    (kill-buffer (get-file-buffer path))))

(defun jgy/copy-this-file (new-path &optional force-p)
  "Copy the current buffer's file to NEW-PATH and visit it."
  (interactive (list (read-file-name "Copy file to: ") current-prefix-arg))
  (let ((path (buffer-file-name (buffer-base-buffer))))
    (unless path (user-error "Buffer is not visiting a file"))
    (make-directory (file-name-directory new-path) t)
    (copy-file path new-path (or force-p 1))
    (find-file new-path)))

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

(defun jgy/search-symbol-at-point ()
  (interactive)
  (consult-ripgrep nil (thing-at-point 'symbol t)))

(defun jgy/eval-buffer-or-region ()
  "Evaluate the region when active, otherwise the whole buffer."
  (interactive)
  (if (region-active-p)
      (progn (eval-region (region-beginning) (region-end))
             (deactivate-mark)
             (message "Evaluated region"))
    (eval-buffer)
    (message "Evaluated buffer")))

(defun jgy/toggle-line-numbers ()
  "Cycle absolute -> relative -> off."
  (interactive)
  (setq display-line-numbers
        (pcase display-line-numbers
          ('t 'relative)
          ('relative nil)
          (_ t)))
  (message "Line numbers: %s" (or display-line-numbers "off")))

(defun jgy/toggle-indent-style ()
  (interactive)
  (setq indent-tabs-mode (not indent-tabs-mode))
  (message "Indent style: %s" (if indent-tabs-mode "tabs" "spaces")))

(defun jgy/reveal-in-finder ()
  "Reveal the current file in Finder."
  (interactive)
  (call-process "open" nil 0 nil "-R"
                (or (buffer-file-name (buffer-base-buffer)) default-directory)))

(use-package general
  :ensure t
  :config
  (general-evil-setup t)

  (general-create-definer jgy/leader-keys
    :states '(normal insert visual emacs motion)
    :keymaps 'override
    :prefix "SPC"
    :global-prefix "C-SPC")

  ;; home for major-mode specific keys
  (general-create-definer jgy/localleader-keys
    :states '(normal insert visual emacs motion)
    :keymaps 'override
    :prefix "SPC m"
    :global-prefix "C-SPC m")
  (which-key-add-key-based-replacements "SPC m" "localleader")

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
    "h"   '(:keymap help-map :which-key "help")
    "w"   '(:keymap evil-window-map :package evil :which-key "window")

    "b"  '(:ignore t :which-key "buffer")
    "bb" '(consult-buffer :which-key "switch buffer")
    "bB" '(consult-project-buffer :which-key "switch project buffer")
    "bd" '(kill-current-buffer :which-key "kill buffer")
    "bk" '(kill-current-buffer :which-key "kill buffer")
    "bi" '(ibuffer :which-key "ibuffer")
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
    "ca" '(lsp-execute-code-action :which-key "code action")
    "cc" '(compile :which-key "compile")
    "cC" '(recompile :which-key "recompile")
    "cd" '(lsp-find-definition :which-key "definition")
    "cD" '(lsp-find-references :which-key "references")
    "ce" '(jgy/eval-buffer-or-region :which-key "eval buffer/region")
    "cf" '(apheleia-format-buffer :which-key "format buffer")
    "ci" '(lsp-find-implementation :which-key "implementations")
    "ck" '(lsp-describe-thing-at-point :which-key "documentation")
    "cl" '(:keymap lsp-command-map :package lsp-mode :which-key "lsp")
    "co" '(lsp-organize-imports :which-key "organize imports")
    "cr" '(lsp-rename :which-key "rename")
    "ct" '(lsp-find-type-definition :which-key "type definition")
    "cw" '(delete-trailing-whitespace :which-key "delete trailing whitespace")
    "cx" '(consult-flymake :which-key "list diagnostics")

    "f"  '(:ignore t :which-key "file")
    "fC" '(jgy/copy-this-file :which-key "copy this file")
    "fd" '(dirvish :which-key "dirvish")
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
    "g]" '(diff-hl-next-hunk :which-key "next hunk")
    "g[" '(diff-hl-previous-hunk :which-key "previous hunk")
    "gb" '(magit-branch-checkout :which-key "switch branch")
    "gB" '(magit-blame-addition :which-key "blame")
    "gc" '(magit-commit :which-key "commit")
    "gf" '(magit-fetch :which-key "fetch")
    "gF" '(magit-file-dispatch :which-key "file dispatch")
    "gg" '(magit-status :which-key "status")
    "gl" '(magit-log-current :which-key "log")
    "gL" '(magit-log-buffer-file :which-key "buffer log")
    "gr" '(diff-hl-revert-hunk :which-key "revert hunk")
    "gR" '(vc-revert :which-key "revert file")
    "gs" '(diff-hl-stage-dwim :which-key "stage hunk")

    "i"  '(:ignore t :which-key "insert")
    "if" '(jgy/insert-buffer-path :which-key "file path")
    "ir" '(consult-register :which-key "register")
    "iu" '(insert-char :which-key "unicode char")
    "iy" '(consult-yank-pop :which-key "from kill ring")

    "o"  '(:ignore t :which-key "open")
    "o-" '(dired-jump :which-key "dired here")
    "oa" '(ai-code-menu :which-key "ai code")
    "od" '(dap-debug :which-key "debugger")
    "oe" '(eshell :which-key "eshell")
    "oo" '(jgy/reveal-in-finder :which-key "reveal in finder")
    "op" '(treemacs :which-key "project sidebar")
    "oP" '(dirvish-side :which-key "dirvish sidebar")
    "ot" '(ghostel :which-key "terminal")

    "p"  '(:ignore t :which-key "project")
    "p!" '(project-shell-command :which-key "run command")
    "p&" '(project-async-shell-command :which-key "run command async")
    "pb" '(project-switch-to-buffer :which-key "project buffer")
    "pc" '(project-compile :which-key "compile project")
    "pd" '(project-dired :which-key "project root")
    "pe" '(project-eshell :which-key "project eshell")
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
    "si" '(consult-imenu :which-key "symbols in buffer")
    "sI" '(consult-imenu-multi :which-key "symbols in project")
    "sj" '(evil-show-jumps :which-key "jump list")
    "sm" '(evil-show-marks :which-key "marks")
    "sp" '(consult-ripgrep :which-key "search project")
    "ss" '(consult-line :which-key "search buffer")
    "sS" '(consult-line-multi :which-key "search open buffers")
    ;; lsp-mode feeds imenu, so this lists LSP document symbols in code buffers
    "sy" '(consult-imenu :which-key "symbols in buffer")

    "t"  '(:ignore t :which-key "toggle")
    "tc" '(display-fill-column-indicator-mode :which-key "fill column indicator")
    "td" '(toggle-debug-on-error :which-key "debug on error")
    "tf" '(toggle-frame-fullscreen :which-key "fullscreen")
    "tI" '(jgy/toggle-indent-style :which-key "indent style")
    "tl" '(jgy/toggle-line-numbers :which-key "line numbers")
    "tr" '(read-only-mode :which-key "read-only")
    "tt" '(consult-theme :which-key "choose theme")
    "tw" '(visual-line-mode :which-key "soft line wrapping")

    "~"  '(:ignore t :which-key "popup")
    "~~" '(popper-toggle :which-key "toggle latest popup")
    "~n" '(popper-cycle :which-key "cycle popups")
    "~t" '(popper-toggle-type :which-key "popup <-> normal window"))

  ;; SPC h is `help-map', so "r" has to stop being info-emacs-manual first
  (keymap-unset help-map "r" t)
  (keymap-set help-map "r r" #'jgy/reload-config)
  (which-key-add-key-based-replacements "SPC h r" "reload")

  ;; window layout history, next to evil's own C-w bindings
  (general-def evil-window-map
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
    "]e" #'flymake-goto-next-error
    "[e" #'flymake-goto-prev-error
    "]h" #'diff-hl-next-hunk
    "[h" #'diff-hl-previous-hunk
    "zx" #'kill-current-buffer))

;; 把辅助 buffer 收进底部可切换的 popup 窗口
(use-package popper
  :ensure t
  ;; 终端下收不到 C-`，用 SPC ~ 前缀；这两个键留给 GUI
  :bind (("C-`" . popper-toggle)
         ("M-`" . popper-cycle))
  :init
  (setq popper-reference-buffers
        '("\\*Messages\\*"
          "\\*Warnings\\*"
          "\\*Backtrace\\*"
          "\\*Async Shell Command\\*"
          "\\*lsp-help\\*"
          "Output\\*$"
          help-mode
          eshell-mode
          compilation-mode
          xref--xref-buffer-mode
          flymake-diagnostics-buffer-mode
          vterm-mode))
  (setq popper-window-height 0.33)
  (popper-mode 1)
  (popper-echo-mode 1))

;; bound to SPC f e; declared so it does not depend on lsp-treemacs pulling it in
(use-package treemacs
  :ensure t
  :commands treemacs)

(when (eq system-type 'darwin)
  (setq insert-directory-program "/opt/homebrew/bin/gls"))

(use-package dired
  :config
  (setq dired-listing-switches
        "-l --almost-all --human-readable --group-directories-first --no-group")
  ;; this command is useful when you want to close the window of `dirvish-side'
  ;; automatically when opening a file
  (put 'dired-find-alternate-file 'disabled nil))

(use-package dirvish
  :ensure t
	:init
	(dirvish-override-dired-mode)
	:custom
  (dirvish-quick-access-entries ; It's a custom option, `setq' won't work
   '(("h" "~/"                          "Home")
     ("d" "~/Downloads/"                "Downloads")))
	:bind ; Bind `dirvish-fd|dirvish-side|dirvish-dwim' as you see fit
  (:map dirvish-mode-map               ; Dirvish inherits `dired-mode-map'
				(";"   . dired-up-directory)        ; So you can adjust `dired' bindings here
				("?"   . dirvish-dispatch)          ; [?] a helpful cheatsheet
				("a"   . dirvish-setup-menu)        ; [a]ttributes settings:`t' toggles mtime, `f' toggles fullframe, etc.
				("f"   . dirvish-file-info-menu)    ; [f]ile info
				("o"   . dirvish-quick-access)      ; [o]pen `dirvish-quick-access-entries'
				("s"   . dirvish-quicksort)         ; [s]ort flie list
				("r"   . dirvish-history-jump)      ; [r]ecent visited
				("l"   . dirvish-ls-switches-menu)  ; [l]s command flags
				("v"   . dirvish-vc-menu)           ; [v]ersion control commands
				("*"   . dirvish-mark-menu)
				("y"   . dirvish-yank-menu)
				("N"   . dirvish-narrow)
				("^"   . dirvish-history-last)
				("TAB" . dirvish-subtree-toggle)
				("M-f" . dirvish-history-go-forward)
				("M-b" . dirvish-history-go-backward)
				("M-e" . dirvish-emerge-menu)))

;; magit needs transient >= 0.13; Emacs 30 bundles 0.7.2.2, so shadow it early
(elpaca transient)

(use-package magit
  :ensure t
  :after transient
	:init
	(setq magit-process-connection-type t)
  :config
  ;; magit only forwards prompts it recognizes; anything else silently
  ;; stalls in *magit-process*
  (add-to-list 'magit-process-password-prompt-regexps
               "^.*Verification code: ?$"))

;; gutter diffs feed SPC g s/r and ]h/[h
(use-package diff-hl
  :ensure t
  :demand t
  :config
  ;; the fringe is disabled and terminal frames have none, so draw in the margin
  (diff-hl-margin-mode 1)
  (global-diff-hl-mode 1)
  (add-hook 'magit-pre-refresh-hook #'diff-hl-magit-pre-refresh)
  (add-hook 'magit-post-refresh-hook #'diff-hl-magit-post-refresh))

;; lsp advertises `snippetSupport' only when `yas-minor-mode' is fbound, which the
;; `:hook' autoload satisfies from startup; servers then send parameter placeholders
(use-package yasnippet
  :ensure t
  :hook (lsp-mode . yas-minor-mode))

(use-package lsp-mode
  :ensure t
  :init
  (setq lsp-keymap-prefix "C-c l")
  ;; flycheck is not installed; pin the backend so a stray dependency cannot switch it
  (setq lsp-diagnostics-provider :flymake)
  :hook ((go-mode . lsp-deferred)
         (haskell-mode . lsp-deferred)
         (lua-mode . lsp-deferred)
         (java-mode . lsp-deferred)
         (java-ts-mode . lsp-deferred)
         (lsp-mode . lsp-enable-which-key-integration))
  :commands (lsp lsp-deferred)
	:config
  (with-eval-after-load 'evil
    (evil-define-minor-mode-key 'normal 'lsp-mode
      (kbd "K")  #'lsp-describe-thing-at-point
      (kbd "gD") #'lsp-find-references
      (kbd "gI") #'lsp-find-implementation)))

(use-package lsp-ui
  :ensure t
  :commands lsp-ui-mode)

(use-package dap-mode
  :ensure t)

;; Haskell
(use-package haskell-mode
  :ensure t
  :custom
  (haskell-process-type 'cabal-repl))

;; async format-on-save for every language; the RCS-patch apply keeps point put
(use-package apheleia
  :ensure t
  ;; `:bind' alone would defer the package and never run `:config'
  :demand t
  :bind ("C-c r" . apheleia-format-buffer)
  :config
  (setf (alist-get 'haskell-mode apheleia-mode-alist) 'ormolu)
  ;; java formatting belongs to jdt.ls, see `lsp-java-format-tab-size'
  (setf (alist-get 'java-mode apheleia-mode-alist nil t) nil)
  (setf (alist-get 'java-ts-mode apheleia-mode-alist nil t) nil)
  (apheleia-global-mode 1))

(use-package lua-mode
  :ensure t)

(use-package go-mode
  :ensure t)

(use-package rust-mode
  :ensure t)

;; Java
(defvar jgy/sdkman-java-dir (expand-file-name "~/.sdkman/candidates/java/"))

;; global tab-width is 2; lsp-java derives the jdt.ls formatter settings
;; from `c-basic-offset' and `indent-tabs-mode', so these cover both sides
(defun jgy/java-indent-setup ()
  (setq-local indent-tabs-mode nil
              tab-width 4)
  (when (boundp 'c-basic-offset)
    (setq-local c-basic-offset 4))
  (when (boundp 'java-ts-mode-indent-offset)
    (setq-local java-ts-mode-indent-offset 4)))

(add-hook 'java-mode-hook #'jgy/java-indent-setup)
(add-hook 'java-ts-mode-hook #'jgy/java-indent-setup)

(use-package nerd-icons
  :ensure t)

(use-package lsp-java
  :ensure t
  :init
  ;; eclipse.jdt.ls itself needs JDK 21+, independent of what a project targets
  (setq lsp-java-java-path (expand-file-name "25.0.3-tem/bin/java" jgy/sdkman-java-dir))
  ;; JDKs offered to projects; :default is used when a project declares no release
  (setq lsp-java-configuration-runtimes
        (vector (list :name "JavaSE-1.8"
                      :path (expand-file-name "8.0.492-zulu" jgy/sdkman-java-dir))
                (list :name "JavaSE-17"
                      :path (expand-file-name "17.0.19-tem" jgy/sdkman-java-dir)
                      :default t)
                (list :name "JavaSE-25"
                      :path (expand-file-name "25.0.3-tem" jgy/sdkman-java-dir))))
  (setq lsp-java-save-actions-organize-imports nil)
  :config
  ;; jdt.ls has no annotation processing of its own, so Lombok-generated
  ;; members (@Slf4j's `log', @Data's accessors) need the agent to patch ecj
  (add-to-list 'lsp-java-vmargs
               (concat "-javaagent:"
                       (expand-file-name "tmp/lombok.jar" user-emacs-directory))
               t)
  (require 'dap-java))

;; libghostty-vt terminal; the native module is a prebuilt binary fetched on first use
(use-package ghostel
  :ensure t)

(use-package csv-mode
	:ensure t)

;; * AI
;; ACP client; needs `npm install -g @agentclientprotocol/claude-agent-acp'
(use-package agent-shell
  :ensure t
	:ensure-system-package
	((claude . "brew install claude-code")
   (claude-agent-acp . "npm install -g @agentclientprotocol/claude-agent-acp"))
  :commands (agent-shell agent-shell-anthropic-start-claude-code))

(use-package gptel
	:ensure t)

(use-package agent-shell-dashboard
	:ensure (:host github :repo "wandersoncferreira/agent-shell-dashboard")
	:after agent-shell
	:commands (agent-shell-dashboard)
	:config
	;; Optional: open it on startup
	(setq initial-buffer-choice #'agent-shell-dashboard))

(use-package agent-shell-hq
  :ensure (:host nil :repo "https://github.com/sreenivasvrao/agent-shell-hq"
								 :files ("*.el"))
	:after agent-shell)
