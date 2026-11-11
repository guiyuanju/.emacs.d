;;; overlook-remote-close-test.el --- Close session regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-remote-service)

(ert-deftest overlook-remote-close-confirms-without-provider-controls ()
  (let ((buffer (generate-new-buffer "close-agent"))
        (state "one") (closed 0))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq overlook-agent-identity '((agent . "test"))))
          (cl-letf (((symbol-function 'overlook-remote--state) (lambda (_) (cons nil state)))
                    ((symbol-function 'overlook-agent-close)
                     (lambda (target)
                       (should-not (buffer-local-value 'overlook-remote--queue target))
                       (cl-incf closed) (kill-buffer target))))
            (with-current-buffer buffer (setq overlook-remote--queue '((:id "pending" :text "pending"))))
            (let* ((body `((id . ,(overlook-remote-service-agent-id buffer)) (action . "close")))
                   (confirmation (overlook-remote-service-session body))
                   (confirmed (append `((confirmationToken . ,(plist-get confirmation :confirmationToken))
                                        (confirmations . [,(plist-get confirmation :confirm)])) body)))
              (should (plist-get confirmation :confirm))
              (should (buffer-live-p buffer))
              (should (= closed 0))
              (setq state "two")
              (should (plist-get (overlook-remote-service-session confirmed) :confirm))
              (should (= closed 0))
              (setq state "one")
              (should (equal (overlook-remote-service-session confirmed) '(:ok t :closed t)))
              (should-not (buffer-live-p buffer))
              (should (= closed 1)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest overlook-remote-close-failure-retains-queued-prompts ()
  (with-temp-buffer
    (setq overlook-remote--queue '((:id "pending" :text "pending"))
          overlook-remote--queue-error "failed")
    (cl-letf (((symbol-function 'overlook-agent-close) (lambda (_) (error "Cannot close"))))
      (should-error (overlook-remote-service--close (current-buffer)))
      (should (equal overlook-remote--queue '((:id "pending" :text "pending"))))
      (should (equal overlook-remote--queue-error "failed")))))

(ert-deftest overlook-agent-close-keeps-resumable-data-and-provider-metadata ()
  (let ((buffer (generate-new-buffer "resumable-close-agent"))
        (overlook-agent-saved '(((agent . "test") (session . "other"))))
        (overlook-agent--saved-loaded t)
        (overlook-agent-save-functions (list (lambda (_) '((courier . "helper")))))
        written)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq overlook-agent-identity
                  `((agent . "test") (session . ,(lambda () "session"))
                    (project . "project") (root . "/tmp/"))))
          (cl-letf (((symbol-function 'overlook-projects) (lambda () '("project")))
                    ((symbol-function 'overlook-agent--write) (lambda (&rest _) t))
                    ((symbol-function 'overlook-agent-save)
                     (lambda () (setq written (copy-tree overlook-agent-saved))))
                    ((symbol-function 'overlook-agent-changed) #'ignore))
            (should (overlook-agent-close buffer))
            (should-not (buffer-live-p buffer))
            (should (= (length written) 2))
            (should (equal (alist-get 'session (car written)) "session"))
            (should (equal (alist-get 'courier (car written)) "helper"))
            (should (equal (alist-get 'project (car written)) "project"))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest overlook-agent-close-without-session-does-not-invent-saved-record ()
  (let ((buffer (generate-new-buffer "unsaved-close-agent"))
        (overlook-agent-saved nil) (overlook-agent--saved-loaded t))
    (with-current-buffer buffer (setq overlook-agent-identity '((agent . "test"))))
    (cl-letf (((symbol-function 'overlook-agent-save) #'ignore)
              ((symbol-function 'overlook-agent-changed) #'ignore))
      (should (overlook-agent-close buffer))
      (should-not overlook-agent-saved)
      (should-not (buffer-live-p buffer)))))

(ert-deftest overlook-agent-close-save-failure-does-not-stop-agent ()
  (let ((buffer (generate-new-buffer "save-failure-close-agent"))
        (overlook-agent-saved nil) (overlook-agent--saved-loaded t))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq overlook-agent-identity
                  `((agent . "test") (session . ,(lambda () "session")))))
          (cl-letf (((symbol-function 'overlook-agent--write)
                     (lambda (&rest _) (error "Disk full"))))
            (should-error (overlook-agent-close buffer))
            (should (buffer-live-p buffer))
            (should-not overlook-agent-saved)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest overlook-remote-close-success-replays-after-buffer-is-gone ()
  (let ((buffer (generate-new-buffer "idempotent-close-agent"))
        (overlook-remote-service--receipts (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-current-buffer buffer (setq overlook-agent-identity '((agent . "test"))))
          (cl-letf (((symbol-function 'overlook-remote--state) (lambda (_) (cons nil "stable")))
                    ((symbol-function 'overlook-agent-close) (lambda (target) (kill-buffer target))))
            (let* ((body `((id . ,(overlook-remote-service-agent-id buffer))
                           (action . "close") (requestId . "close-request")))
                   (confirmation (overlook-remote-service-session body))
                   (confirmed (append `((confirmationToken . ,(plist-get confirmation :confirmationToken))
                                        (confirmations . [,(plist-get confirmation :confirm)])) body)))
              (should (equal (overlook-remote-service-once "/api/session" confirmed
                                                         #'overlook-remote-service-session)
                             '(:ok t :closed t)))
              (should-not (buffer-live-p buffer))
              (should (equal (overlook-remote-service-once "/api/session" confirmed
                                                         #'overlook-remote-service-session)
                             '(:ok t :closed t))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest overlook-remote-seen-service-forwards-position-and-epoch ()
  (let ((buffer (generate-new-buffer "seen-agent")))
    (unwind-protect
        (progn
          (with-current-buffer buffer (setq overlook-agent-identity '((agent . "test"))))
          (cl-letf (((symbol-function 'overlook-remote--seen)
                     (lambda (target through epoch)
                       (should (eq target buffer))
                       (should (= through 12))
                       (should (equal epoch "epoch"))
                       '(:ok t :readThrough 12 :unreadCount 1))))
            (should (equal (overlook-remote-service-seen
                            `((id . ,(overlook-remote-service-agent-id buffer))
                              (through . 12) (epoch . "epoch")))
                           '(:ok t :readThrough 12 :unreadCount 1)))))
      (kill-buffer buffer))))
