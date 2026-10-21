;;; jgy-prog.el --- Language server, indentation and SQL formatting helpers -*- lexical-binding: t; -*-

;;; Commentary:
;; basedpyright 用项目 .venv，Java 四格缩进，SQLMesh 项目启用其 LSP，SQL 按需选择 sqlfluff 方言。

;;; Code:

(require 'project)
(require 'xref)

(declare-function eglot--project "eglot")
(declare-function eglot-find-implementation "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function eglot-ensure "eglot")
(declare-function consult-global-mark "consult")
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

(defun jgy-sqlmesh-signal-locations (name)
  "Return xref items for signal NAME defined under the project's signals/."
  (when-let* ((root (jgy-sqlmesh-project-p))
              (dir (expand-file-name "signals" root))
              ((file-directory-p dir)))
    (let ((regexp (format "^def %s\\_>" (regexp-quote name)))
          items)
      (dolist (file (directory-files dir t "\\.py\\'") (nreverse items))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (when (re-search-forward regexp nil t)
            (push (xref-make (buffer-substring (line-beginning-position)
                                               (line-end-position))
                             (xref-make-file-location
                              file (line-number-at-pos) 0))
                  items)))))))

;; sqlmesh_lsp 不解析 signals (...) 里的 signal 名，这里先接管，其余交给 Eglot。
(defun jgy-sqlmesh-signal-xref-backend ()
  "Return the signal backend when the symbol at point is a SQLMesh signal."
  (when-let* ((name (thing-at-point 'symbol t))
              ((jgy-sqlmesh-signal-locations name)))
    'jgy-sqlmesh-signal))

(cl-defmethod xref-backend-identifier-at-point ((_ (eql jgy-sqlmesh-signal)))
  (thing-at-point 'symbol t))

(cl-defmethod xref-backend-definitions ((_ (eql jgy-sqlmesh-signal)) name)
  (jgy-sqlmesh-signal-locations name))

(defun jgy-sqlmesh-setup ()
  "Enable SQLMesh's language server in SQLMesh projects."
  (when (and buffer-file-name (jgy-sqlmesh-project-p))
    (setq-local sql-product 'postgres
                apheleia-inhibit t)
    (local-set-key [remap apheleia-format-buffer] #'eglot-format-buffer)
    (add-hook 'xref-backend-functions #'jgy-sqlmesh-signal-xref-backend -10 t)
    (eglot-ensure)))

(defun jgy-xref-history ()
  "Pick a position from the xref back stack and return to it.
Like repeating `xref-go-back' up to that position, so `xref-go-forward'
retraces the skipped levels."
  (interactive)
  (let* ((history (xref--get-history))
         (back (seq-filter #'marker-buffer (car history)))
         (origin (point-marker)))
    (unless back (user-error "At start of xref history"))
    (consult-global-mark back)
    (if-let* ((index (seq-position
                      (car history) (point-marker)
                      (lambda (m here)
                        (and (eq (marker-buffer m) (marker-buffer here))
                             (= m here))))))
        (let ((skipped (cons origin (seq-take (car history) index)))
              (target (nth index (car history))))
          (dolist (marker skipped) (xref--push-forward marker))
          (setcar history (nthcdr (1+ index) (car history)))
          (set-marker target nil)
          (run-hooks 'xref-after-return-hook))
      (set-marker origin nil))))

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
