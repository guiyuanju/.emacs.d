;;; overlook-remote.el --- Steer the agents from a phone on the local network -*- lexical-binding: t; -*-

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

;; `overlook-remote-mode' serves a page for a phone's browser: the
;; dashboard, drawn from the same model as in Emacs, with the answers
;; its agents wait for; and for each agent, what it is doing, its
;; replies and a box to prompt it.  It runs on simple-httpd,
;; whose single server it takes over while on.  It listens on this
;; machine only until `overlook-remote-host' is set to "0.0.0.0", which
;; serves the local network.
;;
;; The page and its scripts hold nothing; its calls under /overlook/api/
;; carry the token kept in `overlook-remote-token-file'.  `overlook-remote-url'
;; gives the address with the token after #, which the page stores and
;; strips.  Replies show as markdown, through marked, and DOMPurify strips
;; what could run in the page and so get at the token.
;; The calls travel as plain HTTP, so anyone watching the network can read
;; the token: serve only a network you trust.

;;; Code:

(require 'cl-lib)
(require 'simple-httpd)
(require 'url-util)
(require 'overlook-agent)

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

(defcustom overlook-remote-transcript-size 8000
  "How many characters of an agent's buffer, from its end, the page shows."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-remote-history 300
  "How many of each agent's latest prompts, replies and tool calls are kept."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-remote-wait 25
  "Seconds the page's call for news is held open while nothing happens."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-remote-diff-size 20000
  "How many characters of a tool call's diff the page shows."
  :type 'natnum
  :group 'overlook)

(defcustom overlook-remote-image-size (* 20 1024 1024)
  "Largest image, in bytes, the page shows or takes from the phone."
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
    ("/vendor/purify.js" "vendor/purify.js" "text/javascript"))
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

(defun overlook-remote--agent-buffer (id)
  "The agent buffer named ID."
  (let ((buffer (and (stringp id) (get-buffer id))))
    (if (overlook-agent-p buffer) buffer (user-error "No agent %s" id))))

(defun overlook-remote--text (text)
  "TEXT without properties, or an empty string for nil."
  (if text (substring-no-properties text) ""))

(defun overlook-remote--tail (buffer)
  "The last `overlook-remote-transcript-size' characters of BUFFER."
  (with-current-buffer buffer
    (buffer-substring-no-properties
     (max (point-min) (- (point-max) overlook-remote-transcript-size))
     (point-max))))

(defun overlook-remote--choices (choices)
  "CHOICES an agent offers, as the page shows them."
  (vconcat (mapcar (pcase-lambda (`(,key ,label . ,_))
                     `(:key ,key :label ,(overlook-remote--text label)))
                   choices)))

(defun overlook-remote--agent (buffer &optional detail)
  "Agent BUFFER as the page shows it.
With DETAIL, its last reply and the end of its transcript too."
  (let ((root (overlook-agent-get buffer 'root)))
    `(:id ,(buffer-name buffer)
      :agent ,(overlook-remote--text (overlook-agent-get buffer 'agent))
      :status ,(symbol-name (buffer-local-value 'overlook-agent-status buffer))
      :title ,(overlook-remote--text (overlook-agent--title buffer))
      :perspective ,(overlook-remote--text (ignore-errors (overlook-agent-perspective buffer)))
      :project ,(if root (file-name-nondirectory (directory-file-name root)) "")
      :brief ,(overlook-remote--text (overlook-agent--brief buffer))
      :choices ,(overlook-remote--choices (overlook-agent--choices buffer))
      ,@(when detail
          `(:reply ,(overlook-remote--text (overlook-agent--reply buffer))
            :transcript ,(overlook-remote--tail buffer))))))

(defun overlook-remote--prompt (buffer text)
  "Submit TEXT to agent BUFFER, unless it cannot take a prompt now."
  (let ((submit (or (overlook-agent-get buffer 'submit)
                    (user-error "%s cannot take a prompt" (buffer-name buffer))))
        (ready (overlook-agent-get buffer 'ready)))
    (with-current-buffer buffer
      (unless (if ready (funcall ready)
                (not (memq overlook-agent-status '(working waiting))))
        (user-error "%s is busy, or has text in its input" (buffer-name buffer)))
      (funcall submit text))))

;;; Dashboard

(defun overlook-remote--faces (face)
  "Names of FACE, a face or list of faces, and of those they inherit from."
  (let ((todo (list face))
        names)
    (while todo
      (let ((face (pop todo)))
        (cond ((and (symbolp face) face (not (keywordp face)) (facep face)
                    (not (member (symbol-name face) names)))
               (push (symbol-name face) names)
               (push (face-attribute face :inherit nil) todo))
              ((keywordp (car-safe face)) (push (plist-get face :inherit) todo))
              ((proper-list-p face) (setq todo (append face todo))))))
    (nreverse names)))

(defun overlook-remote--runs (row text spans)
  "SPANS, newest first, with TEXT's runs of one look and ROW's look added.
A string with an `overlook-alt' shows that instead, like an icon's name."
  (let ((text (copy-sequence text))
        (start 0))
    (overlook--row-look row text 0 (length text))
    (while (< start (length text))
      (let* ((alt (get-text-property start 'overlook-alt text))
             (end (if alt
                      (next-single-property-change start 'overlook-alt text (length text))
                    (next-property-change start text (length text))))
             (faces (vconcat (overlook-remote--faces (get-text-property start 'face text))))
             (piece (or alt (substring-no-properties text start end)))
             (last (car spans)))
        (if (and last (not (plist-get last :right)) (not (plist-get last :wrap))
                 (equal (plist-get last :faces) faces))
            (plist-put last :text (concat (plist-get last :text) piece))
          (push (list :text piece :faces faces) spans))
        (setq start end)))
    spans))

(defun overlook-remote--spans (row)
  "ROW's content as runs of one look, each (:text T :faces NAMES), in order.
An empty run marked :right starts what is aligned to the right edge; a
run (:wrap PIECES :gap N) holds pieces, each a vector of runs, that
wrap to lines starting where the first did."
  (let (spans)
    (dolist (segment (overlook-row-segments row))
      (pcase segment
        (`(:right ,text . ,_)
         (unless (string-blank-p text)
           (push (list :text "" :faces [] :right t) spans)
           (setq spans (overlook-remote--runs row text spans))))
        (`(:wrap ,pieces . ,_)
         (push (list :wrap (vconcat (mapcar (lambda (piece)
                                              (vconcat (nreverse
                                                        (overlook-remote--runs row piece nil))))
                                            pieces))
                     :gap (or (plist-get segment :gap) 1))
               spans))
        (_ (let ((text (overlook--segment segment "" nil)))
             (setq spans (overlook-remote--runs
                          row (if spans text (string-trim-left text)) spans))))))
    (vconcat (nreverse spans))))

(defun overlook-remote--node (row parent)
  "ROW of the dashboard's model as the page shows it, under the node of id PARENT.
An agent's row names it in :agent and gives the answers it offers in
:choices."
  (let* ((value (overlook-row-key row))
         (id (substring (secure-hash 'sha1 (concat parent
                                                   (let ((print-length nil) (print-level nil))
                                                     (prin1-to-string value))))
                        0 16))
         (agent (pcase (overlook-row-id row) (`(agent . ,buffer) buffer))))
    `(:id ,id
      :spans ,(overlook-remote--spans row)
      ,@(and (overlook-row-heading row) '(:heading t))
      ,@(and (overlook-row-attention row) '(:attention t))
      ,@(and (overlook-row-folded row) '(:folded t))
      ,@(and (overlook-agent-p agent)
             `(:agent ,(buffer-name agent)
               :choices ,(overlook-remote--choices (overlook-row-choices row))))
      :children ,(vconcat (mapcar (lambda (child) (overlook-remote--node child id))
                                  (overlook-row-rows row))))))

(defvar overlook-remote--dashboard nil
  "The model the page's dashboard was last made of, and that dashboard.
As (MODEL SECTIONS . HASH).")

(defvar overlook-remote--model nil
  "A cell holding the model the calls answered together share, or nil.")

(defmacro overlook-remote--together (&rest body)
  "Run BODY, the calls it answers sharing one model."
  (declare (indent 0))
  `(let ((overlook-remote--model (list nil))) ,@body))

(defun overlook-remote--model ()
  "The dashboard's model: the live dashboard's while fresh, else a new one.
Calls answered in one `overlook-remote--together' share a new one."
  (if (overlook-live-p)
      (overlook-latest-model)
    (if overlook-remote--model
        (with-memoization (car overlook-remote--model) (overlook-model))
      (overlook-model))))

(defun overlook-remote--dashboard ()
  "The dashboard as the page shows it, and a hash telling when that changes.
Made once per model `overlook-remote--model' gives."
  (let ((model (overlook-remote--model)))
    (unless (eq model (car overlook-remote--dashboard))
      (let ((sections (vconcat (mapcar (lambda (row) (overlook-remote--node row ""))
                                       model))))
        (setq overlook-remote--dashboard
              (cons model (cons sections (secure-hash 'sha1 (json-serialize sections)))))))
    (cdr overlook-remote--dashboard)))

(defun overlook-remote--dashboard-call (known)
  "A call for the dashboard from a page knowing state KNOWN.
As (NEWS-P . ANSWER), what `overlook-remote--hold' takes.  A page
knowing it waits for the live dashboard to redraw after a change, as
the redraw gathers the model the page then shares."
  (cons (lambda ()
          (and (or (null known) (not (overlook-live-p)) (overlook-model-fresh-p))
               (not (equal known (cdr (overlook-remote--dashboard))))))
        (lambda ()
          (let ((dashboard (overlook-remote--dashboard)))
            (overlook-remote--json 200 `(:sections ,(car dashboard) :known ,(cdr dashboard)))))))

;;; Images

(defconst overlook-remote--image-types
  '(("png" . "image/png") ("jpg" . "image/jpeg") ("jpeg" . "image/jpeg")
    ("gif" . "image/gif") ("webp" . "image/webp"))
  "Extensions of the images the page shows, with their types.")

(defconst overlook-remote--image-path-regexp
  (rx (or (seq "@\"" (group (+ (not (any "\"\n"))) "." (or "png" "jpg" "jpeg" "gif" "webp"))
               "\"")
          (seq (? (or "@" "file://"))
               (group (+ (not (any "][ \t\n\"'`()<>|,;" nonascii)))
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

(defvar-local overlook-remote--items nil
  "This agent's activity since `overlook-remote-mode' started, newest first.
Each item is a plist: :item its number, :seq the change that last
touched it, :type and the entries of the event that made it.  Pieces of
one reply make one item, and so do the updates of one tool call.")
(put 'overlook-remote--items 'permanent-local t)

(defvar overlook-remote--waiting nil
  "Calls for news held open, each (PROCESS CALL TIMER).
CALL is (NEWS-P . ANSWER): NEWS-P tells whether it has news, ANSWER
gives the response.")

(defvar overlook-remote--wake-timer nil
  "Timer answering the calls for news that have some, or nil.")

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

(defun overlook-remote--diff (diffs)
  "DIFFS, each (:file F :old OLD :new NEW), as one unified diff, cut short."
  (truncate-string-to-width
   (mapconcat (lambda (diff)
                (overlook-remote--unified (or (plist-get diff :file) "file")
                                          (or (plist-get diff :old) "")
                                          (or (plist-get diff :new) "")))
              diffs "")
   overlook-remote-diff-size nil nil "\n…"))

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
       (plist-put item :diff (overlook-remote--diff (plist-get event :diffs))))
     (when-let* ((files (append (seq-keep (lambda (image)
                                            (if (plist-get image :data)
                                                (overlook-remote--image-data
                                                 (plist-get image :data) (plist-get image :mime))
                                              (plist-get image :file)))
                                          (plist-get event :images))
                                (overlook-remote--image-files (plist-get event :output)
                                                              default-directory))))
       (plist-put item :files (delete-dups (append (plist-get item :files) files)))))))

(defun overlook-remote--present (item root)
  "ITEM as the page reads it, with :images the numbers of the images it shows.
Relative paths in its text are under ROOT."
  (let ((images (delete-dups
                 (seq-keep #'overlook-remote--image
                           (append (plist-get item :files)
                                   (overlook-remote--image-files
                                    (concat (plist-get item :title) "\n" (plist-get item :text))
                                    root))))))
    (append (cl-loop for (key value) on item by #'cddr
                     unless (eq key :files) append (list key value))
            (list :images (vconcat images)))))

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
      (overlook-remote--update item event)))
  (overlook-remote--wake))

(defun overlook-remote--state (buffer)
  "Agent BUFFER as the page shows it, and a hash telling when that changes."
  (let ((agent (overlook-remote--agent buffer)))
    (cons agent (secure-hash 'sha1 (json-serialize agent)))))

(defun overlook-remote--news (buffer after)
  "Agent BUFFER's state and its items changed after change AFTER.
After a change Emacs never made, as when it restarted, all its items,
marked :reset."
  (cond
   ((not (buffer-live-p buffer))
    (overlook-remote--json 409 '(:error "The agent is gone")))
   (t
    (let ((reset (> after overlook-remote--seq))
          (state (overlook-remote--state buffer)))
      (overlook-remote--json
       200 `(:agent ,(car state) :known ,(cdr state) :seq ,overlook-remote--seq
             :reset ,(if reset t :false)
             :items ,(let ((root (or (overlook-agent-get buffer 'root) default-directory)))
                       (vconcat
                        (mapcar (lambda (item) (overlook-remote--present item root))
                                (seq-filter (lambda (item)
                                              (or reset (> (plist-get item :seq) after)))
                                            (reverse (buffer-local-value 'overlook-remote--items
                                                                         buffer))))))))))))

(defun overlook-remote--news-p (buffer after known)
  "Non-nil when agent BUFFER has news for a page at change AFTER and state KNOWN."
  (or (not (buffer-live-p buffer))
      (> after overlook-remote--seq)
      (seq-some (lambda (item) (> (plist-get item :seq) after))
                (buffer-local-value 'overlook-remote--items buffer))
      (not (equal known (cdr (overlook-remote--state buffer))))))

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
          (overlook-remote--answer waiting))))))

(defun overlook-remote--wake ()
  "Answer the held calls that have news, shortly, so that bursts go together."
  (when (and overlook-remote--waiting (not overlook-remote--wake-timer))
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

(defun overlook-remote--api (method route query request)
  "Answer METHOD on ROUTE with QUERY and REQUEST, as (STATUS MIME BODY).
A call for news with none yet is answered (:hold CALL), as
`overlook-remote--news-or-hold' gives."
  (pcase (list method route)
    ('("GET" "/api/agents")
     (overlook-remote--json
      200 `(:agents ,(vconcat (mapcar #'overlook-remote--agent (overlook-agent-buffers))))))
    ('("GET" "/api/agent")
     (overlook-remote--json
      200 (overlook-remote--agent
           (overlook-remote--agent-buffer (cadr (assoc "id" query))) t)))
    ('("GET" "/api/events")
     (let ((buffer (overlook-remote--agent-buffer (cadr (assoc "id" query))))
           (after (string-to-number (or (cadr (assoc "after" query)) "0")))
           (known (cadr (assoc "known" query))))
       (overlook-remote--news-or-hold (overlook-remote--events-call buffer after known))))
    ('("GET" "/api/dashboard")
     (overlook-remote--news-or-hold
      (overlook-remote--dashboard-call (cadr (assoc "known" query)))))
    ('("POST" "/api/prompt")
     (let* ((body (overlook-remote--body request))
            (text (string-trim (or (alist-get 'text body) ""))))
       (when (string-empty-p text) (user-error "Nothing to send"))
       (overlook-remote--prompt (overlook-remote--agent-buffer (alist-get 'id body)) text)
       (overlook-remote--json 200 '(:ok t))))
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
    ('("POST" "/api/choose")
     (let ((body (overlook-remote--body request)))
       (overlook-agent-choose (overlook-remote--agent-buffer (alist-get 'id body))
                              (alist-get 'key body))
       (overlook-remote--json 200 '(:ok t))))
    (_ (overlook-remote--json 404 `(:error ,(format "No %s %s" method route))))))

(defun overlook-remote--respond (method path query request)
  "Answer METHOD on PATH with QUERY and REQUEST, as (STATUS MIME BODY)."
  (let ((route (string-remove-suffix "/" (string-remove-prefix "/overlook" path))))
    (cond
     ((and (equal method "GET") (assoc route overlook-remote--files))
      (pcase-let ((`(,_ ,file ,mime) (assoc route overlook-remote--files)))
        (list 200 mime (with-temp-buffer
                         (insert-file-contents (expand-file-name file overlook-remote--directory))
                         (buffer-string)))))
     ((not (overlook-remote--authorized-p request))
      (overlook-remote--json 401 '(:error "Open the page from M-x overlook-remote-url")))
     (t (condition-case err
            (overlook-remote--api method route query request)
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
    (response (overlook-remote--send proc response))))

;;; Mode

(defvar overlook-remote--off-timer nil
  "Timer turning the mode off while it serves beyond this machine, or nil.")

(defun overlook-remote--address ()
  "This machine's IPv4 address on the local network, or nil.
Prefers Ethernet and Wi-Fi interfaces, named en on macOS and Linux."
  (let ((addresses
         (seq-keep (pcase-lambda (`(,interface . ,address))
                     (let ((ip (format-network-address address t)))
                       (unless (string-match-p "\\`\\(?:127\\|169\\.254\\)\\." ip)
                         (cons interface ip))))
                   (network-interface-list nil 'ipv4))))
    (cdr (or (seq-find (lambda (entry) (string-prefix-p "en" (car entry))) addresses)
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
    (remove-hook 'overlook-agent-event-functions #'overlook-remote--record)
    (remove-hook 'overlook-agent-changed-hook #'overlook-remote--wake)
    (remove-hook 'overlook-refresh-hook #'overlook-remote--refreshed)
    (remove-hook 'overlook-after-model-hook #'overlook-remote--redrawn)
    (setq overlook-remote--dashboard nil)
    (mapc #'overlook-remote--answer overlook-remote--waiting)
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
    (when (and overlook-remote-network-minutes
               (not (member overlook-remote-host '("127.0.0.1" "localhost" "::1"))))
      (setq overlook-remote--off-timer
            (run-at-time (* 60 overlook-remote-network-minutes) nil
                         (lambda ()
                           (overlook-remote-mode -1)
                           (message "overlook remote: off after %d minutes on the network"
                                    overlook-remote-network-minutes)))))
    (overlook-remote-url))))

(provide 'overlook-remote)
;;; overlook-remote.el ends here
