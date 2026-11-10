;;; overlook-remote.el --- Steer agents from a phone on the local network -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
;; URL: https://github.com/guiyuanju/overlook
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Serves the browser API, manages connections and mode lifecycle.
;; Dashboard serialization and agent activity live in separate modules.

;;; Code:

(require 'simple-httpd)
(require 'url-util)
(require 'overlook-agent)
(require 'overlook-remote-model)
(require 'overlook-remote-activity)

(defcustom overlook-remote-host "127.0.0.1"
  "Address the page is served on.
\"127.0.0.1\" serves this machine only; \"0.0.0.0\" every network
interface, so a phone on the local network can open it."
  :type 'string
  :group 'overlook)

(defcustom overlook-remote-port 8765
  "Port the page is served on."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-remote-token-file (locate-user-emacs-file "overlook-remote-token")
  "File holding the token the page's calls must carry."
  :type 'file
  :group 'overlook)

(defcustom overlook-remote-wait 25
  "Seconds the page's call for news is held open while nothing happens."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-remote-network-minutes 120
  "Minutes after which the mode turns off when it serves beyond this machine.
Nil keeps it on."
  :type '(choice (natnum :tag "Minutes") (const :tag "Never" nil))
  :group 'overlook)

(defconst overlook-remote--directory
  (file-name-directory (or load-file-name buffer-file-name ""))
  "Directory of the files the page is made of.")

(defconst overlook-remote--files
  '(("" "overlook-remote.html" "text/html")
    ("/vendor/marked.js" "vendor/marked.js" "text/javascript")
    ("/vendor/purify.js" "vendor/purify.js" "text/javascript")
    ("/vendor/pixelify-sans-400.woff2" "vendor/pixelify-sans-400.woff2" "font/woff2")
    ("/vendor/pixelify-sans-700.woff2" "vendor/pixelify-sans-700.woff2" "font/woff2"))
  "Routes under /overlook served without the token, each (ROUTE FILE MIME).")

;;; Token

(defun overlook-remote--random-hex ()
  "64 hex digits from the system's random source, or nil where there is none."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary))
      (when (and (file-readable-p "/dev/urandom")
                 (eql 0 (ignore-errors (call-process "head" "/dev/urandom" t nil "-c" "32")))
                 (= (buffer-size) 32))
        (mapconcat (lambda (byte) (format "%02x" byte)) (buffer-string) "")))))

(defun overlook-remote-new-token ()
  "Replace the token, so pages holding the old one stop working; return it."
  (interactive)
  (random t)
  (let ((token (or (overlook-remote--random-hex)
                   (secure-hash 'sha256 (format "%s %s %s %s" (random) (random)
                                                (current-time) (emacs-pid))))))
    (with-file-modes #o600
      (with-temp-file overlook-remote-token-file (insert token "\n")))
    (when (called-interactively-p 'interactive)
      (message "New token; open the page again from `overlook-remote-url'"))
    token))

(defun overlook-remote--token ()
  "The token the page's calls must carry, made on first use."
  (if (file-exists-p overlook-remote-token-file)
      (with-temp-buffer
        (insert-file-contents overlook-remote-token-file)
        (string-trim (buffer-string)))
    (overlook-remote-new-token)))

(defun overlook-remote--authorized-p (request)
  "Non-nil when REQUEST carries the token."
  (equal (cadr (assoc "Authorization" request))
         (concat "Bearer " (overlook-remote--token))))

;;; Agents

(define-error 'overlook-remote-missing-agent "Agent no longer exists" 'user-error)

(defun overlook-remote--agent-buffer (id)
  "The agent buffer named ID."
  (let ((buffer (and (stringp id) (get-buffer id))))
    (if (overlook-agent-p buffer) buffer
      (signal 'overlook-remote-missing-agent (list (format "No agent %s" id))))))

(defvar overlook-remote--streams nil
  "Dashboard streams open, each (PROCESS . HASH), HASH the dashboard last sent.")

(defvar overlook-remote--ping-timer nil
  "Timer keeping `overlook-remote--streams' alive, or nil.")

(defun overlook-remote--dashboard-call (known)
  "A call for the dashboard from a page knowing state KNOWN.
As (NEWS-P . ANSWER), what `overlook-remote--hold' takes.  A page
knowing it waits for the live dashboard to redraw after a change, as
the redraw gathers the model the page then shares."
  (cons (lambda ()
          (and (or (null known) (equal known "")
                   (not (overlook-live-p)) (overlook-model-fresh-p))
               (not (equal known (cdr (overlook-remote--dashboard))))))
        (lambda () (overlook-remote--json 200 (overlook-remote--dashboard-news known)))))

(defun overlook-remote--stream-write (stream text)
  "Write TEXT to STREAM, dropping it when its connection is gone."
  (unless (and (process-live-p (car stream))
               (ignore-errors (process-send-string (car stream) text) t))
    (setq overlook-remote--streams (delq stream overlook-remote--streams))))

(defun overlook-remote--stream-news (stream)
  "Send STREAM the dashboard, as an event, if it changed since the last."
  (when (funcall (car (overlook-remote--dashboard-call (cdr stream))))
    (let ((news (overlook-remote--dashboard-news (cdr stream))))
      (setcdr stream (plist-get news :known))
      (overlook-remote--stream-write
       stream (concat "data: " (json-serialize news) "\n\n")))))

(defun overlook-remote--ping ()
  "Keep the streams' connections busy, so that dead ones show."
  (dolist (stream overlook-remote--streams)
    (overlook-remote--stream-write stream ": ping\n\n"))
  (unless overlook-remote--streams
    (cancel-timer overlook-remote--ping-timer)
    (setq overlook-remote--ping-timer nil)))

(defun overlook-remote--stream (proc known)
  "Stream the dashboard to PROC as server-sent events, from state KNOWN on."
  (let ((stream (cons proc known)))
    (process-send-string proc (concat "HTTP/1.1 200 OK\r\n"
                                      "Content-Type: text/event-stream\r\n"
                                      "Cache-Control: no-store\r\n\r\n"
                                      ": open\n\n"))
    (push stream overlook-remote--streams)
    (unless overlook-remote--ping-timer
      (setq overlook-remote--ping-timer
            (run-at-time overlook-remote-wait overlook-remote-wait #'overlook-remote--ping)))
    (overlook-remote--stream-news stream)))

(defvar overlook-remote--waiting nil
  "Calls for news held open, each (PROCESS CALL TIMER).
CALL is (NEWS-P . ANSWER): NEWS-P tells whether it has news, ANSWER
gives the response.")

(defvar overlook-remote--wake-timer nil
  "Timer answering the calls for news that have some, or nil.")

(defun overlook-remote--news (buffer after)
  "HTTP response for agent BUFFER's activity changed after AFTER."
  (if (not (buffer-live-p buffer))
      (overlook-remote--json 409 '(:error "The agent is gone"))
    (overlook-remote--json 200 (overlook-remote--news-data buffer after))))

(defun overlook-remote--events-call (buffer after known)
  "A call for agent BUFFER's news after AFTER and state KNOWN.
As (NEWS-P . ANSWER), what `overlook-remote--hold' takes."
  (cons (lambda () (overlook-remote--news-p buffer after known))
        (lambda () (overlook-remote--news buffer after))))

(defun overlook-remote--answer (waiting)
  "Answer the held call WAITING with what news there is."
  (pcase-let ((`(,proc (,_ . ,answer) ,timer) waiting))
    (cancel-timer timer)
    (setq overlook-remote--waiting (delq waiting overlook-remote--waiting))
    (when (process-live-p proc)
      (overlook-remote--send proc (funcall answer)))))

(defun overlook-remote--answer-news ()
  "Answer the held calls that have news."
  (setq overlook-remote--wake-timer nil)
  (overlook-remote--together
    (dolist (waiting overlook-remote--waiting)
      (pcase-let ((`(,proc (,news-p . ,_) ,_) waiting))
        (when (or (not (process-live-p proc)) (funcall news-p))
          (overlook-remote--answer waiting))))
    (mapc #'overlook-remote--stream-news overlook-remote--streams)))

(defun overlook-remote--wake ()
  "Answer the held calls that have news, shortly, so that bursts go together."
  (when (and (or overlook-remote--waiting overlook-remote--streams)
             (not overlook-remote--wake-timer))
    (setq overlook-remote--wake-timer (run-at-time 0.2 nil #'overlook-remote--answer-news))))

(defun overlook-remote--redrawn ()
  "Answer the held calls once the live dashboard has gathered its model."
  (when (overlook-live-p) (overlook-remote--wake)))

(defun overlook-remote--refreshed ()
  "Answer the held calls after a change, unless the live dashboard will redraw."
  (unless (overlook-live-p) (overlook-remote--wake)))

(defun overlook-remote--hold (proc call)
  "Hold CALL on PROC, a (NEWS-P . ANSWER), until it has news or waits too long."
  (let ((waiting (list proc call nil)))
    (setf (nth 2 waiting) (run-at-time overlook-remote-wait nil
                                       #'overlook-remote--answer waiting))
    (push waiting overlook-remote--waiting)))

(defun overlook-remote--news-or-hold (call)
  "CALL's answer when it has news, else (:hold CALL).
CALL is (NEWS-P . ANSWER)."
  (if (funcall (car call)) (funcall (cdr call)) (list :hold call)))

;;; Requests

(defun overlook-remote--body (request)
  "REQUEST's JSON body as an alist."
  (condition-case nil
      (json-parse-string (decode-coding-string (or (cadr (assoc "Content" request)) "")
                                               'utf-8)
                         :object-type 'alist)
    (json-error (user-error "The body is not JSON"))))

(defun overlook-remote--json (status data)
  "A response of STATUS carrying DATA as JSON."
  (list status "application/json" (decode-coding-string (json-serialize data) 'utf-8)))

(defvar overlook-remote--receipts (make-hash-table :test #'equal)
  "Successful message requests retained for the lifetime of this Emacs.")

(defun overlook-remote--once (route body send)
  "Call SEND with message BODY for ROUTE, once for BODY's `requestId'.
A retry gets the response of the first call that succeeded."
  (let* ((key (alist-get 'requestId body))
         (signature (list route (alist-get 'id body) (alist-get 'action body)
                          (alist-get 'text body)))
         (receipt (and key (gethash key overlook-remote--receipts))))
    (when (and key (not (and (stringp key) (<= 1 (length key) 128))))
      (user-error "Invalid request ID"))
    (if receipt
        (if (equal signature (car receipt)) (cdr receipt)
          (user-error "Request ID already used for a different message"))
      (let ((response (funcall send body)))
        (when (and key (alist-get 'ok (json-parse-string (nth 2 response) :object-type 'alist)))
          (puthash key (cons signature response) overlook-remote--receipts))
        response))))

(defun overlook-remote--send-prompt (body)
  "Give the agent BODY names the prompt in it."
  (let ((text (string-trim (or (alist-get 'text body) ""))))
    (when (string-empty-p text) (user-error "Nothing to send"))
    (overlook-remote--json
     200 `(:ok t :queued ,(if (overlook-remote--prompt
                               (overlook-remote--agent-buffer (alist-get 'id body)) text)
                              t :false)))))

(defun overlook-remote--api (method route query request)
  "Answer METHOD on ROUTE with QUERY and REQUEST, as (STATUS MIME BODY).
A call for news with none yet is answered (:hold CALL), as
`overlook-remote--news-or-hold' gives, and one for the dashboard's
stream (:stream KNOWN)."
  (pcase (list method route)
    ('("GET" "/api/agents")
     (overlook-remote--json
      200 `(:agents ,(vconcat (mapcar #'overlook-remote--agent (overlook-agent-buffers))))))
    ('("GET" "/api/agent")
     (overlook-remote--json
      200 (overlook-remote--agent
           (overlook-remote--agent-buffer (cadr (assoc "id" query))) t)))
    ('("GET" "/api/events")
     (let* ((buffer (overlook-remote--agent-buffer (cadr (assoc "id" query))))
            (epoch (cadr (assoc "epoch" query)))
            (after (and (member epoch (list nil "" overlook-remote--epoch))
                        (string-to-number (or (cadr (assoc "after" query)) "0"))))
            (known (cadr (assoc "known" query))))
       (overlook-remote--news-or-hold (overlook-remote--events-call buffer after known))))
    ('("GET" "/api/dashboard")
     (overlook-remote--news-or-hold
      (overlook-remote--dashboard-call (cadr (assoc "known" query)))))
    ('("GET" "/api/dashboard/stream")
     (list :stream (cadr (assoc "known" query))))
    ('("POST" "/api/prompt")
     (overlook-remote--once route (overlook-remote--body request)
                            #'overlook-remote--send-prompt))
    ('("POST" "/api/unqueue")
     (let ((body (overlook-remote--body request)))
       (overlook-remote--unqueue (overlook-remote--agent-buffer (alist-get 'id body))
                                 (or (alist-get 'text body) ""))
       (overlook-remote--json 200 '(:ok t))))
    ('("POST" "/api/seen")
     (overlook-agent-seen (overlook-remote--agent-buffer
                           (alist-get 'id (overlook-remote--body request))))
     (overlook-remote--json 200 '(:ok t)))
    ('("POST" "/api/retry")
     (let ((body (overlook-remote--body request)))
       (overlook-remote--clear-queue-error
        (overlook-remote--agent-buffer (alist-get 'id body)))
       (overlook-remote--json 200 '(:ok t))))
    ('("POST" "/api/session")
     (overlook-remote--once route (overlook-remote--body request)
                            #'overlook-remote--session))
    ('("GET" "/api/image")
     (let ((file (nth 1 (assq (string-to-number (or (cadr (assoc "n" query)) ""))
                              overlook-remote--images))))
       (unless (and file (overlook-remote--image file)) (user-error "No such image"))
       (list 200 (overlook-remote--image-mime file)
             (with-temp-buffer
               (set-buffer-multibyte nil)
               (insert-file-contents-literally file)
               (buffer-string)))))
    ('("POST" "/api/upload")
     (let* ((body (overlook-remote--body request))
            (buffer (overlook-remote--agent-buffer (alist-get 'id body)))
            (mime (alist-get 'mime body))
            (extension (car (rassoc mime overlook-remote--image-types)))
            (data (ignore-errors (base64-decode-string (or (alist-get 'data body) ""))))
            (attach (or (overlook-agent-get buffer 'attach)
                        (user-error "%s cannot take files" (buffer-name buffer)))))
       (unless (and extension data (overlook-remote--image-data-p data mime))
         (user-error "Send a PNG, JPEG, GIF or WebP image"))
       (when (> (length data) overlook-remote-image-size)
         (user-error "The image is over %s" (file-size-human-readable overlook-remote-image-size)))
       (overlook-remote--json
        200 `(:text ,(overlook-remote--text
                      (with-current-buffer buffer
                        (funcall attach (format "phone-%s.%s"
                                                (format-time-string "%Y%m%d-%H%M%S-%3N")
                                                extension)
                                 data)))))))
    ('("GET" "/api/diff")
     (overlook-remote--dashboard)
     (let ((diff (overlook-row-diff (or (gethash (cadr (assoc "node" query)) overlook-remote--rows)
                                        (user-error "That row is gone")))))
       (unless diff (user-error "That row has no diff"))
       (overlook-remote--json 200 `(:diff ,(overlook-remote--cut (funcall diff))))))
    ('("POST" "/api/command")
     (overlook-remote--command (overlook-remote--body request)))
    ('("POST" "/api/choose")
     (let ((body (overlook-remote--body request)))
       (overlook-agent-choose (overlook-remote--agent-buffer (alist-get 'id body))
                              (alist-get 'key body))
       (overlook-remote--json 200 '(:ok t))))
    (_ (overlook-remote--json 404 `(:error ,(format "No %s %s" method route))))))

(defun overlook-remote--session (body)
  "Run the allowlisted session action in BODY, confirming in the browser."
  (let* ((buffer (overlook-remote--agent-buffer (alist-get 'id body)))
         (action (alist-get 'action body))
         (text (string-trim (or (alist-get 'text body) "")))
         (run (or (overlook-agent-get buffer 'remote-action)
                  (user-error "This agent has no session controls")))
         (controls (overlook-remote--controls buffer))
         (confirmed (append (alist-get 'confirmations body) nil))
         (question (pcase action
                     ("reload" "Reload this session? Unsent prompts may be lost.")
                     ("restart" "Start a fresh conversation? Unsent prompts may be lost.")))
         (ask (lambda (prompt &rest _)
                (unless (member prompt confirmed) (throw 'confirm prompt))
                t)))
    (unless (or (and (equal action "steer") (plist-get controls :steer))
                (member action (plist-get controls :actions)))
      (user-error "This agent does not support %s" action))
    (when (and (equal action "steer") (string-empty-p text))
      (user-error "Nothing to steer"))
    (let ((result
           (catch 'confirm
             (when question (funcall ask question))
             (cl-letf (((symbol-function 'y-or-n-p) ask)
                       ((symbol-function 'yes-or-no-p) ask))
               (with-current-buffer buffer (funcall run action text))))))
      (if (stringp result)
          (overlook-remote--json 200 `(:confirm ,result))
        (overlook-remote--json 200 `(:ok t :agent ,(buffer-name result)))))))

(defun overlook-remote--command (body)
  "Run the command BODY names on a row of the dashboard, once confirmed.
A command needing confirmation that BODY does not confirm is answered
with its question in :confirm instead."
  (overlook-remote--dashboard)
  (let* ((row (or (gethash (alist-get 'node body) overlook-remote--rows)
                  (user-error "That row is gone")))
         (command (or (overlook-row-command row (alist-get 'name body))
                      (user-error "That row no longer offers %s" (alist-get 'name body))))
         (text (string-trim (or (alist-get 'text body) "")))
         (option (alist-get 'option body))
         (confirm (plist-get command :confirm))
         (question (if (functionp confirm) (funcall confirm) confirm)))
    (when (and (plist-get command :input) (string-empty-p text))
      (user-error "Nothing to send"))
    (when (and (plist-get command :options) (not (member option (plist-get command :options))))
      (user-error "Pick one of %s" (string-join (plist-get command :options) ", ")))
    (if (and question (not (eq (alist-get 'confirmed body) t)))
        (overlook-remote--json 200 `(:confirm ,(overlook-remote--text question)))
      (let ((result (apply (plist-get command :run)
                           (append (and (plist-get command :input) (list text))
                                   (and (plist-get command :options) (list option))))))
        (overlook-refresh)
        (pcase-let ((`(,agent . ,draft) (if (bufferp (car-safe result)) result (list result))))
          (overlook-remote--json
           200 `(:ok t
                 ,@(and (overlook-agent-p agent) `(:agent ,(buffer-name agent)))
                 ,@(and draft `(:draft ,(overlook-remote--text draft))))))))))

(defun overlook-remote--respond (method path query request)
  "Answer METHOD on PATH with QUERY and REQUEST, as (STATUS MIME BODY)."
  (let ((route (string-remove-suffix "/" (string-remove-prefix "/overlook" path))))
    (cond
     ((and (equal method "GET") (assoc route overlook-remote--files))
      (pcase-let ((`(,_ ,file ,mime) (assoc route overlook-remote--files)))
        (list 200 mime (with-temp-buffer
                         (let ((file (expand-file-name file overlook-remote--directory)))
                           (if (string-prefix-p "font/" mime)
                               (progn (set-buffer-multibyte nil)
                                      (insert-file-contents-literally file))
                             (insert-file-contents file)))
                         (buffer-string)))))
     ((not (overlook-remote--authorized-p request))
      (overlook-remote--json 401 '(:error "Open the page from M-x overlook-remote-url")))
     (t (condition-case err
            (overlook-remote--api method route query request)
          (overlook-remote-missing-agent
           (overlook-remote--json 404 `(:error ,(error-message-string err) :code "agent_missing")))
          (user-error (overlook-remote--json 409 `(:error ,(error-message-string err)))))))))

(defun overlook-remote--send (proc response)
  "Send RESPONSE, (STATUS MIME BODY), to PROC."
  (pcase-let ((`(,status ,mime ,body) response))
    (httpd-with-buffer proc mime
      (unless (multibyte-string-p body) (set-buffer-multibyte nil))
      (insert body)
      (httpd-send-header proc mime status :Cache-Control "no-store"))))

(defun overlook-remote--servlet (proc path query request)
  "Serve PATH with QUERY for REQUEST to PROC; simple-httpd's servlet for /overlook."
  (pcase (overlook-remote--together (overlook-remote--respond (caar request) path query request))
    (`(:hold ,call) (overlook-remote--hold proc call))
    (`(:stream ,known) (overlook-remote--stream proc known))
    (response (overlook-remote--send proc response))))

;;; Mode

(defvar overlook-remote--off-timer nil
  "Timer turning the mode off while it serves beyond this machine, or nil.")

(defvar overlook-remote--mode-line nil
  "What the dashboard's mode line says of the page while it is served.")

(defun overlook-remote--local-p ()
  "Non-nil when `overlook-remote-host' serves this machine only."
  (member overlook-remote-host '("127.0.0.1" "localhost" "::1")))

(defun overlook-remote--mode-line ()
  "Where the page is served, for `overlook-mode-line-functions'."
  overlook-remote--mode-line)

(defconst overlook-remote--tailscale-address
  "\\`100\\.\\(?:6[4-9]\\|[7-9][0-9]\\|1[01][0-9]\\|12[0-7]\\)\\."
  "Matches an address in 100.64.0.0/10, the range Tailscale assigns from.")

(defun overlook-remote--address ()
  "The IPv4 address a phone should open, or nil.
Prefers Tailscale's, in 100.64.0.0/10, which reaches this machine from
any network; then Ethernet and Wi-Fi interfaces, named en on macOS and
Linux."
  (let ((addresses
         (seq-keep (pcase-lambda (`(,interface . ,address))
                     (let ((ip (format-network-address address t)))
                       (unless (string-match-p "\\`\\(?:127\\|169\\.254\\)\\." ip)
                         (cons interface ip))))
                   (network-interface-list nil 'ipv4))))
    (cdr (or (seq-find (lambda (entry)
                         (string-match-p overlook-remote--tailscale-address (cdr entry)))
                       addresses)
             (seq-find (lambda (entry) (string-prefix-p "en" (car entry))) addresses)
             (car addresses)))))

;;;###autoload
(defun overlook-remote-url ()
  "Show the page's address, with its token, and copy it."
  (interactive)
  (let ((url (format "http://%s:%d/overlook/#%s"
                     (pcase overlook-remote-host
                       ("0.0.0.0" (or (overlook-remote--address) "localhost"))
                       ("127.0.0.1" "localhost")
                       (host host))
                     overlook-remote-port (overlook-remote--token))))
    (kill-new url)
    (message "overlook remote, copied: %s" url)
    url))

;;;###autoload
(define-minor-mode overlook-remote-mode
  "Serve the dashboard to a browser, a phone's if `overlook-remote-host' allows.
Open the address `overlook-remote-url' shows.  The page shows the
dashboard as it changes, and the answers the agents on it offer; it
follows each agent's prompts, replies and tool calls as they come, from
when the mode started, answers what it asks and prompts it.  It takes
over simple-httpd's server, which serves one Emacs at a time."
  :global t
  :group 'overlook
  (cond
   ((not overlook-remote-mode)
    (overlook-stop-updates 'remote)
    (remove-hook 'overlook-agent-event-functions #'overlook-remote--record)
    (remove-hook 'overlook-agent-changed-hook #'overlook-remote--wake)
    (remove-hook 'overlook-refresh-hook #'overlook-remote--refreshed)
    (remove-hook 'overlook-after-model-hook #'overlook-remote--redrawn)
    (remove-hook 'overlook-mode-line-functions #'overlook-remote--mode-line)
    (force-mode-line-update t)
    (setq overlook-remote--dashboard nil
          overlook-remote--versions nil
          overlook-remote--rows nil)
    (mapc #'overlook-remote--answer overlook-remote--waiting)
    (mapc (lambda (stream) (delete-process (car stream))) overlook-remote--streams)
    (setq overlook-remote--streams nil)
    (when overlook-remote--ping-timer (cancel-timer overlook-remote--ping-timer))
    (setq overlook-remote--ping-timer nil)
    (when overlook-remote--queue-timer (cancel-timer overlook-remote--queue-timer))
    (setq overlook-remote--queue-timer nil)
    (dolist (buffer (overlook-agent-buffers))
      (with-current-buffer buffer (setq overlook-remote--queue nil)))
    (when overlook-remote--off-timer (cancel-timer overlook-remote--off-timer))
    (setq overlook-remote--off-timer nil)
    (httpd-stop)
    (fmakunbound 'httpd/overlook))
   ((and httpd-serve-files httpd-root (file-directory-p httpd-root))
    (setq overlook-remote-mode nil)
    (user-error "Set `httpd-serve-files' to nil first, or %s goes on the network too"
                httpd-root))
   (t
    (add-hook 'overlook-agent-event-functions #'overlook-remote--record)
    (add-hook 'overlook-agent-changed-hook #'overlook-remote--wake)
    (add-hook 'overlook-refresh-hook #'overlook-remote--refreshed)
    (add-hook 'overlook-after-model-hook #'overlook-remote--redrawn)
    (defalias 'httpd/overlook #'overlook-remote--servlet)
    (let ((httpd-host overlook-remote-host)
          (httpd-port overlook-remote-port))
      (httpd-start))
    (setq overlook-remote--mode-line
          (if (overlook-remote--local-p)
              (propertize "remote" 'help-echo "overlook-remote serves this machine only")
            (propertize (concat "remote " (or (overlook-remote--address) overlook-remote-host))
                        'face 'warning
                        'help-echo "overlook-remote serves the local network")))
    (add-hook 'overlook-mode-line-functions #'overlook-remote--mode-line)
    (force-mode-line-update t)
    (overlook-start-updates 'remote)
    (when (and overlook-remote-network-minutes (not (overlook-remote--local-p)))
      (setq overlook-remote--off-timer
            (run-at-time (* 60 overlook-remote-network-minutes) nil
                         (lambda ()
                           (overlook-remote-mode -1)
                           (message "overlook remote: off after %d minutes on the network"
                                    overlook-remote-network-minutes)))))
    (overlook-remote-url))))

(provide 'overlook-remote)
;;; overlook-remote.el ends here
