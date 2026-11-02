;;; overlook-courier-event.el --- Events for agents, from sources that watch the world -*- lexical-binding: t; -*-

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

;; An event is something an agent may have to act on, such as a CI run
;; that failed.  It is a plist:
;;
;;   :source    who saw it, such as "ci"
;;   :thread    the stream it belongs to, such as a branch; its room is
;;              named after it, and the agents following the room get it
;;   :text      what an agent is told
;;   :key       optional; an event of the same source and key again is
;;              a duplicate, and is left out
;;   :fallback  who hears of it when no agent follows the room: an agent
;;              id, "none" for nobody, or nil for
;;              `overlook-courier-room-publish-fallback'
;;
;; `overlook-courier-event-emit' leaves out duplicates, passes the event through
;; `overlook-courier-event-filters', posts it in its room and logs what became of
;; it in `overlook-courier-event-log'.  A source pushing events, from a hook say,
;; calls it directly.  A source asking for them registers with
;; `overlook-courier-event-add-source' and is polled at its interval; its polls
;; run their commands through `overlook-courier-event-run', which keeps the
;; processes of all sources to `overlook-courier-event-max-processes' at once, and
;; may use `overlook-courier-event-first-look-p' to leave out what had happened
;; before it first looked.  Sources are named by strings.

;;; Code:

