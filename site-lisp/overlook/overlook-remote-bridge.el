;;; overlook-remote-bridge.el --- Publish overlook to the overlook-remoted daemon -*- lexical-binding: t; -*-

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

;; Connects Emacs to overlook-remoted, the daemon serving the dashboard
;; and agents to a phone, over a unix socket (NDJSON JSON-RPC 2.0, see
;; remote/docs/bridge-protocol.md).  Emacs publishes the dashboard tree,
;; each conversation's state and raw agent events, and runs the commands
;; the daemon forwards.  Turn it on with `overlook-remote-bridge-mode'.

;;; Code:

(require 'overlook-remote-bridge-data)
(require 'overlook-agent-session)

(defcustom overlook-remote-bridge-socket
  (expand-file-name "overlook-remote/bridge.sock"
                    (or (getenv "XDG_RUNTIME_DIR") "~/.local/state"))
  "Unix socket overlook-remoted listens on for Emacs."
  :type 'file
  :group 'overlook)

(defcustom overlook-remote-bridge-flush-delay 0.05
  "Seconds changes gather before they are sent together."
  :type 'number
  :group 'overlook)

(defcustom overlook-remote-bridge-retry-delays '(0.5 . 30)
  "First and longest wait, in seconds, before connecting again."
  :type '(cons number number)
  :group 'overlook)

(defcustom overlook-remote-bridge-buffer-limits (cons 2000 (* 16 1024 1024))
  "Most events, and their bytes, kept while the daemon is unreachable."
  :type '(cons natnum natnum)
  :group 'overlook)

(defcustom overlook-remote-bridge-dashboard-interval 0.5
  "Fewest seconds between two dashboards sent, as gathering one takes a while."
  :type 'number
  :group 'overlook)

(defcustom overlook-remote-bridge-redraw-wait 2
  "Seconds to wait for a shown dashboard to redraw before gathering its model."
  :type 'number
  :group 'overlook)

(defcustom overlook-remote-bridge-hello-timeout 10
  "Seconds to wait for the daemon to answer the handshake before trying again."
  :type 'number
  :group 'overlook)

(defcustom overlook-remote-bridge-diff-size 20000
  "How many characters of a row's diff are sent."
  :type 'natnum
  :group 'overlook)

(defconst overlook-remote-bridge-protocol 1
  "Version of the bridge protocol this file speaks.")

(defconst overlook-remote-bridge--chunk 8000
  "Most bytes written to the socket at once.
A write the socket cannot take whole makes Emacs wait 20 ms, and macOS
gives local sockets 8 KiB of buffer, so longer output goes out over
several turns of the event loop.")

(define-error 'overlook-remote-bridge-error "Bridge request failed")

;;; State

(defvar overlook-remote-bridge--epoch
  (format "%d-%s" (emacs-pid) (format-time-string "%s%N"))
  "Name of this Emacs process for the daemon, kept across reloads.")

(defvar overlook-remote-bridge--process nil
  "Connection to the daemon, or nil.")

(defvar overlook-remote-bridge--state nil
  "Connection state: nil offline, `hello' handshaking, `live' or `refused'.")

(defvar overlook-remote-bridge--partial ""
  "Bytes received after the last complete line.")

(defvar overlook-remote-bridge--inbox nil
  "Complete lines received and not yet handled, oldest first.")

(defvar overlook-remote-bridge--handling nil
  "Non-nil while lines are being handled, so a nested filter call only queues.")

(defvar overlook-remote-bridge--retry-timer nil
  "Timer connecting again, or nil.")

(defvar overlook-remote-bridge--retry-delay nil
  "Seconds before the next connection attempt.")

(defvar overlook-remote-bridge--hello-count 0
  "Number of handshakes started in this process, for their ids.")

(defvar overlook-remote-bridge--hello nil
  "Id of the pending handshake and the lost count it reported, as (ID . LOST).")

(defvar overlook-remote-bridge--hello-timer nil
  "Timer giving up on the pending handshake, or nil.")

(defvar overlook-remote-bridge--outbox nil
  "Output not yet written, oldest first, each (TEXT . EVENT-P).")

(defvar overlook-remote-bridge--outbox-timer nil
  "Timer writing more of `overlook-remote-bridge--outbox', or nil.")

(defvar overlook-remote-bridge--draining nil
  "Non-nil while the outbox is being written, so a nested call leaves it.")

(defvar overlook-remote-bridge--max-bytes (* 64 1024 1024)
  "Longest line the daemon accepts.")

(defvar overlook-remote-bridge--events nil
  "Agent events not yet sent, newest first.")

(defvar overlook-remote-bridge--event-totals (cons 0 0)
  "Count and approximate bytes of `overlook-remote-bridge--events'.")

(defvar overlook-remote-bridge--lost 0
  "Events dropped since the last handshake.")

(defvar overlook-remote-bridge--flush-timer nil
  "Timer sending gathered changes, and when it fires, as (TIMER . TIME), or nil.")

(defvar overlook-remote-bridge--dashboard-dirty nil
  "When the dashboard changed after it was last serialized, or nil.")

(defvar overlook-remote-bridge--dirty nil
  "Agent buffers whose state may have changed, or t for all.")

(defvar overlook-remote-bridge--sent-dashboard nil
  "JSON of the sections last sent.")

(defvar overlook-remote-bridge--dashboard-at 0
  "When the dashboard was last serialized.")

