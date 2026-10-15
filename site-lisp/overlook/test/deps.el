;;; deps.el --- Install overlook's dependencies for CI -*- lexical-binding: t; -*-

;; Loaded before test/run.el or test/lint.el when OVERLOOK_INSTALL_DEPS is
;; set: installs the packages they need into .elpa/ from GNU ELPA and MELPA.

(require 'package)
(setq package-user-dir (expand-file-name ".elpa" (file-name-directory
                                                  (directory-file-name
                                                   (file-name-directory load-file-name))))
      package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("melpa" . "https://melpa.org/packages/")))
(package-initialize)
(let ((wanted '(magit-section perspective agent-shell package-lint)))
  (when (seq-remove #'package-installed-p wanted)
    (package-refresh-contents)
    (dolist (name wanted)
      (unless (package-installed-p name) (package-install name)))))
