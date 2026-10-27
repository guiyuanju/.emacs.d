;;; iuiw-ui.el --- Fonts and flat Modus faces -*- lexical-binding: t; -*-

;;; Commentary:
;; 字体（缺失时用 Homebrew 安装）和与扁平 mode line 一致的 Modus 配色。
;; 要在 load-theme 之后加载，配色函数用到 Modus 的宏。

;;; Code:


(declare-function modus-themes-get-color-value "modus-themes")

(defvar iuiw-font-size 14 "Default font size, overridable from local.el.")
(defvar iuiw-font-family "Sarasa Mono SC")
(defvar iuiw-variable-pitch-font-family "Sarasa UI SC")

(defvar iuiw-font-casks '(("Sarasa Mono SC" . "font-sarasa-gothic"))
  "Homebrew casks providing font families.")

(defun iuiw-font-available-p (family)
  (find-font (font-spec :family family)))

(defun iuiw-apply-fonts ()
  "Use Sarasa for every face and script."
  (when (iuiw-font-available-p iuiw-font-family)
    (setf (alist-get 'font default-frame-alist)
          (format "%s %d" iuiw-font-family iuiw-font-size))
    (set-face-attribute 'default nil :family iuiw-font-family :height (* iuiw-font-size 10))
    (set-face-attribute 'fixed-pitch nil :family iuiw-font-family)
    (set-face-attribute 'variable-pitch nil :family iuiw-variable-pitch-font-family)
    ;; 固定中日韩字体族，否则粗体会回退到 Arial Unicode MS。
    (dolist (script '(han cjk-misc bopomofo kana hangul))
      (set-fontset-font t script (font-spec :family iuiw-font-family)))))

(defun iuiw-ensure-fonts ()
  "Install missing fonts with Homebrew in the background, then reapply them."
  (interactive)
  (let ((casks (when-let* (((not (iuiw-font-available-p iuiw-font-family)))
                           (cask (alist-get iuiw-font-family iuiw-font-casks nil nil #'equal)))
                 (list cask))))
    (cond
     ((null casks))
     ((not (executable-find "brew"))
      (display-warning 'fonts (format "Missing fonts; run: brew install --cask %s"
                                      (string-join casks " "))))
     (t
      (message "Installing fonts: %s" (string-join casks " "))
      (make-process
       :name "iuiw-font-install"
       :buffer "*font-install*"
       :command (append '("brew" "install" "--cask") casks)
       :sentinel (lambda (process _event)
                   (when (memq (process-status process) '(exit signal))
                     (if (zerop (process-exit-status process))
                         ;; macOS 注册新字体有延迟，立即应用会找不到。
                         (run-with-timer 2 nil
                                         (lambda ()
                                           (clear-font-cache)
                                           (iuiw-apply-fonts)
                                           (message "Fonts installed: %s" (string-join casks " "))))
                       (display-warning 'fonts "Font install failed; see *font-install*")))))))))

;; Furifont 用 OpenType 连字给汉字词注假名，Emacs 默认逐字渲染汉字，
;; 要用组合规则把连续汉字交给塑形器。中日汉字码位相同，只能全局切换。
(defvar iuiw-furigana-font-family "Furifont Sans")

(defvar iuiw-furigana-font-url
  "https://github.com/antfu/furifont/releases/latest/download/FurifontSans-Regular.otf")

(defun iuiw-furigana--han-ranges ()
  "Ranges of Han characters, plus 々 which joins kanji runs."
  (let (ranges)
    (map-char-table (lambda (range script)
                      ;; map-char-table 复用同一个 cons 传 range。
                      (when (eq script 'han) (push (copy-tree range) ranges)))
                    char-script-table)
    (cons ?々 ranges)))

(defun iuiw-furigana--enable ()
  (dolist (script '(han kana))
    (set-fontset-font t script (font-spec :family iuiw-furigana-font-family) nil 'prepend))
  (let ((rule (list (vector "\\cC+" 0 #'compose-gstring-for-graphic))))
    (dolist (range (iuiw-furigana--han-ranges))
      (set-char-table-range composition-function-table range rule)))
  (clear-face-cache t))

(defun iuiw-furigana--disable ()
  (dolist (range (iuiw-furigana--han-ranges))
    (set-char-table-range composition-function-table range nil))
  (iuiw-apply-fonts)
  (clear-face-cache t))

(defun iuiw-furigana--install-font (then)
  "Download Furifont into ~/Library/Fonts, then call THEN."
  (let ((file (expand-file-name (file-name-nondirectory iuiw-furigana-font-url)
                                "~/Library/Fonts/")))
    (message "Downloading %s..." iuiw-furigana-font-family)
    (make-process
     :name "iuiw-furigana-install"
     :buffer "*font-install*"
     :command (list "curl" "-fsSL" "-o" file iuiw-furigana-font-url)
     :sentinel (lambda (process _event)
                 (when (memq (process-status process) '(exit signal))
                   (if (zerop (process-exit-status process))
                       ;; macOS 注册新字体有延迟，立即应用会找不到。
                       (run-with-timer 2 nil (lambda () (clear-font-cache) (funcall then)))
                     (display-warning 'fonts "Furifont download failed; see *font-install*")))))))

(define-minor-mode iuiw-furigana-mode
  "Show furigana over kanji with Furifont.  Chinese text gets readings too."
  :global t
  :group 'faces
  (cond
   ((not iuiw-furigana-mode) (iuiw-furigana--disable))
   ((iuiw-font-available-p iuiw-furigana-font-family) (iuiw-furigana--enable))
   (t
    (setq iuiw-furigana-mode nil)
    (when (y-or-n-p (format "%s is not installed.  Download it? " iuiw-furigana-font-family))
      (iuiw-furigana--install-font (lambda () (iuiw-furigana-mode 1)))))))

;; Modus draws window dividers gray and gives header lines their own strip.
;; Reuse the flat mode line's colors for them so the frame looks like one piece.
(defun iuiw-modus-flat-faces ()
  "Match header lines to the flat mode line."
  (let ((bg-inactive (modus-themes-get-color-value 'bg-inactive t))
        (bg-dim (modus-themes-get-color-value 'bg-dim t))
        (bg-active (modus-themes-get-color-value 'bg-active t)))
    (set-face-attribute 'header-line nil :background bg-inactive)
    (set-face-attribute 'header-line-inactive nil
                        :background bg-dim :foreground bg-active)))

(provide 'iuiw-ui)
;;; iuiw-ui.el ends here
