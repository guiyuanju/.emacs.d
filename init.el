;; * UI
(setq inhibit-startup-message t) ; don't show the splash screen
(setq visible-bell nil) ; flash when the bell rings
(setq ring-bell-function 'ignore) ; disable bell sound
(setq use-dialog-box nil) ; don't use ui dialogs for prompting
(menu-bar-mode -1) ; disable menu bar on the top, the same line as apple icon
(tool-bar-mode -1) ; disable tool bar, the same line as close, maximize buttons
(scroll-bar-mode -1) ; disable visible scrollbar
(tooltip-mode -1) ; disable tooltips
(set-fringe-mode 0) ; fringe
(blink-cursor-mode -1) ; disable cursor blinking
(hl-line-mode 1) ; highlight current line
(global-display-line-numbers-mode 1) ; enable line numbers in every buffer
(set-frame-font "Iosevka 15" nil t) ; set font and size for all buffers
(load-theme 'modus-vivendi t) ; load theme

;; * Function
(recentf-mode 1) ; use recentf-open-files to open recent files
(save-place-mode 1) ; restore cursor location
(global-auto-revert-mode 1) ; revert buffers when underlying files has changed
(setq global-auto-revert-non-file-buffers t) ; revert Dired and other buffers
(setq history-length 25) (savehist-mode 1) ; save what you enter into minibuffer prompts, use M-p, M-n to get previous-history-element or next-history-element
(setq enable-recursive-minibuffers t) ; support opening new minibuffers from inside existing minibuffers.
(setq read-extended-command-predicate #'command-completion-default-include-p) ; hide commands in M-x which do not work in the current mode

;; * Unclutter
;; move custom vars to a separate file and load it (custom-set-variables ...)
(setq custom-file (locate-user-emacs-file "custom-vars.el"))
(load custom-file 'noerror 'nomessage)
;; move auto backup file to tmp/backups
(setq backup-directory-alist `(("." . ,(expand-file-name "tmp/backups/" user-emacs-directory))))
;; auto-save-mode doesn't create the path automatically!
(make-directory (expand-file-name "tmp/auto-saves/" user-emacs-directory) t)
(setq auto-save-list-file-prefix (expand-file-name "tmp/auto-saves/sessions/" user-emacs-directory)
      auto-save-file-name-transforms `((".*" ,(expand-file-name "tmp/auto-saves/" user-emacs-directory) t)))
;; projectile and lsp mode files clean up
(setq projectile-known-projects-file (expand-file-name "tmp/projectile-bookmarks.eld" user-emacs-directory)
      lsp-session-file (expand-file-name "tmp/.lsp-session-v1" user-emacs-directory))


;; Elpaca Elisp Packaeg Manager
(defvar elpaca-installer-version 0.7)
(defvar elpaca-directory (expand-file-name "elpaca/" user-emacs-directory))
(defvar elpaca-builds-directory (expand-file-name "builds/" elpaca-directory))
(defvar elpaca-repos-directory (expand-file-name "repos/" elpaca-directory))
(defvar elpaca-order '(elpaca :repo "https://github.com/progfolio/elpaca.git"
                              :ref nil :depth 1
                              :files (:defaults "elpaca-test.el" (:exclude "extensions"))
                              :build (:not elpaca--activate-package)))
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

;; Path
(use-package exec-path-from-shell
  :ensure t
  :if (memq window-system '(mac ns x))
  :config
  (setq exec-path-from-shell-variables '("PATH" "GOPATH"))
  (exec-path-from-shell-initialize))

;; Vertico
(use-package vertico
  :ensure t
  :custom
  ;; (vertico-scroll-margin 0) ;; Different scroll margin
  ;; (vertico-count 20) ;; Show more candidates
  ;; (vertico-resize t) ;; Grow and shrink the Vertico minibuffer
  (vertico-cycle t) ;; Enable cycling for `vertico-next/previous'
  :config
  (vertico-mode))

(use-package consult
  :ensure t
  :custom
  (completion-styles '(substring basic)))

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

(use-package which-key
  :ensure t
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

(defun jgy/evil-hook ()
  (dolist (mode '(custom-mode
                  eshell-mode
                  git-rebase-mode
                  erc-mode
                  circe-server-mode
                  circe-chat-mode
                  circe-query-mode
                  sauron-mode
                  term-mode))
   (add-to-list 'evil-emacs-state-modes mode)))

(use-package evil
  :ensure t
  :init
  (setq evil-want-integration t)
  (setq evil-want-keybinding nil)
  (setq evil-want-C-u-scroll t)
  (setq evil-want-C-i-jump nil)
  :hook (evil-mode . jgy/evil-hook)
  :config
  (evil-mode 1)
  (define-key evil-insert-state-map (kbd "C-g") 'evil-normal-state)
  (define-key evil-insert-state-map (kbd "C-h") 'evil-delete-backward-char-and-join)
  (evil-global-set-key 'motion "j" 'evil-next-visual-line)
  (evil-global-set-key 'motion "k" 'evil-previous-visual-line)
  (evil-set-initial-state 'messages-buffer-mode 'normal)
  (evil-set-initial-state 'dashboard-mode 'normal)))

(use-package evil-collection
  :after evil
  :ensure t
  :config
  (evil-collection-init))

(use-package evil-commentary
  :ensure t
  :config
  (evil-commentary-mode 1))

(use-package general
  :ensure t
  :config
  (general-evil-setup t)

  (general-create-definer jgy/leader-keys
    :keymaps '(normal insert visual emacs)
    :prefix "SPC"
    :global-prefix "C-SPC"))

(jgy/leader-keys
  "t"  '(:ignore t :which-key "toggles")
  "tt" '(consult-theme :which-key "choose theme")

  "o" '(:ignore t :which-key "open")
  "oe" '(eshell :which-key "eshell")

  "b" '(:ignore :which-key "buffer")
  "bd" '(kill-buffer :which-key "kill buffer")

  "f" '(:ignore t :which-key "file")
  "fr" '(consult-recent-file :which-key "recent files")
  "ff" '(find-file :which-key "find file")
  "fs" '(consult-line :which-key "search")

  "w" '(:ignore t :which-key "window")
  "wd" '(delete-window :which-key "delete window")
  )

(use-package magit
  :ensure t)

(use-package lsp-mode
  :init
  (setq lsp-keymap-prefix "C-c l")
  :hook ((go-mode . lsp-deferred)
         (haskell-mode . lsp-deferred)
         (lua-mode . lsp-deferred)
         (lsp-mode . lsp-enable-which-key-integration))
  :commands (lsp lsp-deferred))

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

;; Haskell formatter
(use-package ormolu
  :ensure t
  :hook (haskell-mode . ormolu-format-on-save-mode)
  :bind
  (:map haskell-mode-map
	("C-c r" . ormolu-format-buffer)))

(use-package lua-mode
  :ensure t)

(use-package go-mode
  :ensure t)

(use-package vterm
    :ensure t)
