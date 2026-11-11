;;; iuiw-notify-overlook.el --- Remote-only Overlook push notifications -*- lexical-binding: t; -*-

(require 'iuiw-notify)
(require 'seq)

(defvar overlook-remote-mode)
(defvar overlook-usage--rows)
(defvar overlook-agent-turn)
(defvar overlook-agent-status)
(declare-function overlook-agent-get "overlook-agent-core" (buffer key))

(defcustom iuiw-notify-overlook-long-turn-seconds 60
  "Minimum turn duration for an agent completion push notification."
  :type 'natnum
  :group 'iuiw-notify)

(defvar-local iuiw-notify-overlook--turn nil)
(defvar-local iuiw-notify-overlook--sent nil)
(defvar iuiw-notify-overlook--quotas (make-hash-table :test #'equal)
  "Usage row names to their tracked reset times and notification flags.")

(defun iuiw-notify-overlook--send (title body group)
  "Send TITLE and BODY in GROUP only while remote access is enabled."
  (when (bound-and-true-p overlook-remote-mode)
    (condition-case err
        (iuiw-notify-send title body :group group)
      (error (display-warning 'iuiw-notify (error-message-string err) :warning)))))

(defun iuiw-notify-overlook--agent (original event)
  "Observe agent EVENT around ORIGINAL without changing desktop notifications."
  (let ((open (and overlook-agent-turn (null (cdr overlook-agent-turn)))))
    (prog1 (funcall original event)
      (when (bound-and-true-p overlook-remote-mode)
        (let ((turn (car overlook-agent-turn)))
          (unless (equal turn iuiw-notify-overlook--turn)
            (setq iuiw-notify-overlook--turn turn
                  iuiw-notify-overlook--sent nil))
          (let* ((kind (cond
                        ((or (eq event 'attention)
                             (and open (eq event 'finished)
                                  (eq overlook-agent-status 'waiting))) 'waiting)
                        ((eq event 'failed) 'failed)
                        ((and open (eq event 'finished)
                              (memq overlook-agent-status '(done idle))
                              (numberp turn) (numberp (cdr overlook-agent-turn))
                              (>= (- (cdr overlook-agent-turn) turn)
                                  iuiw-notify-overlook-long-turn-seconds)) 'done)))
                 (agent (or (overlook-agent-get (current-buffer) 'agent) "Agent")))
            (when (and kind (not (memq kind iuiw-notify-overlook--sent)))
              (push kind iuiw-notify-overlook--sent)
              (iuiw-notify-overlook--send
               (pcase kind
                 ('waiting "Agent 需要你处理")
                 ('failed "Agent 运行失败")
                 (_ "Agent 已完成"))
               (format "%s：%s。请打开 Overlook remote 查看。" agent
                       (pcase kind
                         ('waiting "等待批准或回答")
                         ('failed "本轮执行失败")
                         (_ "长任务已结束")))
               "overlook-agent"))))))))

(defun iuiw-notify-overlook--usage (&rest _)
  "Track exhausted quota windows and notify once when all have reset."
  (if (not (bound-and-true-p overlook-remote-mode))
      (clrhash iuiw-notify-overlook--quotas)
    (let ((now (float-time)))
      (dolist (row overlook-usage--rows)
        (let* ((name (substring-no-properties (car row)))
               (windows (cdr row))
               (exhausted (seq-filter (lambda (window)
                                        (and (numberp (nth 1 window))
                                             (>= (nth 1 window) 100))) windows))
               (known (and windows
                           (seq-every-p (lambda (window) (numberp (nth 1 window))) windows)
                           (seq-every-p (lambda (window) (numberp (nth 2 window))) exhausted)))
               (at (and known exhausted (apply #'max (mapcar #'caddr exhausted))))
               (previous (gethash name iuiw-notify-overlook--quotas)))
          (cond
           ((and at (> at now))
            (unless (equal at (plist-get previous :at))
              (puthash name (list :at at :sent nil) iuiw-notify-overlook--quotas)))
           ((and known previous (not (plist-get previous :sent))
                 (or (null exhausted) (<= (plist-get previous :at) now)))
            (puthash name (plist-put previous :sent t) iuiw-notify-overlook--quotas)
            (iuiw-notify-overlook--send
             "账号额度可再使用"
             (format "%s：%s。" name
                     (if exhausted "已到额度重置时间，可尝试继续使用" "额度已恢复可用"))
             "overlook-usage"))))))))

(defun iuiw-notify-overlook--remote-changed ()
  "Start a fresh notification interval when remote access is toggled."
  (clrhash iuiw-notify-overlook--quotas)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (local-variable-p 'iuiw-notify-overlook--sent)
        (setq iuiw-notify-overlook--turn nil
              iuiw-notify-overlook--sent nil)))))

(with-eval-after-load 'overlook-agent-core
  (advice-add 'overlook-agent-report :around #'iuiw-notify-overlook--agent))
(with-eval-after-load 'overlook-usage
  (advice-add 'overlook-usage-scan :after #'iuiw-notify-overlook--usage))
(add-hook 'overlook-remote-mode-hook #'iuiw-notify-overlook--remote-changed)

(provide 'iuiw-notify-overlook)
;;; iuiw-notify-overlook.el ends here
