;;; run.el --- Byte-compile courier and run its tests -*- lexical-binding: t; -*-

;; emacs -Q --batch -l test/run.el
;; Dependencies are found through COURIER_LOAD_PATH, a list of
;; directories separated like PATH.

(let* ((root (file-name-directory (directory-file-name
                                   (file-name-directory load-file-name))))
       (out (make-temp-file "courier-elc" t)))
  (dolist (dir (parse-colon-path (getenv "COURIER_LOAD_PATH")))
    (add-to-list 'load-path dir))
  (add-to-list 'load-path root)
  (setq byte-compile-error-on-warn t
        byte-compile-dest-file-function
        (lambda (file) (expand-file-name (concat (file-name-base file) ".elc") out)))
  (let ((failed (seq-remove #'byte-compile-file
                            (directory-files root t "\\`courier.*\\.el\\'"))))
    (delete-directory out t)
    (when failed
      (message "Byte-compilation failed: %s" (mapconcat #'file-name-nondirectory failed " "))
      (kill-emacs 1)))
  (require 'ert)
  (mapc #'load (directory-files (expand-file-name "test" root) t "-test\\.el\\'"))
  (ert-run-tests-batch-and-exit))
