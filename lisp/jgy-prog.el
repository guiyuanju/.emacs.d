;;; jgy-prog.el --- Language server, indentation and SQL formatting helpers -*- lexical-binding: t; -*-

;;; Commentary:
;; basedpyright 用项目 .venv，Java 四格缩进，SQLMesh 项目启用其 LSP，SQL 按需选择 sqlfluff 方言。

;;; Code:

(require 'project)

(declare-function eglot--project "eglot")
(declare-function eglot-find-implementation "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function eglot-ensure "eglot")
(defvar apheleia-inhibit)

(defun jgy-eglot-python-configuration (server)
  "Return basedpyright settings for SERVER's project virtualenv."
  (when-let* ((root (project-root (eglot--project server)))
              (python (expand-file-name ".venv/bin/python" root))
              ((file-executable-p python)))
    `(:python (:pythonPath ,python)
      :basedpyright (:analysis
                     (:typeCheckingMode "standard"
                      :diagnosticSeverityOverrides
                      (:reportPrivateImportUsage "none"))))))

(defun jgy-java-indent-setup ()
  "Use four-space indentation in Java buffers."
  (setq-local indent-tabs-mode nil tab-width 4)
  (when (boundp 'c-basic-offset) (setq-local c-basic-offset 4))
  (when (boundp 'java-ts-mode-indent-offset)
    (setq-local java-ts-mode-indent-offset 4)))

(defun jgy-sqlmesh-project-p ()
  "Return non-nil when point is inside a SQLMesh project."
  (locate-dominating-file
   default-directory
   (lambda (directory)
     (and (file-exists-p (expand-file-name "config.yaml" directory))
          (file-directory-p (expand-file-name "models" directory))))))

(defun jgy-sqlmesh-setup ()
  "Enable SQLMesh's language server in SQLMesh projects."
  (when (and buffer-file-name (jgy-sqlmesh-project-p))
    (setq-local sql-product 'postgres
                apheleia-inhibit t)
    (local-set-key [remap apheleia-format-buffer] #'eglot-format-buffer)
    (eglot-ensure)))

(defvar jgy-sql-dialects '("mysql" "postgres" "redshift")
  "sqlfluff dialects offered when formatting SQL.")

(defvar-local jgy-sql-dialect "redshift"
  "sqlfluff dialect used to format this buffer.")

(defun jgy-sql-read-dialect (&rest _)
  "Ask which dialect to format this SQL buffer with."
  (when (derived-mode-p 'sql-mode)
    (setq jgy-sql-dialect
          (completing-read (format-prompt "SQL dialect" jgy-sql-dialect)
                           jgy-sql-dialects nil t nil nil jgy-sql-dialect))))

(defun jgy-sql-inhibit-format-on-save ()
  "Format SQL buffers only on demand."
  (derived-mode-p 'sql-mode))

(provide 'jgy-prog)
;;; jgy-prog.el ends here
