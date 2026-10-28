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
