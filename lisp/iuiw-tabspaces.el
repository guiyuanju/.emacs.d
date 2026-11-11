;;; iuiw-tabspaces.el --- Restore tabspaces at startup -*- lexical-binding: t; -*-

;;; Commentary:
;; 启动时把第一个 tab 命名为 main，恢复上次保存的 tab，回到最近用过的那个。

;;; Code:

(require 'tabspaces)

(defvar overlook-project-switch-times)

;; 恢复的布局里，看板的 side window 还在，显示的却是别的 buffer。
(defun iuiw-tabspaces--delete-side-windows ()
  "Delete the side windows of every tab, then reselect the current one."
  (let ((current (tabspaces--current-tab-name)))
    (dolist (name (tabspaces--list-tabspaces))
      (tab-bar-select-tab-by-name name)
      (dolist (window (window-list nil 'nomini))
        (when (or (window-parameter window 'window-side)
                  (eq (window-dedicated-p window) 'side))
          (ignore-errors (delete-window window)))))
    (tab-bar-select-tab-by-name current)))

(defun iuiw-tabspaces--most-recent ()
  "Name of the tab switched to last, per overlook, or nil."
  (let ((times (bound-and-true-p overlook-project-switch-times)))
    (car (seq-sort-by (lambda (name) (alist-get name times 0 nil #'equal)) #'>
                      (tabspaces--list-tabspaces)))))

(defun iuiw-tabspaces-restore ()
  "Name the first tab main, then restore the saved tabs."
  (unless (alist-get 'explicit-name (tab-bar--current-tab))
    (tab-bar-rename-tab "main"))
  (when (file-exists-p tabspaces-session-file)
    ;; 恢复时逐个访问 tab，overlook 会把每次访问记成切换。
    (let ((times (and (boundp 'overlook-project-switch-times)
                      (list overlook-project-switch-times))))
      (tabspaces-restore-session tabspaces-session-file)
      (iuiw-tabspaces--delete-side-windows)
      (when times
        (setq overlook-project-switch-times (car times))))
    (when-let* ((name (iuiw-tabspaces--most-recent)))
      (tab-bar-select-tab-by-name name))))

(provide 'iuiw-tabspaces)
;;; iuiw-tabspaces.el ends here
