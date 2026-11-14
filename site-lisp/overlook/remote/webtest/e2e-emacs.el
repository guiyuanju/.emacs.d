;;; e2e-emacs.el --- A dev Emacs for the end-to-end page tests -*- lexical-binding: t; -*-

;; emacs -Q --batch -l e2e-emacs.el, with EMACSLOADPATH reaching overlook
;; and its dependencies.  Environment:
;;   OVERLOOK_E2E_CONTROL  unix socket taking lines of JSON strings, each an
;;                         Elisp form, answering one JSON line {"ok": …} or {"error": …}
;;   OVERLOOK_E2E_ROOT     directory the fake project and agents work in
;;   OVERLOOK_E2E_SOCKET   bridge socket; enables `overlook-remote-bridge-mode'
;;   OVERLOOK_E2E_OLD_PORT and OVERLOOK_E2E_TOKEN_FILE  serve the old
;;                         `overlook-remote-mode' instead, for measurements
;; The fake agents record what they are asked to do in `e2e-log'.

(require 'overlook)
(require 'overlook-agent)
(require 'overlook-remote-bridge)

(setq overlook-agent-notify-function #'ignore
      overlook-agent--focused-function #'ignore
      overlook-courier-skill-directories nil
      gc-cons-threshold (* 64 1024 1024))

(defvar e2e-root (file-name-as-directory (getenv "OVERLOOK_E2E_ROOT"))
  "Directory of the fake project.")

(defvar e2e-log nil
  "What the fake agents and rows were asked to do, newest first, as plists.")

(defvar e2e-agents nil
  "Fake agents, each (NAME . BUFFER).")

(defvar e2e-done nil
  "Non-nil once the harness is asked to quit.")

(defun e2e-note (&rest entry)
  "Record ENTRY, a plist, in `e2e-log'."
  (push entry e2e-log))

(defun e2e-agent (name)
  "Buffer of fake agent NAME."
  (or (alist-get name e2e-agents nil nil #'equal) (error "No agent %s" name)))

(defun e2e-id (name)
  "Conversation id of fake agent NAME."
  (overlook-data-agent-id (e2e-agent name)))

(defvar-local e2e--ready t
  "Whether this fake agent takes a prompt now.")

(defvar-local e2e--choices nil
  "Answers this fake agent offers, each (KEY LABEL).")

(defvar-local e2e--form nil
  "Question form this fake agent waits on, or nil.")

(defun e2e--identity (name provider)
  "Identity of fake agent NAME of PROVIDER with every capability."
  `((agent . ,provider) (root . ,e2e-root) (project . "shop")
    (submit . ,(lambda (text)
                 (e2e-note :op "submit" :agent name :text text)
                 (overlook-agent-event 'prompt :text text)
                 (overlook-agent-report 'working)))
    (ready . ,(lambda () e2e--ready))
    (reply . ,(lambda () "Earlier reply."))
    (title . ,(lambda () (format "Work on %s" name)))
    (choices . ,(lambda ()
                  (mapcar (pcase-lambda (`(,key ,label))
                            (list key label
                                  (lambda ()
                                    (e2e-note :op "choose" :agent name :key key)
                                    (setq e2e--choices nil))))
                          e2e--choices)))
    (form . ,(lambda () e2e--form))
    (answer . ,(lambda (id action values)
                 (e2e-note :op "answer" :agent name :form id :action action
                           :values (json-serialize (or values :null)))
                 (setq e2e--form nil)))
    (remote-controls . ,(lambda () '(:steer t :actions ("stop" "restart"))))
    (remote-action
     . ,(lambda (action text)
          (when (or (not (equal action "restart"))
                    (y-or-n-p "Agent is busy. Restart anyway?"))
            (e2e-note :op "action" :agent name :action action :text text))
          (current-buffer)))
    (attach . ,(lambda (file data)
                 (e2e-note :op "attach" :agent name :name file :bytes (length data))
                 (format "@%s" file)))))

