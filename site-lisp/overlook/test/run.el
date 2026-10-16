;;; run.el --- Byte-compile overlook and run its tests -*- lexical-binding: t; -*-

;; emacs -Q --batch -l test/run.el
;; Dependencies are found through OVERLOOK_LOAD_PATH, a list of
;; directories separated like PATH.

(let* ((root (file-name-directory (directory-file-name
                                   (file-name-directory load-file-name))))
       (out (make-temp-file "overlook-elc" t)))
  (dolist (dir (parse-colon-path (getenv "OVERLOOK_LOAD_PATH")))
    (add-to-list 'load-path dir))
  (add-to-list 'load-path root)
  (setq byte-compile-error-on-warn t
        byte-compile-dest-file-function
        (lambda (file) (expand-file-name (concat (file-name-base file) ".elc") out)))
  (let ((failed (seq-remove #'byte-compile-file
                            (directory-files root t "\\`\\(?:overlook.*\\|courier\\)\\.el\\'"))))
    (delete-directory out t)
    (when failed
      (message "Byte-compilation failed: %s" (mapconcat #'file-name-nondirectory failed " "))
      (kill-emacs 1)))
  (require 'ert)
  (mapc #'load (directory-files (expand-file-name "test" root) t "-test\\.el\\'"))
  ;; Batch Emacs has no focused frame, so agent turns would notify the desktop.
  (setq overlook-agent-notify-function #'ignore)
  (ert-run-tests-batch-and-exit))
