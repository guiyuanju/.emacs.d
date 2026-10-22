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

(ert-deftest overlook-agent-shell-leaves-ignored-shells-untracked ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (let ((overlook-agent-shell-ignore-function (lambda () (eq (current-buffer) buffer))))
      (overlook-agent-shell--track)
      (should-not (overlook-agent-p buffer)))))

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
             (lambda (title body _buffer) (push (cons title body) sent))))
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

(ert-deftest overlook-agent-shell-restored-session-is-idle ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (let ((ended 0)
          (overlook-agent-notify nil))
      (let ((overlook-agent-turn-end-hook (list (lambda () (cl-incf ended))))
            (overlook-perspectives-function #'ignore))
        (overlook-agent-shell--on-event '((:event . agent-message-chunk)))
        (overlook-agent-shell--on-event '((:event . tool-call-update)))
        (should (eq overlook-agent-status 'working))
        (overlook-agent-shell--on-event '((:event . session-restored)))
        (should (eq overlook-agent-status 'idle))
        (should-not overlook-agent-turn)
        (should (= ended 1))))))

(ert-deftest overlook-agent-shell-ends-a-turn-the-agent-began-itself ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (overlook-agent-shell--track)
    (let ((overlook-agent-notify nil)
          (overlook-perspectives-function #'ignore)
          (busy t)
          (usage '((params (update (sessionUpdate . "usage_update") (cost (amount . 0.1)))))))
      (cl-flet ((reply (text)
                  (overlook-agent-shell--on-notification
                   `((params (update (sessionUpdate . "agent_message_chunk")
                                     (content (text . ,text))))))
                  (overlook-agent-shell--on-event '((:event . agent-message-chunk)))))
        (cl-letf (((symbol-function 'shell-maker-busy) (lambda () busy)))
          (overlook-agent-shell--on-event '((:event . input-submitted)))
          (reply "Waiting on the build.")
          (overlook-agent-shell--on-notification usage)
          (should (eq overlook-agent-status 'working))
          (overlook-agent-shell--on-event '((:event . turn-complete)))
          (should (equal (overlook-agent--brief buffer) "Waiting on the build."))
          (setq busy nil)
          (reply "The build passed.")
          (should (eq overlook-agent-status 'working))
          (overlook-agent-shell--on-notification
           '((params (update (sessionUpdate . "usage_update") (used . 10)))))
          (should (eq overlook-agent-status 'working))
          (overlook-agent-shell--on-notification usage)
          (should (eq overlook-agent-status 'done))
          (should (cdr overlook-agent-turn))
          (should (equal (overlook-agent--brief buffer) "The build passed.")))))))

(ert-deftest overlook-agent-shell-startup-failure-has-a-fallback-message ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (let ((overlook-agent-notify nil))
      (overlook-agent-shell--on-event '((:event . error)))
      (should (eq overlook-agent-status 'failed))
      (should (equal overlook-agent-error "Agent request failed"))
      (should-not overlook-agent-turn))))

(ert-deftest overlook-agent-reply-brief-reads-markdown ()
  (let ((overlook-agent-identity nil))
    (cl-flet ((brief (reply)
                (with-temp-buffer
                  (setq-local overlook-agent-identity `((reply . ,(lambda () reply))))
                  (overlook-agent--reply-brief (current-buffer)))))
      (should (equal (brief "\n**Done**: pushed `dca5f03` to [main](http://x).\n\n- more\n")
                     "Done: pushed dca5f03 to main."))
      (should (equal (brief "## Plan\n```\ncode?\n```\n| a | b |\n---\nSplit it in two.  Go ahead?")
                     "? Go ahead?"))
      (should (equal (brief "先做一，再做二。要按这个做吗？") "? 要按这个做吗？"))
      (should (equal (brief "建议：按这个做吗？") "? 按这个做吗？"))
      (should-not (brief "\n```\nonly code\n```\n"))
      (should-not (brief nil)))))

(ert-deftest overlook-agent-shell-brief-follows-the-turn ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (overlook-agent-shell--track)
    (let ((overlook-agent-notify nil)
          (overlook-perspectives-function #'ignore)
          (reply (lambda (text)
                   (overlook-agent-shell--on-notification
                    `((params (update (sessionUpdate . "agent_message_chunk")
                                      (content (text . ,text))))))))
          (tool (lambda (title)
                  (overlook-agent-shell--on-notification
                   '((params (update (sessionUpdate . "tool_call")))))
                  (overlook-agent-shell--on-event
                   `((:event . tool-call-update) (:data (:tool-call (:title . ,title))))))))
      (overlook-agent-shell--on-event '((:event . input-submitted)))
      (funcall reply "Let me look.")
      (funcall tool "git status")
      (should (equal (overlook-agent--brief buffer) "git status"))
      (overlook-agent-shell--on-event
       '((:event . permission-request) (:data (:tool-call (:title . "git push")))))
      (should (equal (overlook-agent--brief buffer) "⚠ git push"))
      (should (eq overlook-agent-status 'waiting))
      (overlook-agent-shell--on-event '((:event . permission-response)))
      (overlook-agent-shell--on-event
       '((:event . elicitation-request) (:data (:message . "Which one?"))))
      (should (equal (overlook-agent--brief buffer) "? Which one?"))
      (overlook-agent-shell--on-event '((:event . elicitation-response)))
      (should (equal (overlook-agent--brief buffer) "git status"))
      (funcall reply "Pushed **main**.\n\nAll green.")
      (overlook-agent-shell--on-event '((:event . turn-complete)))
      (should (equal (overlook-agent--brief buffer) "Pushed main."))
      (should (eq overlook-agent-status 'done))
      (overlook-agent-shell--on-event '((:event . input-submitted)))
      (should (eq overlook-agent-status 'working))
      (should-not (overlook-agent--brief buffer))
      (funcall reply "Two ways.  Which do you want?")
      (overlook-agent-shell--on-event '((:event . turn-complete)))
      (should (equal (overlook-agent--brief buffer) "? Which do you want?"))
      (should (eq overlook-agent-status 'waiting))
      ;; The next prompt answers it, even when sent without looking.
      (overlook-agent-shell--on-event '((:event . input-submitted)))
      (should (eq overlook-agent-status 'working)))))

(ert-deftest overlook-agent-shell-answers-permissions-oldest-first ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (overlook-agent-shell--track)
    (let* ((overlook-agent-notify nil)
           (overlook-perspectives-function #'ignore)
           (sent nil)
           (interrupted nil)
           (actions '(((:kind . "allow_once") (:option . "Allow") (:option-id . "a1"))
                      ((:kind . "allow_always") (:option . "Always") (:option-id . "a2"))
                      ((:kind . "reject_once") (:option . "Reject") (:option-id . "r1")))))
      (setf (map-elt agent-shell--state :tool-calls)
            `(("t1" (:permission-request-id . 7) (:permission-actions . ,actions))
              ("t2" (:permission-request-id . 8) (:permission-actions . ,actions)
               (:diffs . (diff)))))
      (cl-letf (((symbol-function 'agent-shell--send-permission-response)
                 (cl-function
                  (lambda (&key request-id option-id tool-call-id &allow-other-keys)
                    (push (list request-id option-id) sent)
                    (overlook-agent-shell--on-event
                     `((:event . permission-response) (:data (:tool-call-id . ,tool-call-id)))))))
                ((symbol-function 'agent-shell-interrupt)
                 (lambda (&optional _) (setq interrupted t)))
                ((symbol-function 'agent-shell--make-diff-viewing-function)
                 (lambda (&rest _) (lambda () 'diff))))
        (overlook-agent-shell--on-event '((:event . input-submitted)))
        (dolist (call '(("t1" . "Edit a.el") ("t2" . "Edit b.el")))
          (overlook-agent-shell--on-event
           `((:event . permission-request)
             (:data (:tool-call-id . ,(car call)) (:tool-call (:title . ,(cdr call)))))))
        (should (equal (overlook-agent--brief buffer) "⚠ Edit a.el (+1)"))
        (should (equal (mapcar (lambda (choice) (seq-take choice 2))
                               (overlook-agent--choices buffer))
                       '(("y" "Allow") ("!" "Always") ("n" "Reject"))))
        (should (eq overlook-agent-status 'waiting))
        (overlook-agent-choose buffer "y")
        (should (equal sent '((7 "a1"))))
        ;; The next one is still waiting, now with its diff to look at.
        (should (equal (overlook-agent--brief buffer) "⚠ Edit b.el"))
        (should (equal (car (car (last (overlook-agent--choices buffer)))) "v"))
        (should (eq overlook-agent-status 'waiting))
        (overlook-agent-choose buffer "n")
        (should (equal (car sent) '(8 "r1")))
        (should interrupted)
        (should-not (overlook-agent--choices buffer))
        (should (eq overlook-agent-status 'working))))))

(ert-deftest overlook-agent-shell-answers-a-one-option-question ()
  (overlook-agent-shell-test-with-shell 'claude-code
    (overlook-agent-shell--track)
    (let* ((overlook-agent-notify nil)
           (overlook-perspectives-function #'ignore)
           (fields '(((:key . "q") (:type . single-select) (:custom-key . "q_custom")
                      (:options ((:value . "a") (:title . "Plan A"))
                                ((:value . "b") (:title . "Plan B"))))
                     ((:key . "q_custom") (:type . string) (:folded-into . "q"))))
           (elicitation `((:status . pending) (:fields . ,fields)))
           (set nil))
      (cl-letf (((symbol-function 'agent-shell-elicitation--get)
                 (lambda (_state id) (when (equal id 3) elicitation)))
                ((symbol-function 'agent-shell-elicitation--set-values)
                 (lambda (_state _id pairs) (setq set pairs)))
                ((symbol-function 'agent-shell-elicitation--submit)
                 (cl-function
                  (lambda (&key id &allow-other-keys)
                    (overlook-agent-shell--on-event
                     `((:event . elicitation-response) (:data (:request-id . ,id))))))))
        (overlook-agent-shell--on-event
         '((:event . elicitation-request) (:data (:request-id . 3) (:message . "Which plan?"))))
        (should (equal (overlook-agent--brief buffer) "? Which plan?"))
        (should (equal (mapcar #'car (overlook-agent--choices buffer)) '("1" "2")))
        (overlook-agent-choose buffer "2")
        (should (equal set '(("q" . "b") ("q_custom"))))
        (should-not overlook-agent-shell--questions)
        ;; A form asking more than one thing is answered in the shell.
        (setf (alist-get :fields elicitation) (append fields (list '((:key . "x") (:type . string)))))
        (overlook-agent-shell--on-event
         '((:event . elicitation-request) (:data (:request-id . 3) (:message . "Two things?"))))
        (should (equal (overlook-agent--brief buffer) "? Two things?"))
        (should-not (overlook-agent--choices buffer))))))

;;; overlook-agent-shell-test.el ends here
