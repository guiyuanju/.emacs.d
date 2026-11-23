;;; overlook-remote-bridge-test.el --- Tests for overlook-remote-bridge -*- lexical-binding: t; -*-

;; A fake daemon, a local socket server in this Emacs, speaks the bridge
;; protocol to the mode under test.

(require 'ert)
(require 'overlook-remote-bridge)

;;; Fake daemon

(defvar overlook-bridge-test--client nil
  "The fake daemon's connection from Emacs, or nil.")

(defvar overlook-bridge-test--received nil
  "Messages the fake daemon received and nobody took yet, oldest first.")

(defvar overlook-bridge-test--partial ""
  "Bytes the fake daemon received after the last complete line.")

(defvar overlook-bridge-test--id 0
  "Id of the fake daemon's latest request.")

(defun overlook-bridge-test--filter (process chunk)
  "Take CHUNK from PROCESS, a connection to the fake daemon."
  (setq overlook-bridge-test--client process)
  (let ((lines (split-string (concat overlook-bridge-test--partial chunk) "\n")))
    (setq overlook-bridge-test--partial (car (last lines)))
    (dolist (line (butlast lines))
      (setq overlook-bridge-test--received
            (append overlook-bridge-test--received
                    (list (json-parse-string (decode-coding-string line 'utf-8)
                                             :object-type 'alist :array-type 'list
                                             :null-object :null :false-object :false)))))))

(defun overlook-bridge-test--accepted (_server client _message)
  "Note CLIENT, a new connection to the fake daemon."
  (setq overlook-bridge-test--client client
        overlook-bridge-test--partial ""))

(defun overlook-bridge-test--serve (socket)
  "Start the fake daemon on SOCKET."
  (make-network-process :name "overlook-bridge-test" :server t :family 'local
                        :service socket :coding 'binary :noquery t
                        :log #'overlook-bridge-test--accepted
                        :filter #'overlook-bridge-test--filter))

(defun overlook-bridge-test--wait (predicate &optional seconds)
  "Process input until PREDICATE returns non-nil, within SECONDS; return its value."
  (let ((deadline (+ (float-time) (or seconds 3)))
        value)
    (while (and (not (setq value (funcall predicate))) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (or value (ert-fail "Timed out"))))

(defun overlook-bridge-test--quiet (seconds)
  "Process input for SECONDS."
  (let ((deadline (+ (float-time) seconds)))
    (while (< (float-time) deadline) (accept-process-output nil 0.02))))

(defun overlook-bridge-test--find (predicate)
  "The first received message satisfying PREDICATE, once one came."
  (overlook-bridge-test--wait (lambda () (seq-find predicate overlook-bridge-test--received))))

(defun overlook-bridge-test--take (predicate)
  "Remove and return the first received message satisfying PREDICATE."
  (let ((message (overlook-bridge-test--find predicate)))
    (setq overlook-bridge-test--received (delq message overlook-bridge-test--received))
    message))

(defun overlook-bridge-test--take-method (method)
  "Remove and return the first received message of METHOD."
  (overlook-bridge-test--take (lambda (message) (equal (alist-get 'method message) method))))

(defun overlook-bridge-test--methods ()
  "Methods of the received messages, responses as \"response\"."
  (mapcar (lambda (message) (or (alist-get 'method message) "response"))
          overlook-bridge-test--received))

(defun overlook-bridge-test--send (message)
  "Send MESSAGE, a plist, from the fake daemon."
  (process-send-string overlook-bridge-test--client
                       (concat (json-serialize message) "\n")))

(defun overlook-bridge-test--request (method &optional params)
  "Send request METHOD with PARAMS, a plist, and return the response."
  (let ((id (setq overlook-bridge-test--id (1+ overlook-bridge-test--id))))
    (overlook-bridge-test--send (list :jsonrpc "2.0" :id id :method method :params params))
    (overlook-bridge-test--take (lambda (message) (equal (alist-get 'id message) id)))))

(defun overlook-bridge-test--result (method &optional params)
  "Result of request METHOD with PARAMS, failing on an error."
  (let ((response (overlook-bridge-test--request method params)))
    (should-not (alist-get 'error response))
    (alist-get 'result response)))

(defun overlook-bridge-test--error (method &optional params)
  "Error code and problem of request METHOD with PARAMS, as (CODE PROBLEM)."
  (let ((error (alist-get 'error (overlook-bridge-test--request method params))))
    (list (alist-get 'code error) (alist-get 'problem (alist-get 'data error)))))

(defun overlook-bridge-test--handshake ()
  "Accept the mode's hello and return the sync's params."
  (let ((hello (overlook-bridge-test--take-method "hello")))
    (overlook-bridge-test--send
     `(:jsonrpc "2.0" :id ,(alist-get 'id hello)
       :result (:protocol 1 :daemon "test" :historyEpoch "h1" :maxMessageBytes 67108864)))
    (prog1 (alist-get 'params (overlook-bridge-test--take-method "sync"))
      (should (eq overlook-remote-bridge--state 'live)))))

;;; Fake dashboard and agents

(defvar overlook-bridge-test--agent nil
  "The fake agent's buffer.")

(defvar overlook-bridge-test--log nil
  "What the fake agent and rows were asked to do, newest first.")

(defvar overlook-bridge-test--ready t
  "Whether the fake agent takes a prompt now.")

(defvar overlook-bridge-test--form-id "form-1"
  "Id of the form the fake agent waits on.")

(defun overlook-bridge-test--section ()
  "The fake dashboard: a project with commands, the agent and file rows."
  (list
   (overlook-section-row
    "Projects"
    (list (overlook-row
           :id '(project . "shop") :content "shop"
           :commands
           (list (list :name "new" :label "New" :input "Task" :options '("claude" "codex")
                       :run (lambda (text option)
                              (push (list 'new text option) overlook-bridge-test--log)
                              (cons overlook-bridge-test--agent "draft text")))
                 (list :name "close" :label "Close" :confirm "Close project shop?"
                       :run (lambda ()
                              (when (y-or-n-p "Really?") (push 'close overlook-bridge-test--log))
                              nil)))
           :children
           (append (and (buffer-live-p overlook-bridge-test--agent)
                        (list (overlook-row :id (cons 'agent overlook-bridge-test--agent)
                                            :content "agent" :attention t
                                            :choices (overlook-agent-choices
                                                      overlook-bridge-test--agent))))
                   (list (overlook-row :content "a.el" :diff (lambda () "-x\n+y\n"))
                         (overlook-row :content "same")
                         (overlook-row :content "same"))))))))

(defun overlook-bridge-test--identity (root)
  "Identity of a fake agent working in ROOT, with every capability."
  `((agent . "claude") (root . ,(file-name-as-directory root))
    (submit . ,(lambda (text) (push (list 'submit text) overlook-bridge-test--log)))
    (ready . ,(lambda () overlook-bridge-test--ready))
    (reply . ,(lambda () "Done: café"))
    (title . ,(lambda () "Fix the bug"))
    (choices . ,(lambda () (list (list "y" "Allow" (lambda () (push 'chose overlook-bridge-test--log))))))
    (form . ,(lambda ()
               (list :id overlook-bridge-test--form-id :message "Pick" :answerable t
                     :fields (list (list :key "k" :type "single" :title "K" :description ""
                                         :required t :other :null
                                         :options (list (list :value "a" :title "A"
                                                              :description "")))))))
    (answer . ,(lambda (id action values)
                 (push (list 'answer id action values) overlook-bridge-test--log)))
    (remote-controls
     . ,(lambda ()
          (list :steer t :actions '("model" "stop" "restart")
                :slash '((:name "/compact" :description ""))
                :settings (list (list :id "model" :label "Model" :value "opus"
                                      :choices (list (list :value "opus" :name "Opus")
                                                     (list :value "sonnet" :name "Sonnet")))))))
    (remote-action
     . ,(lambda (action text)
          (pcase action
            ("stop" (error "Boom"))
            ("restart" (when (y-or-n-p "Busy. Continue?")
                         (push (list action text) overlook-bridge-test--log)))
            ("model" (when (equal text "bad") (user-error "Unknown model: bad"))
             (push (list action text) overlook-bridge-test--log))
            (_ (push (list action text) overlook-bridge-test--log)))
          (current-buffer)))
    (attach . ,(lambda (name data) (format "@%s:%d" name (length data))))))

(defmacro overlook-bridge-test-with-daemon (&rest body)
  "Run BODY with a fake agent and the mode connected to a fake daemon.
BODY sees the agent's conversation id as `id' and the sync's params as `sync'."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "olb" t))
          (root (make-temp-file "olb-root" t))
          (overlook-remote-bridge-socket (expand-file-name "s.sock" dir))
          (overlook-remote-bridge-retry-delays '(0.05 . 0.2))
          (overlook-remote-bridge-flush-delay 0.01)
          (overlook-remote-bridge-dashboard-interval 0)
          (overlook-remote-bridge-buffer-limits overlook-remote-bridge-buffer-limits)
          (overlook-agent-notify-function #'ignore)
          (overlook-sections (list #'overlook-bridge-test--section))
          (overlook-bridge-test--received nil)
          (overlook-bridge-test--client nil)
          (overlook-bridge-test--partial "")
          (overlook-bridge-test--log nil)
          (overlook-bridge-test--ready t)
          (overlook-bridge-test--form-id "form-1")
          (overlook-bridge-test--agent (generate-new-buffer "olb-agent"))
          (server (overlook-bridge-test--serve overlook-remote-bridge-socket))
          (id (overlook-data-agent-id overlook-bridge-test--agent)))
     (ignore id)
     (unwind-protect
         (progn
           (with-current-buffer overlook-bridge-test--agent
             (insert "earlier\nlatest")
             (setq overlook-agent-identity (overlook-bridge-test--identity root)))
           (overlook-remote-bridge-mode 1)
           (let ((sync (overlook-bridge-test--handshake)))
             (ignore sync)
             ,@body))
       (overlook-remote-bridge-mode -1)
       (delete-process server)
       (when (process-live-p overlook-bridge-test--client)
         (delete-process overlook-bridge-test--client))
       (when (buffer-live-p overlook-bridge-test--agent)
         (kill-buffer overlook-bridge-test--agent))
       (delete-directory dir t)
       (delete-directory root t))))

(defun overlook-bridge-test--node (nodes title)
  "The node titled TITLE among NODES and their children."
  (seq-some (lambda (node)
              (if (equal (alist-get 'title node) title) node
                (overlook-bridge-test--node (alist-get 'children node) title)))
            nodes))

(defun overlook-bridge-test--conversation (sync id)
  "Conversation ID in SYNC."
  (seq-find (lambda (conversation) (equal (alist-get 'id conversation) id))
            (alist-get 'conversations sync)))

(defun overlook-bridge-test--path (sync &rest titles)
  "Key path in SYNC's dashboard through the nodes of TITLES."
  (let ((nodes (alist-get 'dashboard sync)) path)
    (dolist (title titles)
      (let ((node (seq-find (lambda (node) (equal (alist-get 'title node) title)) nodes)))
        (push (alist-get 'key node) path)
        (setq nodes (alist-get 'children node))))
    (vconcat (nreverse path))))

;;; Handshake and sync

(ert-deftest overlook-bridge-handshake-and-sync ()
  (let ((hello nil))
    (cl-letf* ((take (symbol-function 'overlook-bridge-test--take-method))
               ((symbol-function 'overlook-bridge-test--take-method)
                (lambda (method)
                  (let ((message (funcall take method)))
                    (when (equal method "hello") (setq hello message))
                    message))))
      (overlook-bridge-test-with-daemon
        (let ((params (alist-get 'params hello)))
          (should (string-prefix-p "hello-" (alist-get 'id hello)))
          (should (= (alist-get 'protocol params) 1))
          (should (equal (alist-get 'epoch params) overlook-remote-bridge--epoch))
          (should (= (alist-get 'pid params) (emacs-pid)))
          (should (natnump (alist-get 'lost params)))
          (should (equal (alist-get 'emacs params) emacs-version)))
        (let* ((dashboard (alist-get 'dashboard sync))
               (projects (car dashboard))
               (shop (overlook-bridge-test--node dashboard "shop"))
               (agent (seq-find (lambda (node) (equal (alist-get 'conversation node) id))
                                (alist-get 'children shop)))
               (file (overlook-bridge-test--node dashboard "a.el"))
               (conversation (overlook-bridge-test--conversation sync id))
               (controls (alist-get 'controls conversation)))
          (should (equal (alist-get 'kind projects) "group"))
          (should (eq (alist-get 'heading projects) t))
          (should (equal (alist-get 'kind shop) "project"))
          (should (= (length (alist-get 'key shop)) 64))
          (should (equal (mapcar (lambda (c) (alist-get 'name c)) (alist-get 'commands shop))
                         '("new" "close")))
          (should (equal (alist-get 'options (car (alist-get 'commands shop))) '("claude" "codex")))
          (should (eq (alist-get 'confirm (cadr (alist-get 'commands shop))) t))
          (should (equal (alist-get 'key agent) id))
          (should (equal (alist-get 'kind agent) "agent"))
          (should (eq (alist-get 'attention agent) t))
          (should (equal (alist-get 'choices agent) '(((key . "y") (label . "Allow")))))
          (should (eq (alist-get 'diff file) t))
          (should-not (assq 'subtitle file))
          ;; Duplicate sibling keys are sent as they are; the daemon tells them apart.
          (should (= 2 (seq-count (lambda (node) (equal (alist-get 'title node) "same"))
                                  (alist-get 'children shop))))
          (should (equal (alist-get 'provider conversation) "claude"))
          (should (equal (alist-get 'title conversation) "Fix the bug"))
          (should (equal (alist-get 'status conversation) "idle"))
          (should (equal (alist-get 'root conversation) (file-name-as-directory root)))
          (should (equal (alist-get 'folder conversation)
                         (file-name-nondirectory (directory-file-name root))))
          (should (eq (alist-get 'canAttach conversation) t))
          (should (equal (alist-get 'id (alist-get 'form conversation)) "form-1"))
          (should (equal (alist-get 'fields (alist-get 'form conversation))
                         '(((key . "k") (type . "single") (title . "K") (required . t)
                            (options ((value . "a") (title . "A")))))))
          (should (eq (alist-get 'steer controls) t))
          (should (equal (alist-get 'actions controls) '("model" "stop" "restart" "close")))
          (should (equal (alist-get 'slash controls) '(((name . "/compact")))))
          (should (equal (alist-get 'settings controls)
                         '(((id . "model") (label . "Model") (value . "opus")
                            (choices ((value . "opus") (name . "Opus"))
                                     ((value . "sonnet") (name . "Sonnet"))))))))))))

(ert-deftest overlook-bridge-shows-its-state-in-the-mode-line ()
  (overlook-bridge-test-with-daemon
    (should (memq #'overlook-remote-bridge--mode-line overlook-mode-line-functions))
    (should (string-match-p "connected" (get-text-property 0 'help-echo (overlook-remote-bridge--mode-line))))
    (delete-process overlook-bridge-test--client)
    (overlook-bridge-test--wait (lambda () (not (eq overlook-remote-bridge--state 'live))))
    (should (string-match-p "offline" (get-text-property 0 'help-echo (overlook-remote-bridge--mode-line)))))
  (should-not (memq #'overlook-remote-bridge--mode-line overlook-mode-line-functions)))

;;; Publishing

(ert-deftest overlook-bridge-forwards-and-merges-events ()
  (overlook-bridge-test-with-daemon
    (with-current-buffer overlook-bridge-test--agent
      (overlook-agent-event 'prompt :text "Go")
      (overlook-agent-event 'text :text "Hel")
      (overlook-agent-event 'text :text "lo" :images (list (list :file "shot.png")))
      (overlook-agent-event 'tool :id "t1" :title "Read a.el" :status "pending" :kind "read"
                            :diffs (list (list :file "a.el" :old nil :new "x")))
      (overlook-agent-event 'tool :id "t1" :status "completed" :output "done")
      (overlook-agent-event 'tool :id "t2" :status "failed")
      (overlook-agent-event 'end)
      (overlook-agent-event 'error :text "bad"))
    (let ((events (mapcar (lambda (_) (alist-get 'params (overlook-bridge-test--take-method "agent.event")))
                          (number-sequence 1 6))))
      (should (equal (mapcar (lambda (event) (alist-get 'type event)) events)
                     '("prompt" "text" "tool" "tool" "end" "error")))
      (dolist (event events)
        (should (equal (alist-get 'conversation event) id))
        (should (string-match-p "\\`[0-9-]+T[0-9:]+\\.[0-9]\\{3\\}Z\\'" (alist-get 'at event))))
      (pcase-let ((`(,prompt ,text ,tool ,other ,end ,error) events))
        (should (equal (alist-get 'text prompt) "Go"))
        (should (equal (alist-get 'text text) "Hello"))
        (should (equal (alist-get 'images text)
                       `(((file . ,(expand-file-name "shot.png" (file-name-as-directory root)))))))
        (should (equal (alist-get 'id tool) "t1"))
        (should (equal (alist-get 'title tool) "Read a.el"))
        (should (equal (alist-get 'status tool) "completed"))
        (should (equal (alist-get 'kind tool) "read"))
        (should (equal (alist-get 'output tool) "done"))
        (should (equal (alist-get 'diffs tool) '(((file . "a.el") (old . "") (new . "x")))))
        (should (equal (alist-get 'id other) "t2"))
        (should-not (assq 'text end))
        (should (equal (alist-get 'text error) "bad"))))))

(ert-deftest overlook-bridge-sends-only-changed-states ()
  (overlook-bridge-test-with-daemon
    ;; Nothing changed: a refresh sends nothing.
    (overlook-refresh)
    (overlook-agent-changed)
    (overlook-bridge-test--quiet 0.15)
    (should-not overlook-bridge-test--received)
    ;; A change sends the conversation and the dashboard once each.
    (with-current-buffer overlook-bridge-test--agent (setq overlook-agent-status 'working))
    (overlook-agent-changed)
    (overlook-agent-changed)
    (let ((set (alist-get 'params (overlook-bridge-test--take-method "conversation.set")))
          (dashboard (alist-get 'params (overlook-bridge-test--take-method "dashboard.set"))))
      (should (equal (alist-get 'status (alist-get 'conversation set)) "working"))
      (should (equal (alist-get 'status (seq-find (lambda (node)
                                                   (equal (alist-get 'conversation node) id))
                                                 (alist-get 'children (overlook-bridge-test--node
                                                                       (alist-get 'sections dashboard)
                                                                       "shop"))))
                     "working")))
    (overlook-bridge-test--quiet 0.1)
    (should-not overlook-bridge-test--received)
    ;; A killed agent's events go before its removal.
    (with-current-buffer overlook-bridge-test--agent (overlook-agent-event 'end))
    (kill-buffer overlook-bridge-test--agent)
    (overlook-agent-changed)
    (overlook-bridge-test--find (lambda (message) (equal (alist-get 'method message) "dashboard.set")))
    (should (equal (seq-take (overlook-bridge-test--methods) 2) '("agent.event" "conversation.remove")))
    (should (equal (alist-get 'conversation (alist-get 'params (cadr overlook-bridge-test--received))) id))))

(ert-deftest overlook-bridge-buffers-events-while-disconnected ()
  (overlook-bridge-test-with-daemon
    (setq overlook-remote-bridge-buffer-limits (cons 2 (* 1024 1024))
          overlook-remote-bridge-retry-delays '(0.3 . 0.3))
    (delete-process overlook-bridge-test--client)
    (overlook-bridge-test--wait (lambda () (not (eq overlook-remote-bridge--state 'live))))
    (with-current-buffer overlook-bridge-test--agent
      (overlook-agent-event 'prompt :text "one")
      (overlook-agent-event 'prompt :text "two")
      (overlook-agent-event 'prompt :text "three"))
    (should (= overlook-remote-bridge--lost 1))
    (let ((hello (alist-get 'params (overlook-bridge-test--find
                                     (lambda (message) (equal (alist-get 'method message) "hello"))))))
      (should (= (alist-get 'lost hello) 1))
      (should (equal (alist-get 'epoch hello) overlook-remote-bridge--epoch)))
    (should (overlook-bridge-test--conversation (overlook-bridge-test--handshake) id))
    (should (equal (mapcar (lambda (_) (alist-get 'text (alist-get 'params (overlook-bridge-test--take-method
                                                                             "agent.event"))))
                           '(1 2))
                   '("two" "three")))
    (should (= overlook-remote-bridge--lost 0))
    (should-not overlook-remote-bridge--events)))

(ert-deftest overlook-bridge-sends-dashboards-at-most-once-an-interval ()
  (overlook-bridge-test-with-daemon
    (setq overlook-remote-bridge-dashboard-interval 0.4)
    (let ((started (float-time)))
      (dolist (status '(working idle working))
        (with-current-buffer overlook-bridge-test--agent (setq overlook-agent-status status))
        (overlook-agent-changed)
        (overlook-bridge-test--quiet 0.05))
      (overlook-bridge-test--take-method "dashboard.set")
      (should (>= (- (float-time) started) 0.3)))
    (overlook-bridge-test--quiet 0.5)
    (should-not (member "dashboard.set" (overlook-bridge-test--methods)))
    ;; A request's dashboard change goes before its response, interval or not.
    (with-current-buffer overlook-bridge-test--agent (setq overlook-agent-status 'idle))
    (overlook-agent-changed)
    (overlook-bridge-test--take-method "dashboard.set")
    (setq overlook-bridge-test--received nil)
    (with-current-buffer overlook-bridge-test--agent (setq overlook-agent-status 'done))
    (overlook-bridge-test--result "node.command" `(:path ,(overlook-bridge-test--path sync "Projects" "shop")
                                                   :name "new" :text "x" :option "codex"))
    (should (member "dashboard.set" (overlook-bridge-test--methods)))))

(ert-deftest overlook-bridge-writes-long-messages-in-order ()
  (overlook-bridge-test-with-daemon
    (let ((long (make-string (* 5 overlook-remote-bridge--chunk) ?é)))
      (with-current-buffer overlook-bridge-test--agent
        (overlook-agent-event 'text :text long)
        (overlook-agent-event 'prompt :text "after"))
      (should (equal (alist-get 'text (alist-get 'params (overlook-bridge-test--take-method "agent.event")))
                     long))
      (should (equal (alist-get 'text (alist-get 'params (overlook-bridge-test--take-method "agent.event")))
                     "after")))
    ;; Events left unwritten when the connection closes count as lost.
    (setq overlook-remote-bridge--lost 0
          overlook-remote-bridge--outbox (list (cons "a" t) (cons "b" nil) (cons "c" t)))
    (overlook-remote-bridge--clear-outbox)
    (should (= overlook-remote-bridge--lost 2))
    (should-not overlook-remote-bridge--outbox)))

(ert-deftest overlook-bridge-gives-up-on-an-unanswered-hello ()
  (let ((overlook-bridge-test--received nil)
        (overlook-bridge-test--client nil)
        (dir (make-temp-file "olb" t)))
    (unwind-protect
        (let* ((overlook-remote-bridge-socket (expand-file-name "s.sock" dir))
               (overlook-remote-bridge-retry-delays '(0.05 . 0.05))
               (overlook-remote-bridge-hello-timeout 0.2)
               (overlook-sections nil)
               (server (overlook-bridge-test--serve overlook-remote-bridge-socket)))
          (unwind-protect
              (progn
                (overlook-remote-bridge-mode 1)
                (let ((first (overlook-bridge-test--take-method "hello"))
                      (client overlook-bridge-test--client))
                  (overlook-bridge-test--wait (lambda () (not (process-live-p client))))
                  (should-not (eq overlook-remote-bridge--state 'live))
                  (should-not (equal (alist-get 'id (overlook-bridge-test--take-method "hello"))
                                     (alist-get 'id first)))))
            (overlook-remote-bridge-mode -1)
            (delete-process server)))
      (delete-directory dir t))))

(ert-deftest overlook-bridge-stops-on-a-protocol-mismatch ()
  (let ((overlook-bridge-test--received nil)
        (dir (make-temp-file "olb" t)))
    (unwind-protect
        (let* ((overlook-remote-bridge-socket (expand-file-name "s.sock" dir))
               (overlook-remote-bridge-retry-delays '(0.05 . 0.05))
               (overlook-sections nil)
               (server (overlook-bridge-test--serve overlook-remote-bridge-socket)))
          (unwind-protect
              (progn
                (overlook-remote-bridge-mode 1)
                (let ((hello (overlook-bridge-test--take-method "hello")))
                  (overlook-bridge-test--send
                   `(:jsonrpc "2.0" :id ,(alist-get 'id hello)
                     :error (:code 409 :message "Protocol 2 needed"
                             :data (:problem "protocol_mismatch")))))
                (overlook-bridge-test--wait (lambda () (eq overlook-remote-bridge--state 'refused)))
                (overlook-bridge-test--quiet 0.3)
                (should-not overlook-bridge-test--received)
                (should-not overlook-remote-bridge--retry-timer))
            (overlook-remote-bridge-mode -1)
            (delete-process server)))
      (delete-directory dir t))))

(ert-deftest overlook-bridge-reads-split-lines-and-utf-8 ()
  (overlook-bridge-test-with-daemon
    (let* ((first (encode-coding-string
                   (concat (json-serialize '(:jsonrpc "2.0" :id 101 :method "ping" :params (:x "é")))
                           "\n"
                           (json-serialize '(:jsonrpc "2.0" :id 102 :method "ping")))
                   'utf-8))
           ;; The cut falls inside the two bytes of "é".
           (cut (1+ (string-search "\303" first))))
      (process-send-string overlook-bridge-test--client (substring first 0 cut))
      (overlook-bridge-test--quiet 0.05)
      (process-send-string overlook-bridge-test--client (substring first cut))
      (overlook-bridge-test--take (lambda (message) (equal (alist-get 'id message) 101)))
      (overlook-bridge-test--quiet 0.05)
      (should-not (seq-find (lambda (message) (equal (alist-get 'id message) 102))
                            overlook-bridge-test--received))
      (process-send-string overlook-bridge-test--client "\n")
      (overlook-bridge-test--take (lambda (message) (equal (alist-get 'id message) 102))))
    ;; Text that is not valid UTF-8 arrives with replacement characters.
    (with-current-buffer overlook-bridge-test--agent
      (overlook-agent-event 'text :text (concat "a" (string #x3fffa0) "é")))
    (should (equal (alist-get 'text (alist-get 'params (overlook-bridge-test--take-method "agent.event")))
                   "a�é"))))

(ert-deftest overlook-bridge-marks-conversations-seen-and-resyncs ()
  (overlook-bridge-test-with-daemon
    (with-current-buffer overlook-bridge-test--agent (setq overlook-agent-status 'done))
    (overlook-bridge-test--send `(:jsonrpc "2.0" :method "conversation.seen" :params (:conversation ,id)))
    (overlook-bridge-test--wait (lambda () (eq (buffer-local-value 'overlook-agent-status
                                                                   overlook-bridge-test--agent)
                                               'idle)))
    (setq overlook-bridge-test--received nil)
    (overlook-bridge-test--send '(:jsonrpc "2.0" :method "resync" :params nil))
    (should (overlook-bridge-test--conversation
             (alist-get 'params (overlook-bridge-test--take-method "sync")) id))))

;;; Reloading

(defun overlook-bridge-test--timers ()
  "Functions of the bridge's pending timers."
  (seq-filter (lambda (function)
                (and (symbolp function)
                     (string-prefix-p "overlook-remote-bridge-" (symbol-name function))))
              (mapcar #'timer--function (append timer-list timer-idle-list))))

(ert-deftest overlook-bridge-survives-reloading ()
  ;; Agents edit the bridge from the phone and load it into the Emacs serving them.
  (overlook-bridge-test-with-daemon
    (let ((process overlook-remote-bridge--process)
          (timers (overlook-bridge-test--timers))
          (file (locate-library "overlook-remote-bridge.el" t)))
      (should file)
      (load file nil t t)
      (load file nil t t)
      (should overlook-remote-bridge-mode)
      (should (eq overlook-remote-bridge--process process))
      (should (process-live-p process))
      (should (= 1 (seq-count (lambda (p) (string-prefix-p "overlook-remote-bridge" (process-name p)))
                              (process-list))))
      (pcase-dolist (`(,hook ,function) overlook-remote-bridge--hooks)
        (should (= 1 (seq-count (lambda (f) (eq f function)) (default-value hook)))))
      (should (equal (overlook-bridge-test--timers) timers))
      (should (eq overlook-remote-bridge--state 'live))
      (with-current-buffer overlook-bridge-test--agent
        (overlook-agent-event 'prompt :text "after reload"))
      (should (equal (alist-get 'text (alist-get 'params (overlook-bridge-test--take-method "agent.event")))
                     "after reload"))
      (should (eq (overlook-bridge-test--result "ping") nil))
      (should-not (member "hello" (overlook-bridge-test--methods))))))

;;; Requests

(ert-deftest overlook-bridge-prompts-and-queues ()
  (overlook-bridge-test-with-daemon
    (should (equal (overlook-bridge-test--result "conversation.prompt" `(:conversation ,id :text " hi "))
                   '((delivery . "sent"))))
    (should (equal overlook-bridge-test--log '((submit "hi"))))
    (should (equal (overlook-bridge-test--error "conversation.prompt" `(:conversation ,id :text "  "))
                   '(400 "empty_text")))
    (should (equal (overlook-bridge-test--error "conversation.prompt" '(:conversation "gone" :text "x"))
                   '(404 "conversation_missing")))
    (setq overlook-bridge-test--ready nil)
    ;; The queue's new state is sent before the response.
    (let* ((response (overlook-bridge-test--request "conversation.prompt" `(:conversation ,id :text "later")))
           (queued (alist-get 'queueId (alist-get 'result response)))
           (set (overlook-bridge-test--take-method "conversation.set")))
      (should (equal (alist-get 'delivery (alist-get 'result response)) "queued"))
      (should (equal (alist-get 'queue (alist-get 'conversation (alist-get 'params set)))
                     `(((id . ,queued) (text . "later")))))
      (let ((second (alist-get 'queueId (overlook-bridge-test--result
                                         "conversation.prompt" `(:conversation ,id :text "later")))))
        (should-not (equal queued second))
        (should (equal (overlook-bridge-test--result "conversation.unqueue"
                                                     `(:conversation ,id :queueId ,second))
                       nil))
        (should (equal (overlook-bridge-test--error "conversation.unqueue"
                                                    `(:conversation ,id :queueId ,second))
                       '(409 "already_sent"))))
      ;; A failed delivery waits for a retry.
      (with-current-buffer overlook-bridge-test--agent
        (setq overlook-remote-bridge--queue-error "failed"))
      (setq overlook-bridge-test--ready t)
      (overlook-remote-bridge--deliver)
      (should (equal overlook-bridge-test--log '((submit "hi"))))
      (should-not (overlook-bridge-test--result "conversation.retry" `(:conversation ,id)))
      (should-not (buffer-local-value 'overlook-remote-bridge--queue-error overlook-bridge-test--agent))
      (overlook-remote-bridge--deliver)
      (should (equal overlook-bridge-test--log '((submit "later") (submit "hi"))))
      (should-not (buffer-local-value 'overlook-remote-bridge--queue overlook-bridge-test--agent))
      (should-not overlook-remote-bridge--queue-timer)
      (should (equal (overlook-bridge-test--error "conversation.unqueue"
                                                  `(:conversation ,id :queueId ,queued))
                     '(409 "already_sent"))))
    ;; An agent without submit cannot take prompts.
    (with-current-buffer overlook-bridge-test--agent
      (setf (alist-get 'submit overlook-agent-identity nil t) nil))
    (should (equal (overlook-bridge-test--error "conversation.prompt" `(:conversation ,id :text "x"))
                   '(409 "prompt_unsupported")))))

(ert-deftest overlook-bridge-runs-session-actions-with-confirmations ()
  (overlook-bridge-test-with-daemon
    (should (equal (overlook-bridge-test--result "conversation.action"
                                                 `(:conversation ,id :action "steer" :text "turn"))
                   `((outcome . "done") (conversation . ,id))))
    (should (equal overlook-bridge-test--log '(("steer" "turn"))))
    (should (equal (overlook-bridge-test--error "conversation.action"
                                                `(:conversation ,id :action "steer" :text " "))
                   '(400 "empty_text")))
    (should (equal (overlook-bridge-test--error "conversation.action"
                                                `(:conversation ,id :action "eval" :text "x"))
                   '(400 "unsupported_action")))
    (should (equal (overlook-bridge-test--result "conversation.action"
                                                 `(:conversation ,id :action "model" :text "sonnet"))
                   `((outcome . "done") (conversation . ,id))))
    (should (equal (car overlook-bridge-test--log) '("model" "sonnet")))
    (should (equal (overlook-bridge-test--error "conversation.action"
                                                `(:conversation ,id :action "model" :text "bad"))
                   '(409 "state_conflict")))
    (should (equal (overlook-bridge-test--error "conversation.action" `(:conversation ,id :action "stop"))
                   '(500 "internal_error")))
    ;; Restart asks its own question, then the agent's, before it runs.
    (setq overlook-bridge-test--log nil)
    (let* ((first (overlook-bridge-test--result "conversation.action"
                                                `(:conversation ,id :action "restart" :confirmed [])))
           (question (alist-get 'question first))
           (second (overlook-bridge-test--result
                    "conversation.action" `(:conversation ,id :action "restart" :confirmed [,question]))))
      (should (equal (alist-get 'outcome first) "confirm"))
      (should (equal question "Start a fresh conversation? Unsent prompts may be lost."))
      (should (equal second '((outcome . "confirm") (question . "Busy. Continue?"))))
      (should-not overlook-bridge-test--log)
      (should (equal (overlook-bridge-test--result
                      "conversation.action"
                      `(:conversation ,id :action "restart" :confirmed [,question "Busy. Continue?"]))
                     `((outcome . "done") (conversation . ,id))))
      (should (equal overlook-bridge-test--log '(("restart" "")))))
    ;; Close asks first, discards the queue, and the conversation goes.
    (with-current-buffer overlook-bridge-test--agent
      (setq overlook-remote-bridge--queue '((:id "queued-x" :text "x"))))
    (cl-letf (((symbol-function 'overlook-agent-close)
               (lambda (buffer)
                 (should-not (buffer-local-value 'overlook-remote-bridge--queue buffer))
                 (kill-buffer buffer))))
      (let ((question (alist-get 'question (overlook-bridge-test--result
                                            "conversation.action"
                                            `(:conversation ,id :action "close")))))
        (should (string-prefix-p "Close agent Fix the bug? Queued prompts will be discarded." question))
        (should (buffer-live-p overlook-bridge-test--agent))
        (setq overlook-bridge-test--received nil)
        (should (equal (overlook-bridge-test--result
                        "conversation.action" `(:conversation ,id :action "close" :confirmed [,question]))
                       '((outcome . "done") (closed . t))))
        (should-not (buffer-live-p overlook-bridge-test--agent))))
    (overlook-agent-changed)
    (should (equal (alist-get 'conversation (alist-get 'params (overlook-bridge-test--take-method
                                                                "conversation.remove")))
                   id))))

(ert-deftest overlook-bridge-answers-choices-forms-and-attachments ()
  (overlook-bridge-test-with-daemon
    (should-not (overlook-bridge-test--result "conversation.choose" `(:conversation ,id :key "y")))
    (should (equal overlook-bridge-test--log '(chose)))
    (should (equal (overlook-bridge-test--error "conversation.choose" `(:conversation ,id :key "n"))
                   '(409 "state_conflict")))
    (should-not (overlook-bridge-test--result
                 "conversation.answer"
                 `(:conversation ,id :form "form-1" :action "accept" :values (:k "a" :many ["x" "y"]))))
    (should (equal (car overlook-bridge-test--log)
                   '(answer "form-1" "accept" ((k . "a") (many . ["x" "y"])))))
    (should (equal (overlook-bridge-test--error "conversation.answer"
                                                `(:conversation ,id :form "old" :action "decline"))
                   '(409 "state_conflict")))
    (let ((file (make-temp-file "olb-upload" nil ".png" "\211PNG-bytes")))
      (unwind-protect
          (should (equal (overlook-bridge-test--result
                          "conversation.attach"
                          `(:conversation ,id :path ,file :name "phone-1.png"))
                         '((text . "@phone-1.png:10"))))
        (delete-file file)))
    (should (equal (overlook-bridge-test--result "conversation.earlier" `(:conversation ,id))
                   '((reply . "Done: café") (transcript . "earlier\nlatest"))))
    (should (equal (overlook-bridge-test--result "ping") nil))
    (let ((error (alist-get 'error (overlook-bridge-test--request "eval"))))
      (should (= (alist-get 'code error) -32601))
      (should-not (alist-get 'data error)))
    ;; An agent without these capabilities refuses them by name.
    (with-current-buffer overlook-bridge-test--agent
      (setq overlook-agent-identity '((agent . "plain"))))
    (should (equal (overlook-bridge-test--error "conversation.answer"
                                                `(:conversation ,id :form "form-1" :action "accept"))
                   '(409 "answer_unsupported")))
    (should (equal (overlook-bridge-test--error "conversation.attach"
                                                `(:conversation ,id :path "/nonexistent" :name "x.png"))
                   '(409 "attachment_unsupported")))
    (should (equal (overlook-bridge-test--error "conversation.retry" '(:conversation "gone"))
                   '(404 "conversation_missing")))))

(ert-deftest overlook-bridge-runs-row-commands-and-diffs ()
  (overlook-bridge-test-with-daemon
    (let ((shop (overlook-bridge-test--path sync "Projects" "shop"))
          (file (overlook-bridge-test--path sync "Projects" "shop" "a.el")))
      (should (equal (overlook-bridge-test--result
                      "node.command" `(:path ,shop :name "new" :text " fix it " :option "codex"))
                     `((outcome . "done") (conversation . ,id) (draft . "draft text"))))
      (should (equal (car overlook-bridge-test--log) '(new "fix it" "codex")))
      (should (equal (overlook-bridge-test--error "node.command"
                                                  `(:path ,shop :name "new" :text " " :option "codex"))
                     '(400 "empty_text")))
      (should (equal (overlook-bridge-test--error "node.command"
                                                  `(:path ,shop :name "new" :text "x" :option "pi"))
                     '(400 "invalid_option")))
      (should (equal (overlook-bridge-test--error "node.command" `(:path ,shop :name "gone"))
                     '(404 "command_missing")))
      (should (equal (overlook-bridge-test--error "node.command" '(:path ["nope"] :name "new"))
                     '(404 "node_missing")))
      ;; The command's question, then the questions it asks while running.
      (setq overlook-bridge-test--log nil)
      (should (equal (overlook-bridge-test--result "node.command" `(:path ,shop :name "close" :confirmed []))
                     '((outcome . "confirm") (question . "Close project shop?"))))
      (should (equal (overlook-bridge-test--result
                      "node.command" `(:path ,shop :name "close" :confirmed ["Close project shop?"]))
                     '((outcome . "confirm") (question . "Really?"))))
      (should-not overlook-bridge-test--log)
      (should (equal (overlook-bridge-test--result
                      "node.command"
                      `(:path ,shop :name "close" :confirmed ["Close project shop?" "Really?"]))
                     '((outcome . "done"))))
      (should (equal overlook-bridge-test--log '(close)))
      (should (equal (overlook-bridge-test--result "node.diff" `(:path ,file))
                     '((diff . "-x\n+y\n"))))
      (should (equal (overlook-bridge-test--error "node.diff" `(:path ,shop))
                     '(404 "diff_missing")))
      (should (equal (overlook-bridge-test--error "node.diff" '(:path ["nope"]))
                     '(404 "node_missing"))))))

;;; Data

(ert-deftest overlook-bridge-tells-duplicate-siblings-apart-by-path ()
  (let* ((first (overlook-row :content "same" :commands (list (list :name "a" :label "A"))))
         (second (overlook-row :content "same" :commands (list (list :name "b" :label "B"))))
         (rows (make-hash-table :test #'equal))
         (sections (overlook-remote-bridge-sections
                    (list (overlook-section-row "S" (list first second))) rows))
         (section (plist-get (aref sections 0) :key))
         (key (plist-get (aref (plist-get (aref sections 0) :children) 0) :key)))
    (should (equal key (plist-get (aref (plist-get (aref sections 0) :children) 1) :key)))
    (should (eq (gethash (list section key) rows) first))
    (should (eq (gethash (list section (concat key "#2")) rows) second))))

;; Keys only lists Emacs bindings, so the phone does not get it.
(ert-deftest overlook-bridge-leaves-out-hidden-sections ()
  (let ((sections (overlook-remote-bridge-sections
                   (list (overlook-section-row "Keys" (list (overlook-row :content "w")))
                         (overlook-section-row "Inbox" (list (overlook-row :content "x"))))
                   (make-hash-table :test #'equal))))
    (should (equal (mapcar (lambda (node) (plist-get node :title)) sections) '("Inbox")))))

(ert-deftest overlook-bridge-splits-long-text-and-cuts-output ()
  (with-temp-buffer
    (let* ((text (make-string (+ overlook-remote-bridge--text-limit 10) ?a))
           (events (overlook-remote-bridge-events (current-buffer) (list :type 'text :text text)))
           (tool (car (overlook-remote-bridge-events
                       (current-buffer)
                       (list :type 'tool :id "t" :output (make-string (* 300 1024) ?é)
                             :diffs (list (list :file "big" :old (make-string (* 3 1024 1024) ?x)
                                                :new "")))))))
      (should (> (length events) 1))
      (should (equal (apply #'concat (mapcar (lambda (event) (plist-get event :text)) events)) text))
      (should (<= (string-bytes (plist-get tool :output)) overlook-remote-bridge--output-limit))
      (should-not (plist-get tool :diffs))
      (should-not (overlook-remote-bridge-events (current-buffer) '(:type unknown))))))

(ert-deftest overlook-bridge-merges-only-allowed-neighbours ()
  (let ((text (lambda (conversation text) (list :conversation conversation :at "t" :type "text" :text text)))
        (tool (lambda (id &rest more) (append (list :conversation "c" :at "t" :type "tool" :id id) more))))
    (should (equal (plist-get (overlook-remote-bridge-merge (funcall text "c" "a") (funcall text "c" "b")) :text)
                   "ab"))
    (should-not (overlook-remote-bridge-merge (funcall text "c" "a") (funcall text "d" "b")))
    (should-not (overlook-remote-bridge-merge (funcall tool "1") (funcall tool "2")))
    (let ((merged (overlook-remote-bridge-merge (funcall tool "1" :title "T" :status "pending")
                                                (funcall tool "1" :status "completed"))))
      (should (equal (plist-get merged :title) "T"))
      (should (equal (plist-get merged :status) "completed")))
    (should-not (overlook-remote-bridge-merge (funcall text "c" "a") (funcall tool "1")))))

;;; overlook-remote-bridge-test.el ends here

;;; Supervision

(ert-deftest overlook-bridge-says-bye-when-turned-off-or-quitting ()
  (overlook-bridge-test-with-daemon
    (should (memq #'overlook-remote-bridge--bye kill-emacs-hook))
    ;; Queued output goes before bye, so bye starts a line of its own.
    (overlook-remote-bridge--notify "agent.event" '(:conversation "x" :at "t" :type "end"))
    (overlook-remote-bridge-mode -1)
    (should-not (memq #'overlook-remote-bridge--bye kill-emacs-hook))
    (overlook-bridge-test--take-method "bye")
    (should (equal (car (last (overlook-bridge-test--methods))) "agent.event"))))

(ert-deftest overlook-bridge-restarts-emacs-on-request ()
  (overlook-bridge-test-with-daemon
    (let (calls)
      (cl-letf (((symbol-function 'save-some-buffers) (lambda (&rest args) (push (cons 'save args) calls)))
                ((symbol-function 'kill-emacs) (lambda (&rest _) (push 'kill calls))))
        (should-not (overlook-bridge-test--result "emacs.restart"))
        (should-not calls)
        (overlook-bridge-test--wait (lambda () (memq 'kill calls)))
        (should (equal (reverse calls) '((save t) kill)))))))

(ert-deftest overlook-bridge-sends-agent-row-marks-as-note ()
  (let ((buffer (generate-new-buffer "olb-note"))
        (overlook-agent-row-marks
         (list (lambda (_) (propertize " awaiting claude quota" 'face 'warning))
               (lambda (_) nil)
               (lambda (_) " ← boss"))))
    (unwind-protect
        (progn
          (with-current-buffer buffer (setq overlook-agent-identity '((agent . "claude"))))
          (let* ((rows (make-hash-table :test #'equal))
                 (sections (overlook-remote-bridge-sections
                            (list (overlook-section-row
                                   "S" (list (overlook-row :id (cons 'agent buffer) :content "a")
                                             (overlook-row :content "plain"))))
                            rows))
                 (children (plist-get (aref sections 0) :children)))
            (should (equal (plist-get (aref children 0) :note) "awaiting claude quota ← boss"))
            (should-not (plist-member (aref children 1) :note))))
      (kill-buffer buffer))))
