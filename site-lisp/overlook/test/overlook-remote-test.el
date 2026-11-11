;;; overlook-remote-test.el --- Tests for overlook-remote -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-remote)

(defvar overlook-remote-test--submitted nil
  "Prompts the fake agent was given, newest first.")

(defvar overlook-remote-test--chosen nil
  "Answers the fake agent was given, newest first.")

(defmacro overlook-remote-test-with-agent (ready &rest body)
  "Run BODY with a token and a fake agent \"claude\", taking prompts when READY."
  (declare (indent 1))
  `(let* ((overlook-remote-token-file (make-temp-file "overlook-remote-token"))
          (overlook-remote-test--submitted nil)
          (overlook-remote-test--chosen nil)
          (agent (generate-new-buffer "claude@shop")))
     (delete-file overlook-remote-token-file)
     (unwind-protect
         (progn
           (with-current-buffer agent
             (insert "earlier output\nlatest output")
             (setq overlook-agent-identity
                   `((agent . "claude") (root . "/work/shop/")
                     (submit . ,(lambda (text) (push text overlook-remote-test--submitted)))
                     (ready . ,(lambda () ,ready))
                     (reply . ,(lambda () "Done: café"))
                     (choices . ,(lambda ()
                                   (list (list "y" "Allow" (lambda () (push "y" overlook-remote-test--chosen)))
                                         (list "n" "Reject" (lambda () (push "n" overlook-remote-test--chosen)))))))))
           ,@body)
       (kill-buffer agent)
       (when (file-exists-p overlook-remote-token-file)
         (delete-file overlook-remote-token-file)))))

