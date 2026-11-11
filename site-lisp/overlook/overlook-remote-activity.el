;;; overlook-remote-activity.el --- Agent activity and attachments for the browser -*- lexical-binding: t; -*-

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

;; Maintains prompt queues, agent snapshots, activity history and images.
;; Returns browser data without handling HTTP requests.

;;; Code:

(require 'overlook-remote-model)

(declare-function overlook-remote--wake "overlook-remote" ())

(defcustom overlook-remote-transcript-size 8000
  "How many characters of an agent's buffer, from its end, the page shows."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-remote-history 300
  "How many of each agent's latest prompts, replies and tool calls are kept."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-remote-diff-size 20000
  "How many characters of a diff the page shows."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-remote-image-size (* 20 1024 1024)
  "Largest image, in bytes, the page shows or takes from the phone."
  :type 'natnum
  :group 'overlook)

(defun overlook-remote--tail (buffer)
  "The last `overlook-remote-transcript-size' characters of BUFFER."
  (with-current-buffer buffer
    (buffer-substring-no-properties
     (max (point-min) (- (point-max) overlook-remote-transcript-size))
     (point-max))))

(defun overlook-remote--controls (buffer)
  "What agent BUFFER's `remote-controls' offers, or nil."
  (overlook-agent-call buffer 'remote-controls))

(defun overlook-remote--agent (buffer &optional detail)
  "Agent BUFFER as the page shows it.
With DETAIL, its last reply and the end of its transcript too."
  (let ((root (overlook-agent-get buffer 'root)))
    `(:id ,(buffer-name buffer)
      :agent ,(overlook-remote--text (overlook-agent-get buffer 'agent))
      :status ,(symbol-name (buffer-local-value 'overlook-agent-status buffer))
      :context ,(buffer-local-value 'overlook-agent-context buffer)
      :title ,(overlook-remote--text (overlook-agent-title buffer))
      :project ,(overlook-remote--text (ignore-errors (overlook-agent-project buffer)))
      :folder ,(if root (file-name-nondirectory (directory-file-name root)) "")
      :brief ,(overlook-remote--text (overlook-agent-brief buffer))
      :choices ,(overlook-remote--choices (overlook-agent-choices buffer))
      :queued ,(vconcat (buffer-local-value 'overlook-remote--queue buffer))
      :queueError ,(or (buffer-local-value 'overlook-remote--queue-error buffer) :null)
      ,@(when-let* ((controls (overlook-remote--controls buffer)))
          `(:controls (:slash ,(vconcat (plist-get controls :slash))
                       :steer ,(if (plist-get controls :steer) t :false)
                       :actions ,(vconcat (plist-get controls :actions)))))
      ,@(when detail
          `(:reply ,(overlook-remote--text (overlook-agent-reply buffer))
            :transcript ,(overlook-remote--tail buffer))))))

(defvar-local overlook-remote--queue nil
  "Prompts from the page waiting for this agent to take one, oldest first.")

(defvar-local overlook-remote--queue-error nil
  "Last queue submission error; blocks delivery until explicitly retried.")

(defvar overlook-remote--queue-timer nil
  "Timer sending queued prompts while some wait, or nil.")

(defun overlook-remote--prompt (buffer text)
  "Submit TEXT to agent BUFFER, or queue it while the agent is busy.
Return non-nil when it was queued."
  (unless (overlook-agent-get buffer 'submit)
    (user-error "%s cannot take a prompt" (buffer-name buffer)))
  (with-current-buffer buffer
    (if (and (null overlook-remote--queue) (overlook-agent-ready-p buffer))
        (progn (overlook-agent-submit buffer text) nil)
      (setq overlook-remote--queue (append overlook-remote--queue (list text)))
      (unless overlook-remote--queue-timer
        (setq overlook-remote--queue-timer (run-at-time 1 1 #'overlook-remote--send-queued)))
      (overlook-remote--wake)
      t)))

(defun overlook-remote--send-queued ()
  "Submit to each agent ready for it the first prompt queued for it.
Stop looking once no prompt is queued."
  (let ((waiting (seq-filter (lambda (buffer) (buffer-local-value 'overlook-remote--queue buffer))
                             (overlook-agent-buffers))))
    (dolist (buffer waiting)
      (when (and (not (buffer-local-value 'overlook-remote--queue-error buffer))
                 (overlook-agent-ready-p buffer))
        (with-current-buffer buffer
          (let ((text (car overlook-remote--queue)))
            (condition-case err
                (progn
                  (overlook-agent-submit buffer text)
                  (pop overlook-remote--queue))
              (error (setq overlook-remote--queue-error (error-message-string err))))))
        (overlook-remote--wake)))
    (unless (seq-some (lambda (buffer) (buffer-local-value 'overlook-remote--queue buffer)) waiting)
      (cancel-timer overlook-remote--queue-timer)
      (setq overlook-remote--queue-timer nil))))

(defun overlook-remote--unqueue (buffer text)
  "Take the first prompt TEXT out of agent BUFFER's queue."
  (with-current-buffer buffer
    (unless (member text overlook-remote--queue)
      (user-error "That prompt was sent already"))
    (setq overlook-remote--queue (cl-remove text overlook-remote--queue :count 1 :test #'equal)))
  (overlook-remote--clear-queue-error buffer))

(defun overlook-remote--clear-queue-error (buffer)
  "Let agent BUFFER's queue go on after an error."
  (with-current-buffer buffer (setq overlook-remote--queue-error nil))
  (overlook-remote--wake))

;;; Images

(defconst overlook-remote--image-types
  '(("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("webp" . "image/webp"))
  "Extensions of the images the page shows, with their types.")

(defconst overlook-remote--image-path-regexp
  (rx (or (seq "@\"" (group (+ (not (in "\"\n"))) "." (or "png" "jpg" "jpeg" "gif" "webp"))
               "\"")
          (seq (? (or "@" "file://"))
               (group (+ (not (in "][ \t\n\"'`()<>|,;" nonascii)))
                      "." (or "png" "jpg" "jpeg" "gif" "webp"))
               symbol-end)))
  "A path to an image in text: plain, file://, or an @ mention, maybe quoted.
Unquoted, it is ASCII, so that it ends where prose in other scripts begins.")

(defvar overlook-remote--images nil
  "Images the page may fetch, newest first, each (NUMBER FILE STAMP HASH).
STAMP is the file's size and modification time when it was numbered, HASH
its contents' SHA-1: one picture gets one number, a file rewritten a new one.")

(defvar overlook-remote--image-count 0
  "Number of the latest image in `overlook-remote--images'.")

(defvar overlook-remote--image-directory nil
  "Directory of the images that came as data, made on first use.")

(defun overlook-remote--image-mime (file)
  "Type of image FILE by its extension, or nil when it is no image."
  (cdr (assoc (downcase (or (file-name-extension file) "")) overlook-remote--image-types)))

(defun overlook-remote--image (file)
  "Number the page fetches image FILE by, or nil unless it is a readable image."
  (let* ((file (expand-file-name file))
         (attributes (file-attributes file))
         (stamp (and attributes (list (file-attribute-size attributes)
                                      (file-attribute-modification-time attributes)))))
    (when (and stamp
               (overlook-remote--image-mime file)
               (eq (file-attribute-type attributes) nil)
               (file-readable-p file)
               (<= (car stamp) overlook-remote-image-size))
      (or (car (seq-find (lambda (image) (and (equal (nth 1 image) file)
                                              (equal (nth 2 image) stamp)))
                         overlook-remote--images))
          (let ((hash (with-temp-buffer
                        (set-buffer-multibyte nil)
                        (insert-file-contents-literally file)
                        (secure-hash 'sha1 (current-buffer)))))
            (or (car (seq-find (lambda (image) (equal (nth 3 image) hash))
                               overlook-remote--images))
                (progn
                  (setq overlook-remote--image-count (1+ overlook-remote--image-count))
                  (push (list overlook-remote--image-count file stamp hash)
                        overlook-remote--images)
                  (setq overlook-remote--images (seq-take overlook-remote--images 500))
                  overlook-remote--image-count)))))))

(defun overlook-remote--image-data-p (data mime)
  "Non-nil when the bytes DATA begin as an image of type MIME does."
  (pcase mime
    ("image/png" (string-prefix-p "\x89PNG" data))
    ("image/jpeg" (string-prefix-p "\xff\xd8\xff" data))
    ("image/gif" (string-prefix-p "GIF8" data))
    ("image/webp" (and (string-prefix-p "RIFF" data)
                       (equal (substring data 8 (min 12 (length data))) "WEBP")))))

(defun overlook-remote--image-data (base64 mime)
  "Save image BASE64 of type MIME and return its file, or nil if it is none."
  (when-let* ((extension (car (rassoc mime overlook-remote--image-types)))
              (data (ignore-errors (base64-decode-string base64)))
              ((overlook-remote--image-data-p data mime)))
    (unless (and overlook-remote--image-directory
                 (file-directory-p overlook-remote--image-directory))
      (setq overlook-remote--image-directory (make-temp-file "overlook-remote-images" t)))
    (let ((file (expand-file-name (format "%s.%s" (secure-hash 'sha1 data) extension)
                                  overlook-remote--image-directory))
          (coding-system-for-write 'no-conversion))
      (unless (file-exists-p file)
        (write-region data nil file nil 'silent))
      file)))

(defun overlook-remote--image-files (text root)
  "The image files TEXT names that exist, relative ones under ROOT."
  (let ((case-fold-search t)
        (start 0)
        files)
    (while (string-match overlook-remote--image-path-regexp (or text "") start)
      (setq start (match-end 0))
      (let ((file (expand-file-name (url-unhex-string (or (match-string 1 text)
                                                          (match-string 2 text)))
                                    root)))
        (when (overlook-remote--image file)
          (push file files))))
    (delete-dups (nreverse files))))

;;; Activity

(defvar overlook-remote--seq 0
  "Number of the latest change to any agent's items.")

(defvar overlook-remote--epoch (format-time-string "%s%N")
  "Name of this Emacs session's run of `overlook-remote--seq'.")

(defvar-local overlook-remote--items nil
  "This agent's activity since `overlook-remote-mode' started, newest first.
Each item is a plist: :item its number, :seq the change that last
touched it, :type and the entries of the event that made it.  Pieces of
one reply make one item, and so do the updates of one tool call; a reply
keeps in :marks its text's length at each change, newest first.")

(defun overlook-remote--unified (file old new)
  "Unified diff of FILE from OLD to NEW text."
  (let ((coding-system-for-write 'utf-8)
        (coding-system-for-read 'utf-8)
        (a (make-temp-file "overlook-old"))
        (b (make-temp-file "overlook-new")))
    (unwind-protect
        (with-temp-buffer
          (with-temp-file a (insert old))
          (with-temp-file b (insert new))
          (call-process "diff" nil t nil "-u" "--label" file "--label" file a b)
          (buffer-string))
      (delete-file a)
      (delete-file b))))

(defun overlook-remote--cut (diff)
  "DIFF cut short to `overlook-remote-diff-size' characters."
  (truncate-string-to-width diff overlook-remote-diff-size nil nil "\n…"))

(defun overlook-remote--diff (diffs)
  "DIFFS, each (:file F :old OLD :new NEW), as one unified diff, cut short."
  (overlook-remote--cut
   (mapconcat (lambda (diff)
                (overlook-remote--unified (or (plist-get diff :file) "file")
                                          (or (plist-get diff :old) "")
                                          (or (plist-get diff :new) "")))
              diffs "")))

(defun overlook-remote--new-item (event)
  "A new item for EVENT, every entry the page reads present."
  (pcase (plist-get event :type)
    ('tool (list :type "tool" :id (plist-get event :id) :title "" :status "" :kind "" :diff ""
                 :files nil))
    ('text (list :type "text" :text ""))
    (type (list :type (symbol-name type) :text (or (plist-get event :text) "")))))

(defun overlook-remote--update (item event)
  "Bring ITEM up to date with EVENT, of the same reply or tool call."
  (pcase (plist-get event :type)
    ('text (plist-put item :text (concat (plist-get item :text) (plist-get event :text))))
    ('tool
     (dolist (key '(:title :status :kind))
       (when-let* ((value (plist-get event key)))
         (plist-put item key value)))
     (when (and (string-empty-p (plist-get item :diff)) (plist-get event :diffs))
       (plist-put item :diff (overlook-remote--diff (plist-get event :diffs))))))
  (when-let* ((files (append (seq-keep (lambda (image)
                                         (if (plist-get image :data)
                                             (overlook-remote--image-data
                                              (plist-get image :data) (plist-get image :mime))
                                           (plist-get image :file)))
                                       (plist-get event :images))
                             (overlook-remote--image-files (plist-get event :output)
                                                           default-directory))))
    (plist-put item :files (delete-dups (append (plist-get item :files) files)))))

(defun overlook-remote--present (item root after)
  "ITEM as the page reads it, with :images the numbers of the images it shows.
Relative paths in its text are under ROOT.  A reply a page knew at change
AFTER comes as the text it lacks, after :offset characters."
  (let ((offset (or (and after (<= (plist-get item :item) after)
                         (cdr (seq-find (lambda (mark) (<= (car mark) after))
                                        (plist-get item :marks))))
                    0))
        (images (delete-dups
                 (seq-keep #'overlook-remote--image
                           (append (plist-get item :files)
                                   (overlook-remote--image-files
                                    (concat (plist-get item :title) "\n" (plist-get item :text))
                                    root))))))
    (append (cl-loop for (key value) on item by #'cddr
                     unless (memq key '(:files :marks))
                     append (list key (if (eq key :text) (substring value offset) value)))
            (list :offset offset :images (vconcat images)))))

(defun overlook-remote--record (buffer event)
  "Add EVENT of agent BUFFER to its items, and wake the calls waiting for news."
  (with-current-buffer buffer
    (setq overlook-remote--seq (1+ overlook-remote--seq))
    (let ((item (pcase (plist-get event :type)
                  ('text (and (equal (plist-get (car overlook-remote--items) :type) "text")
                              (car overlook-remote--items)))
                  ('tool (seq-find (lambda (item)
                                     (and (equal (plist-get item :type) "tool")
                                          (equal (plist-get item :id) (plist-get event :id))))
                                   overlook-remote--items)))))
      (unless item
        (setq item (append (list :item overlook-remote--seq :seq 0)
                           (overlook-remote--new-item event)))
        (push item overlook-remote--items)
        (setq overlook-remote--items (seq-take overlook-remote--items overlook-remote-history)))
      (plist-put item :seq overlook-remote--seq)
      (overlook-remote--update item event)
      (when (equal (plist-get item :type) "text")
        (plist-put item :marks (cons (cons overlook-remote--seq (length (plist-get item :text)))
                                     (plist-get item :marks))))))
  (overlook-remote--wake))

(defun overlook-remote--state (buffer)
  "Agent BUFFER as the page shows it, and a hash telling when that changes."
  (let ((agent (overlook-remote--agent buffer)))
    (cons agent (secure-hash 'sha1 (json-serialize agent)))))

(defun overlook-remote--reset-p (after)
  "Non-nil when change AFTER is not one this Emacs made; nil AFTER is none."
  (or (null after) (> after overlook-remote--seq)))

(defun overlook-remote--news-p (buffer after known)
  "Non-nil when agent BUFFER has news for a page at change AFTER and state KNOWN.
Nil AFTER is a change of another Emacs session."
  (or (not (buffer-live-p buffer))
      (overlook-remote--reset-p after)
      (seq-some (lambda (item) (> (plist-get item :seq) after))
                (buffer-local-value 'overlook-remote--items buffer))
      (not (equal known (cdr (overlook-remote--state buffer))))))

(put 'overlook-remote--queue 'permanent-local t)

(put 'overlook-remote--queue-error 'permanent-local t)

(put 'overlook-remote--items 'permanent-local t)

(defun overlook-remote--news-data (buffer after)
  "Agent BUFFER's state and activity changed after AFTER, as browser data."
  (let ((reset (overlook-remote--reset-p after))
        (state (overlook-remote--state buffer)))
    `(:agent ,(car state) :known ,(cdr state) :seq ,overlook-remote--seq
      :epoch ,overlook-remote--epoch :reset ,(if reset t :false)
      :items ,(let ((root (or (overlook-agent-get buffer 'root) default-directory)))
                (vconcat
                 (mapcar (lambda (item)
                           (overlook-remote--present item root (and (not reset) after)))
                         (seq-filter (lambda (item)
                                       (or reset (> (plist-get item :seq) after)))
                                     (reverse (buffer-local-value 'overlook-remote--items
                                                                  buffer)))))))))

(provide 'overlook-remote-activity)
;;; overlook-remote-activity.el ends here
