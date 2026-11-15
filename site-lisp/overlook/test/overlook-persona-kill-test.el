;;; overlook-persona-kill-test.el --- Persona kill actions -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-agent-courier)
(require 'overlook-remote-bridge)

(ert-deftest overlook-persona-kill-confirms-and-returns-to-start ()
  (let ((buffer (generate-new-buffer " *persona-kill-test*"))
        (overlook-remote-bridge--rows (make-hash-table :test #'equal))
        (overlook-remote-bridge--dashboard-dirty nil))
    (unwind-protect
        (cl-letf (((symbol-function 'overlook-courier-persona)
                   (lambda (_) '(:name "helper" :engine "test")))
                  ((symbol-function 'overlook-courier-agent) #'identity)
                  ((symbol-function 'overlook-courier-agent-buffer)
                   (lambda (_) (and (buffer-live-p buffer) buffer)))
                  ((symbol-function 'overlook-remote-bridge--publish-dashboard) #'ignore)
                  ((symbol-function 'overlook-refresh) #'ignore))
          (with-current-buffer buffer
            (setq overlook-agent-identity '((agent . "test"))))
          (let* ((row (overlook-agent-courier--persona-row "helper"))
                 (params '((path . ["helper"]) (name . "kill") (confirmed . []))))
            (should (overlook-row-command row "open"))
            (should (overlook-row-command row "kill"))
            (puthash '("helper") row overlook-remote-bridge--rows)
            (let ((result (overlook-remote-bridge--command params)))
              (should (equal (plist-get result :outcome) "confirm"))
              (should (buffer-live-p buffer))
              (should-not
               (equal (plist-get
                       (overlook-remote-bridge--command
                        `((path . ["helper"]) (name . "kill")
                          (confirmed . [,(plist-get result :question)])))
                       :outcome)
                      "confirm"))))
          (should-not (buffer-live-p buffer))
          (let ((row (overlook-agent-courier--persona-row "helper")))
            (should (overlook-row-command row "start"))
            (should-not (overlook-row-command row "kill"))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))
