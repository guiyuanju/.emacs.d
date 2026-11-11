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
(require 'overlook-remote-contract)
(require 'overlook-remote-service)

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
    ("/icon.svg" "remote-icon.svg" "image/svg+xml")
    ("/apple-touch-icon.png" "remote-icon-180.png" "image/png")
    ("/icon-192.png" "remote-icon-192.png" "image/png")
    ("/icon-512.png" "remote-icon-512.png" "image/png")
    ("/manifest.webmanifest" "remote.webmanifest" "application/manifest+json")
    ("/vendor/marked.js" "vendor/marked.js" "text/javascript")
    ("/vendor/purify.js" "vendor/purify.js" "text/javascript")
    ("/vendor/framework7.js" "vendor/framework7.js" "text/javascript")
    ("/vendor/framework7.css" "vendor/framework7.css" "text/css"))
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
  "Resolve the conversation identified by ID."
  (overlook-remote-service-agent-buffer id))

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
       stream (concat "data: " (nth 2 (overlook-remote--json 200 news)) "\n\n")))))

(defun overlook-remote--ping ()
  "Keep the streams' connections busy, so that dead ones show."
  (dolist (stream overlook-remote--streams)
    (overlook-remote--stream-write stream ": ping\n\n"))
  (unless overlook-remote--streams
    (when overlook-remote--ping-timer (cancel-timer overlook-remote--ping-timer))
    (setq overlook-remote--ping-timer nil)))

