;;; courier-event.el --- Events for agents, from sources that watch the world -*- lexical-binding: t; -*-

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
;;              id, `none' for nobody, or nil for
;;              `courier-room-publish-fallback'
;;
;; `courier-event-emit' leaves out duplicates, passes the event through
;; `courier-event-filters', posts it in its room and logs what became of
;; it in `courier-event-log'.  A source pushing events, from a hook say,
;; calls it directly.  A source asking for them registers with
;; `courier-event-add-source' and is polled at its interval; its polls
;; run their commands through `courier-event-run', which keeps the
;; processes of all sources to `courier-event-max-processes' at once, and
;; may use `courier-event-first-look-p' to leave out what had happened
;; before it first looked.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'courier)
(require 'courier-room)

(defcustom courier-event-tick 10
  "Seconds between checks of which sources are due for a poll."
  :type 'number
  :group 'courier)

(defcustom courier-event-max-processes 4
  "Most processes the sources' polls run at once."
  :type 'natnum
  :group 'courier)

(defcustom courier-event-log-size 200
  "Most events kept in `courier-event-log'."
  :type 'natnum
  :group 'courier)

(defcustom courier-event-key-memory 5000
  "Most event keys remembered to leave out duplicates."
  :type 'natnum
  :group 'courier)

(defvar courier-event-filters nil
  "Functions of an event returning it, changed or not, or nil to drop it.
They run in order on each event that is not a duplicate.")

(defvar courier-event-log nil
  "Recent events, newest first, each with :time, :outcome and :reached.
The outcome is `delivered', `unclaimed', `dropped' or `duplicate'.")

(defvar courier-event--keys (make-hash-table :test #'equal)
  "Keys of the events seen, as (SOURCE . KEY).")

(defvar courier-event--key-order nil
  "The keys in `courier-event--keys', oldest first.")

(defvar courier-event--looked (make-hash-table :test #'equal)
  "Subjects the sources have looked at, as (SOURCE . SUBJECT).")

(defvar courier-event--sources nil
  "Alist of each registered source's name to a plist of :interval, :poll and :next.")

(defvar courier-event--timer nil)

(defvar courier-event--running 0
  "Processes of `courier-event-run' running.")

(defvar courier-event--waiting nil
  "Calls of `courier-event-run' waiting for a process, oldest first.")

;;; Emitting

(defun courier-event--name (source)
  "SOURCE as a string."
  (if (symbolp source) (symbol-name source) source))

(defun courier-event-remember (source key)
  "Note that the event of SOURCE and KEY was seen; return nil if it had been."
  (let ((entry (cons (courier-event--name source) key)))
    (unless (gethash entry courier-event--keys)
      (puthash entry t courier-event--keys)
      (setq courier-event--key-order (nconc courier-event--key-order (list entry)))
      (when (> (hash-table-count courier-event--keys) courier-event-key-memory)
        (remhash (pop courier-event--key-order) courier-event--keys))
      t)))

(defun courier-event--log (event outcome &optional reached)
  "Log EVENT with its OUTCOME and the ids it REACHED, and return the entry."
  (let ((entry (append (list :time (float-time) :outcome outcome :reached reached) event)))
    (push entry courier-event-log)
    (when (> (length courier-event-log) courier-event-log-size)
      (setcdr (nthcdr (1- courier-event-log-size) courier-event-log) nil))
    entry))

(defun courier-event-emit (event)
  "Post EVENT, a plist as the Commentary describes, in its thread's room.
Returns its entry in `courier-event-log'."
  (let ((source (courier-event--name (or (plist-get event :source) "event")))
        (key (plist-get event :key)))
    (setq event (plist-put (copy-sequence event) :source source))
    (if (and key (not (courier-event-remember source key)))
        (courier-event--log event 'duplicate)
      (if-let* ((kept (seq-reduce (lambda (event filter) (and event (funcall filter event)))
                                  courier-event-filters event)))
          (let* ((room (courier-room-name-for (or (plist-get kept :thread)
                                                  (user-error "Event without a thread"))))
                 (reached (courier-room-publish room source (plist-get kept :text)
                                                (plist-get kept :fallback))))
            (courier-event--log (plist-put kept :thread room)
                                (if reached 'delivered 'unclaimed) reached))
        (courier-event--log event 'dropped)))))

(defun courier-event-first-look-p (source subject)
  "Non-nil the first time SOURCE looks at SUBJECT, such as a branch."
  (let ((entry (cons (courier-event--name source) subject)))
    (unless (gethash entry courier-event--looked)
      (puthash entry t courier-event--looked))))

;;; Sources

(cl-defun courier-event-add-source (name &key interval poll)
  "Poll source NAME by calling POLL, of no arguments, every INTERVAL seconds.
The first poll comes INTERVAL seconds from now."
  (setf (alist-get name courier-event--sources nil nil #'equal)
        (list :interval interval :poll poll :next (+ (float-time) interval)))
  (courier-event--start-timer))

(defun courier-event-remove-source (name)
  "Stop polling source NAME."
  (setq courier-event--sources (assoc-delete-all name courier-event--sources))
  (courier-event--start-timer))

(defun courier-event--start-timer ()
  "Run the polling timer while some source is registered."
  (when (timerp courier-event--timer) (cancel-timer courier-event--timer))
  (setq courier-event--timer
        (and courier-event--sources
             (run-with-timer courier-event-tick courier-event-tick #'courier-event--tick))))

(defun courier-event--tick ()
  "Poll the sources that are due."
  (let ((now (float-time)))
    (pcase-dolist (`(,name . ,source) courier-event--sources)
      (when (>= now (plist-get source :next))
        (plist-put source :next (+ now (plist-get source :interval)))
        (condition-case err
            (funcall (plist-get source :poll))
          (error (message "courier: polling %s failed: %s" name (error-message-string err))))))))

(defun courier-event-poll (name)
  "Poll source NAME now."
  (interactive (list (intern (completing-read "Poll source: "
                                              (mapcar #'car courier-event--sources) nil t))))
  (funcall (plist-get (or (alist-get name courier-event--sources nil nil #'equal)
                          (user-error "No source %s" name))
                      :poll)))

;;; Processes

(defun courier-event-run (dir command then)
  "Run COMMAND in DIR, calling THEN with its output, or nil when it fails.
Waits while `courier-event-max-processes' run already."
  (if (>= courier-event--running courier-event-max-processes)
      (setq courier-event--waiting (nconc courier-event--waiting (list (list dir command then))))
    (cl-incf courier-event--running)
    (courier-event--process dir command
                            (lambda (text)
                              (cl-decf courier-event--running)
                              (when-let* ((next (pop courier-event--waiting)))
                                (apply #'courier-event-run next))
                              (funcall then text)))))

(defun courier-event--process (dir command then)
  "Start COMMAND in DIR, calling THEN with its output, or nil when it fails."
  (let ((output (generate-new-buffer " *courier-event*"))
        (errors (generate-new-buffer " *courier-event-errors*"))
        (default-directory (file-name-as-directory dir)))
    (condition-case nil
        (make-process
         :name "courier-event" :buffer output :stderr errors :noquery t
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

(defun courier-event-format (entry)
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

(defun courier-event-cli (from args)
  "Run the event command ARGS for agent FROM and return its output."
  (pcase args
    ((and `("emit" . ,rest)
          (let `(,options ,thread ,text)
            (courier-options rest '("--from" "--key" "--fallback"))))
     (let* ((fallback (cdr (assoc "--fallback" options)))
            (entry (courier-event-emit
                    (list :source (or (cdr (assoc "--from" options)) from "event")
                          :thread thread :text text
                          :key (cdr (assoc "--key" options))
                          :fallback (if (equal fallback "none") 'none fallback)))))
       (pcase (plist-get entry :outcome)
         ('delivered (format "Posted in #%s; it reached %s." (plist-get entry :thread)
                             (string-join (plist-get entry :reached) ", ")))
         ('unclaimed (format "Posted in #%s; nobody follows it." (plist-get entry :thread)))
         (outcome (format "Not posted: %s." outcome)))))
    ((or `("log") `("log" ,n))
     (courier-or-empty (mapconcat #'courier-event-format
                    (reverse (take (if n (string-to-number n) 20) courier-event-log))
                    "\n")
         "No events yet."))
    (_ (user-error "Usage: courier event emit [--from SOURCE] [--key KEY] \
[--fallback ID|none] THREAD MESSAGE | log [N]"))))

(provide 'courier-event)
;;; courier-event.el ends here
