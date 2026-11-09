;;; early-init.el --- Early Emacs configuration -*- lexical-binding: t; -*-

(setq package-enable-at-startup nil
      native-comp-async-report-warnings-errors 'silent)

;; 启动期间不做 GC，启动完恢复默认阈值。
(let ((threshold gc-cons-threshold))
  (setq gc-cons-threshold most-positive-fixnum)
  (add-hook 'emacs-startup-hook (lambda () (setq gc-cons-threshold threshold)) -90))

;; 启动中改字体、边距、工具栏时保持像素尺寸，不按行列数重算，
;; 否则启动期间窗口管理器（Raycast）设的大小会被改回去。
(setq frame-inhibit-implied-resize t
      frame-resize-pixelwise t)
(setq default-frame-alist
      (append '((menu-bar-lines . 0) (tool-bar-lines . 0)
                (vertical-scroll-bars) (undecorated-round . t))
              default-frame-alist))