(defvar overlook-remote-bridge--sent (make-hash-table :test #'equal)
  "Conversation ids mapped to (BUFFER . JSON) of the state last sent.")

(defvar overlook-remote-bridge--rows nil
  "Rows of the dashboard last serialized, by key path, or nil.")

(defvar overlook-remote-bridge--gathering nil
  "Non-nil while the bridge itself gathers the model.")

(defvar overlook-remote-bridge--queue-timer nil
  "Timer delivering queued prompts while some wait, or nil.")

(defvar overlook-remote-bridge--queue-count 0
  "Number of prompts queued in this process, for their ids.")

(defvar-local overlook-remote-bridge--queue nil
  "Remote prompts waiting for this agent, each (:id ID :text TEXT), oldest first.")

(put 'overlook-remote-bridge--queue 'permanent-local t)

(defvar-local overlook-remote-bridge--queue-error nil
  "Why delivering this agent's queue failed; delivery waits for a retry.")

(put 'overlook-remote-bridge--queue-error 'permanent-local t)

(defvar overlook-remote-bridge-mode)

;;; Errors

(defun overlook-remote-bridge--fail (code problem message)
  "Answer the request being handled with error CODE, PROBLEM and MESSAGE."
  (signal 'overlook-remote-bridge-error (list code problem message)))

(defun overlook-remote-bridge--string (value)
  "VALUE when it is a string, else \"\"."
  (if (stringp value) value ""))

(defun overlook-remote-bridge--buffer (id &optional noerror)
  "Agent buffer of conversation ID; unless NOERROR, fail when it is gone."
  (or (and (stringp id)
           (seq-find (lambda (buffer) (equal id (overlook-data-agent-id buffer)))
                     (overlook-agent-buffers)))
      (unless noerror
        (overlook-remote-bridge--fail 404 "conversation_missing" "That conversation is gone"))))

(defun overlook-remote-bridge--name (buffer)
  "What to call agent BUFFER in messages."
  (or (overlook-agent-title buffer) (buffer-name buffer)))

;;; Mode line

(defun overlook-remote-bridge--mode-line ()
  "The bridge's state, for `overlook-mode-line-functions'."
  (pcase overlook-remote-bridge--state
    ('live (propertize (overlook-mode-line-icon "nf-cod-remote" "remote")
                       'help-echo "Remote: connected to overlook-remoted"))
    ('refused (propertize (overlook-mode-line-icon "nf-cod-remote" "remote!" 'error)
                          'help-echo "Remote: overlook-remoted speaks another protocol"))
    (_ (propertize (overlook-mode-line-icon "nf-cod-remote" "remote" 'shadow)
                   'help-echo "Remote: overlook-remoted is offline"))))

(defun overlook-remote-bridge--set-state (state)
  "Make STATE the connection's and show it."
  (unless (eq state overlook-remote-bridge--state)
    (setq overlook-remote-bridge--state state)
    (force-mode-line-update t)))

;;; Writing

(defun overlook-remote-bridge--drain ()
  "Write the outbox, `overlook-remote-bridge--chunk' bytes per turn."
  (setq overlook-remote-bridge--outbox-timer nil)
  (unless overlook-remote-bridge--draining
    (let ((overlook-remote-bridge--draining t)
          (budget overlook-remote-bridge--chunk))
      (while (and overlook-remote-bridge--outbox (> budget 0)
                  (process-live-p overlook-remote-bridge--process))
        (let* ((entry (car overlook-remote-bridge--outbox))
               (text (car entry))
               (piece (if (<= (length text) budget) text (substring text 0 budget))))
          (if (eq piece text)
              (pop overlook-remote-bridge--outbox)
            (setcar entry (substring text budget)))
          (setq budget (- budget (length piece)))
          (condition-case nil
              (process-send-string overlook-remote-bridge--process piece)
            (error (overlook-remote-bridge--drop)))))
      (when (and overlook-remote-bridge--outbox
                 (process-live-p overlook-remote-bridge--process))
        (setq overlook-remote-bridge--outbox-timer
              (run-at-time 0 nil #'overlook-remote-bridge--drain))))))

(defun overlook-remote-bridge--clear-outbox ()
  "Forget the output not written, counting the events in it as lost."
  (when (timerp overlook-remote-bridge--outbox-timer)
    (cancel-timer overlook-remote-bridge--outbox-timer))
  (setq overlook-remote-bridge--lost
        (+ overlook-remote-bridge--lost (seq-count #'cdr overlook-remote-bridge--outbox))
        overlook-remote-bridge--outbox nil
        overlook-remote-bridge--outbox-timer nil))

(defun overlook-remote-bridge--write-line (line &optional event)
  "Send LINE, unibyte JSON, to the daemon; non-nil when it went.
EVENT non-nil says LINE is an agent event, counted as lost if the
connection closes before it is written."
  (cond
   ((not (process-live-p overlook-remote-bridge--process)) nil)
   ((> (length line) overlook-remote-bridge--max-bytes)
    (message "overlook-remote-bridge: dropped a message of %d bytes" (length line))
    nil)
   (t (setq overlook-remote-bridge--outbox
            (nconc overlook-remote-bridge--outbox (list (cons (concat line "\n") event))))
      (overlook-remote-bridge--drain)
      t)))

(defun overlook-remote-bridge--write (message &optional event)
  "Send MESSAGE, a plist, to the daemon; non-nil when it went.
EVENT is as for `overlook-remote-bridge--write-line'."
  (overlook-remote-bridge--write-line (overlook-remote-bridge-json message) event))

(defun overlook-remote-bridge--notify (method params)
  "Send notification METHOD with PARAMS, a plist; non-nil when it went."
  (overlook-remote-bridge--write (list :jsonrpc "2.0" :method method :params params)
                                 (equal method "agent.event")))

(defun overlook-remote-bridge--notify-raw (method params)
  "Send notification METHOD whose PARAMS are given as JSON text."
  (overlook-remote-bridge--write-line
   (concat "{\"jsonrpc\":\"2.0\",\"method\":\"" method "\",\"params\":" params "}")))

;;; Connection

(defun overlook-remote-bridge--connect ()
  "Connect to the daemon and start the handshake, or try again later."
  (setq overlook-remote-bridge--retry-timer nil)
  (when (and overlook-remote-bridge-mode
             (not (process-live-p overlook-remote-bridge--process))
             (not (eq overlook-remote-bridge--state 'refused)))
    (condition-case err
        (let ((process (make-network-process
                        :name "overlook-remote-bridge" :family 'local
                        :service (expand-file-name overlook-remote-bridge-socket)
                        :coding 'binary :noquery t
                        :filter #'overlook-remote-bridge--filter
                        :sentinel #'overlook-remote-bridge--sentinel)))
          (setq overlook-remote-bridge--process process
                overlook-remote-bridge--partial ""
                overlook-remote-bridge--inbox nil)
          (overlook-remote-bridge--set-state 'hello)
          (overlook-remote-bridge--send-hello))
      (file-error (overlook-remote-bridge--retry))
      (error (message "overlook-remote-bridge: cannot connect: %s" (error-message-string err))
             (overlook-remote-bridge--retry)))))

(defun overlook-remote-bridge--retry ()
  "Connect again after the current delay, with jitter, then double it."
  (when (and overlook-remote-bridge-mode
             (not overlook-remote-bridge--retry-timer)
             (not (eq overlook-remote-bridge--state 'refused)))
    (let ((delay (or overlook-remote-bridge--retry-delay
                     (car overlook-remote-bridge-retry-delays))))
      (setq overlook-remote-bridge--retry-timer
            (run-at-time (* delay (+ 0.8 (* 0.4 (/ (random 1000) 1000.0)))) nil
                         #'overlook-remote-bridge--connect)
            overlook-remote-bridge--retry-delay
            (min (cdr overlook-remote-bridge-retry-delays) (* 2 delay))))))

(defun overlook-remote-bridge--disconnected ()
  "Forget the connection, keeping what is to be sent once it is back."
  (overlook-remote-bridge--clear-outbox)
  (overlook-remote-bridge--cancel-hello)
  (setq overlook-remote-bridge--process nil
        overlook-remote-bridge--partial ""
        overlook-remote-bridge--inbox nil
        overlook-remote-bridge--hello nil)
  (unless (eq overlook-remote-bridge--state 'refused)
    (overlook-remote-bridge--set-state nil)))

(defun overlook-remote-bridge--drop ()
  "Close the connection after an error and try again later."
  (let ((process overlook-remote-bridge--process))
    (overlook-remote-bridge--disconnected)
    (when process (delete-process process))
    (overlook-remote-bridge--retry)))

(defun overlook-remote-bridge--sentinel (process _event)
  "Notice that PROCESS, the connection, closed."
  (when (and (eq process overlook-remote-bridge--process)
             (not (process-live-p process)))
    (overlook-remote-bridge--disconnected)
    (overlook-remote-bridge--retry)))

(defun overlook-remote-bridge--cancel-hello ()
  "Stop waiting for the handshake to time out."
  (when (timerp overlook-remote-bridge--hello-timer)
    (cancel-timer overlook-remote-bridge--hello-timer))
  (setq overlook-remote-bridge--hello-timer nil))

(defun overlook-remote-bridge--hello-timed-out (id)
  "Give up on handshake ID if the daemon has not answered it yet."
  (setq overlook-remote-bridge--hello-timer nil)
  (when (equal id (car overlook-remote-bridge--hello))
    (message "overlook-remote-bridge: overlook-remoted did not answer; trying again")
    (overlook-remote-bridge--drop)))

(defun overlook-remote-bridge--send-hello ()
  "Start the handshake."
  (let ((id (format "hello-%d" (setq overlook-remote-bridge--hello-count
                                     (1+ overlook-remote-bridge--hello-count)))))
    (setq overlook-remote-bridge--hello (cons id overlook-remote-bridge--lost))
    (overlook-remote-bridge--cancel-hello)
    (setq overlook-remote-bridge--hello-timer
          (run-at-time overlook-remote-bridge-hello-timeout nil
                       #'overlook-remote-bridge--hello-timed-out id))
    (overlook-remote-bridge--write
     (list :jsonrpc "2.0" :id id :method "hello"
           :params (list :protocol overlook-remote-bridge-protocol
                         :epoch overlook-remote-bridge--epoch
                         :emacs emacs-version :pid (emacs-pid)
                         :lost overlook-remote-bridge--lost)))))

(defun overlook-remote-bridge--welcomed (result)
  "Finish the handshake the daemon accepted with RESULT: sync, then replay."
  (let ((lost (cdr overlook-remote-bridge--hello)))
    (overlook-remote-bridge--cancel-hello)
    (setq overlook-remote-bridge--hello nil
          overlook-remote-bridge--retry-delay nil
          overlook-remote-bridge--lost (max 0 (- overlook-remote-bridge--lost lost)))
    (when (natnump (alist-get 'maxMessageBytes result))
      (setq overlook-remote-bridge--max-bytes (alist-get 'maxMessageBytes result)))
    (overlook-remote-bridge--set-state 'live)
    (overlook-remote-bridge--sync)
    (overlook-remote-bridge--flush)))

(defun overlook-remote-bridge--refused (error)
  "Handle the daemon refusing the handshake with ERROR, an alist."
  (if (equal (alist-get 'problem (alist-get 'data error)) "protocol_mismatch")
      (let ((process overlook-remote-bridge--process))
        (overlook-remote-bridge--set-state 'refused)
        (overlook-remote-bridge--disconnected)
        (when process (delete-process process))
        (message "overlook-remote-bridge: %s; update overlook or overlook-remoted"
                 (or (alist-get 'message error) "protocol mismatch")))
    (message "overlook-remote-bridge: handshake failed: %s" (alist-get 'message error))
    (overlook-remote-bridge--drop)))

;;; Reading

(defun overlook-remote-bridge--filter (process chunk)
  "Take CHUNK of bytes from PROCESS, handling each complete line."
  (when (eq process overlook-remote-bridge--process)
    (let* ((text (concat overlook-remote-bridge--partial chunk))
           (last (cl-position ?\n text :from-end t)))
      (if (not last)
          (setq overlook-remote-bridge--partial text)
        (setq overlook-remote-bridge--partial (substring text (1+ last))
              overlook-remote-bridge--inbox
              (append overlook-remote-bridge--inbox
                      (split-string (substring text 0 last) "\n" t)))
        (unless overlook-remote-bridge--handling
          (let ((overlook-remote-bridge--handling t))
            (while (and overlook-remote-bridge--inbox
                        (eq process overlook-remote-bridge--process))
              (overlook-remote-bridge--receive (pop overlook-remote-bridge--inbox)))))))))

(defun overlook-remote-bridge--receive (line)
  "Handle LINE, one message from the daemon."
  (let ((message (condition-case nil
                     (json-parse-string (decode-coding-string line 'utf-8)
                                        :object-type 'alist :null-object :null
                                        :false-object :false)
                   (json-error nil))))
    (cond
     ((not (consp message))
      (message "overlook-remote-bridge: unreadable message ignored"))
     ((alist-get 'method message)
      (if (assq 'id message)
          (overlook-remote-bridge--answer (alist-get 'id message) (alist-get 'method message)
                                          (alist-get 'params message))
        (overlook-remote-bridge--notified (alist-get 'method message)
                                          (alist-get 'params message))))
     ((and overlook-remote-bridge--hello
           (equal (alist-get 'id message) (car overlook-remote-bridge--hello)))
      (if (assq 'error message)
          (overlook-remote-bridge--refused (alist-get 'error message))
        (overlook-remote-bridge--welcomed (alist-get 'result message)))))))

(defun overlook-remote-bridge--notified (method params)
  "Handle notification METHOD with PARAMS from the daemon."
  (pcase method
    ("conversation.seen"
     (when-let* ((buffer (overlook-remote-bridge--buffer (alist-get 'conversation params) t)))
       (overlook-agent-seen buffer)))
    ("resync"
     (overlook-remote-bridge--flush)
     (overlook-remote-bridge--sync))))

(defun overlook-remote-bridge--answer (id method params)
  "Run request ID, METHOD with PARAMS, and send its response once all else is sent."
  (let ((response
         (condition-case err
             (list :jsonrpc "2.0" :id id
                   :result (overlook-remote-bridge--call method (if (consp params) params nil)))
           (overlook-remote-bridge-error
            (pcase-let ((`(,code ,problem ,text) (cdr err)))
              (list :jsonrpc "2.0" :id id
                    :error `(:code ,code :message ,text
                             ,@(and problem (list :data (list :problem problem)))))))
           (user-error
            (list :jsonrpc "2.0" :id id
                  :error (list :code 409 :message (error-message-string err)
                               :data '(:problem "state_conflict"))))
           (error
            (message "overlook-remote-bridge: %s failed: %S" method err)
            (list :jsonrpc "2.0" :id id
                  :error (list :code 500 :message "The request could not be completed"
                               :data '(:problem "internal_error")))))))
    ;; What the request changed reaches the daemon before its response.
    (overlook-remote-bridge--flush t)
    (overlook-remote-bridge--write response)))

;;; Publishing

(defun overlook-remote-bridge--schedule (&optional delay)
  "Send gathered changes in DELAY seconds, or `overlook-remote-bridge-flush-delay'."
  (when (eq overlook-remote-bridge--state 'live)
    (let* ((delay (or delay overlook-remote-bridge-flush-delay))
           (time (+ (float-time) delay)))
      (unless (and overlook-remote-bridge--flush-timer
                   (<= (cdr overlook-remote-bridge--flush-timer) time))
        (when overlook-remote-bridge--flush-timer
          (cancel-timer (car overlook-remote-bridge--flush-timer)))
        (setq overlook-remote-bridge--flush-timer
              (cons (run-at-time delay nil #'overlook-remote-bridge--flush-later) time))))))

(defun overlook-remote-bridge--flush-later ()
  "Send gathered changes, from a timer."
  (with-demoted-errors "overlook-remote-bridge: %S"
    (overlook-remote-bridge--flush)))

(defun overlook-remote-bridge--sections ()
  "Serialize the dashboard's model, recording its rows; return its JSON."
  (let* ((rows (make-hash-table :test #'equal))
         (model (let ((overlook-remote-bridge--gathering t))
                  ;; Only the live dashboard's redraws keep a shared model fresh.
                  (if (overlook-live-p) (overlook-latest-model) (overlook-model))))
         (json (overlook-remote-bridge-json (overlook-remote-bridge-sections model rows))))
    (setq overlook-remote-bridge--rows rows
          overlook-remote-bridge--dashboard-dirty nil
          overlook-remote-bridge--dashboard-at (float-time))
    json))

(defun overlook-remote-bridge--publish-dashboard (&optional force)
  "Send the dashboard if it changed; FORCE skips waiting for a redraw."
  (when (or force overlook-remote-bridge--dashboard-dirty (not overlook-remote-bridge--rows))
    (let ((dirty (or overlook-remote-bridge--dashboard-dirty (float-time)))
          (next (+ overlook-remote-bridge--dashboard-at overlook-remote-bridge-dashboard-interval)))
      (cond
       ((and (not force) (< (float-time) next))
        (overlook-remote-bridge--schedule (- next (float-time))))
       ((and (not force)
             (not (overlook-model-fresh-p))
             (get-buffer-window overlook-buffer-name t)
             (< (- (float-time) dirty) overlook-remote-bridge-redraw-wait))
        ;; The shown dashboard redraws soon and gathers the model to share.
        (overlook-remote-bridge--schedule
         (- (+ dirty overlook-remote-bridge-redraw-wait) (float-time))))
       (t
        (let ((json (overlook-remote-bridge--sections)))
          (when (and (eq overlook-remote-bridge--state 'live)
                     (not (equal json overlook-remote-bridge--sent-dashboard))
                     (overlook-remote-bridge--notify-raw
                      "dashboard.set" (concat "{\"sections\":" json "}")))
            (setq overlook-remote-bridge--sent-dashboard json))))))))

(defun overlook-remote-bridge--conversation-json (buffer)
  "JSON of agent BUFFER's state, or nil when it cannot be serialized."
  (condition-case err
      (let ((json (overlook-remote-bridge-json
                   (overlook-remote-bridge-conversation
                    buffer
                    (buffer-local-value 'overlook-remote-bridge--queue buffer)
                    (buffer-local-value 'overlook-remote-bridge--queue-error buffer)))))
        (if (<= (length json) (* 1024 1024))
            json
          (message "overlook-remote-bridge: %s is too large to publish" (buffer-name buffer))
          nil))
    (error (message "overlook-remote-bridge: %s: %S" (buffer-name buffer) err)
           nil)))

(defun overlook-remote-bridge--publish-conversations ()
  "Send the state of each changed conversation."
  (let ((buffers (if (eq overlook-remote-bridge--dirty t)
                     (overlook-agent-buffers)
                   (seq-filter #'overlook-agent-p overlook-remote-bridge--dirty))))
    (setq overlook-remote-bridge--dirty nil)
    (dolist (buffer buffers)
      (when-let* ((json (overlook-remote-bridge--conversation-json buffer))
                  (id (overlook-data-agent-id buffer))
                  ((not (equal json (cdr (gethash id overlook-remote-bridge--sent)))))
                  ((overlook-remote-bridge--notify-raw
                    "conversation.set" (concat "{\"conversation\":" json "}"))))
        (puthash id (cons buffer json) overlook-remote-bridge--sent)))))

(defun overlook-remote-bridge--publish-events ()
  "Send the events gathered, oldest first, keeping those a failed write left."
  (let ((events (reverse overlook-remote-bridge--events)))
    (while (and events (overlook-remote-bridge--notify "agent.event" (car events)))
      (pop events))
    (setq overlook-remote-bridge--events (reverse events)
          overlook-remote-bridge--event-totals
          (cons (length events)
                (apply #'+ (mapcar #'overlook-remote-bridge-event-size events))))))

(defun overlook-remote-bridge--publish-removals ()
  "Tell the daemon of the conversations whose buffers are gone."
  (let (gone)
    (maphash (lambda (id entry) (unless (overlook-agent-p (car entry)) (push id gone)))
             overlook-remote-bridge--sent)
    (dolist (id gone)
      (when (overlook-remote-bridge--notify "conversation.remove" (list :conversation id))
        (remhash id overlook-remote-bridge--sent)))))

(defun overlook-remote-bridge--flush (&optional now)
  "Send every change gathered, in protocol order.
NOW sends a changed dashboard without waiting for its interval or a redraw."
  (when overlook-remote-bridge--flush-timer
    (cancel-timer (car overlook-remote-bridge--flush-timer))
    (setq overlook-remote-bridge--flush-timer nil))
  (when (eq overlook-remote-bridge--state 'live)
    (overlook-remote-bridge--publish-conversations)
    (overlook-remote-bridge--publish-events)
    (overlook-remote-bridge--publish-removals)
    (overlook-remote-bridge--publish-dashboard
     (and now overlook-remote-bridge--dashboard-dirty t))))

(defun overlook-remote-bridge--sync ()
  "Send the whole state, replacing what the daemon has."
  (let* ((sections (condition-case err (overlook-remote-bridge--sections)
                     (error (message "overlook-remote-bridge: dashboard: %S" err) "[]")))
         (entries (delq nil (mapcar (lambda (buffer)
                                      (when-let* ((json (overlook-remote-bridge--conversation-json
                                                         buffer)))
                                        (list (overlook-data-agent-id buffer) buffer json)))
                                    (overlook-agent-buffers)))))
    (when (overlook-remote-bridge--notify-raw
           "sync" (concat "{\"dashboard\":" sections ",\"conversations\":["
                          (mapconcat #'caddr entries ",") "]}"))
      (setq overlook-remote-bridge--sent-dashboard sections
            overlook-remote-bridge--dirty nil)
      (clrhash overlook-remote-bridge--sent)
      (pcase-dolist (`(,id ,buffer ,json) entries)
        (puthash id (cons buffer json) overlook-remote-bridge--sent)))))

(defun overlook-remote-bridge--enqueue (event)
  "Keep EVENT to send, merged into the one before when allowed."
  (let* ((totals overlook-remote-bridge--event-totals)
         (previous (car overlook-remote-bridge--events))
         (merged (and previous (overlook-remote-bridge-merge previous event))))
    (if merged
        (progn (setcar overlook-remote-bridge--events merged)
               (setcdr totals (+ (cdr totals) (- (overlook-remote-bridge-event-size merged)
                                                 (overlook-remote-bridge-event-size previous)))))
      (push event overlook-remote-bridge--events)
      (setcar totals (1+ (car totals)))
      (setcdr totals (+ (cdr totals) (overlook-remote-bridge-event-size event))))
    (while (and overlook-remote-bridge--events
                (or (> (car totals) (car overlook-remote-bridge-buffer-limits))
                    (> (cdr totals) (cdr overlook-remote-bridge-buffer-limits))))
      (let ((oldest (car (last overlook-remote-bridge--events))))
        (setq overlook-remote-bridge--events (nbutlast overlook-remote-bridge--events)
              overlook-remote-bridge--lost (1+ overlook-remote-bridge--lost))
        (setcar totals (1- (car totals)))
        (setcdr totals (- (cdr totals) (overlook-remote-bridge-event-size oldest)))))))

;;; Hooks

(defun overlook-remote-bridge--dashboard-changed ()
  "Note that the dashboard changed, and send it soon."
  (unless overlook-remote-bridge--dashboard-dirty
    (setq overlook-remote-bridge--dashboard-dirty (float-time)))
  (overlook-remote-bridge--schedule))

(defun overlook-remote-bridge--refreshed ()
  "Follow an `overlook-refresh'."
  (overlook-remote-bridge--dashboard-changed))

(defun overlook-remote-bridge--redrawn ()
  "Follow a model another view gathered, which the bridge can share."
  (unless overlook-remote-bridge--gathering
    (overlook-remote-bridge--dashboard-changed)))

(defun overlook-remote-bridge--agents-changed ()
  "Note that any agent's state may have changed."
  (setq overlook-remote-bridge--dirty t)
  (overlook-remote-bridge--schedule))

(defun overlook-remote-bridge--touch (buffer)
  "Note that agent BUFFER's state may have changed."
  (unless (or (eq overlook-remote-bridge--dirty t)
              (memq buffer overlook-remote-bridge--dirty))
    (push buffer overlook-remote-bridge--dirty))
  (overlook-remote-bridge--schedule))

(defun overlook-remote-bridge--record (buffer event)
  "Keep agent BUFFER's EVENT to send."
  (when (buffer-live-p buffer)
    (mapc #'overlook-remote-bridge--enqueue (overlook-remote-bridge-events buffer event))
    (overlook-remote-bridge--touch buffer)))

(defconst overlook-remote-bridge--hooks
  '((overlook-refresh-hook overlook-remote-bridge--refreshed)
    (overlook-after-model-hook overlook-remote-bridge--redrawn)
    (overlook-agent-changed-hook overlook-remote-bridge--agents-changed)
    (overlook-agent-event-functions overlook-remote-bridge--record)
    (overlook-mode-line-functions overlook-remote-bridge--mode-line))
  "Hooks the mode adds, each (HOOK FUNCTION).")

;;; Prompt queue

(defun overlook-remote-bridge--queue-changed (buffer)
  "Publish agent BUFFER's queue, delivering it while prompts wait."
  (when (and (buffer-local-value 'overlook-remote-bridge--queue buffer)
             (not overlook-remote-bridge--queue-timer))
    (setq overlook-remote-bridge--queue-timer
          (run-at-time 1 1 #'overlook-remote-bridge--deliver)))
  (overlook-remote-bridge--touch buffer))

(defun overlook-remote-bridge--deliver ()
  "Submit to each ready agent the first prompt queued for it."
  (let ((waiting (seq-filter (lambda (buffer)
                               (buffer-local-value 'overlook-remote-bridge--queue buffer))
                             (overlook-agent-buffers))))
    (dolist (buffer waiting)
      (when (and (not (buffer-local-value 'overlook-remote-bridge--queue-error buffer))
                 (overlook-agent-ready-p buffer))
        (with-current-buffer buffer
          (condition-case err
              (progn (overlook-agent-submit buffer (plist-get (car overlook-remote-bridge--queue) :text))
                     (pop overlook-remote-bridge--queue))
            (error (setq overlook-remote-bridge--queue-error (error-message-string err)))))
        (overlook-remote-bridge--touch buffer)))
    (unless (seq-some (lambda (buffer) (buffer-local-value 'overlook-remote-bridge--queue buffer))
                      waiting)
      (cancel-timer overlook-remote-bridge--queue-timer)
      (setq overlook-remote-bridge--queue-timer nil))))

;;; Requests

(defun overlook-remote-bridge--confirming (confirmed questions run)
  "Call RUN unless a question it or QUESTIONS asks first is not in CONFIRMED.
Return RUN's outcome, or a confirm outcome with the first such question."
  (let* ((ask (lambda (prompt &rest _)
                (let ((prompt (overlook-remote-bridge--text prompt)))
                  (if (member prompt confirmed) t
                    (throw 'overlook-remote-bridge--confirm prompt)))))
         (result (catch 'overlook-remote-bridge--confirm
                   (mapc ask questions)
                   (cl-letf (((symbol-function 'y-or-n-p) ask)
                             ((symbol-function 'yes-or-no-p) ask))
                     (list (funcall run))))))
    (if (stringp result)
        (list :outcome "confirm" :question result)
      (car result))))

(defun overlook-remote-bridge--confirmed (params)
  "Questions PARAMS says the user confirmed."
  (seq-filter #'stringp (append (alist-get 'confirmed params) nil)))

(defun overlook-remote-bridge--prompt (params)
  "Submit PARAMS' text to its conversation, or queue it while the agent is busy."
  (let ((buffer (overlook-remote-bridge--buffer (alist-get 'conversation params)))
        (text (string-trim (overlook-remote-bridge--string (alist-get 'text params)))))
    (when (string-empty-p text)
      (overlook-remote-bridge--fail 400 "empty_text" "Nothing to send"))
    (unless (overlook-agent-get buffer 'submit)
      (overlook-remote-bridge--fail 409 "prompt_unsupported"
                                    (format "%s cannot take a prompt"
                                            (overlook-remote-bridge--name buffer))))
    (with-current-buffer buffer
      (if (and (null overlook-remote-bridge--queue) (overlook-agent-ready-p buffer))
          (progn (overlook-agent-submit buffer text)
                 (overlook-remote-bridge--touch buffer)
                 '(:delivery "sent"))
        (let ((id (format "queued-%d" (setq overlook-remote-bridge--queue-count
                                            (1+ overlook-remote-bridge--queue-count)))))
          (setq overlook-remote-bridge--queue
                (append overlook-remote-bridge--queue (list (list :id id :text text))))
          (overlook-remote-bridge--queue-changed buffer)
          (list :delivery "queued" :queueId id))))))

(defun overlook-remote-bridge--unqueue (params)
  "Withdraw PARAMS' queued prompt and let delivery go on."
  (let* ((buffer (overlook-remote-bridge--buffer (alist-get 'conversation params)))
         (id (alist-get 'queueId params)))
    (with-current-buffer buffer
      (let ((item (seq-find (lambda (item) (equal id (plist-get item :id)))
                            overlook-remote-bridge--queue)))
        (unless item
          (overlook-remote-bridge--fail 409 "already_sent" "That prompt was sent already"))
        (setq overlook-remote-bridge--queue (delq item overlook-remote-bridge--queue)
              overlook-remote-bridge--queue-error nil)))
    (overlook-remote-bridge--queue-changed buffer)
    nil))

(defun overlook-remote-bridge--retry-queue (params)
  "Let PARAMS' conversation deliver its queue again after an error."
  (let ((buffer (overlook-remote-bridge--buffer (alist-get 'conversation params))))
    (with-current-buffer buffer (setq overlook-remote-bridge--queue-error nil))
    (overlook-remote-bridge--queue-changed buffer)
    nil))

(defun overlook-remote-bridge--close-question (buffer)
  "The question confirming that agent BUFFER is to be closed."
  (format "Close agent %s?%s Queued prompts will be discarded. %s"
          (overlook-remote-bridge--name buffer)
          (if (overlook-agent-ready-p buffer) "" " Its current work will stop.")
          (if (overlook-agent-session buffer)
              "This conversation will remain saved for resuming."
            "This agent has no resumable session and cannot be restored.")))

(defun overlook-remote-bridge--close (buffer)
  "Close agent BUFFER, its remote queue discarded unless closing fails."
  (with-current-buffer buffer
    (let ((queue overlook-remote-bridge--queue)
          (queue-error overlook-remote-bridge--queue-error))
      (setq overlook-remote-bridge--queue nil
            overlook-remote-bridge--queue-error nil)
      (unwind-protect
          (overlook-agent-close buffer)
        (when (buffer-live-p buffer)
          (setq overlook-remote-bridge--queue queue
                overlook-remote-bridge--queue-error queue-error))))))

(defun overlook-remote-bridge--action (params)
  "Run PARAMS' session action, or ask to confirm it first."
  (let* ((buffer (overlook-remote-bridge--buffer (alist-get 'conversation params)))
         (action (overlook-remote-bridge--string (alist-get 'action params)))
         (text (string-trim (overlook-remote-bridge--string (alist-get 'text params))))
         (run (overlook-agent-get buffer 'remote-action))
         (controls (overlook-remote-bridge-controls buffer)))
    (unless (or (equal action "close")
                (and run (if (equal action "steer")
                             (plist-get controls :steer)
                           (member action (plist-get controls :actions)))))
      (overlook-remote-bridge--fail 400 "unsupported_action"
                                    (format "This agent does not support %s" action)))
    (when (and (equal action "steer") (string-empty-p text))
      (overlook-remote-bridge--fail 400 "empty_text" "Nothing to steer"))
    (overlook-remote-bridge--confirming
     (overlook-remote-bridge--confirmed params)
     (pcase action
       ("close" (list (overlook-remote-bridge--close-question buffer)))
       ("reload" '("Reload this session? Unsent prompts may be lost."))
       ("restart" '("Start a fresh conversation? Unsent prompts may be lost.")))
     (lambda ()
       (if (equal action "close")
           (progn (overlook-remote-bridge--close buffer)
                  '(:outcome "done" :closed t))
         (let ((result (with-current-buffer buffer (funcall run action text))))
           `(:outcome "done"
             ,@(and (overlook-agent-p result)
                    (list :conversation (overlook-data-agent-id result))))))))))

(defun overlook-remote-bridge--choose (params)
  "Give PARAMS' conversation the answer it offers under PARAMS' key."
  (overlook-agent-choose (overlook-remote-bridge--buffer (alist-get 'conversation params))
                         (overlook-remote-bridge--string (alist-get 'key params)))
  nil)

(defun overlook-remote-bridge--answer-form (params)
  "Answer or decline PARAMS' question form with its values."
  (let* ((buffer (overlook-remote-bridge--buffer (alist-get 'conversation params)))
         (id (overlook-remote-bridge--string (alist-get 'form params)))
         (values (alist-get 'values params)))
    (unless (overlook-agent-get buffer 'answer)
      (overlook-remote-bridge--fail 409 "answer_unsupported"
                                    (format "%s cannot be answered from here"
                                            (overlook-remote-bridge--name buffer))))
    (unless (equal id (overlook-remote-bridge--text
                       (plist-get (overlook-agent-form buffer) :id)))
      (overlook-remote-bridge--fail 409 "state_conflict" "That question is no longer asked"))
    (overlook-agent-answer buffer id (overlook-remote-bridge--string (alist-get 'action params))
                           (and (consp values) values))
    nil))

(defun overlook-remote-bridge--attach (params)
  "Hand PARAMS' file to its conversation's agent; return the text naming it."
  (let* ((buffer (overlook-remote-bridge--buffer (alist-get 'conversation params)))
         (attach (or (overlook-agent-get buffer 'attach)
                     (overlook-remote-bridge--fail 409 "attachment_unsupported"
                                                   "This conversation cannot take files")))
         (data (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert-file-contents-literally
                  (overlook-remote-bridge--string (alist-get 'path params)))
                 (buffer-string))))
    (list :text (overlook-remote-bridge--text
                 (with-current-buffer buffer
                   (funcall attach (overlook-remote-bridge--string (alist-get 'name params))
                            data))))))

(defun overlook-remote-bridge--earlier (params)
  "Last reply and transcript tail of PARAMS' conversation."
  (let ((buffer (overlook-remote-bridge--buffer (alist-get 'conversation params))))
    (list :reply (overlook-remote-bridge--text (overlook-agent-reply buffer))
          :transcript (overlook-remote-bridge-tail buffer))))

(defun overlook-remote-bridge--row (params)
  "Row at PARAMS' key path in the latest dashboard."
  (when (or overlook-remote-bridge--dashboard-dirty (not overlook-remote-bridge--rows))
    (overlook-remote-bridge--publish-dashboard t))
  (let ((path (alist-get 'path params)))
    (or (and (or (vectorp path) (consp path))
             (gethash (append path nil) overlook-remote-bridge--rows))
        (overlook-remote-bridge--fail 404 "node_missing" "That row is gone"))))

(defun overlook-remote-bridge--command (params)
  "Run PARAMS' row command, or ask to confirm it first."
  (let* ((row (overlook-remote-bridge--row params))
         (name (overlook-remote-bridge--string (alist-get 'name params)))
         (command (or (overlook-row-command row name)
                      (overlook-remote-bridge--fail 404 "command_missing"
                                                    (format "That row no longer offers %s" name))))
         (input (plist-get command :input))
         (options (plist-get command :options))
         (text (string-trim (overlook-remote-bridge--string (alist-get 'text params))))
         (option (alist-get 'option params))
         (confirm (plist-get command :confirm))
         (question (if (functionp confirm) (funcall confirm) confirm)))
    (when (and input (string-empty-p text))
      (overlook-remote-bridge--fail 400 "empty_text" "Nothing to send"))
    (when (and options (not (member option options)))
      (overlook-remote-bridge--fail 400 "invalid_option"
                                    (format "Pick one of %s" (string-join options ", "))))
    (overlook-remote-bridge--confirming
     (overlook-remote-bridge--confirmed params)
     (cond ((stringp question) (list (substring-no-properties question)))
           (question (list (format "%s?" (overlook-remote-bridge--text
                                          (plist-get command :label))))))
     (lambda ()
       (let ((result (apply (plist-get command :run)
                            (append (and input (list text)) (and options (list option))))))
         (overlook-refresh)
         (pcase-let ((`(,agent . ,draft) (if (bufferp (car-safe result)) result (list result))))
           `(:outcome "done"
             ,@(and (overlook-agent-p agent) (list :conversation (overlook-data-agent-id agent)))
             ,@(and (stringp draft) (list :draft (overlook-remote-bridge--text draft))))))))))

(defun overlook-remote-bridge--diff (params)
  "Unified diff of PARAMS' row, cut to `overlook-remote-bridge-diff-size'."
  (let* ((row (overlook-remote-bridge--row params))
         (diff (or (overlook-row-diff row)
                   (overlook-remote-bridge--fail 404 "diff_missing" "That row has no diff")))
         (text (overlook-remote-bridge--text (funcall diff))))
    (list :diff (if (> (length text) overlook-remote-bridge-diff-size)
                    (concat (substring text 0 overlook-remote-bridge-diff-size) "\n…")
                  text))))

(defconst overlook-remote-bridge--methods
  '(("conversation.prompt" . overlook-remote-bridge--prompt)
    ("conversation.unqueue" . overlook-remote-bridge--unqueue)
    ("conversation.retry" . overlook-remote-bridge--retry-queue)
    ("conversation.action" . overlook-remote-bridge--action)
    ("conversation.choose" . overlook-remote-bridge--choose)
    ("conversation.answer" . overlook-remote-bridge--answer-form)
    ("conversation.attach" . overlook-remote-bridge--attach)
    ("conversation.earlier" . overlook-remote-bridge--earlier)
    ("node.command" . overlook-remote-bridge--command)
    ("node.diff" . overlook-remote-bridge--diff)
    ("ping" . ignore))
  "Requests the daemon may send, each (METHOD . FUNCTION of the params).")

(defun overlook-remote-bridge--call (method params)
  "Result of request METHOD with PARAMS, a plist; nil means {}."
  (let ((function (cdr (assoc method overlook-remote-bridge--methods))))
    (unless function
      (overlook-remote-bridge--fail -32601 nil (format "Method not found: %s" method)))
    (funcall function params)))

;;; Mode

(defun overlook-remote-bridge--start ()
  "Follow the dashboard and agents, and connect to the daemon."
  (overlook-toggle-hooks t overlook-remote-bridge--hooks)
  (overlook-start-updates 'bridge)
  (setq overlook-remote-bridge--retry-delay nil
        overlook-remote-bridge--dashboard-dirty (float-time)
        overlook-remote-bridge--dirty t)
  (overlook-remote-bridge--set-state nil)
  (force-mode-line-update t)
  (overlook-remote-bridge--connect))

(defun overlook-remote-bridge--stop ()
  "Disconnect, stop following, and drop what was not sent."
  (overlook-toggle-hooks nil overlook-remote-bridge--hooks)
  (overlook-stop-updates 'bridge)
  (dolist (timer (list overlook-remote-bridge--retry-timer
                       (car overlook-remote-bridge--flush-timer)
                       overlook-remote-bridge--queue-timer))
    (when (timerp timer) (cancel-timer timer)))
  (let ((process overlook-remote-bridge--process))
    (overlook-remote-bridge--disconnected)
    (when process (delete-process process)))
  (dolist (buffer (overlook-agent-buffers))
    (with-current-buffer buffer
      (setq overlook-remote-bridge--queue nil
            overlook-remote-bridge--queue-error nil)))
  ;; Events go unrecorded while off, so a later connection reports the gap.
  (when overlook-remote-bridge--sent-dashboard
    (setq overlook-remote-bridge--lost (max 1 overlook-remote-bridge--lost)))
  (setq overlook-remote-bridge--retry-timer nil
        overlook-remote-bridge--flush-timer nil
        overlook-remote-bridge--queue-timer nil
        overlook-remote-bridge--events nil
        overlook-remote-bridge--event-totals (cons 0 0)
        overlook-remote-bridge--sent-dashboard nil
        overlook-remote-bridge--rows nil
        overlook-remote-bridge--dirty nil
        overlook-remote-bridge--dashboard-dirty nil)
  (clrhash overlook-remote-bridge--sent)
  (overlook-remote-bridge--set-state nil)
  (force-mode-line-update t))

;;; Address and token

(defcustom overlook-remote-bridge-token-file (locate-user-emacs-file "overlook-remote-token")
  "File holding the token the page must carry; overlook-remoted's -token-file."
  :type 'file
  :group 'overlook)

(defcustom overlook-remote-bridge-port 8766
  "Port overlook-remoted serves the page on, for `overlook-remote-bridge-url'."
  :type 'natnum
  :group 'overlook)

(defconst overlook-remote-bridge--tailscale-address
  "\\`100\\.\\(?:6[4-9]\\|[7-9][0-9]\\|1[01][0-9]\\|12[0-7]\\)\\."
  "Matches an address in 100.64.0.0/10, the range Tailscale assigns from.")

(defun overlook-remote-bridge--address ()
  "The IPv4 address a phone should open: Tailscale's, else an en interface's."
  (let ((addresses
         (seq-keep (pcase-lambda (`(,interface . ,address))
                     (let ((ip (format-network-address address t)))
                       (unless (string-match-p "\\`\\(?:127\\|169\\.254\\)\\." ip)
                         (cons interface ip))))
                   (network-interface-list nil 'ipv4))))
    (cdr (or (seq-find (lambda (entry)
                         (string-match-p overlook-remote-bridge--tailscale-address (cdr entry)))
                       addresses)
             (seq-find (lambda (entry) (string-prefix-p "en" (car entry))) addresses)
             (car addresses)))))

(defun overlook-remote-bridge--random-hex ()
  "64 hex digits from the system's random source, or nil where there is none."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary))
      (when (and (file-readable-p "/dev/urandom")
                 (eql 0 (ignore-errors (call-process "head" "/dev/urandom" t nil "-c" "32")))
                 (= (buffer-size) 32))
        (mapconcat (lambda (byte) (format "%02x" byte)) (buffer-string) "")))))

(defun overlook-remote-bridge-new-token ()
  "Replace the token, so pages holding the old one stop working; return it.
overlook-remoted rereads the file by itself."
  (interactive)
  (random t)
  (let ((token (or (overlook-remote-bridge--random-hex)
                   (secure-hash 'sha256 (format "%s %s %s %s" (random) (random)
                                                (current-time) (emacs-pid))))))
    (make-directory (file-name-directory (expand-file-name overlook-remote-bridge-token-file)) t)
    (with-file-modes #o600
      (with-temp-file overlook-remote-bridge-token-file (insert token "\n")))
    (when (called-interactively-p 'interactive)
      (message "New token; open the page again from `overlook-remote-bridge-url'"))
    token))

(defun overlook-remote-bridge--token ()
  "The page's token, made on first use."
  (if (file-exists-p overlook-remote-bridge-token-file)
      (with-temp-buffer
        (insert-file-contents overlook-remote-bridge-token-file)
        (string-trim (buffer-string)))
    (overlook-remote-bridge-new-token)))

;;;###autoload
(defun overlook-remote-bridge-url ()
  "Show the page's address, with its token, and copy it."
  (interactive)
  (let ((url (format "http://%s:%d/overlook/#%s"
                     (or (overlook-remote-bridge--address) "localhost")
                     overlook-remote-bridge-port (overlook-remote-bridge--token))))
    (kill-new url)
    (message "overlook remote, copied: %s" url)
    url))

;;;###autoload
(define-minor-mode overlook-remote-bridge-mode
  "Publish the dashboard and agents to overlook-remoted, and take its commands.
The daemon serves them to a phone; Emacs connects to its socket,
`overlook-remote-bridge-socket', and reconnects whenever the daemon
restarts.  The dashboard's mode line shows whether it is connected."
  :global t
  :group 'overlook
  (if overlook-remote-bridge-mode
      (overlook-remote-bridge--start)
    (overlook-remote-bridge--stop)))

(provide 'overlook-remote-bridge)
;;; overlook-remote-bridge.el ends here
