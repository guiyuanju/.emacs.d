;;; overlook-perspective-test.el --- Tests for overlook-perspective -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-perspective)

(ert-deftest overlook-perspective-buffers-stay-put ()
  (let ((persp-mode-hook nil)
        (persp-switch-hook nil)
        (switched 0)
        (buffer (get-buffer-create "overlook-perspective-test")))
    (unwind-protect
        (progn
          (persp-mode 1)
          (persp-switch "other")
          (persp-add-buffer buffer)
          (persp-switch "main")
          (let ((count (lambda (&rest _) (setq switched (1+ switched)))))
            (advice-add 'persp-switch :before count)
            (unwind-protect
                (should (memq buffer (overlook-perspective--buffers "other")))
              (advice-remove 'persp-switch count)))
          (should (= switched 0))
          (should-not (overlook-perspective--buffers "missing")))
      (persp-mode -1)
      (kill-buffer buffer))))

(ert-deftest overlook-perspective-detached-buffer-stays-out-when-shown ()
  (let ((persp-mode-hook nil)
        (persp-switch-hook nil)
        (overlook-perspective-mode nil)
        (buffer (get-buffer-create "overlook-perspective-detached")))
    (unwind-protect
        (progn
          (persp-mode 1)
          (overlook-perspective-mode 1)
          (persp-switch "other")
          (persp-add-buffer buffer)
          (persp-switch "main")
          (persp-add-buffer buffer)
          (overlook-detach buffer)
          (should-not (memq buffer (overlook-perspective--buffers "main")))
          (should-not (memq buffer (overlook-perspective--buffers "other")))
          (switch-to-buffer buffer)
          (should (memq buffer (overlook-perspective--buffers "main")))
          ;; Batch Emacs does not redisplay, which runs the hook.
          (should (memq #'overlook--detach-shown
                        (buffer-local-value 'window-buffer-change-functions buffer)))
          (overlook--detach-shown (selected-window))
          (should-not (memq buffer (overlook-perspective--buffers "main"))))
      (overlook-perspective-mode -1)
      (persp-mode -1)
      (kill-buffer buffer))))
