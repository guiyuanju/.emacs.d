;;; overlook-remote-bridge-data.el --- Bridge payloads for overlook-remoted -*- lexical-binding: t; -*-

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

;; Turns dashboard rows, agent buffers and agent events into the plists
;; of the bridge protocol (remote/docs/bridge-protocol.md).  Pure data:
;; no connection, timers or hashing.

;;; Code:

(require 'overlook-data)
(require 'overlook-row)

(defcustom overlook-remote-bridge-transcript-size 8000
  "How many characters from the end of an agent's buffer `earlier' returns."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-remote-bridge-hidden-sections '("Keys")
  "Titles of dashboard sections the phone does not get.
Keys lists Emacs key bindings, which do nothing on a phone."
  :type '(repeat string)
  :group 'overlook)

(defconst overlook-remote-bridge--text-limit (* 1024 1024)
  "Most bytes of text one agent event carries.")

(defconst overlook-remote-bridge--output-limit (* 256 1024)
  "Most bytes of tool output one event carries.")

(defconst overlook-remote-bridge--diff-limit (* 2 1024 1024)
  "Largest old or new text of a diff entry that is sent.")

(defconst overlook-remote-bridge--statuses '("idle" "working" "waiting" "done" "failed")
  "Statuses a conversation may have on the wire.")

;;; Strings

(defconst overlook-remote-bridge--invalid
  (concat "[" (string #x3fff80) "-" (string #x3fffff)
          (string #xd800) "-" (string #xdfff) "]")
  "Matches characters with no UTF-8 encoding: raw bytes and surrogates.")

(defun overlook-remote-bridge--valid (string)
  "STRING with characters JSON cannot carry replaced by U+FFFD."
  (let ((string (if (and (not (multibyte-string-p string))
                         (string-match-p "[^\0-\177]" string))
                    (decode-coding-string string 'utf-8)
                  string)))
    (if (and (multibyte-string-p string)
             (string-match-p overlook-remote-bridge--invalid string))
        (replace-regexp-in-string overlook-remote-bridge--invalid "�" string t t)
      string)))

(defun overlook-remote-bridge--valid-tree (value)
  "VALUE, a payload, with every string made valid for JSON."
  (cond ((stringp value) (overlook-remote-bridge--valid value))
        ((vectorp value) (vconcat (mapcar #'overlook-remote-bridge--valid-tree value)))
        ((consp value) (cons (overlook-remote-bridge--valid-tree (car value))
                             (overlook-remote-bridge--valid-tree (cdr value))))
        (t value)))

(defun overlook-remote-bridge-json (payload)
  "PAYLOAD as a unibyte UTF-8 JSON string."
  (condition-case nil
      (json-serialize payload)
    ;; Rare, so the tree is only walked once serializing failed.
    (wrong-type-argument (json-serialize (overlook-remote-bridge--valid-tree payload)))))

(defun overlook-remote-bridge--text (value)
  "VALUE as a string without properties; nil gives \"\"."
  (cond ((null value) "")
        ((stringp value) (substring-no-properties value))
        ((eq value :null) "")
        (t (format "%s" value))))

(defun overlook-remote-bridge--put (key value)
  "(KEY VALUE) for a plist when VALUE is a non-empty string, else nil."
  (let ((text (and value (not (eq value :null)) (overlook-remote-bridge--text value))))
    (and text (not (string-empty-p text)) (list key text))))

(defun overlook-remote-bridge--bytes-cut (string limit)
  "STRING cut to at most LIMIT bytes of UTF-8."
  (if (<= (string-bytes string) limit)
      string
    (let ((end (min (length string) limit)))
      (while (> (string-bytes (substring string 0 end)) limit)
        (setq end (max 0 (min (1- end) (floor (* end limit) (string-bytes (substring string 0 end)))))))
      (substring string 0 end))))

(defun overlook-remote-bridge-timestamp (&optional time)
  "TIME, or now, as RFC 3339 UTC with milliseconds."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%3NZ" time t))

;;; Dashboard

(defun overlook-remote-bridge--legacy-row-data (row)
  "Plain text data for extension ROW without a data provider."
  (let (title subtitle)
    (dolist (segment (overlook-row-segments row))
      (pcase segment
        (`(:fit ,text . ,_) (push (overlook-remote-bridge--text text) subtitle))
        (`(:cell . ,_) nil)
        (_ (push (overlook-remote-bridge--text (overlook-segment-text segment)) title))))
    (list :kind (if (overlook-row-heading row) "group" "text")
          :title (string-trim (apply #'concat (nreverse title)))
          :subtitle (string-join (nreverse subtitle) " "))))

(defun overlook-remote-bridge--row-data (row)
  "Business data behind ROW."
  (or (overlook-data (overlook-row-id row))
      (run-hook-with-args-until-success 'overlook-row-data-functions row)
      (overlook-remote-bridge--legacy-row-data row)))

(defun overlook-remote-bridge--row-key (row data)
  "Key of ROW, whose business DATA is given, stable across redraws."
  (let ((resource (plist-get data :resourceId)))
    (if (and (stringp resource) (not (string-empty-p resource)))
        resource
      (overlook-data-id (overlook-row-key row)))))

(defun overlook-remote-bridge--count (value)
  "VALUE when it is a line count, else nil."
  (and (natnump value) value))

(defun overlook-remote-bridge--scalar (value)
  "VALUE when it is a number or non-empty string, else nil."
  (cond ((numberp value) value)
        ((and (stringp value) (not (string-empty-p value))) (substring-no-properties value))))

(defun overlook-remote-bridge--windows (windows)
  "Usage WINDOWS as UsageWindow plists, or nil."
  (when (and windows (not (eq windows :null)))
    (vconcat
     (mapcar (lambda (window)
               (let ((value (overlook-remote-bridge--scalar (plist-get window :value)))
                     (reset (overlook-remote-bridge--scalar (plist-get window :reset))))
                 `(:label ,(overlook-remote-bridge--text (plist-get window :label))
                   ,@(and value (list :value value))
                   ,@(and reset (list :reset reset)))))
             windows))))

(defun overlook-remote-bridge-choices (choices)
  "CHOICES, each (KEY LABEL . _), as Choice plists, or nil."
  (when choices
    (vconcat (mapcar (pcase-lambda (`(,key ,label . ,_))
                       (list :key (overlook-remote-bridge--text key)
                             :label (overlook-remote-bridge--text label)))
                     choices))))

(defun overlook-remote-bridge--commands (commands)
  "Row COMMANDS as Command plists, or nil."
  (when commands
    (vconcat
     (mapcar (lambda (command)
               `(:name ,(overlook-remote-bridge--text (plist-get command :name))
                 :label ,(overlook-remote-bridge--text (plist-get command :label))
                 ,@(overlook-remote-bridge--put :input (plist-get command :input))
                 ,@(and (plist-get command :options)
                        (list :options (vconcat (mapcar #'overlook-remote-bridge--text
                                                        (plist-get command :options)))))
                 ,@(and (plist-get command :confirm) '(:confirm t))))
             commands))))

(defun overlook-remote-bridge-node (row path rows siblings)
  "ROW as a Node plist; PATH is its parent's key path, newest key first.
ROW is recorded in hash table ROWS under its key path, a list, the key
told apart from earlier SIBLINGS' (a table of key counts) as the daemon
does, by a \"#N\" suffix."
  (let* ((data (overlook-remote-bridge--row-data row))
         (key (overlook-remote-bridge--row-key row data))
         (count (puthash key (1+ (gethash key siblings 0)) siblings))
         (path (cons (if (> count 1) (format "%s#%d" key count) key) path))
         (agent (pcase (overlook-row-id row) (`(agent . ,buffer) buffer)))
         (agent (and (overlook-agent-p agent) agent))
         (seen (make-hash-table :test #'equal))
         (children (mapcar (lambda (child) (overlook-remote-bridge-node child path rows seen))
                           (overlook-row-rows row)))
         (status (and (stringp (plist-get data :status)) (string-trim (plist-get data :status))))
         (added (overlook-remote-bridge--count (plist-get data :added)))
         (removed (overlook-remote-bridge--count (plist-get data :removed)))
         (windows (overlook-remote-bridge--windows (plist-get data :windows)))
         (choices (and agent (overlook-remote-bridge-choices (overlook-row-choices row))))
         (commands (overlook-remote-bridge--commands (overlook-row-commands row))))
    (puthash (reverse path) row rows)
    `(:key ,key
      :kind ,(let ((kind (overlook-remote-bridge--text (plist-get data :kind))))
               (if (string-empty-p kind) "text" kind))
      :title ,(overlook-remote-bridge--text (plist-get data :title))
      ,@(overlook-remote-bridge--put :subtitle (plist-get data :subtitle))
      ,@(overlook-remote-bridge--put :provider (plist-get data :provider))
      ,@(overlook-remote-bridge--put :status status)
      ,@(overlook-remote-bridge--put :account (plist-get data :account))
      ,@(overlook-remote-bridge--put :branch (plist-get data :branch))
      ,@(and added (list :added added))
      ,@(and removed (list :removed removed))
      ,@(overlook-remote-bridge--put :due (plist-get data :due))
      ,@(overlook-remote-bridge--put :persona (plist-get data :persona))
      ,@(overlook-remote-bridge--put :description (plist-get data :description))
      ,@(and windows (list :windows windows))
      ,@(and (overlook-row-heading row) '(:heading t))
      ,@(and (overlook-row-attention row) '(:attention t))
      ,@(and agent (list :conversation (overlook-data-agent-id agent)))
      ,@(and choices (list :choices choices))
      ,@(and commands (list :commands commands))
      ,@(and (overlook-row-diff row) '(:diff t))
      ,@(and children (list :children (vconcat children))))))

(defun overlook-remote-bridge-sections (model rows)
  "Sections of dashboard MODEL as a vector of Node plists, recording ROWS."
  (let ((seen (make-hash-table :test #'equal)))
    (vconcat (mapcar (lambda (row) (overlook-remote-bridge-node row nil rows seen))
                     (seq-remove (lambda (row)
                                   (pcase (overlook-row-id row)
                                     (`(section ,title) (member title overlook-remote-bridge-hidden-sections))))
                                 model)))))

;;; Conversations

(defun overlook-remote-bridge--form (form)
  "Question FORM as a Form plist, or nil."
  (when form
    (let ((text #'overlook-remote-bridge--text))
      `(:id ,(funcall text (plist-get form :id))
        :message ,(funcall text (plist-get form :message))
        ,@(and (eq (plist-get form :answerable) t) '(:answerable t))
        :fields
        ,(vconcat
          (mapcar
           (lambda (field)
             (let ((options (plist-get field :options)))
               `(:key ,(funcall text (plist-get field :key))
                 :type ,(let ((type (funcall text (plist-get field :type))))
                          (if (string-empty-p type) "unsupported" type))
                 :title ,(funcall text (plist-get field :title))
                 ,@(overlook-remote-bridge--put :description (plist-get field :description))
                 ,@(and (eq (plist-get field :required) t) '(:required t))
                 ,@(and options
                        (list :options
                              (vconcat
                               (mapcar (lambda (option)
                                         `(:value ,(funcall text (plist-get option :value))
                                           :title ,(funcall text (plist-get option :title))
                                           ,@(overlook-remote-bridge--put
                                              :description (plist-get option :description))))
                                       options))))
                 ,@(overlook-remote-bridge--put :other (plist-get field :other)))))
           (plist-get form :fields)))))))

(defun overlook-remote-bridge-controls (buffer)
  "What agent BUFFER's `remote-controls' offers, as a plist; :actions has \"close\"."
  (let ((controls (overlook-agent-call buffer 'remote-controls)))
    (plist-put (copy-sequence controls) :actions
               (delete-dups (append (mapcar #'overlook-remote-bridge--text
                                            (plist-get controls :actions))
                                    '("close"))))))

(defun overlook-remote-bridge--controls (controls)
  "CONTROLS, as `overlook-remote-bridge-controls' gives them, as a Controls plist."
  (let ((slash (plist-get controls :slash))
        (settings (plist-get controls :settings))
        (text #'overlook-remote-bridge--text))
    `(,@(and (plist-get controls :steer) '(:steer t))
      :actions ,(vconcat (plist-get controls :actions))
      ,@(and slash
             (list :slash (vconcat
                           (mapcar (lambda (command)
                                     `(:name ,(funcall text (plist-get command :name))
                                       ,@(overlook-remote-bridge--put
                                          :description (plist-get command :description))))
                                   slash))))
      ,@(and settings
             (list :settings
                   (vconcat
                    (mapcar (lambda (setting)
                              (list :id (funcall text (plist-get setting :id))
                                    :label (funcall text (plist-get setting :label))
                                    :value (funcall text (plist-get setting :value))
                                    :choices (vconcat
                                              (mapcar (lambda (choice)
                                                        (list :value (funcall text (plist-get choice :value))
                                                              :name (funcall text (plist-get choice :name))))
                                                      (plist-get setting :choices)))))
                            settings)))))))

(defun overlook-remote-bridge-root (buffer)
  "Absolute directory agent BUFFER works in."
  (expand-file-name (or (overlook-agent-get buffer 'root)
                        (buffer-local-value 'default-directory buffer)
                        "~/")))

(defun overlook-remote-bridge-conversation (buffer queue queue-error)
  "Agent BUFFER as a Conversation plist, with its remote QUEUE and QUEUE-ERROR.
QUEUE is a list of (:id ID :text TEXT), oldest first."
  (let* ((data (overlook-data (cons 'agent buffer)))
         (root (overlook-remote-bridge-root buffer))
         (status (symbol-name (buffer-local-value 'overlook-agent-status buffer)))
         (context (buffer-local-value 'overlook-agent-context buffer))
         (choices (overlook-remote-bridge-choices (overlook-agent-choices buffer)))
         (form (overlook-remote-bridge--form (overlook-agent-form buffer))))
    `(:id ,(overlook-data-agent-id buffer)
      :provider ,(let ((name (overlook-remote-bridge--text (overlook-agent-get buffer 'agent))))
                   (if (string-empty-p name) "agent" name))
      :title ,(overlook-remote-bridge--text (overlook-agent-title buffer))
      :status ,(if (member status overlook-remote-bridge--statuses) status "idle")
      ,@(overlook-remote-bridge--put :persona (plist-get data :persona))
      ,@(overlook-remote-bridge--put :description (plist-get data :description))
      ,@(overlook-remote-bridge--put :project (ignore-errors (overlook-agent-project buffer)))
      ,@(overlook-remote-bridge--put :folder (file-name-nondirectory (directory-file-name root)))
      :root ,root
      ,@(overlook-remote-bridge--put :brief (overlook-agent-brief buffer))
      ,@(and (numberp context) (list :context context))
      ,@(and choices (list :choices choices))
      ,@(and form (list :form form))
      ,@(and queue (list :queue (vconcat (mapcar (lambda (item)
                                                    (list :id (plist-get item :id)
                                                          :text (plist-get item :text)))
                                                  queue))))
      ,@(overlook-remote-bridge--put :queueError queue-error)
      :controls ,(overlook-remote-bridge--controls (overlook-remote-bridge-controls buffer))
      ,@(and (overlook-agent-get buffer 'attach) '(:canAttach t)))))

(defun overlook-remote-bridge-tail (buffer)
  "The last `overlook-remote-bridge-transcript-size' characters of BUFFER."
  (with-current-buffer buffer
    (buffer-substring-no-properties
     (max (point-min) (- (point-max) overlook-remote-bridge-transcript-size))
     (point-max))))

;;; Events

(defun overlook-remote-bridge--images (images root)
  "Event IMAGES as Image plists, relative files under ROOT, or nil."
  (when images
    (vconcat
     (delq nil
           (mapcar (lambda (image)
                     (cond ((plist-get image :data)
                            (list :data (overlook-remote-bridge--text (plist-get image :data))
                                  :mime (overlook-remote-bridge--text (plist-get image :mime))))
                           ((plist-get image :file)
                            (list :file (expand-file-name (plist-get image :file) root)))))
                   images)))))

(defun overlook-remote-bridge--diffs (diffs)
  "Tool DIFFS as Diff plists, leaving out entries too large to send, or nil."
  (let ((entries
         (delq nil
               (mapcar (lambda (diff)
                         (let ((old (overlook-remote-bridge--text (plist-get diff :old)))
                               (new (overlook-remote-bridge--text (plist-get diff :new))))
                           (unless (or (> (string-bytes old) overlook-remote-bridge--diff-limit)
                                       (> (string-bytes new) overlook-remote-bridge--diff-limit))
                             (list :file (overlook-remote-bridge--text (plist-get diff :file))
                                   :old old :new new))))
                       diffs))))
    (and entries (vconcat entries))))

(defun overlook-remote-bridge-events (buffer event &optional time)
  "EVENT of agent BUFFER at TIME as a list of Event plists.
Usually one; long text is split, and unknown types give none."
  (let* ((type (plist-get event :type))
         (head (list :conversation (overlook-data-agent-id buffer)
                     :at (overlook-remote-bridge-timestamp time)
                     :type (if (symbolp type) (symbol-name type) (format "%s" type))))
         (text (overlook-remote-bridge--text (plist-get event :text))))
    (pcase type
      ((or 'prompt 'error) (list (append head (list :text text))))
      ('end (list head))
      ('text
       (let ((images (overlook-remote-bridge--images (plist-get event :images)
                                                     (overlook-remote-bridge-root buffer)))
             (chunk (/ overlook-remote-bridge--text-limit 4))
             pieces)
         (if (<= (string-bytes text) overlook-remote-bridge--text-limit)
             (push text pieces)
           (while (> (length text) 0)
             (push (substring text 0 (min chunk (length text))) pieces)
             (setq text (substring text (min chunk (length text))))))
         (setq pieces (nreverse pieces))
         (let ((events (mapcar (lambda (piece) (append head (list :text piece))) pieces)))
           (when images
             (nconc (car (last events)) (list :images images)))
           events)))
      ('tool
       (let ((images (overlook-remote-bridge--images (plist-get event :images)
                                                     (overlook-remote-bridge-root buffer)))
             (diffs (overlook-remote-bridge--diffs (plist-get event :diffs)))
             (output (plist-get event :output)))
         (list `(,@head
                 :id ,(overlook-remote-bridge--text (plist-get event :id))
                 ,@(overlook-remote-bridge--put :title (plist-get event :title))
                 ,@(overlook-remote-bridge--put :status (plist-get event :status))
                 ,@(overlook-remote-bridge--put :kind (plist-get event :kind))
                 ,@(and diffs (list :diffs diffs))
                 ,@(overlook-remote-bridge--put
                    :output (and output (overlook-remote-bridge--bytes-cut
                                         (overlook-remote-bridge--text output)
                                         overlook-remote-bridge--output-limit)))
                 ,@(and images (list :images images)))))))))

(defun overlook-remote-bridge-event-size (event)
  "Approximate bytes EVENT takes, counting its strings."
  (let ((size 100))
    (named-let walk ((value event))
      (cond ((stringp value) (setq size (+ size (string-bytes value))))
            ((vectorp value) (mapc #'walk value))
            ((consp value) (walk (car value)) (walk (cdr value)))))
    size))

(defun overlook-remote-bridge-merge (older newer)
  "OLDER and NEWER adjacent events merged into one, or nil when they may not be."
  (when (equal (plist-get older :conversation) (plist-get newer :conversation))
    (pcase (list (plist-get older :type) (plist-get newer :type))
      ('("text" "text")
       (let ((text (concat (plist-get older :text) (plist-get newer :text)))
             (images (vconcat (plist-get older :images) (plist-get newer :images))))
         (when (<= (string-bytes text) overlook-remote-bridge--text-limit)
           `(:conversation ,(plist-get newer :conversation) :at ,(plist-get newer :at)
             :type "text" :text ,text
             ,@(and (> (length images) 0) (list :images images))))))
      ('("tool" "tool")
       (when (equal (plist-get older :id) (plist-get newer :id))
         (let ((merged (copy-sequence older))
               (images (vconcat (plist-get older :images) (plist-get newer :images))))
           (setq merged (plist-put merged :at (plist-get newer :at)))
           (dolist (key '(:title :status :kind :diffs :output))
             (when-let* ((value (plist-get newer key)))
               (setq merged (plist-put merged key value))))
           (if (> (length images) 0) (plist-put merged :images images) merged)))))))

(provide 'overlook-remote-bridge-data)
;;; overlook-remote-bridge-data.el ends here