(defun overlook-remote-test--call (method path &optional body token query)
  "Answer METHOD on PATH with JSON BODY, carrying TOKEN or the right one.
QUERY is the parsed query.  Return (STATUS . DATA) with DATA parsed."
  (pcase-let ((`(,status ,_ ,text)
               (overlook-remote--respond
                method path query
                `((,method ,path "HTTP/1.1")
                  ("Authorization" ,(concat "Bearer " (or token (overlook-remote--token))))
                  ,@(when body
                      `(("Content" ,(encode-coding-string (json-encode body) 'utf-8))))))))
    (cons status (json-parse-string text :object-type 'alist :array-type 'list))))

(ert-deftest overlook-remote-session-controls-confirm-and-allowlist ()
  (overlook-remote-test-with-agent t
    (let ((ran nil))
      (with-current-buffer agent
        (setf (alist-get 'remote-controls overlook-agent-identity)
              (lambda () '(:actions ("restart"))))
        (setf (alist-get 'remote-action overlook-agent-identity)
              (lambda (action _text)
                (when (y-or-n-p "Agent is busy. Restart anyway?")
                  (setq ran action))
                agent)))
      (let* ((body `((id . ,(buffer-name agent)) (action . "restart")))
             (first (cdr (overlook-remote-test--call "POST" "/api/session" body)))
             (question (alist-get 'confirm first)))
        (should (stringp question))
        (should-not ran)
        (push (cons 'confirmations (vector question)) body)
        (setf (alist-get 'confirmationToken body) (alist-get 'confirmationToken first))
        (let ((second (cdr (overlook-remote-test--call "POST" "/api/session" body))))
          (should (equal (alist-get 'confirm second) "Agent is busy. Restart anyway?"))
          (should-not ran)
          (setf (alist-get 'confirmationToken body) (alist-get 'confirmationToken second))
          (setf (alist-get 'confirmations body)
                (vector question (alist-get 'confirm second)))
          (should (equal (alist-get 'agent (cdr (overlook-remote-test--call
                                                "POST" "/api/session" body)))
                         (overlook-remote-service-agent-id agent)))
          (should (equal ran "restart"))))
      (dolist (action '("eval" "fork" "steer"))
        (should (= 400 (car (overlook-remote-test--call
                             "POST" "/api/session"
                             `((id . ,(buffer-name agent)) (action . ,action) (text . "hello"))))))))))

(ert-deftest overlook-remote-steers-without-draining-the-queue ()
  (overlook-remote-test-with-agent nil
    (let (steered)
      (with-current-buffer agent
        (setq overlook-remote--queue '((:id "later" :text "later")))
        (setf (alist-get 'remote-controls overlook-agent-identity)
              (lambda () '(:steer t :slash ((:name "compact"))))
              (alist-get 'remote-action overlook-agent-identity)
              (lambda (action text)
                (should (equal action "steer"))
                (setq steered text)
                agent)))
      (let ((body `((id . ,(buffer-name agent)) (action . "steer") (text . "change course"))))
        (should (= 200 (car (overlook-remote-test--call "POST" "/api/session" body)))))
      (should (equal steered "change course"))
      (should-not overlook-remote-test--submitted)
      (should (equal (buffer-local-value 'overlook-remote--queue agent) '((:id "later" :text "later"))))
      (should (= 400 (car (overlook-remote-test--call
                           "POST" "/api/session"
                           `((id . ,(buffer-name agent)) (action . "steer") (text . " "))))))
      (let ((controls (plist-get (overlook-remote--agent agent) :controls)))
        (should (eq (plist-get controls :steer) t))
        (should (equal (plist-get (aref (plist-get controls :slash) 0) :name) "compact"))))))

(ert-deftest overlook-remote-token-is-kept-private-and-reused ()
  (overlook-remote-test-with-agent t
    (let ((token (overlook-remote--token)))
      (should (= (length token) 64))
      (should (= (file-modes overlook-remote-token-file) #o600))
      (should (equal (overlook-remote--token) token))
      (should-not (equal (overlook-remote-new-token) token)))))

(ert-deftest overlook-remote-identifies-missing-sessions ()
  (overlook-remote-test-with-agent t
    (let ((response (overlook-remote-test--call "GET" "/api/agent" nil nil
                                              '(("id" "missing-agent")))))
      (should (= 404 (car response)))
      (should (equal "agent_missing" (alist-get 'code (cdr response)))))))

(ert-deftest overlook-remote-serializes-no-queue-error-as-null ()
  (overlook-remote-test-with-agent nil
    (with-current-buffer agent (setq overlook-remote--queue '((:id "later" :text "later"))))
    (let* ((response (cdr (overlook-remote-test--call "GET" "/api/agent" nil nil
                                                    `(("id" ,(buffer-name agent))))))
           (error (alist-get 'queueError response)))
      (should (eq error :null))
      (should (equal (alist-get 'queued response) '("later"))))))

(ert-deftest overlook-remote-offers-tailscale-then-the-local-network ()
  (cl-flet ((address (&rest interfaces)
              (cl-letf (((symbol-function 'network-interface-list)
                         (lambda (&rest _) interfaces)))
                (overlook-remote--address))))
    (let ((loopback '("lo0" . [127 0 0 1 0]))
          (wifi '("en0" . [192 168 1 2 0]))
          (tailscale '("utun6" . [100 111 224 2 0])))
      (should (equal (address loopback wifi tailscale) "100.111.224.2"))
      (should (equal (address '("utun1" . [10 0 0 2 0]) wifi) "192.168.1.2"))
      ;; A public address in 100/8, below and above Tailscale's range.
      (should (equal (address '("utun6" . [100 63 0 1 0]) wifi) "192.168.1.2"))
      (should (equal (address '("utun6" . [100 128 0 1 0]) wifi) "192.168.1.2"))
      (should (equal (address '("utun6" . [100 64 0 1 0]) wifi) "100.64.0.1"))
      (should (equal (address '("utun6" . [100 127 0 1 0]) wifi) "100.127.0.1"))
      (should-not (address loopback)))))

(ert-deftest overlook-remote-page-needs-no-token-but-calls-do ()
  (overlook-remote-test-with-agent t
    (pcase-let ((`(,status ,mime ,_) (overlook-remote--respond "GET" "/overlook/" nil nil)))
      (should (= status 200))
      (should (equal mime "text/html")))
    (pcase-let ((`(,status ,mime ,body)
                 (overlook-remote--respond "GET" "/overlook/vendor/purify.js" nil nil)))
      (should (= status 200))
      (should (equal mime "text/javascript"))
      (should (string-match-p "DOMPurify" body)))
    (dolist (asset '(("framework7.js" "text/javascript" "Framework7")
                    ("framework7.css" "text/css" "Framework7")))
      (pcase-let ((`(,status ,mime ,body)
                   (overlook-remote--respond "GET" (concat "/overlook/vendor/" (car asset)) nil nil)))
        (should (= status 200))
        (should (equal mime (cadr asset)))
        (should (string-match-p (caddr asset) body))))
    (should (= (car (overlook-remote--respond "GET" "/overlook/vendor/../overlook-remote.el" nil nil))
               401))
    (should (= (car (overlook-remote-test--call "GET" "/overlook/api/agents" nil "wrong")) 401))))

(ert-deftest overlook-remote-install-assets-need-no-token ()
  (dolist (size '(180 192 512))
    (pcase-let* ((route (if (= size 180) "/apple-touch-icon.png"
                         (format "/icon-%s.png" size)))
                 (`(,status ,mime ,body)
                  (overlook-remote--respond "GET" (concat "/overlook" route) nil nil)))
      (should (= status 200))
      (should (equal mime "image/png"))
      (should-not (multibyte-string-p body))
      (should (equal (substring body 0 8) (unibyte-string 137 80 78 71 13 10 26 10)))))
  (pcase-let ((`(,status ,mime ,body)
               (overlook-remote--respond "GET" "/overlook/manifest.webmanifest" nil nil)))
    (should (= status 200))
    (should (equal mime "application/manifest+json"))
    ;; Keep the installing page's credential-bearing URL as the launch URL.
    (should-not (assq 'start_url (json-parse-string body :object-type 'alist)))))

(ert-deftest overlook-remote-lists-agents-with-their-choices ()
  (overlook-remote-test-with-agent t
    (pcase-let* ((`(,status . ,data) (overlook-remote-test--call "GET" "/overlook/api/agents"))
                 (agent (seq-find (lambda (a) (equal (alist-get 'id a) (overlook-remote-service-agent-id agent)))
                                  (alist-get 'agents data))))
      (should (= status 200))
      (should (equal (alist-get 'folder agent) "shop"))
      (should (equal (alist-get 'status agent) "idle"))
      (should (equal (mapcar (lambda (c) (alist-get 'key c)) (alist-get 'choices agent))
                     '("y" "n"))))))

(ert-deftest overlook-remote-shows-an-agents-reply-and-transcript ()
  (overlook-remote-test-with-agent t
    (pcase-let ((`(,status . ,agent) (overlook-remote-test--call
                                      "GET" "/overlook/api/agent" nil nil
                                      '(("id" "claude@shop")))))
      (should (= status 200))
      (should (equal (alist-get 'reply agent) "Done: café"))
      (should (string-suffix-p "latest output" (alist-get 'transcript agent))))
    (should (= (car (overlook-remote-test--call "GET" "/overlook/api/agent" nil nil
                                                '(("id" "nobody"))))
               404))))

(ert-deftest overlook-remote-deduplicates-message-retries ()
  (overlook-remote-test-with-agent t
    (let* ((overlook-remote-service--receipts (make-hash-table :test #'equal))
           (body `((id . ,(buffer-name agent)) (text . "once") (requestId . "retry-1")))
           (first (overlook-remote-test--call "POST" "/api/prompt" body)))
      (should (equal first (overlook-remote-test--call "POST" "/api/prompt" body)))
      (should (equal overlook-remote-test--submitted '("once")))
      (setf (alist-get 'text body) "different")
      (should (= 409 (car (overlook-remote-test--call "POST" "/api/prompt" body)))))))

(ert-deftest overlook-remote-keeps-older-message-receipts ()
  (let ((overlook-remote-service--receipts (make-hash-table :test #'equal))
        (submitted 0))
    (let ((send (lambda (_body)
                  (setq submitted (1+ submitted))
                  '(:ok t))))
      (dotimes (index 300)
        (overlook-remote--once "/api/prompt" `((requestId . ,(number-to-string index))) send))
      (overlook-remote--once "/api/prompt" '((requestId . "0")) send)
      (should (= submitted 300)))))

(ert-deftest overlook-remote-preserves-failed-queue-until-retry ()
  (overlook-remote-test-with-agent t
    (let ((overlook-remote--queue-timer (run-at-time 3600 nil #'ignore)))
      (unwind-protect
          (progn
            (with-current-buffer agent
              (setq overlook-remote--queue '((:id "keep" :text "keep") (:id "later" :text "later")))
              (setf (alist-get 'submit overlook-agent-identity) (lambda (_) (error "Unavailable"))))
            (overlook-remote--send-queued)
            (should (equal (buffer-local-value 'overlook-remote--queue agent) '((:id "keep" :text "keep") (:id "later" :text "later"))))
            (should (equal (plist-get (overlook-remote--agent agent) :queueError) "Unavailable"))
            (with-current-buffer agent
              (setf (alist-get 'submit overlook-agent-identity)
                    (lambda (text) (push text overlook-remote-test--submitted))))
            (overlook-remote--send-queued)
            (should-not overlook-remote-test--submitted)
            (overlook-remote-test--call "POST" "/api/retry" `((id . ,(buffer-name agent))))
            (overlook-remote--send-queued)
            (should (equal overlook-remote-test--submitted '("keep")))
            (should (equal (buffer-local-value 'overlook-remote--queue agent) '((:id "later" :text "later")))))
        (when overlook-remote--queue-timer (cancel-timer overlook-remote--queue-timer))))))

(ert-deftest overlook-remote-prompts-a-ready-agent ()
  (overlook-remote-test-with-agent t
    (should (= (car (overlook-remote-test--call "POST" "/overlook/api/prompt"
                                                '((id . "claude@shop") (text . " 继续 "))))
               200))
    (should (equal overlook-remote-test--submitted '("继续")))))

(defvar overlook-remote-test--ready nil
  "Whether the fake agent takes a prompt now.")

(ert-deftest overlook-remote-queues-prompts-for-a-busy-agent ()
  (overlook-remote-test-with-agent overlook-remote-test--ready
    (let ((overlook-remote-test--ready nil)
          (overlook-remote--queue-timer nil)
          (overlook-remote--waiting nil)
          (prompt (lambda (text)
                    (cdr (overlook-remote-test--call "POST" "/overlook/api/prompt"
                                                     `((id . "claude@shop") (text . ,text)))))))
      (unwind-protect
          (progn
            (should (eq (alist-get 'queued (funcall prompt "one")) t))
            (funcall prompt "two")
            (funcall prompt "three")
            (should overlook-remote--queue-timer)
            (should (equal (plist-get (overlook-remote--agent agent) :queued) ["one" "two" "three"]))
            (should (= (car (overlook-remote-test--call "POST" "/overlook/api/unqueue"
                                                        '((id . "claude@shop") (text . "two"))))
                       200))
            ;; Busy: nothing goes.
            (overlook-remote--send-queued)
            (should-not overlook-remote-test--submitted)
            ;; Ready: one prompt a turn, the oldest first.
            (setq overlook-remote-test--ready t)
            (overlook-remote--send-queued)
            (should (equal overlook-remote-test--submitted '("one")))
            ;; While some wait, a new one waits behind them.
            (should (eq (alist-get 'queued (funcall prompt "four")) t))
            (overlook-remote--send-queued)
            (overlook-remote--send-queued)
            (should (equal overlook-remote-test--submitted '("four" "three" "one")))
            (should-not overlook-remote--queue-timer)
            (should (= (car (overlook-remote-test--call "POST" "/overlook/api/unqueue"
                                                        '((id . "claude@shop") (text . "two"))))
                       409)))
        (when overlook-remote--queue-timer (cancel-timer overlook-remote--queue-timer))))))

(ert-deftest overlook-remote-answers-what-an-agent-asks ()
  (overlook-remote-test-with-agent t
    (should (= (car (overlook-remote-test--call "POST" "/overlook/api/choose"
                                                '((id . "claude@shop") (key . "n"))))
               200))
    (should (equal overlook-remote-test--chosen '("n")))
    (should (= (car (overlook-remote-test--call "POST" "/overlook/api/choose"
                                                '((id . "claude@shop") (key . "!"))))
               409))))

(ert-deftest overlook-remote-seen-resets-done-only ()
  (overlook-remote-test-with-agent t
    (dolist (status '((done . idle) (waiting . waiting) (failed . failed)))
      (with-current-buffer agent (setq overlook-agent-status (car status)))
      (should (= 200 (car (overlook-remote-test--call
                           "POST" "/api/seen" `((id . ,(buffer-name agent)))))))
      (should (eq (buffer-local-value 'overlook-agent-status agent) (cdr status))))))

(defmacro overlook-remote-test-with-dashboard (&rest body)
  "Run BODY with the agent of `overlook-remote-test-with-agent' under \"shop\"."
  (declare (indent 0))
  `(let ((overlook-projects-function (lambda () '("shop")))
         (overlook-current-project-function (lambda () "shop"))
         (overlook-project-buffers-function (lambda (_) (list agent)))
         (overlook-project-root-function (lambda (_) "/work/shop/"))
         (overlook-project-functions (list #'overlook--checkout-rows))
         (overlook-worktrees-functions nil)
         (overlook-worktree-functions (list #'overlook-agent--rows))
         (overlook-sections (list #'overlook--projects-section)))
     ,@body))

(defun overlook-remote-test--text (node)
  "The title of semantic NODE from the dashboard call."
  (alist-get 'title node))

(ert-deftest overlook-remote-serves-the-dashboard-with-the-agents-choices ()
  (overlook-remote-test-with-agent t
    (overlook-remote-test-with-dashboard
      (with-current-buffer agent (setq overlook-agent-status 'waiting))
      (pcase-let* ((`(,status . ,data) (overlook-remote-test--call "GET" "/overlook/api/dashboard"))
                   (`(,section) (alist-get 'sections data))
                   (`(,shop) (alist-get 'children section))
                   (`(,row) (alist-get 'children shop)))
        (should (= status 200))
        (should (equal (overlook-remote-test--text section) "Projects"))
        (should (eq (alist-get 'heading section) t))
        (should-not (alist-get 'spans section))
        (should (equal (overlook-remote-test--text shop) "shop"))
        ;; The agent's row names it and carries its answers.
        (should (equal (alist-get 'agent row) (overlook-remote-service-agent-id agent)))
        (should (eq (alist-get 'attention row) t))
        (should (equal (mapcar (lambda (c) (alist-get 'key c)) (alist-get 'choices row))
                       '("y" "n")))
        (should (equal (alist-get 'provider row) "claude"))
        (should (equal (alist-get 'status row) "waiting"))
        (should-not (alist-get 'spans row))
        (should-not (alist-get 'agent shop))
        (should (= (length (alist-get 'id row)) 16))
        ;; Nothing changed: the call is held, until the agent stops asking.
        (let ((known (alist-get 'known data)))
          (should (eq (car (overlook-remote--respond
                            "GET" "/overlook/api/dashboard" `(("known" ,known))
                            `(("GET" "/overlook/api/dashboard" "HTTP/1.1")
                              ("Authorization" ,(concat "Bearer " (overlook-remote--token))))))
                      :hold))
          (should (= (car (overlook-remote-test--call "POST" "/overlook/api/choose"
                                                      '((id . "claude@shop") (key . "y"))))
                     200))
          (with-current-buffer agent
            (setf (alist-get 'choices overlook-agent-identity) (lambda () nil)))
          (pcase-let ((`(,status . ,news) (overlook-remote-test--call
                                           "GET" "/overlook/api/dashboard" nil nil
                                           `(("known" ,known)))))
            (should (= status 200))
            (should-not (equal (alist-get 'known news) known))))
        ;; The answer it no longer offers is refused.
        (should (= (car (overlook-remote-test--call "POST" "/overlook/api/choose"
                                                    '((id . "claude@shop") (key . "y"))))
                   409))))))

(ert-deftest overlook-remote-wakes-a-held-dashboard-call-on-a-refresh ()
  (overlook-remote-test-with-agent t
    (overlook-remote-test-with-dashboard
      (let* ((overlook-remote--waiting nil)
             (overlook-remote--wake-timer nil)
             (overlook-refresh-hook (list #'overlook-remote--refreshed))
             (sent nil)
             (proc (make-pipe-process :name "overlook-remote-test" :noquery t))
             (known (cdr (overlook-remote--dashboard))))
        (unwind-protect
            (cl-letf (((symbol-function 'overlook-remote--send)
                       (lambda (p response) (push (cons p response) sent))))
              (overlook-remote--hold proc (overlook-remote--dashboard-call known))
              (overlook-remote--answer-news)
              (should-not sent)
              (with-current-buffer agent (setq overlook-agent-status 'working))
              (overlook-refresh)
              (should overlook-remote--wake-timer)
              (overlook-remote--answer-news)
              (should (eq (caar sent) proc))
              (should (string-search "\"sections\"" (nth 3 (car sent))))
              (should-not overlook-remote--waiting))
          (delete-process proc))))))

(ert-deftest overlook-remote-data-does-not-depend-on-faces ()
  (let ((plain (overlook-row :content "Example"))
        (styled (overlook-row :content (propertize "Example" 'face 'error))))
    (should (equal (overlook-remote--row-data plain) (overlook-remote--row-data styled)))
    (should-not (plist-member (overlook-remote--node styled "") :spans))))

(ert-deftest overlook-remote-missing-semantic-fields-serialize-as-null ()
  (let ((overlook-row-data-functions
         (list (lambda (_row)
                 '(:kind "todo" :title "Task" :subtitle nil :due nil
                   :windows [(:label "5h" :value 0 :reset nil)])))))
    (let* ((node (overlook-remote--node (overlook-row :content "Task") ""))
           (json (json-serialize node)))
      (should (string-search "\"subtitle\":null" json))
      (should (string-search "\"due\":null" json))
      (should (string-search "\"reset\":null" json))
      (should (string-search "\"value\":0" json)))))

(ert-deftest overlook-remote-project-data-ignores-display-annotations ()
  (dolist (id '((project . "demo") (closed-project "demo")))
    (let ((data (overlook-remote--row-data (overlook-row :id id :content "demo * workspace"))))
      (should (equal (plist-get data :title) "demo"))
      (should (equal (plist-get data :kind) "project")))))

(ert-deftest overlook-remote-preserves-full-agent-title ()
  (overlook-remote-test-with-agent t
    (with-current-buffer agent
      (setf (alist-get 'title overlook-agent-identity)
            (lambda () "A very long title with more than thirty characters")))
    (let* ((row (overlook-agent--row agent "shop"))
           (data (overlook-remote--row-data row)))
      (should (equal (plist-get data :title) (overlook-agent-title agent)))
      (should (equal (plist-get data :provider) "claude")))))

(ert-deftest overlook-remote-usage-is-numeric-and-expired-windows-reset ()
  (let* ((overlook-usage--rows '(("claude @home" ("5h" 42 200) ("7d" 90 50))))
         (row (overlook-row :id '(usage . "claude @home"))))
    (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 100)))
      (let* ((data (overlook-remote--row-data row))
             (windows (plist-get data :windows)))
        (should (equal (plist-get data :account) "home"))
        (should (= (plist-get (aref windows 0) :value) 42))
        (should (= (plist-get (aref windows 1) :value) 0))
        (should-not (plist-get (aref windows 1) :reset))))))

(ert-deftest overlook-remote-files-keep-full-paths-and-counts ()
  (cl-letf (((symbol-function 'overlook-repo--status)
             (lambda (_) '("main" ("long/path/example.el" " M" 12 3 nil)))))
    (let ((data (overlook-remote--row-data
                 (overlook-row :id '(repo-file "/work/" "long/path/example.el")
                               :content "l/p/example.el +12 -3"))))
      (should (equal (plist-get data :path) "long/path/example.el"))
      (should (equal (plist-get data :title) "example.el"))
      (should (= (plist-get data :added) 12)))))

(ert-deftest overlook-remote-first-dashboard-does-not-wait-for-redraw ()
  (let ((overlook-remote--dashboard nil))
    (cl-letf (((symbol-function 'overlook-live-p) (lambda () t))
              ((symbol-function 'overlook-model-fresh-p) (lambda () nil))
              ((symbol-function 'overlook-remote--dashboard)
               (lambda () (cons [] "current"))))
      (should (funcall (car (overlook-remote--dashboard-call ""))))
      (should-not (funcall (car (overlook-remote--dashboard-call "older")))))))

(ert-deftest overlook-remote-shares-the-live-dashboard-s-model ()
  (overlook-remote-test-with-agent t
    (overlook-remote-test-with-dashboard
      (let ((gathered 0)
            (overlook-remote--dashboard nil)
            (overlook-remote--waiting nil)
            (overlook-remote--wake-timer nil)
            (overlook-before-render-hook nil)
            (dashboard (get-buffer-create overlook-buffer-name)))
        (add-hook 'overlook-before-render-hook (lambda () (setq gathered (1+ gathered))))
        (unwind-protect
            (with-current-buffer dashboard
              (overlook-mode)
              (overlook--render)
              (should (= gathered 1))
              ;; The page's dashboard is made of the model the redraw gathered.
              (pcase-let ((`(,status . ,data) (overlook-remote-test--call
                                               "GET" "/overlook/api/dashboard")))
                (should (= status 200))
                (should (= gathered 1))
                (should (equal (alist-get 'known data) (cdr (overlook-remote--dashboard))))
                ;; After a change, a page that knows the dashboard waits for the redraw.
                (let ((known (alist-get 'known data)))
                  (with-current-buffer agent (setq overlook-agent-status 'waiting))
                  (overlook-refresh)
                  (should-not (funcall (car (overlook-remote--dashboard-call known))))
                  (should (= gathered 1))
                  (overlook--render)
                  (should (= gathered 2))
                  (should (funcall (car (overlook-remote--dashboard-call known))))
                  (should (= gathered 2))))
              ;; Without the dashboard, each call gathers its own.
              (kill-buffer dashboard)
              (overlook-remote--dashboard)
              (overlook-remote--dashboard)
              (should (= gathered 4)))
          (when (buffer-live-p dashboard) (kill-buffer dashboard))
          (when (timerp overlook--timer) (cancel-timer overlook--timer))
          (setq overlook--timer nil))))))

(ert-deftest overlook-remote-keeps-one-item-per-reply-and-tool-call ()
  (overlook-remote-test-with-agent t
    (let ((overlook-remote--seq 0)
          (overlook-remote--waiting nil))
      (overlook-remote--record agent '(:type prompt :text "fix it"))
      (overlook-remote--record agent '(:type text :text "On "))
      (overlook-remote--record agent '(:type tool :id "t1" :title "Edit a.el" :status "pending"))
      (overlook-remote--record agent '(:type text :text "it"))
      (overlook-remote--record agent '(:type text :text " now"))
      (overlook-remote--record agent '(:type tool :id "t1" :status "completed"
                                       :diffs ((:file "a.el" :old "x\n" :new "y\n"))))
      (let ((items (reverse (buffer-local-value 'overlook-remote--items agent))))
        (should (equal (mapcar (lambda (item) (plist-get item :type)) items)
                       '("prompt" "text" "tool" "text")))
        (should (equal (plist-get (nth 3 items) :text) "it now"))
        (should (equal (plist-get (nth 2 items) :title) "Edit a.el"))
        (should (equal (plist-get (nth 2 items) :status) "completed"))
        (should (string-match-p "^-x$" (plist-get (nth 2 items) :diff)))
        (should (string-match-p "^\\+y$" (plist-get (nth 2 items) :diff)))
        (should (= (plist-get (nth 2 items) :seq) 6))))))

(ert-deftest overlook-remote-sends-news-since-the-pages-last-change ()
  (overlook-remote-test-with-agent t
    (let ((overlook-remote--seq 0)
          (overlook-remote--waiting nil))
      (overlook-remote--record agent '(:type prompt :text "fix it"))
      (overlook-remote--record agent '(:type text :text "On it"))
      (pcase-let* ((`(,status . ,news) (overlook-remote-test--call
                                        "GET" "/overlook/api/events" nil nil
                                        '(("id" "claude@shop") ("after" "0"))))
                   (known (alist-get 'known news)))
        (should (= status 200))
        (should (= (alist-get 'seq news) 2))
        (should (equal (mapcar (lambda (item) (alist-get 'type item)) (alist-get 'items news))
                       '("prompt" "text")))
        (should (equal (alist-get 'status (alist-get 'agent news)) "idle"))
        (should (eq (alist-get 'reset news) :false))
        ;; Nothing new: the call is held.
        (should (eq (car (overlook-remote--respond
                          "GET" "/overlook/api/events"
                          `(("id" "claude@shop") ("after" "2") ("known" ,known))
                          `(("GET" "/overlook/api/events" "HTTP/1.1")
                            ("Authorization" ,(concat "Bearer " (overlook-remote--token))))))
                    :hold))
        ;; Its state changed: news at once, with no items.
        (should (equal (alist-get 'items (cdr (overlook-remote-test--call
                                                "GET" "/overlook/api/events" nil nil
                                                '(("id" "claude@shop") ("after" "2")
                                                  ("known" "stale")))))
                       nil))
        ;; A page from before Emacs restarted gets everything again.
        (let ((news (cdr (overlook-remote-test--call
                          "GET" "/overlook/api/events" nil nil
                          `(("id" "claude@shop") ("after" "99") ("known" ,known))))))
          (should (eq (alist-get 'reset news) t))
          (should (= (length (alist-get 'items news)) 2)))))))

(ert-deftest overlook-remote-answers-a-held-call-when-news-comes ()
  (overlook-remote-test-with-agent t
    (let* ((overlook-remote--seq 0)
           (overlook-remote--waiting nil)
           (overlook-remote--wake-timer nil)
           (sent nil)
           (proc (make-pipe-process :name "overlook-remote-test" :noquery t))
           (known (cdr (overlook-remote--state agent))))
      (unwind-protect
          (cl-letf (((symbol-function 'overlook-remote--send)
                     (lambda (p response) (push (cons p response) sent))))
            (overlook-remote--hold proc (overlook-remote--events-call agent 0 known))
            (overlook-remote--answer-news)
            (should-not sent)
            (overlook-remote--record agent '(:type text :text "hi"))
            (should overlook-remote--wake-timer)
            (overlook-remote--answer-news)
            (should (eq (caar sent) proc))
            (should (= (nth 1 (car sent)) 200))
            (should-not overlook-remote--waiting))
        (delete-process proc)))))

;; Replies

(ert-deftest overlook-remote-sends-only-what-a-reply-gained ()
  (overlook-remote-test-with-agent t
    (let ((overlook-remote--seq 0)
          (overlook-remote--waiting nil))
      (overlook-remote--record agent '(:type text :text "On "))
      (let* ((news (cdr (overlook-remote-test--call "GET" "/overlook/api/events" nil nil
                                                    '(("id" "claude@shop") ("after" "0")))))
             (epoch (alist-get 'epoch news)))
        (should (equal (mapcar (lambda (item) (list (alist-get 'offset item) (alist-get 'text item)))
                               (alist-get 'items news))
                       '((0 "On "))))
        (overlook-remote--record agent '(:type text :text "it"))
        (overlook-remote--record agent '(:type text :text " now"))
        (overlook-remote--record agent '(:type prompt :text "thanks"))
        (let ((items (alist-get 'items (cdr (overlook-remote-test--call
                                              "GET" "/overlook/api/events" nil nil
                                              `(("id" "claude@shop") ("after" "1")
                                                ("epoch" ,epoch)))))))
          (should (equal (mapcar (lambda (item) (list (alist-get 'offset item) (alist-get 'text item)))
                                 items)
                         '((3 "it now") (0 "thanks")))))
        ;; A page of another session gets all of it again.
        (let ((news (cdr (overlook-remote-test--call "GET" "/overlook/api/events" nil nil
                                                     '(("id" "claude@shop") ("after" "1")
                                                       ("epoch" "other"))))))
          (should (eq (alist-get 'reset news) t))
          (should (equal (alist-get 'text (car (alist-get 'items news))) "On it now"))
          (should (= (alist-get 'offset (car (alist-get 'items news))) 0)))))))

;; Commands

(defun overlook-remote-test--find (nodes pred)
  "The first of NODES, or of the nodes under them, satisfying PRED."
  (seq-some (lambda (node)
              (if (funcall pred node) node
                (overlook-remote-test--find (alist-get 'children node) pred)))
            nodes))

(ert-deftest overlook-remote-runs-a-row-s-commands ()
  (overlook-remote-test-with-agent t
    (overlook-remote-test-with-dashboard
      (let* ((ran nil)
             (overlook-remote--dashboard nil)
             (overlook-remote--versions nil)
             (overlook-sections
              (list #'overlook--projects-section
                    (lambda ()
                      (overlook-section-row
                       "Notes"
                       (list (overlook-row
                              :content "note"
                              :commands (list (list :name "post" :label "Post" :input "Say"
                                                    :options '("me" "okj")
                                                    :run (lambda (text option)
                                                           (push (list text option) ran)
                                                           nil))
                                              (list :name "show" :label "Show"
                                                    :run (lambda () agent))
                                              (list :name "draft" :label "Draft"
                                                    :run (lambda () (cons agent "todo"))))))))))
             (sections (alist-get 'sections (cdr (overlook-remote-test--call
                                                   "GET" "/overlook/api/dashboard"))))
             (note (overlook-remote-test--find
                    sections (lambda (node) (equal (overlook-remote-test--text node) "note"))))
             (row (overlook-remote-test--find
                   sections (lambda (node) (equal (alist-get 'agent node) (overlook-remote-service-agent-id agent)))))
             (run (lambda (node &rest body)
                    (overlook-remote-test--call "POST" "/overlook/api/command"
                                                `((node . ,(alist-get 'id node)) ,@body)))))
        (should (equal (alist-get 'commands note)
                       '(((name . "post") (label . "Post") (input . "Say") (options "me" "okj"))
                         ((name . "show") (label . "Show"))
                         ((name . "draft") (label . "Draft")))))
        ;; It runs with the text and option given, which must be there.
        (should (equal (funcall run note '(name . "post") '(text . " hi ") '(option . "okj"))
                       '(200 (protocolVersion . 2) (ok . t))))
        (should (equal ran '(("hi" "okj"))))
        (should (= (car (funcall run note '(name . "post") '(text . "  ") '(option . "me"))) 400))
        (should (= (car (funcall run note '(name . "post") '(text . "hi") '(option . "x"))) 400))
        (should (= (car (funcall run note '(name . "gone"))) 404))
        ;; One returning an agent sends the page to it.
        (should (equal (alist-get 'agent (cdr (funcall run note '(name . "show")))) (overlook-remote-service-agent-id agent)))
        ;; One returning text as well leaves it for the agent's prompt.
        (should (equal (alist-get 'draft (cdr (funcall run note '(name . "draft")))) "todo"))
        ;; Killing an agent asks first, and only then kills it.
        (should (equal (mapcar (lambda (c) (alist-get 'name c)) (alist-get 'commands row))
                       '("kill")))
        (should (eq (alist-get 'confirm (car (alist-get 'commands row))) t))
        (should (string-match-p "Kill agent claude@shop"
                                (alist-get 'confirm (cdr (funcall run row '(name . "kill"))))))
        (should (buffer-live-p agent))
        (should (equal (funcall run row '(name . "kill") '(confirmed . t)
                                 (cons 'confirmationToken
                                       (alist-get 'confirmationToken (cdr (funcall run row '(name . "kill")))))) '(200 (protocolVersion . 2) (ok . t))))
        (should-not (buffer-live-p agent))))))

(ert-deftest overlook-remote-serves-a-row-s-diff ()
  (overlook-remote-test-with-agent t
    (overlook-remote-test-with-dashboard
      (let* ((overlook-remote--dashboard nil)
             (overlook-remote--versions nil)
             (overlook-sections
              (list (lambda ()
                      (overlook-section-row
                       "Files"
                       (list (overlook-row :content "a.el" :diff (lambda () "-x\n+y\n"))
                             (overlook-row :content "b.el"))))))
             (sections (alist-get 'sections (cdr (overlook-remote-test--call
                                                   "GET" "/overlook/api/dashboard"))))
             (find (lambda (text)
                     (overlook-remote-test--find
                      sections (lambda (node) (equal (overlook-remote-test--text node) text)))))
             (diff (lambda (node)
                     (overlook-remote-test--call "GET" "/overlook/api/diff" nil nil
                                                 `(("node" ,(alist-get 'id node)))))))
        (should (eq (alist-get 'diff (funcall find "a.el")) t))
        (should-not (alist-get 'diff (funcall find "b.el")))
        (should (equal (funcall diff (funcall find "a.el")) '(200 (protocolVersion . 2) (diff . "-x\n+y\n"))))
        (should (= (car (funcall diff (funcall find "b.el"))) 404))))))

;; Dashboard deltas

(defun overlook-remote-test--same (nodes)
  "Hashes NODES, and those under them, were sent as known."
  (seq-mapcat (lambda (node)
                (if (alist-get 'same node)
                    (list (alist-get 'same node))
                  (overlook-remote-test--same (alist-get 'children node))))
              nodes))

(ert-deftest overlook-remote-sends-the-dashboard-s-changes ()
  (overlook-remote-test-with-agent t
    (overlook-remote-test-with-dashboard
      (let* ((overlook-remote--dashboard nil)
             (overlook-remote--versions nil)
             (overlook-sections (list #'overlook--projects-section
                                      (lambda () (overlook-section-row
                                                  "Notes" (list (overlook-row :content "steady"))))))
             (full (cdr (overlook-remote-test--call "GET" "/overlook/api/dashboard")))
             (notes (nth 1 (alist-get 'sections full))))
        (should-not (overlook-remote-test--same (alist-get 'sections full)))
        (with-current-buffer agent (setq overlook-agent-status 'waiting))
        (let* ((news (cdr (overlook-remote-test--call "GET" "/overlook/api/dashboard" nil nil
                                                      `(("known" ,(alist-get 'known full))))))
               (projects (car (alist-get 'sections news))))
          ;; The section that did not change goes by its hash, the other in full.
          (should (equal (overlook-remote-test--same (alist-get 'sections news))
                         (list (alist-get 'hash notes))))
          (should (equal (overlook-remote-test--text projects) "Projects"))
          (should-not (equal (alist-get 'hash projects)
                             (alist-get 'hash (car (alist-get 'sections full)))))
          ;; A page knowing a dashboard long gone gets all of it.
          (should-not (overlook-remote-test--same
                       (alist-get 'sections (cdr (overlook-remote-test--call
                                                  "GET" "/overlook/api/dashboard" nil nil
                                                  '(("known" "gone"))))))))))))

(ert-deftest overlook-remote-streams-the-dashboard ()
  (overlook-remote-test-with-agent t
    (overlook-remote-test-with-dashboard
      (let* ((overlook-remote--dashboard nil)
             (overlook-remote--versions nil)
             (overlook-remote--streams nil)
             (overlook-remote--ping-timer nil)
             (overlook-remote--waiting nil)
             (overlook-remote--wake-timer nil)
             (overlook-refresh-hook (list #'overlook-remote--refreshed))
             (written nil)
             (proc (make-pipe-process :name "overlook-remote-test" :noquery t)))
        (unwind-protect
            (cl-letf (((symbol-function 'process-send-string)
                       (lambda (_ text) (push text written))))
              (overlook-remote--servlet proc "/overlook/api/dashboard/stream" nil
                                        `(("GET" "/overlook/api/dashboard/stream" "HTTP/1.1")
                                          ("Authorization"
                                           ,(concat "Bearer " (overlook-remote--token)))))
              (should (string-search "text/event-stream" (car (last written))))
              (should (string-prefix-p "data: {\"protocolVersion\":2,\"sections\"" (car written)))
              (should (equal (cdar overlook-remote--streams) (cdr (overlook-remote--dashboard))))
              ;; Nothing changed: nothing sent.
              (setq written nil)
              (overlook-remote--answer-news)
              (should-not written)
              (with-current-buffer agent (setq overlook-agent-status 'working))
              (overlook-refresh)
              (should overlook-remote--wake-timer)
              (overlook-remote--answer-news)
              (should (string-prefix-p "data: " (car written)))
              (should (equal (cdar overlook-remote--streams) (cdr (overlook-remote--dashboard))))
              ;; A closed connection is dropped.
              (delete-process proc)
              (overlook-remote--ping)
              (should-not overlook-remote--streams)
              (should-not overlook-remote--ping-timer))
          (when (process-live-p proc) (delete-process proc))
          (when overlook-remote--ping-timer (cancel-timer overlook-remote--ping-timer))
          (when overlook-remote--wake-timer (cancel-timer overlook-remote--wake-timer)))))))

(defconst overlook-remote-test--png "\x89PNG\r\n\x1a\nfake"
  "Bytes passing for a PNG image.")

(defmacro overlook-remote-test-with-images (&rest body)
  "Run BODY with `dir' a folder holding a.png, \"my shot.png\" and shots/b.png."
  (declare (indent 0))
  `(let ((dir (file-name-as-directory (make-temp-file "overlook-remote-images" t)))
         (overlook-remote--images nil)
         (overlook-remote--image-count 0)
         (overlook-remote--image-directory nil)
         (coding-system-for-write 'no-conversion))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "shots" dir))
           (dolist (name '("a.png" "my shot.png" "shots/b.png"))
             (write-region overlook-remote-test--png nil (expand-file-name name dir) nil 'silent))
           ,@body)
       (delete-directory dir t)
       (when overlook-remote--image-directory
         (delete-directory overlook-remote--image-directory t)))))

(ert-deftest overlook-remote-finds-the-images-text-names ()
  (overlook-remote-test-with-images
    (should (equal (overlook-remote--image-files
                    (format "截图在%sa.png。另见 @\"%smy shot.png\"、file://%sa.png、![x](shots/b.png)、gone.png"
                            dir dir dir)
                    dir)
                   (list (concat dir "a.png") (concat dir "my shot.png")
                         (concat dir "shots/b.png"))))))

(ert-deftest overlook-remote-numbers-each-picture-once ()
  (overlook-remote-test-with-images
    (let ((a (overlook-remote--image (concat dir "a.png")))
          (coding-system-for-write 'no-conversion))
      ;; Same bytes under another name.
      (should (equal (overlook-remote--image (concat dir "shots/b.png")) a))
      (should (equal (overlook-remote--image (concat dir "a.png")) a))
      (write-region (concat overlook-remote-test--png "more") nil (concat dir "a.png") nil 'silent)
      (should-not (equal (overlook-remote--image (concat dir "a.png")) a))
      (should-not (overlook-remote--image (concat dir "gone.png")))
      (should-not (overlook-remote--image dir)))))

(ert-deftest overlook-remote-serves-the-images-of-a-tool-call ()
  (overlook-remote-test-with-agent t
    (overlook-remote-test-with-images
      (let ((overlook-remote--seq 0)
            (overlook-remote--waiting nil))
        (overlook-remote--record
         agent `(:type tool :id "t1" :title "Screenshot" :status "completed"
                 :output ,(format "Saved to %sa.png" dir)
                 :images ((:data ,(base64-encode-string overlook-remote-test--png) :mime "image/png")
                          (:data "bm90IGFuIGltYWdl" :mime "image/png"))))
        (let* ((news (cdr (overlook-remote-test--call "GET" "/overlook/api/events" nil nil
                                                      '(("id" "claude@shop") ("after" "0")))))
               (item (car (alist-get 'items news)))
               (images (alist-get 'images item)))
          (should-not (assq 'files item))
          ;; The data that is no image is left out, and the image sent as data
          ;; is the same picture as a.png.
          (should (= (length images) 1))
          (pcase-let ((`(,status ,mime ,body)
                       (overlook-remote--respond
                        "GET" "/overlook/api/image" `(("n" ,(number-to-string (car images))))
                        `(("GET" "/x" "HTTP/1.1")
                          ("Authorization" ,(concat "Bearer " (overlook-remote--token)))))))
            (should (= status 200))
            (should (equal mime "image/png"))
            (should (equal body overlook-remote-test--png))
            (should-not (multibyte-string-p body)))
          (should (= (car (overlook-remote-test--call "GET" "/overlook/api/image" nil nil
                                                      '(("n" "999"))))
                     404)))))))

(ert-deftest overlook-remote-shows-the-images-of-a-reply ()
  (overlook-remote-test-with-agent t
    (overlook-remote-test-with-images
      (let ((overlook-remote--seq 0)
            (overlook-remote--waiting nil))
        (overlook-remote--record agent '(:type text :text "Here it is:"))
        (overlook-remote--record
         agent `(:type text :text ""
                 :images ((:data ,(base64-encode-string overlook-remote-test--png) :mime "image/png"))))
        (overlook-remote--record agent '(:type text :text " done"))
        (pcase-let* ((news (cdr (overlook-remote-test--call "GET" "/overlook/api/events" nil nil
                                                            '(("id" "claude@shop") ("after" "0")))))
                     (`(,item) (alist-get 'items news)))
          ;; The image goes with the reply it came in.
          (should (equal (alist-get 'text item) "Here it is: done"))
          (should (= (length (alist-get 'images item)) 1)))))))

(ert-deftest overlook-remote-takes-images-from-the-phone ()
  (overlook-remote-test-with-agent t
    (let ((attached nil))
      (with-current-buffer agent
        (push (cons 'attach (lambda (name data) (push (cons name data) attached) "@/shots/x.png"))
              overlook-agent-identity))
      (pcase-let ((`(,status . ,data)
                   (overlook-remote-test--call
                    "POST" "/overlook/api/upload"
                    `((id . "claude@shop") (mime . "image/png")
                      (data . ,(base64-encode-string overlook-remote-test--png))))))
        (should (= status 200))
        (should (equal (alist-get 'text data) "@/shots/x.png"))
        (should (string-match-p "\\`phone-.*\\.png\\'" (caar attached)))
        (should (equal (cdar attached) overlook-remote-test--png)))
      (should (= (car (overlook-remote-test--call
                       "POST" "/overlook/api/upload"
                       '((id . "claude@shop") (mime . "image/png") (data . "bm90IGFuIGltYWdl"))))
                 400))
      (let ((overlook-remote-image-size 4))
        (should (= (car (overlook-remote-test--call
                         "POST" "/overlook/api/upload"
                         `((id . "claude@shop") (mime . "image/png")
                           (data . ,(base64-encode-string overlook-remote-test--png)))))
                   413)))
      (should (= (length attached) 1)))))

(ert-deftest overlook-remote-updates-context-without-a-dashboard ()
  (let ((overlook-buffer-name " *overlook-remote-context-test*")
        (overlook-remote-host "127.0.0.1")
        (overlook-remote-mode nil)
        (overlook--update-consumers nil)
        (overlook--tick-timer nil)
        (overlook-agent-changed-hook nil)
        (overlook-tick-hook (list #'overlook-agent--tick))
        (httpd-serve-files nil))
    (with-temp-buffer
      (setq overlook-agent-identity '((context . (lambda () 42))))
      (cl-letf (((symbol-function 'httpd-start) #'ignore)
                ((symbol-function 'httpd-stop) #'ignore)
                ((symbol-function 'overlook-remote-url) #'ignore))
        (unwind-protect
            (progn
              (overlook-remote-mode 1)
              (should-not (overlook-live-p))
              (overlook--tick)
              (should (= overlook-agent-context 42))
              (should-not (overlook-live-p)))
          (setq overlook-remote--queue '((:id "pending" :text "pending")))
          (overlook-remote-mode -1)
          (should-not overlook-remote--queue)
          (should-not overlook--tick-timer))))))

(ert-deftest overlook-remote-turns-off-after-a-while-on-the-network ()
  (let ((overlook-remote-host "0.0.0.0")
        (overlook-remote-network-minutes 120)
        (overlook-remote-token-file (make-temp-file "overlook-remote-token"))
        (httpd-serve-files nil)
        (overlook-buffer-name " *overlook-remote-only-test*")
        (overlook-sections nil)
        (overlook--update-consumers nil)
        (overlook--tick-timer nil)
        (overlook-remote--off-timer nil))
    (unwind-protect
        (cl-letf (((symbol-function 'httpd-start) #'ignore)
                  ((symbol-function 'httpd-stop) #'ignore))
          (overlook-remote-mode 1)
          (should (timerp overlook-remote--off-timer))
          (should-not (overlook-live-p))
          (should overlook--tick-timer)
          ;; The dashboard tells it serves the network.
          (should (string-prefix-p "Remote: "
                                   (get-text-property 0 'help-echo (overlook-remote--mode-line))))
          (should (eq (get-text-property 0 'face (overlook-remote--mode-line)) 'warning))
          (should (memq #'overlook-remote--mode-line overlook-mode-line-functions))
          (overlook-start)
          (overlook-remote-mode -1)
          (should-not overlook-remote--off-timer)
          (should (equal overlook--update-consumers '(dashboard)))
          (should (timerp overlook--tick-timer))
          (should-not (memq #'overlook-remote--mode-line overlook-mode-line-functions))
          (let ((overlook-remote-host "127.0.0.1"))
            (overlook-remote-mode 1)
            (should-not overlook-remote--off-timer)
            (should (equal (get-text-property 0 'help-echo (overlook-remote--mode-line))
                           "Remote: this machine only"))
            (kill-buffer overlook-buffer-name)
            (should (equal overlook--update-consumers '(remote)))
            (should (timerp overlook--tick-timer))
            (overlook-remote-mode -1)
            (should-not overlook--tick-timer)))
      (when overlook--tick-timer
        (cancel-timer overlook--tick-timer)
        (setq overlook--tick-timer nil))
      (when (get-buffer overlook-buffer-name) (kill-buffer overlook-buffer-name))
      (delete-file overlook-remote-token-file))))

;;; overlook-remote-test.el ends here
