;;; jgy-ui.el --- Fonts and flat Modus faces -*- lexical-binding: t; -*-

;;; Commentary:
;; 字体（缺失时用 Homebrew 安装）和与扁平 mode line 一致的 Modus 配色。
;; 要在 load-theme 之后加载，配色函数用到 Modus 的宏。

;;; Code:

(require 'subr-x)

(defvar jgy-font-size 14 "Default font size, overridable from local.el.")
(defvar jgy-font-family "Sarasa Mono SC")
(defvar jgy-variable-pitch-font-family "Sarasa UI SC")

(defvar jgy-font-casks '(("Sarasa Mono SC" . "font-sarasa-gothic"))
  "Homebrew casks providing font families.")

(defun jgy-font-available-p (family)
  (find-font (font-spec :family family)))

(defun jgy-apply-fonts ()
  "Use Sarasa for every face and script."
  (when (jgy-font-available-p jgy-font-family)
    (setf (alist-get 'font default-frame-alist)
          (format "%s %d" jgy-font-family jgy-font-size))
    (set-face-attribute 'default nil :family jgy-font-family :height (* jgy-font-size 10))
    (set-face-attribute 'fixed-pitch nil :family jgy-font-family)
    (set-face-attribute 'variable-pitch nil :family jgy-variable-pitch-font-family)
    ;; 固定中日韩字体族，否则粗体会回退到 Arial Unicode MS。
    (dolist (script '(han cjk-misc bopomofo kana hangul))
      (set-fontset-font t script (font-spec :family jgy-font-family)))))

(defun jgy-ensure-fonts ()
  "Install missing fonts with Homebrew in the background, then reapply them."
  (interactive)
  (let ((casks (when-let* (((not (jgy-font-available-p jgy-font-family)))
                           (cask (alist-get jgy-font-family jgy-font-casks nil nil #'equal)))
                 (list cask))))
    (cond
     ((null casks))
     ((not (executable-find "brew"))
      (display-warning 'fonts (format "Missing fonts; run: brew install --cask %s"
                                      (string-join casks " "))))
     (t
      (message "Installing fonts: %s" (string-join casks " "))
      (make-process
       :name "jgy-font-install"
       :buffer "*font-install*"
       :command (append '("brew" "install" "--cask") casks)
       :sentinel (lambda (process _event)
                   (when (memq (process-status process) '(exit signal))
                     (if (zerop (process-exit-status process))
                         ;; macOS 注册新字体有延迟，立即应用会找不到。
                         (run-with-timer 2 nil
                                         (lambda ()
                                           (clear-font-cache)
                                           (jgy-apply-fonts)
                                           (message "Fonts installed: %s" (string-join casks " "))))
                       (display-warning 'fonts "Font install failed; see *font-install*")))))))))

;; Modus draws window dividers gray and gives header lines their own strip, and
;; agent-shell tints its header with font-lock colors.  Reuse the flat mode
;; line's colors for all of them so the frame looks like one piece.
(defun jgy-modus-flat-faces ()
  "Match dividers, header lines, and the agent-shell header to the flat mode line."
  (modus-themes-with-colors
    (set-face-attribute 'vertical-border nil :foreground bg-inactive)
    (set-face-attribute 'window-divider nil :foreground bg-inactive)
    (set-face-attribute 'window-divider-first-pixel nil :foreground bg-inactive)
    (set-face-attribute 'window-divider-last-pixel nil :foreground bg-inactive)
    (set-face-attribute 'header-line nil :background bg-inactive)
    (set-face-attribute 'header-line-inactive nil
                        :background bg-dim :foreground bg-active)
    (when (facep 'agent-shell-model)
      (set-face-attribute 'agent-shell-buffer-name nil
                          :inherit 'bold :foreground fg-main)
      (dolist (face '(agent-shell-model agent-shell-thought-level
                      agent-shell-session-mode agent-shell-session-directory
                      agent-shell-container-indicator))
        (set-face-attribute face nil :inherit nil :foreground fg-dim)))))

(provide 'jgy-ui)
;;; jgy-ui.el ends here
