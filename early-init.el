;;; early-init.el --- Early Emacs configuration -*- lexical-binding: t; -*-

(setq package-enable-at-startup nil
      native-comp-async-report-warnings-errors 'silent)

;; 启动期间不做 GC，启动完恢复默认阈值。
(let ((threshold gc-cons-threshold))
  (setq gc-cons-threshold most-positive-fixnum)
  (add-hook 'emacs-startup-hook (lambda () (setq gc-cons-threshold threshold))))
