;;; iuiw-tabspaces.el --- Restore tabspaces at startup -*- lexical-binding: t; -*-

;;; Commentary:
;; 启动时把第一个 tab 命名为 main，恢复上次保存的 tab，回到最近用过的那个。
;; 只有这个 tab 立即打开文件；其余 tab 先建空的，第一次切过去时才打开文件、摆回布局。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'tabspaces)

(defvar overlook-project-switch-times)

(defvar iuiw-tabspaces--pending nil
  "Session entries (RECORDS NAME WINDOW-STATE) of tabs not restored yet.")

(defvar iuiw-tabspaces--inhibit nil
  "Non-nil while tabs are being cycled through, so pending tabs stay pending.")

;; 恢复的布局里，看板的 side window 还在，显示的却是别的 buffer。
(defun iuiw-tabspaces--delete-side-windows ()
  "Delete the side windows of the current tab."
  (dolist (window (window-list nil 'nomini))
    (when (or (window-parameter window 'window-side)
              (eq (window-dedicated-p window) 'side))
      (ignore-errors (delete-window window)))))

(defun iuiw-tabspaces--most-recent (names)
  "The one of NAMES switched to last, per overlook, or nil."
  (when-let* ((times (bound-and-true-p overlook-project-switch-times)))
    (car (seq-sort-by (lambda (name) (alist-get name times 0 nil #'equal)) #'> names))))

(defun iuiw-tabspaces--restore-entry (entry)
  "Open the buffers of session ENTRY in the current tab and put its layout."
  (let (subst)
    (save-window-excursion
      (dolist (rec (car entry))
        (unless (and (stringp rec) (file-remote-p rec))
          (when-let* ((buf (tabspaces--restore-buffer-record rec)))
            (switch-to-buffer buf)
            (when-let* ((name (and (consp rec) (plist-get rec :name)))
                        ((not (equal name (buffer-name buf)))))
              (push (cons name (buffer-name buf)) subst))))))
    (when (caddr entry)
      (with-demoted-errors "tabspaces: window layout not restored: %S"
        (window-state-put (tabspaces--rewrite-window-state (caddr entry) subst)
                          (window-main-window) 'safe)))
    (iuiw-tabspaces--delete-side-windows)))

(defun iuiw-tabspaces--restore-pending (&rest _)
  "Restore the current tab if its buffers have not been opened yet."
  (unless iuiw-tabspaces--inhibit
    (when-let* ((name (tabspaces--current-tab-name))
                (entry (seq-find (lambda (e) (equal (cadr e) name)) iuiw-tabspaces--pending)))
      (setq iuiw-tabspaces--pending (delq entry iuiw-tabspaces--pending))
      (iuiw-tabspaces--restore-entry entry))))

(defun iuiw-tabspaces--forget-pending (tab &rest _)
  "Drop the pending entry of TAB, which is being closed."
  (let ((name (alist-get 'name (cdr tab))))
    (setq iuiw-tabspaces--pending
          (seq-remove (lambda (e) (equal (cadr e) name)) iuiw-tabspaces--pending))))

(defun iuiw-tabspaces--without-restoring (fn &rest args)
  "Call FN with ARGS without restoring the pending tabs it visits."
  (let ((iuiw-tabspaces--inhibit t))
    (apply fn args)))

(defun iuiw-tabspaces--keep-pending (args)
  "Put the saved records of pending tabs back into the session ARGS to write."
  (if (not iuiw-tabspaces--pending)
      args
    (let ((file (car args)))
      (cons file
            (cons (mapcar (lambda (e)
                            (or (seq-find (lambda (p) (equal (cadr p) (cadr e)))
                                          iuiw-tabspaces--pending)
                                e))
                          (cadr args))
                  (cddr args))))))

(defun iuiw-tabspaces-restore ()
  "Name the first tab main, then restore the saved tabs.
Only the most recently used tab opens its buffers now; the others do on
first visit."
  (unless (alist-get 'explicit-name (tab-bar--current-tab))
    (tab-bar-rename-tab "main"))
  (when (file-exists-p tabspaces-session-file)
    (tabspaces--load-session-file tabspaces-session-file)
    (let* ((entries tabspaces--session-list)
           (names (mapcar #'cadr entries))
           (target (or (iuiw-tabspaces--most-recent names) (car (last names))))
           ;; 恢复时逐个访问 tab，overlook 会把每次访问记成切换。
           (times (and (boundp 'overlook-project-switch-times)
                       (list overlook-project-switch-times)))
           (iuiw-tabspaces--inhibit t))
      (setq iuiw-tabspaces--pending
            (seq-remove (lambda (e) (equal (cadr e) target)) entries))
      (cl-letf (((symbol-function 'tabspaces--load-session-file)
                 (lambda (_file)
                   (setq tabspaces--session-list
                         (mapcar (lambda (e) (if (equal (cadr e) target) e (list nil (cadr e) nil)))
                                 entries)))))
        (tabspaces-restore-session tabspaces-session-file))
      (when times
        (setq overlook-project-switch-times (car times)))
      (when target
        (tab-bar-select-tab-by-name target)
        (iuiw-tabspaces--delete-side-windows)))))

(provide 'iuiw-tabspaces)
;;; iuiw-tabspaces.el ends here