(require 'cl-lib)
(require 'ring)
(require 'seq)
(require 'overlook-courier)
(require 'overlook-courier-room)

(defcustom overlook-courier-event-tick 10
  "Seconds between checks of which sources are due for a poll."
  :type 'number
  :group 'overlook-courier)

(defcustom overlook-courier-event-max-processes 4
  "Most processes the sources' polls run at once."
  :type 'natnum
  :group 'overlook-courier)

(defcustom overlook-courier-event-log-size 200
  "Most events kept in `overlook-courier-event-log'."
  :type 'natnum
  :group 'overlook-courier)

(defcustom overlook-courier-event-key-memory 5000
  "Most event keys remembered to leave out duplicates."
  :type 'natnum
  :group 'overlook-courier)

(defvar overlook-courier-event-filters nil
  "Functions of an event returning it, changed or not, or nil to drop it.
They run in order on each event that is not a duplicate.")

(defvar overlook-courier-event-log nil
  "Recent events, newest first, each with :time, :outcome and :reached.
The outcome is `delivered', `unclaimed', `dropped' or `duplicate'.")

(defvar overlook-courier-event--keys (make-hash-table :test #'equal)
  "Keys of the events seen, as (SOURCE . KEY).")

(defvar overlook-courier-event--key-order nil
  "Ring of the keys in `overlook-courier-event--keys', to forget the oldest.")

(defvar overlook-courier-event--looked (make-hash-table :test #'equal)
  "Subjects the sources have looked at, as (SOURCE . SUBJECT).")

(defvar overlook-courier-event--sources nil
  "Alist of each registered source's name to a plist of :interval, :poll and :next.")

(defvar overlook-courier-event--timer nil)

(defvar overlook-courier-event--running 0
  "Processes of `overlook-courier-event-run' running.")

(defvar overlook-courier-event--waiting nil
  "Calls of `overlook-courier-event-run' waiting for a process, oldest first.")

;;; Emitting

(defun overlook-courier-event-remember (source key)
  "Note that the event of SOURCE and KEY was seen; return nil if it had been."
  (let ((entry (cons source key)))
    (unless (gethash entry overlook-courier-event--keys)
      (unless overlook-courier-event--key-order
        (setq overlook-courier-event--key-order (make-ring overlook-courier-event-key-memory)))
      (when (= (ring-length overlook-courier-event--key-order) (ring-size overlook-courier-event--key-order))
        (remhash (ring-remove overlook-courier-event--key-order) overlook-courier-event--keys))
      (ring-insert overlook-courier-event--key-order entry)
      (puthash entry t overlook-courier-event--keys))))

(defun overlook-courier-event--log (event outcome &optional reached)
  "Log EVENT with its OUTCOME and the ids it REACHED, and return the entry."
  (let ((entry (append (list :time (float-time) :outcome outcome :reached reached) event)))
    (setq overlook-courier-event-log (ntake overlook-courier-event-log-size (cons entry overlook-courier-event-log)))
    entry))

(defun overlook-courier-event-emit (event)
  "Post EVENT, a plist as the Commentary describes, in its thread's room.
Returns its entry in `overlook-courier-event-log'."
  (let ((source (or (plist-get event :source) "event"))
        (key (plist-get event :key)))
    (setq event (plist-put (copy-sequence event) :source source))
    (if (and key (not (overlook-courier-event-remember source key)))
        (overlook-courier-event--log event 'duplicate)
      (if-let* ((kept (seq-reduce (lambda (event filter) (and event (funcall filter event)))
                                  overlook-courier-event-filters event)))
          (let* ((room (overlook-courier-room-name-for (or (plist-get kept :thread)
                                                  (user-error "Event without a thread"))))
                 (fallback (plist-get kept :fallback))
                 (reached (overlook-courier-room-publish room source (plist-get kept :text)
                                                (cond ((equal fallback "none") nil)
                                                      (fallback)
                                                      (t overlook-courier-room-publish-fallback)))))
            (overlook-courier-event--log (plist-put kept :thread room)
                                (if reached 'delivered 'unclaimed) reached))
        (overlook-courier-event--log event 'dropped)))))

(defun overlook-courier-event-first-look-p (source subject)
  "Non-nil the first time SOURCE looks at SUBJECT, such as a branch."
  (let ((entry (cons source subject)))
    (unless (gethash entry overlook-courier-event--looked)
      (puthash entry t overlook-courier-event--looked))))

;;; Sources

(cl-defun overlook-courier-event-add-source (name &key interval poll)
  "Poll source NAME by calling POLL, of no arguments, every INTERVAL seconds.
The first poll comes INTERVAL seconds from now."
  (setf (alist-get name overlook-courier-event--sources nil nil #'equal)
        (list :interval interval :poll poll :next (+ (float-time) interval)))
  (overlook-courier-event--start-timer))

(defun overlook-courier-event-remove-source (name)
  "Stop polling source NAME."
  (setq overlook-courier-event--sources (assoc-delete-all name overlook-courier-event--sources))
  (overlook-courier-event--start-timer))

(defun overlook-courier-event--start-timer ()
  "Run the polling timer while some source is registered."
  (when (timerp overlook-courier-event--timer) (cancel-timer overlook-courier-event--timer))
  (setq overlook-courier-event--timer
        (and overlook-courier-event--sources
             (run-with-timer overlook-courier-event-tick overlook-courier-event-tick #'overlook-courier-event--tick))))

(defun overlook-courier-event--tick ()
  "Poll the sources that are due."
  (let ((now (float-time)))
    (pcase-dolist (`(,name . ,source) overlook-courier-event--sources)
      (when (>= now (plist-get source :next))
        (plist-put source :next (+ now (plist-get source :interval)))
        (condition-case err
            (funcall (plist-get source :poll))
          (error (message "courier: polling %s failed: %s" name (error-message-string err))))))))

;;; Processes

(defun overlook-courier-event-run (dir command then)
  "Run COMMAND in DIR, calling THEN with its output, or nil when it fails.
Waits while `overlook-courier-event-max-processes' run already."
  (if (>= overlook-courier-event--running overlook-courier-event-max-processes)
      (setq overlook-courier-event--waiting (nconc overlook-courier-event--waiting (list (list dir command then))))
    (cl-incf overlook-courier-event--running)
    (overlook-courier-event--process dir command
                            (lambda (text)
                              (cl-decf overlook-courier-event--running)
                              (when-let* ((next (pop overlook-courier-event--waiting)))
                                (apply #'overlook-courier-event-run next))
                              (funcall then text)))))

(defun overlook-courier-event--process (dir command then)
  "Start COMMAND in DIR, calling THEN with its output, or nil when it fails."
  (let ((output (generate-new-buffer " *courier-event*"))
        (errors (generate-new-buffer " *courier-event-errors*"))
        (default-directory (file-name-as-directory dir)))
    (condition-case nil
        (make-process
         :name "overlook-courier-event" :buffer output :stderr errors :noquery t
         :connection-type 'pipe :command command
         :sentinel (lambda (process _event)
                     (unless (process-live-p process)
                       (let ((text (and (eq (process-exit-status process) 0)
                                        (with-current-buffer output (buffer-string)))))
                         (kill-buffer output)
                         (kill-buffer errors)
                         (funcall then text)))))
      (error (kill-buffer output) (kill-buffer errors) (funcall then nil)))))

;;; Calls from agents

(defun overlook-courier-event-format (entry)
  "Log ENTRY as one line."
  (format "%s  %-9s %s #%s%s  %s"
          (format-time-string "%m-%d %H:%M" (plist-get entry :time))
          (plist-get entry :outcome)
          (plist-get entry :source)
          (or (plist-get entry :thread) "-")
          (if-let* ((reached (plist-get entry :reached)))
              (concat " → " (string-join reached ", "))
            "")
          (car (split-string (or (plist-get entry :text) "") "\n"))))

(defun overlook-courier-event-cli (from args)
  "Run the event command ARGS for agent FROM and return its output."
  (pcase args
    ((and `("emit" . ,rest)
          (let `(,options ,thread ,text)
            (overlook-courier-options rest '("--from" "--key" "--fallback"))))
     (let ((entry (overlook-courier-event-emit
                   (list :source (or (overlook-courier-option "--from" options) from "event")
                         :thread thread :text text
                         :key (overlook-courier-option "--key" options)
                         :fallback (overlook-courier-option "--fallback" options)))))
       (pcase (plist-get entry :outcome)
         ('delivered (format "Posted in #%s; it reached %s." (plist-get entry :thread)
                             (string-join (plist-get entry :reached) ", ")))
         ('unclaimed (format "Posted in #%s; nobody follows it." (plist-get entry :thread)))
         (outcome (format "Not posted: %s." outcome)))))
    ((or `("log") `("log" ,n))
     (overlook-courier-or-empty (mapconcat #'overlook-courier-event-format
                    (reverse (take (if n (string-to-number n) 20) overlook-courier-event-log))
                    "\n")
         "No events yet."))
    (_ (user-error "Usage: courier event emit [--from SOURCE] [--key KEY] \
[--fallback ID|none] THREAD MESSAGE | log [N]"))))

(provide 'overlook-courier-event)
;;; overlook-courier-event.el ends here
