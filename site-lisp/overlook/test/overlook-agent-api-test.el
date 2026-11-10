;;; overlook-agent-api-test.el --- Agent capability contract -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-agent)

(ert-deftest overlook-agent-capabilities-run-in-the-agent-buffer ()
  (let ((agent (generate-new-buffer "agent-api")) received)
    (unwind-protect
        (progn
          (with-current-buffer agent
            (setq overlook-agent-status 'working
                  overlook-agent-identity
                  `((ready . ,(lambda () (eq (current-buffer) agent)))
                    (submit . ,(lambda (text) (setq received (cons (current-buffer) text)))))))
          (should (overlook-agent-ready-p agent))
          (overlook-agent-submit agent "hello")
          (should (equal received (cons agent "hello")))
          (with-current-buffer agent
            (setf (alist-get 'ready overlook-agent-identity) #'ignore))
          (should-not (overlook-agent-ready-p agent)))
      (kill-buffer agent))))

(ert-deftest overlook-agent-readiness-falls-back-only-without-a-capability ()
  (with-temp-buffer
    (dolist (status '(idle done failed working waiting))
      (setq overlook-agent-status status)
      (should (eq (not (null (overlook-agent-ready-p (current-buffer))))
                  (not (memq status '(working waiting)))))))
  (with-temp-buffer
    (setq overlook-agent-identity '((ready . ignore)))
    (should-not (overlook-agent-ready-p (current-buffer)))))

(ert-deftest overlook-agent-capability-errors-reach-the-caller ()
  (with-temp-buffer
    (should-not (overlook-agent-call (current-buffer) 'reply))
    (should-error (overlook-agent-submit (current-buffer) "hello") :type 'user-error)
    (setq overlook-agent-identity
          `((submit . ,(lambda (_) (error "Submission failed")))))
    (should-error (overlook-agent-submit (current-buffer) "hello") :type 'error)))
