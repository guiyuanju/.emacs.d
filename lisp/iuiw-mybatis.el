;;; iuiw-mybatis.el --- Jump between MyBatis mapper interfaces and XML -*- lexical-binding: t; -*-

;;; Commentary:
;; jdtls 不认 MyBatis 的 XML：在 Mapper 接口的方法上跳到 XML 里同 id 的语句，
;; 在 XML 语句里跳回接口方法；其余情况交给原来的跳转命令。

;;; Code:

(require 'subr-x)
(require 'xref)

(declare-function evil-set-jump "evil-jumps")

(defconst iuiw-mybatis--statement-regexp
  "<\\(?:select\\|insert\\|update\\|delete\\|sql\\)\\_>[^>]*?\\_<id=\"\\([^\"]+\\)\""
  "Regexp matching a mapper statement's opening tag; group 1 is its id.")

(defun iuiw-mybatis--root ()
  "Return the git root of the current file, or `default-directory'."
  (expand-file-name
   (or (locate-dominating-file default-directory ".git") default-directory)))

(defun iuiw-mybatis--rg (&rest args)
  "Run rg with ARGS and return the existing files it prints."
  ;; process-lines 把 stderr 也混进输出，只留真实存在的文件。
  (seq-filter #'file-regular-p (apply #'process-lines-ignore-status "rg" args)))

(defun iuiw-mybatis--java-class ()
  "Return the fully qualified name of this Java buffer's interface."
  (save-excursion
    (goto-char (point-min))
    (when (and (save-excursion (re-search-forward "^[^/*\n]*\\_<interface\\_>" nil t))
               (re-search-forward "^package[ \t]+\\([[:alnum:]_.]+\\)[ \t]*;" nil t))
      (concat (match-string-no-properties 1) "."
              (file-name-base buffer-file-name)))))

(defun iuiw-mybatis--search-file (file regexp)
  "Return the position of the first match of REGEXP in FILE, or nil."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (re-search-forward regexp nil t)
      (match-beginning 0))))

(defun iuiw-mybatis--xml-location (class id)
  "Return (FILE . POS) of statement ID in the mapper XML of CLASS."
  (let ((regexp (format "<\\(?:select\\|insert\\|update\\|delete\\|sql\\)\\_>[^>]*?\\_<id=\"%s\""
                        (regexp-quote id))))
    (seq-some (lambda (file)
                (when-let* ((pos (iuiw-mybatis--search-file file regexp)))
                  (cons file pos)))
              (iuiw-mybatis--rg "-l" "--fixed-strings" "--glob" "*.xml"
                               (format "namespace=\"%s\"" class)
                               (iuiw-mybatis--root)))))

(defun iuiw-mybatis--java-location (class id)
  "Return (FILE . POS) of method ID in CLASS, or of the class when ID is nil."
  (let* ((name (car (last (split-string class "\\."))))
         (package (string-remove-suffix (concat "." name) class))
         (package-regexp (format "^package[ \t]+%s[ \t]*;" (regexp-quote package))))
    (seq-some (lambda (file)
                (when (iuiw-mybatis--search-file file package-regexp)
                  (cons file
                        (or (and id (iuiw-mybatis--search-file
                                     file (format "\\_<%s[ \t\n]*(" (regexp-quote id))))
                            (iuiw-mybatis--search-file
                             file (format "\\_<%s\\_>" (regexp-quote name)))))))
              (iuiw-mybatis--rg "--files" "--glob" (concat name ".java")
                               (iuiw-mybatis--root)))))

(defun iuiw-mybatis--xml-target ()
  "Return the Java location for the mapper statement around point."
  (save-excursion
    (let ((line-end (line-end-position)))
      (goto-char (point-min))
      (when (re-search-forward "<mapper[^>]*?namespace=\"\\([^\"]+\\)\"" nil t)
        (let ((class (match-string-no-properties 1))
              (header-end (point))
              id)
          (goto-char line-end)
          (when (and (re-search-backward iuiw-mybatis--statement-regexp nil t)
                     (> (point) header-end))
            (setq id (match-string-no-properties 1)))
          (iuiw-mybatis--java-location class id))))))

(defun iuiw-mybatis--java-target ()
  "Return the XML location for the mapper method at point."
  (when-let* ((id (thing-at-point 'symbol t))
              (class (iuiw-mybatis--java-class)))
    (iuiw-mybatis--xml-location class id)))

(defun iuiw-mybatis-find-definition ()
  "Jump between a MyBatis mapper method and its XML statement.
Fall back to the command this one remaps when point is not on one."
  (interactive)
  (if-let* ((target (if (derived-mode-p 'nxml-mode)
                        (iuiw-mybatis--xml-target)
                      (iuiw-mybatis--java-target))))
      (progn
        (xref-push-marker-stack)
        (when (fboundp 'evil-set-jump) (evil-set-jump))
        (find-file (car target))
        (goto-char (cdr target)))
    (call-interactively
     (if (eq this-original-command #'iuiw-mybatis-find-definition)
         #'xref-find-definitions
       this-original-command))))

(defvar iuiw-mybatis-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [remap xref-find-definitions] #'iuiw-mybatis-find-definition)
    (define-key map [remap evil-goto-definition] #'iuiw-mybatis-find-definition)
    map)
  "Keymap for `iuiw-mybatis-mode'.")

(define-minor-mode iuiw-mybatis-mode
  "Let go-to-definition jump between MyBatis mapper interfaces and XML."
  :keymap iuiw-mybatis-mode-map)

(provide 'iuiw-mybatis)
;;; iuiw-mybatis.el ends here