(defun overlook-remote--stream (proc known)
  "Stream the dashboard to PROC as server-sent events, from state KNOWN on."
  (overlook-remote--watch-connection proc)
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

(defun overlook-remote--connection-closed (proc event)
  "Release PROC's subscriptions and delegate EVENT to its original sentinel."
  (unless (process-live-p proc)
    (dolist (waiting (copy-sequence overlook-remote--waiting))
      (when (eq (car waiting) proc)
        (cancel-timer (nth 2 waiting))
        (setq overlook-remote--waiting (delq waiting overlook-remote--waiting))))
    (setq overlook-remote--streams
          (seq-remove (lambda (stream) (eq (car stream) proc)) overlook-remote--streams))
    (unless overlook-remote--streams
      (when overlook-remote--ping-timer (cancel-timer overlook-remote--ping-timer))
      (setq overlook-remote--ping-timer nil))
    (unless (or overlook-remote--waiting overlook-remote--streams)
      (when overlook-remote--wake-timer (cancel-timer overlook-remote--wake-timer))
      (setq overlook-remote--wake-timer nil)))
  (when-let* ((sentinel (process-get proc 'overlook-remote-sentinel)))
    (funcall sentinel proc event)))

(defun overlook-remote--watch-connection (proc)
  "Arrange cleanup when subscribed connection PROC closes."
  (unless (eq (process-sentinel proc) #'overlook-remote--connection-closed)
    (process-put proc 'overlook-remote-sentinel (process-sentinel proc))
    (set-process-sentinel proc #'overlook-remote--connection-closed)))

(defun overlook-remote--news (buffer after)
  "HTTP response for agent BUFFER's activity changed after AFTER."
  (if (not (buffer-live-p buffer))
      (overlook-remote--json 404 (overlook-remote-problem 404 "agent_missing" "The agent is gone"))
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
  (overlook-remote--watch-connection proc)
  (let ((waiting (list proc call nil)))
    (setf (nth 2 waiting) (run-at-time overlook-remote-wait nil
                                       #'overlook-remote--answer waiting))
    (push waiting overlook-remote--waiting)))

(defun overlook-remote--news-or-hold (call)
  "CALL's answer when it has news, else (:hold CALL).
CALL is (NEWS-P . ANSWER)."
  (if (funcall (car call)) (funcall (cdr call)) (list :hold call)))

;;; Requests

(defcustom overlook-remote-request-size (* 30 1024 1024)
  "Maximum JSON request body size in bytes, including base64 uploads."
  :type 'natnum
  :group 'overlook)

(defun overlook-remote--body (request &optional route)
  "Parse and validate REQUEST's JSON body for ROUTE."
  (let ((content (or (cadr (assoc "Content" request)) "")))
    (when (> (string-bytes content) overlook-remote-request-size)
      (signal 'overlook-remote-api-error '(413 "request_too_large" "Request body is too large")))
    (condition-case nil
        (overlook-remote-contract-request
         route (json-parse-string (decode-coding-string content 'utf-8)
                                  :object-type 'alist :null-object :null
                                  :false-object :false))
      (json-error
       (signal 'overlook-remote-api-error '(400 "invalid_json" "The body is not JSON"))))))

(defun overlook-remote--json (status data)
  "A response of STATUS carrying DATA as versioned JSON."
  (list status (if (>= status 400) "application/problem+json" "application/json")
        (decode-coding-string
         (json-serialize (overlook-remote-contract-response data))
         'utf-8)))

(defun overlook-remote--once (route body send)
  "Execute SEND for ROUTE and BODY with bounded retry receipts."
  (overlook-remote--json 200 (overlook-remote-service-once route body send)))

(defun overlook-remote--api (method route query request)
  "Answer METHOD on ROUTE with QUERY and REQUEST, as (STATUS MIME BODY).
A call for news with none yet is answered (:hold CALL), as
`overlook-remote--news-or-hold' gives, and one for the dashboard's
stream (:stream KNOWN)."
  (overlook-remote-contract-query route query)
  (pcase (list method route)
    ('("GET" "/api/agents")
     (overlook-remote--json
      200 `(:agents ,(vconcat (mapcar #'overlook-remote--agent (overlook-agent-buffers))))))
    ('("GET" "/api/agent")
     (overlook-remote--json
      200 (overlook-remote--agent
           (overlook-remote--agent-buffer (cadr (assoc "id" query))) t)))
    ('("GET" "/api/history")
     (overlook-remote--json
      200 (overlook-remote--history-data
           (overlook-remote--agent-buffer (cadr (assoc "id" query)))
           (when-let* ((value (cadr (assoc "before" query)))) (string-to-number value))
           (when-let* ((value (cadr (assoc "limit" query)))) (string-to-number value))
           (cadr (assoc "epoch" query)))))
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
     (overlook-remote--once route (overlook-remote--body request route)
                            #'overlook-remote-service-prompt))
    ('("POST" "/api/unqueue")
     (overlook-remote--json 200 (overlook-remote-service-unqueue (overlook-remote--body request route))))
    ('("POST" "/api/seen")
     (overlook-remote--json 200 (overlook-remote-service-seen (overlook-remote--body request route))))
    ('("POST" "/api/retry")
     (overlook-remote--json 200 (overlook-remote-service-retry (overlook-remote--body request route))))
    ('("POST" "/api/session")
     (overlook-remote--once route (overlook-remote--body request route)
                            #'overlook-remote-service-session))
    ('("GET" "/api/image")
     (let ((file (nth 1 (assq (string-to-number (or (cadr (assoc "n" query)) ""))
                              overlook-remote--images))))
       (unless (and file (overlook-remote--image file)) (overlook-remote-contract-error 404 "image_missing" "No such image"))
       (list 200 (overlook-remote--image-mime file)
             (with-temp-buffer
               (set-buffer-multibyte nil)
               (insert-file-contents-literally file)
               (buffer-string)))))
    ('("POST" "/api/upload")
     (overlook-remote--json 200 (overlook-remote-service-upload (overlook-remote--body request route))))
    ('("GET" "/api/diff")
     (overlook-remote--json 200 (overlook-remote-service-diff (cadr (assoc "node" query)))))
    ('("POST" "/api/command")
     (overlook-remote--once route (overlook-remote--body request route)
                            #'overlook-remote-service-command))
    ('("POST" "/api/choose")
     (overlook-remote--json 200 (overlook-remote-service-choose (overlook-remote--body request route))))
    (_ (overlook-remote--json 404 (overlook-remote-problem 404 "route_missing" (format "No %s %s" method route))))))

(defun overlook-remote--respond (method path query request)
  "Answer METHOD on PATH with QUERY and REQUEST, as (STATUS MIME BODY)."
  (let ((route (string-remove-suffix "/" (string-remove-prefix "/overlook" path))))
    (cond
     ((and (equal method "GET") (assoc route overlook-remote--files))
      (pcase-let ((`(,_ ,file ,mime) (assoc route overlook-remote--files)))
        (list 200 mime (with-temp-buffer
                         (let ((file (expand-file-name file overlook-remote--directory)))
                           (if (or (string-prefix-p "font/" mime)
                                   (equal mime "image/png"))
                               (progn (set-buffer-multibyte nil)
                                      (insert-file-contents-literally file))
                             (insert-file-contents file)))
                         (buffer-string)))))
     ((not (overlook-remote--authorized-p request))
      (overlook-remote--json 401 (overlook-remote-problem 401 "unauthorized" "Open the page from M-x overlook-remote-url")))
     (t (condition-case err
            (overlook-remote--api method route query request)
          (overlook-remote-api-error
           (pcase-let ((`(,status ,code ,detail) (cdr err)))
             (overlook-remote--json status (overlook-remote-problem status code detail))))
          (overlook-remote-missing-agent
           (overlook-remote--json 404 (overlook-remote-problem 404 "agent_missing" (error-message-string err))))
          (user-error
           (overlook-remote--json 409 (overlook-remote-problem 409 "state_conflict" (error-message-string err))))
          (error
           (message "Overlook remote: %s %s failed (%s)" method route (car err))
           (overlook-remote--json 500 (overlook-remote-problem 500 "internal_error" "The request could not be completed"))))))))


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
    (when overlook-remote--wake-timer (cancel-timer overlook-remote--wake-timer))
    (setq overlook-remote--wake-timer nil)
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
    ;; simple-httpd serves /overlook with the function of this name.
    (defalias (intern "httpd/overlook") #'overlook-remote--servlet)
    (let ((httpd-host overlook-remote-host)
          (httpd-port overlook-remote-port))
      (httpd-start))
    (setq overlook-remote--mode-line
          (propertize
           (overlook-mode-line-icon "nf-cod-globe" "remote"
                                    (unless (overlook-remote--local-p) 'warning))
           'help-echo (if (overlook-remote--local-p)
                          "Remote: this machine only"
                        (concat "Remote: " (or (overlook-remote--address) overlook-remote-host)))))
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
