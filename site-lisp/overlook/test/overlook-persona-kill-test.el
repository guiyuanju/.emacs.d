;;; overlook-persona-kill-test.el --- Persona kill actions -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-agent-courier)
(require 'overlook-remote-service)

(ert-deftest overlook-persona-kill-confirms-and-returns-to-start ()
  (let ((buffer (generate-new-buffer " *persona-kill-test*"))
        (overlook-remote--rows (make-hash-table :test #'equal)))
    (unwind-protect
        (cl-letf (((symbol-function 'overlook-courier-persona)
                   (lambda (_) '(:name "helper" :engine "test")))
                  ((symbol-function 'overlook-courier-agent) #'identity)
                  ((symbol-function 'overlook-courier-agent-buffer)
                   (lambda (_) (and (buffer-live-p buffer) buffer)))
                  ((symbol-function 'overlook-remote--dashboard) #'ignore)
                  ((symbol-function 'overlook-refresh) #'ignore))
          (with-current-buffer buffer
            (setq overlook-agent-identity '((agent . "test"))))
          (let* ((row (overlook-agent-courier--persona-row "helper"))
                 (body '((node . "helper") (name . "kill"))))
            (should (overlook-row-command row "open"))
            (should (overlook-row-command row "kill"))
            (puthash "helper" row overlook-remote--rows)
            (let ((result (overlook-remote-service-command body)))
              (should (plist-get result :confirm))
              (should (buffer-live-p buffer))
              (should (plist-get
                       (overlook-remote-service-command
                        (append `((confirmed . t)
                                  (confirmationToken . ,(plist-get result :confirmationToken))) body))
                       :ok))))
          (should-not (buffer-live-p buffer))
          (let ((row (overlook-agent-courier--persona-row "helper")))
            (should (overlook-row-command row "start"))
            (should-not (overlook-row-command row "kill"))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))
