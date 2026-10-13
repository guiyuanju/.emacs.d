;;; lint.el --- Run package-lint and checkdoc over courier -*- lexical-binding: t; -*-

;; emacs -Q --batch -l test/lint.el
;; Needs package-lint and courier's dependencies on the load path, from
;; package.el (see test/deps.el) or COURIER_LOAD_PATH.

(let* ((root (file-name-directory (directory-file-name
                                   (file-name-directory load-file-name))))
       (files (directory-files root t "\\`courier.*\\.el\\'"))
       (failed nil))
  (dolist (dir (parse-colon-path (getenv "COURIER_LOAD_PATH")))
    (add-to-list 'load-path dir))
  (add-to-list 'load-path root)
  (require 'package-lint)
  (require 'checkdoc)
  (let ((package-lint-main-file (expand-file-name "courier.el" root)))
    (dolist (file files)
      (with-current-buffer (find-file-noselect file)
        (dolist (issue (package-lint-buffer))
          (setq failed t)
          (message "%s:%d:%d: %s: %s" (file-name-nondirectory file)
                   (nth 0 issue) (nth 1 issue) (nth 2 issue) (nth 3 issue))))))
  ;; checkdoc reports each problem through `checkdoc-error'.
  (advice-add 'checkdoc-error :before (lambda (&rest _) (setq failed t)))
  (dolist (file files) (checkdoc-file file))
  (kill-emacs (if failed 1 0)))
