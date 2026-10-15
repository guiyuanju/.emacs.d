;;; overlook-agent-shell-test.el --- Tests for tracking agent-shell buffers -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-agent-shell)

(defmacro overlook-agent-shell-test-with-shell (identifier &rest body)
  "Run BODY in a fake shell buffer whose config has IDENTIFIER.
Agent \"claude\" is the config `claude-code', roots are /tmp/shop/, and
each environment gathered says how many were gathered so far."
  (declare (indent 1))
  `(let* ((overlook-agent-shell-configs
           '(("claude" . (lambda () '((:identifier . claude-code))))))
          (overlook-agent-root-function (lambda () "/tmp/shop/"))
          (gathered 0)
          (overlook-agent-environment-functions
           (list (lambda (name root)
                   (list (format "ID=%s@%s#%d" name root (cl-incf gathered))))))
          (overlook-agent-changed-hook nil)
          (overlook-agent--last nil)
          (buffer (generate-new-buffer "shell")))
     (unwind-protect
         (with-current-buffer buffer
           (setq major-mode 'agent-shell-mode)
           (setq-local agent-shell--state
                       (list (cons :agent-config (list (cons :identifier ,identifier)))))
           (cl-letf (((symbol-function 'overlook-refresh) #'ignore)
                     ((symbol-function 'agent-shell-subscribe-to) #'ignore))
             ,@body))
       (kill-buffer buffer))))

(ert-deftest overlook-agent-shell-adds-the-environment-once-per-shell ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (let ((args (list :context-buffer buffer :environment-variables '("A=1"))))
      (should (equal (plist-get (overlook-agent-shell--add-environment args)
                                :environment-variables)
                     '("ID=claude@/tmp/shop/#1" "A=1")))
      (should (equal (plist-get (overlook-agent-shell--add-environment args)
                                :environment-variables)
                     '("ID=claude@/tmp/shop/#1" "A=1")))
      (should (equal (plist-get args :environment-variables) '("A=1"))))
    (let ((args (list :context-buffer (get-buffer-create " other"))))
      (unwind-protect
          (should (eq (overlook-agent-shell--add-environment args) args))
        (kill-buffer " other")))))

(ert-deftest overlook-agent-shell-tracks-a-shell-started-any-way ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (overlook-agent-shell--add-environment (list :context-buffer buffer))
    (overlook-agent-shell--track)
    (should (overlook-agent-p buffer))
    (should (equal (overlook-agent-get buffer 'agent) "claude"))
    (should (equal (overlook-agent-get buffer 'root) "/tmp/shop/"))
    (should (equal (overlook-agent-get buffer 'environment) '("ID=claude@/tmp/shop/#1")))
    (should (equal overlook-agent--last "claude"))
    (let ((identity overlook-agent-identity))
      (overlook-agent-shell--track)
      (should (eq overlook-agent-identity identity)))))

(ert-deftest overlook-agent-shell-names-unknown-agents-by-identifier ()
  (overlook-agent-shell-test-with-shell 'gemini-cli
    (overlook-agent-shell--track)
    (should (equal (overlook-agent-get buffer 'agent) "gemini-cli"))
    (should-not (overlook-agent-get buffer 'environment))))

(ert-deftest overlook-agent-shell-start-names-and-roots-its-agent ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (let ((overlook-agent-shell--starting '("codex" . "/tmp/other/")))
      (overlook-agent-shell--add-environment (list :context-buffer buffer)))
    (overlook-agent-shell--track)
    (should (equal (overlook-agent-get buffer 'agent) "codex"))
    (should (equal (overlook-agent-get buffer 'root) "/tmp/other/"))
    (should (equal (overlook-agent-get buffer 'environment) '("ID=codex@/tmp/other/#1")))))

(ert-deftest overlook-agent-shell-failure-survives-viewing-and-completion ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (overlook-agent-shell--track)
    (let* ((overlook-agent-notify t)
           (sent nil)
          (ended 0)
          (overlook-agent-turn-end-hook (list (lambda () (cl-incf ended))))
          (overlook-perspectives-function #'ignore))
      (let ((overlook-agent-notify-function
             (lambda (title body) (push (cons title body) sent))))
        (overlook-agent-shell--on-event '((:event . input-submitted)))
        (overlook-agent-shell--on-event
         '((:event . error) (:data (:code . -1) (:message . "Connection lost"))))
        (should (eq overlook-agent-status 'failed))
        (should (cdr overlook-agent-turn))
        (should (= ended 1))
        (should (equal (overlook-agent--brief buffer) "Connection lost"))
        (should (equal sent '(("claude failed" . "Connection lost"))))
        (save-window-excursion
          (switch-to-buffer buffer)
          (overlook-agent--acknowledge)
          (should (eq overlook-agent-status 'failed)))
        ;; Some frontends finish output after reporting an error.
        (overlook-agent-shell--on-event '((:event . turn-complete)))
        (should (eq overlook-agent-status 'failed))
        (should (= ended 1))
        (should (= (length sent) 1))
        (overlook-agent-shell--on-event '((:event . input-submitted)))
        (should (eq overlook-agent-status 'working))
        (should-not overlook-agent-error)
        (should-not (cdr overlook-agent-turn))
        (overlook-agent-shell--on-event '((:event . turn-complete)))
        (should (eq overlook-agent-status 'done))
        (should (= ended 2))))))

(ert-deftest overlook-agent-shell-startup-failure-has-a-fallback-message ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (let ((overlook-agent-notify nil))
      (overlook-agent-shell--on-event '((:event . error)))
      (should (eq overlook-agent-status 'failed))
      (should (equal overlook-agent-error "Agent request failed"))
      (should-not overlook-agent-turn))))

;;; overlook-agent-shell-test.el ends here
