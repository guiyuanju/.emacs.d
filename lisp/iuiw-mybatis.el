;;; iuiw-mybatis.el --- Jump between MyBatis mapper interfaces and XML -*- lexical-binding: t; -*-

;;; Commentary:
;; jdtls 不认 MyBatis 的 XML：在 Mapper 接口的方法上跳到 XML 里同 id 的语句，
;; 在 XML 语句里跳回接口方法。做成排在最前的 xref backend，只接管跳定义，
;; 找引用等其余请求和不在 mapper 上的跳转都交给下一个 backend（通常是 Eglot）。

;;; Code:

(require 'subr-x)
(require 'xref)

(defconst iuiw-mybatis--statement-open
  "<\\(?:select\\|insert\\|update\\|delete\\|sql\\)\\_>[^>]*?\\_<id=\""
  "Regexp matching a mapper statement's opening tag up to its id's value.")

(defconst iuiw-mybatis--statement-regexp
  (concat iuiw-mybatis--statement-open "\\([^\"]+\\)\"")
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
  "Return the xref location of the first match of REGEXP in FILE, or nil."
  (with-temp-buffer
    (insert-file-contents file)
    (when (re-search-forward regexp nil t)
      (goto-char (match-beginning 0))
      (xref-make-file-location file (line-number-at-pos) (current-column)))))

(defun iuiw-mybatis--xml-location (class id)
  "Return the location of statement ID in the mapper XML of CLASS."
  (let ((regexp (concat iuiw-mybatis--statement-open (regexp-quote id) "\"")))
    (seq-some (lambda (file) (iuiw-mybatis--search-file file regexp))
              (iuiw-mybatis--rg "-l" "--fixed-strings" "--glob" "*.xml"
                               (format "namespace=\"%s\"" class)
                               (iuiw-mybatis--root)))))

(defun iuiw-mybatis--java-location (class id)
  "Return the location of method ID in CLASS, or of the class when ID is nil."
  (let* ((name (car (last (split-string class "\\."))))
         (package (string-remove-suffix (concat "." name) class))
         (package-regexp (format "^package[ \t]+%s[ \t]*;" (regexp-quote package))))
    (seq-some (lambda (file)
                (when (iuiw-mybatis--search-file file package-regexp)
                  (or (and id (iuiw-mybatis--search-file
                               file (format "\\_<%s[ \t\n]*(" (regexp-quote id))))
                      (iuiw-mybatis--search-file
                       file (format "\\_<%s\\_>" (regexp-quote name))))))
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

;;; xref

(defvar-local iuiw-mybatis--target nil
  "Location the last `iuiw-mybatis-xref-backend' call found for point.")

(defun iuiw-mybatis-xref-backend ()
  "Return the MyBatis backend when point is on a mapper method or statement."
  (when-let* ((target (if (derived-mode-p 'nxml-mode)
                          (iuiw-mybatis--xml-target)
                        (iuiw-mybatis--java-target))))
    (setq iuiw-mybatis--target target)
    'iuiw-mybatis))

(defun iuiw-mybatis--next-backend ()
  "Return the backend xref would use without this one."
  (let ((xref-backend-functions
         (remq #'iuiw-mybatis-xref-backend xref-backend-functions)))
    (xref-find-backend)))

;; 光标可以在 XML 语句里任何位置，不一定在符号上。
(cl-defmethod xref-backend-identifier-at-point ((_ (eql iuiw-mybatis)))
  (or (thing-at-point 'symbol t) "MyBatis"))

(cl-defmethod xref-backend-definitions ((_ (eql iuiw-mybatis)) _identifier)
  (list (xref-make (file-name-nondirectory (xref-location-group iuiw-mybatis--target))
                   iuiw-mybatis--target)))

(cl-defmethod xref-backend-references ((_ (eql iuiw-mybatis)) identifier)
  (xref-backend-references (iuiw-mybatis--next-backend) identifier))

(cl-defmethod xref-backend-apropos ((_ (eql iuiw-mybatis)) pattern)
  (xref-backend-apropos (iuiw-mybatis--next-backend) pattern))

(cl-defmethod xref-backend-identifier-completion-table ((_ (eql iuiw-mybatis)))
  (xref-backend-identifier-completion-table (iuiw-mybatis--next-backend)))

(define-minor-mode iuiw-mybatis-mode
  "Let go-to-definition jump between MyBatis mapper interfaces and XML."
  :lighter nil
  (if iuiw-mybatis-mode
      (add-hook 'xref-backend-functions #'iuiw-mybatis-xref-backend -10 t)
    (remove-hook 'xref-backend-functions #'iuiw-mybatis-xref-backend t)))

(provide 'iuiw-mybatis)
;;; iuiw-mybatis.el ends here