(defun e2e-make-agent (name &optional provider)
  "Start fake agent NAME of PROVIDER and return its buffer."
  (let ((buffer (generate-new-buffer (format "%s@shop" name))))
    (with-current-buffer buffer
      (setq default-directory e2e-root)
      (insert (format "Transcript of %s.\n" name))
      (setq overlook-agent-identity (e2e--identity name (or provider "claude")))
      (overlook-agent-register buffer (or provider "claude")))
    (setf (alist-get name e2e-agents nil nil #'equal) buffer)
    buffer))

(defmacro e2e-in (name &rest body)
  "Run BODY in fake agent NAME's buffer."
  (declare (indent 1))
  `(with-current-buffer (e2e-agent ,name) ,@body))

(defun e2e-event (name type &rest properties)
  "Send agent NAME's event TYPE with PROPERTIES."
  (e2e-in name (apply #'overlook-agent-event type properties))
  t)

(defun e2e-report (name event)
  "Report EVENT, as `overlook-agent-report' takes it, for agent NAME."
  (e2e-in name (overlook-agent-report event))
  t)

(defun e2e-set (name &rest settings)
  "Change agent NAME's :ready, :choices or :form per SETTINGS."
  (e2e-in name
    (when (plist-member settings :ready) (setq e2e--ready (plist-get settings :ready)))
    (when (plist-member settings :choices) (setq e2e--choices (plist-get settings :choices)))
    (when (plist-member settings :form) (setq e2e--form (plist-get settings :form)))
    (when (plist-member settings :status)
      (setq overlook-agent-status (plist-get settings :status))))
  (overlook-agent-changed)
  t)

(defun e2e-stream (name text size interval)
  "Stream TEXT as agent NAME's reply in SIZE-character chunks every INTERVAL seconds."
  (let ((chunks nil))
    (while (> (length text) 0)
      (push (substring text 0 (min size (length text))) chunks)
      (setq text (substring text (min size (length text)))))
    (setq chunks (nreverse chunks))
    (named-let next ((rest chunks))
      (when rest
        (e2e-event name 'text :text (car rest))
        (run-at-time interval nil (lambda () (next (cdr rest))))))
    (length chunks)))

(defun e2e-history (name count)
  "Give agent NAME COUNT prompt and reply pairs at once."
  (dotimes (i count)
    (e2e-event name 'prompt :text (format "Question %d" (1+ i)))
    (e2e-event name 'text :text (format "Answer %d: %s" (1+ i) (make-string 60 ?x)))
    (e2e-event name 'end))
  t)

(defun e2e-take-log ()
  "The log, oldest first, emptied."
  (prog1 (vconcat (reverse e2e-log)) (setq e2e-log nil)))

(defun e2e-new-command (project)
  "Row commands for PROJECT's heading."
  (list (list :name "new" :label "New agent" :input "Task" :options '("claude" "codex")
              :run (lambda (task provider)
                     (let ((buffer (e2e-make-agent (format "agent%d" (1+ (length e2e-agents)))
                                                   provider)))
                       (e2e-note :op "new" :project project :task task :provider provider)
                       (cons buffer task))))))

(setq overlook-projects-function (lambda () '("shop"))
      overlook-current-project-function (lambda () "shop")
      overlook-project-buffers-function
      (lambda (_) (seq-filter #'buffer-live-p (mapcar #'cdr e2e-agents)))
      overlook-project-root-function (lambda (_) e2e-root)
      overlook-project-functions (list #'overlook--checkout-rows)
      overlook-worktrees-functions nil
      overlook-worktree-functions (list #'overlook-agent--rows)
      overlook-project-command-functions (list #'e2e-new-command)
      overlook-sections (list #'overlook--projects-section))

(e2e-make-agent "alpha")
(e2e-make-agent "beta" "codex")

;;; Cost

(defvar e2e-timings nil
  "Seconds taken by each timed call, newest first, as (NAME . SECONDS).")

(defun e2e--timed (name)
  "Advice recording how long the advised function, NAME, takes."
  (lambda (original &rest args)
    (let ((start (float-time)))
      (prog1 (apply original args)
        (push (cons name (- (float-time) start)) e2e-timings)))))

(defun e2e-time (&rest functions)
  "Start timing FUNCTIONS, dropping earlier timings."
  (setq e2e-timings nil)
  (dolist (function functions)
    (advice-add function :around (e2e--timed (symbol-name function)) '((name . e2e-time))))
  t)

(defun e2e-timings (function)
  "Milliseconds FUNCTION took, sorted: count, median, 90th percentile, max and total."
  (let* ((times (sort (mapcar (lambda (entry) (* 1000 (cdr entry)))
                              (seq-filter (lambda (entry) (equal (car entry) (symbol-name function)))
                                          e2e-timings))
                      #'<))
         (n (length times)))
    (if (zerop n) (list :count 0)
      (list :count n :median (nth (/ n 2) times) :p90 (nth (floor (* 0.9 (1- n))) times)
            :max (car (last times)) :total (apply #'+ times)))))

(defun e2e-populate (projects agents)
  "Add PROJECTS more projects of AGENTS agents each, every agent with some history."
  (dotimes (p projects)
    (let ((project (format "project%d" p)))
      (dotimes (a agents)
        (let ((buffer (e2e-make-agent (format "p%da%d" p a) (if (cl-oddp a) "codex" "claude"))))
          (with-current-buffer buffer
            (setf (alist-get 'project overlook-agent-identity) project)
            (dotimes (i 5)
              (overlook-agent-event 'prompt :text (format "Question %d" i))
              (overlook-agent-event 'text :text (make-string 300 ?y))))))))
  (let ((names (cons "shop" (mapcar (lambda (p) (format "project%d" p)) (number-sequence 0 (1- projects))))))
    (setq overlook-projects-function (lambda () names)
          overlook-project-buffers-function
          (lambda (project)
            (seq-filter (lambda (buffer)
                          (and (buffer-live-p buffer)
                               (equal (overlook-agent-get buffer 'project) project)))
                        (mapcar #'cdr e2e-agents)))))
  (overlook-agent-changed)
  (length e2e-agents))

;;; Control socket

(defvar e2e--partial (make-hash-table :test #'eq)
  "Bytes received after the last complete line, per control connection.")

(defun e2e--answer (line)
  "JSON line answering control LINE, a form as a JSON string."
  (condition-case err
      (let ((value (eval (car (read-from-string (json-parse-string line))) t)))
        (condition-case nil
            (json-serialize (list :ok (if (null value) :null value)))
          (error (json-serialize (list :ok (format "%S" value))))))
    (error (json-serialize (list :error (error-message-string err))))))

(defun e2e--filter (process chunk)
  "Run each complete line of CHUNK from control PROCESS as a form."
  (let* ((text (concat (gethash process e2e--partial "") chunk))
         (lines (split-string text "\n")))
    (puthash process (car (last lines)) e2e--partial)
    (dolist (line (butlast lines))
      (unless (string-empty-p line)
        (process-send-string process
                             (concat (e2e--answer (decode-coding-string line 'utf-8)) "\n"))))))

(make-network-process :name "e2e-control" :server t :family 'local
                      :service (getenv "OVERLOOK_E2E_CONTROL") :coding 'binary :noquery t
                      :filter #'e2e--filter)

(cond
 ((getenv "OVERLOOK_E2E_OLD_PORT")
  (require 'overlook-remote)
  (setq overlook-remote-port (string-to-number (getenv "OVERLOOK_E2E_OLD_PORT"))
        overlook-remote-host "127.0.0.1"
        overlook-remote-network-minutes nil
        overlook-remote-token-file (getenv "OVERLOOK_E2E_TOKEN_FILE"))
  (overlook-remote-mode 1))
 ((getenv "OVERLOOK_E2E_SOCKET")
  (setq overlook-remote-bridge-socket (getenv "OVERLOOK_E2E_SOCKET")
        overlook-remote-bridge-retry-delays '(0.1 . 0.5))
  (overlook-remote-bridge-mode 1)))

(message "e2e-emacs ready")
(while (not e2e-done)
  (accept-process-output nil 0.05))
(kill-emacs 0)

;;; e2e-emacs.el ends here
