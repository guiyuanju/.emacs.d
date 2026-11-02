;;; overlook-courier-room.el --- Chat rooms for courier's agents and their user -*- lexical-binding: t; -*-

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

;; A room is a log anyone reads at will, kept in a file so it outlives
;; Emacs.  Posting wakes only the members it names, `@ID' or `@all',
;; through their courier mailbox: waking every member on every post would
;; cost each a turn and let agents answer each other until the hop limit.
;; Naming an agent that is not a member adds it, and naming an offline
;; persona with @ID starts it.  A member may instead
;; ask to be woken by every post, or by none.  Other posts wait, and the
;; next prompt courier delivers to a member says how many are unread; a
;; post waking a member brings its latest unread posts along.
;; The user is the member `overlook-courier-room-user'.  A closed room's posts
;; move to an archive.

;;; Code:

(require 'overlook-courier)

(defcustom overlook-courier-room-directory (locate-user-emacs-file "courier-rooms/")
  "Directory keeping each room's posts and the rooms' members."
  :type 'directory
  :group 'overlook-courier)

(defcustom overlook-courier-room-wake-context 20
  "Most earlier posts that come along with a post waking or adding a member."
  :type 'natnum
  :group 'overlook-courier)

(defcustom overlook-courier-room-context-chars 6000
  "Most characters of the earlier posts that come along with one post."
  :type 'natnum
  :group 'overlook-courier)

(defconst overlook-courier-room-user "user"
  "Member id of the user.")

(defcustom overlook-courier-room-publish-fallback nil
  "Id of the agent told of an event that wakes no member, or nil.
An event may name another agent, or nobody, instead."
  :type '(choice (const nil) string)
  :group 'overlook-courier)

(declare-function overlook-courier-worktree-spawn "overlook-courier-worktree")

(defvar overlook-courier-room-post-functions nil
  "Functions of a room's NAME and a POST, called after each post.")

(defvar overlook-courier-room-close-functions nil
  "Functions of a room's NAME, called after it is closed.")

(cl-defstruct (overlook-courier-room (:constructor overlook-courier-room--make) (:copier nil))
  "A chat room."
  name
  (posts nil :documentation "Posts, newest first; each a plist of :n :time :from :body.")
  (count 0)
  (members nil :documentation "Alist of member id to a plist of :read and :wake."))

(defvar overlook-courier-room--rooms nil
  "Alist of room name to room, once loaded.")

(defvar overlook-courier-room--loaded nil)

;;; Storage

(defun overlook-courier-room--file (name)
  "File of room NAME's posts."
  (expand-file-name (concat name ".jsonl") overlook-courier-room-directory))

(defun overlook-courier-room--members-file ()
  "File of every room's members."
  (expand-file-name "members.eld" overlook-courier-room-directory))

(defun overlook-courier-room--read-posts (file)
  "Posts in FILE, newest first."
  (with-temp-buffer
    (insert-file-contents file)
    (let (posts)
      (dolist (line (split-string (buffer-string) "\n" t))
        (push (json-parse-string line :object-type 'plist) posts))
      posts)))

(defun overlook-courier-room--load ()
  "Load the rooms in `overlook-courier-room-directory', once."
  (unless overlook-courier-room--loaded
    (setq overlook-courier-room--loaded t)
    (let ((members (let ((file (overlook-courier-room--members-file)))
                     (and (file-readable-p file)
                          (with-temp-buffer
                            (insert-file-contents file)
                            (read (current-buffer)))))))
      (when (file-directory-p overlook-courier-room-directory)
        (dolist (file (directory-files overlook-courier-room-directory t "\\.jsonl\\'"))
          (let* ((name (file-name-base file))
                 (posts (overlook-courier-room--read-posts file)))
            (push (cons name (overlook-courier-room--make
                              :name name :posts posts :count (length posts)
                              :members (alist-get name members nil nil #'equal)))
                  overlook-courier-room--rooms)))))))

(defun overlook-courier-room--save-members ()
  "Write every room's members to disk."
  (make-directory overlook-courier-room-directory t)
  (let ((print-length nil) (print-level nil))
    (with-temp-file (overlook-courier-room--members-file)
      (prin1 (mapcar (lambda (entry) (cons (car entry) (overlook-courier-room-members (cdr entry))))
                     overlook-courier-room--rooms)
             (current-buffer)))))

;;; Rooms

(defun overlook-courier-room--check-name (name)
  "NAME without a leading #, checked to be a room name."
  (let ((name (string-remove-prefix "#" name)))
    (unless (string-match-p "\\`[a-z0-9][a-z0-9_-]\\{0,31\\}\\'" name)
      (user-error "Room names are lowercase letters, digits, - and _: %s" name))
    name))

(defun overlook-courier-room-name-for (text)
  "A room name made of TEXT, such as a branch name."
  (let ((name (string-trim (replace-regexp-in-string "[^a-z0-9_-]+" "-" (downcase text))
                           "[-_]+" "[-_]+")))
    (when (string-empty-p name) (user-error "No room name in %s" text))
    (string-trim-right (substring name 0 (min 32 (length name))) "[-_]+")))

(defun overlook-courier-room (name &optional create)
  "The room called NAME, made if CREATE is non-nil, or nil."
  (overlook-courier-room--load)
  (let ((name (overlook-courier-room--check-name name)))
    (or (alist-get name overlook-courier-room--rooms nil nil #'equal)
        (when create
          (make-directory overlook-courier-room-directory t)
          (write-region "" nil (overlook-courier-room--file name) t 'silent)
          (let ((room (overlook-courier-room--make :name name)))
            (push (cons name room) overlook-courier-room--rooms)
            room)))))

(defun overlook-courier-room-names ()
  "Names of all rooms, sorted."
  (overlook-courier-room--load)
  (sort (mapcar #'car overlook-courier-room--rooms) #'string<))

(defun overlook-courier-room-member (room id)
  "ID's membership plist in ROOM, or nil."
  (alist-get id (overlook-courier-room-members room) nil nil #'equal))

(defun overlook-courier-room-join (name id &optional wake)
  "Make ID a member of room NAME, made if missing, and return the room.
WAKE is `mention' (the default for a new member), `all' or `none': which
posts wake it.  A new member starts with every earlier post read."
  (let ((room (overlook-courier-room name t)))
    (unless (memq wake '(nil mention all none))
      (user-error "Wake is mention, all or none, not %s" wake))
    (if-let* ((member (overlook-courier-room-member room id)))
        (when wake (setf (plist-get member :wake) wake))
      (push (cons id (list :read (overlook-courier-room-count room) :wake (or wake 'mention)))
            (overlook-courier-room-members room)))
    (overlook-courier-room--save-members)
    (run-hooks 'overlook-courier-changed-hook)
    room))

(defun overlook-courier-room--fit (posts)
  "The latest of POSTS, newest first, that fit as context, oldest first.
Returns (SHOWN . HIDDEN): the posts within `overlook-courier-room-wake-context'
and `overlook-courier-room-context-chars', and how many of POSTS are left out."
  (let ((room overlook-courier-room-context-chars) shown)
    (cl-loop for post in posts
             for text = (overlook-courier-room-format post)
             while (and (< (length shown) overlook-courier-room-wake-context)
                        (<= (length text) room))
             do (setq room (- room (length text)))
             (push post shown))
    (cons shown (- (length posts) (length shown)))))

(defun overlook-courier-room--context (name posts heading)
  "POSTS of room NAME, newest first, as context under HEADING, or nil."
  (pcase-let ((`(,shown . ,hidden) (overlook-courier-room--fit posts)))
    (when shown
      (format "%s%s:\n%s"
              heading
              (if (> hidden 0)
                  (format " (%d earlier: `courier room read %s --last %d`)"
                          hidden name
                          (1+ (- (overlook-courier-room-count (overlook-courier-room name))
                                 (plist-get (car (last posts)) :n))))
                "")
              (mapconcat #'overlook-courier-room-format shown "\n")))))

(defun overlook-courier-room--invitation (name from &optional wake)
  "What an agent added to room NAME by member FROM is told.
WAKE is which posts wake it, as for `overlook-courier-room-join'."
  (let ((recent (overlook-courier-room--context name (overlook-courier-room-posts (overlook-courier-room name))
                                       "Recent posts")))
    (concat (format "[courier] %s added you to the chat room #%s.  %s  Post with \
`courier room post %s MESSAGE`; leave with `courier room leave %s`."
                    (if (or (null from) (equal from overlook-courier-room-user)) "Your user"
                      (format "Agent %s" from))
                    name
                    (pcase wake
                      ('all "Every post wakes you.")
                      ('none "No post wakes you; read them with `courier room read`.")
                      (_ "Posts naming you, @ and your id, or @all wake you."))
                    name name)
            (when recent (concat "  " recent)))))

(defun overlook-courier-room-invite (name id &optional from wake)
  "Make agent ID a member of room NAME for member FROM, and tell it so.
WAKE is which posts wake it, as for `overlook-courier-room-join'.  An offline
agent is not started; it learns of the room once named."
  (let ((agent (overlook-courier-agent id)))
    (unless (or agent (member id (overlook-courier-offline))) (user-error "No agent %s" id))
    (let ((room (overlook-courier-room-join name id wake)))
      (when agent
        (overlook-courier--enqueue agent from
                          (overlook-courier-room--invitation (overlook-courier-room-name room) from wake)
                          (overlook-courier--hops from) t))
      room)))

(cl-defun overlook-courier-room-spawn (name agent directory &optional from effort task
                                   &key worktree wake)
  "Start AGENT in DIRECTORY as a member of room NAME, for member FROM.
EFFORT is its reasoning effort level, or nil.  It works on TASK if
non-nil; otherwise it idles, and learns of the room with the first post
that wakes it.  WORKTREE and WAKE are as for `overlook-courier-spawn' and
`overlook-courier-room-join'.  Returns its id."
  (let* ((name (overlook-courier-room-name (overlook-courier-room name t)))
         (parent (and (overlook-courier-agent from) from))
         (task (and task (concat (overlook-courier-room--invitation name from wake) "\n\n" task)))
         (id (if worktree
                 (progn (require 'overlook-courier-worktree)
                        (overlook-courier-worktree-spawn agent directory worktree task parent effort))
               (overlook-courier-spawn agent directory task parent effort))))
    (overlook-courier-room-join name id wake)
    (unless task
      (overlook-courier-note id (overlook-courier-room--invitation name from wake)))
    id))

(defun overlook-courier-room-close (name)
  "Close room NAME: forget its members, and move its posts to the archive."
  (let* ((room (or (overlook-courier-room name) (user-error "No room #%s" name)))
         (name (overlook-courier-room-name room))
         (archive (expand-file-name "archive" overlook-courier-room-directory)))
    (make-directory archive t)
    (rename-file (overlook-courier-room--file name)
                 (expand-file-name (format-time-string (concat name "-%Y%m%d-%H%M%S.jsonl"))
                                   archive))
    (setq overlook-courier-room--rooms (assoc-delete-all name overlook-courier-room--rooms))
    (overlook-courier-room--save-members)
    (run-hook-with-args 'overlook-courier-room-close-functions name)
    (run-hooks 'overlook-courier-changed-hook)))

(defun overlook-courier-room-leave (name id)
  "Take ID out of room NAME."
  (let ((room (or (overlook-courier-room name) (user-error "No room #%s" name))))
    (setf (overlook-courier-room-members room)
          (cl-remove id (overlook-courier-room-members room) :key #'car :test #'equal))
    (overlook-courier-room--save-members)
    (run-hooks 'overlook-courier-changed-hook)))

(defun overlook-courier-room-unread (room id)
  "How many posts in ROOM member ID has not read."
  (if-let* ((member (overlook-courier-room-member room id)))
      (- (overlook-courier-room-count room) (plist-get member :read))
    0))

(defun overlook-courier-room-mark-read (name id)
  "Mark every post in room NAME read by member ID."
  (when-let* ((room (overlook-courier-room name))
              (member (overlook-courier-room-member room id))
              ((< (plist-get member :read) (overlook-courier-room-count room))))
    (setf (plist-get member :read) (overlook-courier-room-count room))
    (overlook-courier-room--save-members)
    (run-hooks 'overlook-courier-changed-hook)))

(defun overlook-courier-room-history (name &optional last)
  "The posts of room NAME, oldest first; only the LAST ones if non-nil."
  (when-let* ((room (overlook-courier-room name)))
    (reverse (if last (take last (overlook-courier-room-posts room)) (overlook-courier-room-posts room)))))

;;; Posting

(defun overlook-courier-room--names-p (body id)
  "Non-nil when BODY names ID with @ID."
  (string-match-p (concat "@" (regexp-quote id)
                          "\\(?:\\'\\|[^[:alnum:]_@.-]\\|\\.\\(?:\\'\\|[^[:alnum:]]\\)\\)")
                  body))

(defun overlook-courier-room-mentions-p (body id)
  "Non-nil when BODY names member ID with @ID or @all."
  (or (overlook-courier-room--names-p body id) (overlook-courier-room--names-p body "all")))

(defun overlook-courier-room--wake-p (member id body)
  "Non-nil when a post of BODY wakes member ID, of membership MEMBER."
  (pcase (plist-get member :wake)
    ('all t)
    ('none nil)
    (_ (overlook-courier-room-mentions-p body id))))

(defun overlook-courier-room--wake-text (name from body unread &optional event)
  "The prompt waking a member with BODY, posted by FROM in room NAME.
UNREAD are the member's unread posts before it, newest first; those
`overlook-courier-room--fit' allows come along.  EVENT non-nil means FROM is an
event source, not an agent."
  (let ((context (overlook-courier-room--context
                  name unread (format "[courier] Unread in #%s before the post for you" name))))
    (concat
     (when context (concat context "\n\n"))
     (format "[courier] #%s, from %s (answer with `courier room post %s MESSAGE`):\n\n%s"
             name
             (cond ((equal from overlook-courier-room-user) "your user")
                   (event (format "event source %s" from))
                   (t (format "agent %s, not from your user" from)))
             name body))))

(defun overlook-courier-room-post (name from body &optional event)
  "Post BODY from member FROM in room NAME, joining it first if need be.
Agents BODY names with @ID join the room.  Wakes the members the post is
for, and returns the post with :woke, their ids.  EVENT non-nil posts for
an event source FROM, which does not join."
  (let* ((room (overlook-courier-room name t))
         (name (overlook-courier-room-name room))
         (woke nil))
    (unless (or event (overlook-courier-room-member room from))
      (overlook-courier-room-join name from))
    (let ((added (cl-loop for id in (append (mapcar #'overlook-courier-agent-id (overlook-courier-agents))
                                            (overlook-courier-offline))
                          unless (or (equal id from) (overlook-courier-room-member room id))
                          when (overlook-courier-room--names-p body id)
                          collect id)))
      (dolist (id added) (overlook-courier-room-join name id))
    (let ((post (list :n (1+ (overlook-courier-room-count room)) :time (float-time)
                      :from from :body body)))
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (concat (json-serialize post) "\n") nil
                      (overlook-courier-room--file name) t 'silent))
      (push post (overlook-courier-room-posts room))
      (cl-incf (overlook-courier-room-count room))
      ;; Someone who had read everything has read their own post too.
      (when-let* ((author (overlook-courier-room-member room from)))
        (when (= (plist-get author :read) (1- (overlook-courier-room-count room)))
          (setf (plist-get author :read) (overlook-courier-room-count room))
          (overlook-courier-room--save-members)))
      (let ((hops (overlook-courier--hops from)))
        (pcase-dolist (`(,id . ,member) (overlook-courier-room-members room))
          (when-let* (((not (equal id from)))
                      ((overlook-courier-room--wake-p member id body))
                      (agent (if (overlook-courier-room--names-p body id)
                                 (condition-case err
                                     (overlook-courier-reach id from)
                                   (error
                                    (message "courier: could not start %s: %s"
                                             id (error-message-string err))
                                    nil))
                               (overlook-courier-agent id))))
            (push id woke)
            (overlook-courier--enqueue agent from
                              (concat (overlook-courier-room--wake-text
                                       name from body
                                       (cl-loop for earlier in (cdr (overlook-courier-room-posts room))
                                                while (> (plist-get earlier :n) (plist-get member :read))
                                                unless (equal (plist-get earlier :from) id)
                                                collect earlier)
                                       event)
                                      (when (member id added)
                                        (format "\n\n[courier] Being named added you to \
#%s; leave with `courier room leave %s`." name name)))
                              hops t)
            (setf (plist-get member :read) (overlook-courier-room-count room))))
        (overlook-courier-room--save-members))
      (run-hook-with-args 'overlook-courier-room-post-functions name post)
      (run-hooks 'overlook-courier-changed-hook)
      (append post (list :woke (nreverse woke)))))))

(defun overlook-courier-room-publish (name source body &optional fallback)
  "Post BODY in room NAME for event SOURCE, such as \"ci\".
The members it wakes, those asking to be woken by every post, take it.
When it wakes nobody, agent FALLBACK, if non-nil, is sent it to find who
should.  Returns the ids it reached."
  (let* ((post (overlook-courier-room-post name source body t))
         (woke (plist-get post :woke)))
    (if (or woke (null fallback))
        woke
      (let ((name (overlook-courier-room--check-name name)))
        (condition-case err
            (progn
              (overlook-courier--enqueue
               (or (overlook-courier-reach fallback) (user-error "No agent %s" fallback))
               source
               (format "[courier] An event from %s in #%s woke nobody, as no agent \
follows the room:\n\n%s\n\nIf an agent should handle it, add it with `courier room \
invite --wake all %s ID`; or start one with `courier room spawn --wake all %s AGENT DIR \
TASK`.  If it needs nothing, end your turn."
                       source name body name name)
               0 t)
              (list fallback))
          (error
           (message "courier: could not tell %s of an event in #%s: %s"
                    fallback name (error-message-string err))
           nil))))))

;;; Text for agents

(defun overlook-courier-room-format (post)
  "POST as one entry of a transcript."
  (format "[%s] %s: %s"
          (format-time-string "%m-%d %H:%M" (plist-get post :time))
          (plist-get post :from)
          (replace-regexp-in-string "\n" "\n    " (plist-get post :body))))

(defun overlook-courier-room-read (name id &optional last)
  "Transcript of room NAME for member ID: its unread posts, or the LAST ones.
Marks every post read."
  (let* ((room (or (overlook-courier-room name) (user-error "No room #%s" name)))
         (unread (overlook-courier-room-unread room id))
         (posts (overlook-courier-room-history name (or last (and (overlook-courier-room-member room id) unread)))))
    (overlook-courier-room-mark-read name id)
    (if posts
        (mapconcat #'overlook-courier-room-format posts "\n")
      (format "No %sposts in #%s." (if last "" "unread ") (overlook-courier-room-name room)))))

(defun overlook-courier-room--describe (room id)
  "A line describing ROOM for member ID."
  (let ((unread (overlook-courier-room-unread room id)))
    (format "#%s  %d posts%s  members: %s"
            (overlook-courier-room-name room) (overlook-courier-room-count room)
            (if (> unread 0) (format ", %d unread" unread) "")
            (mapconcat (pcase-lambda (`(,member . ,props))
                         (let ((tags (delq nil (list (cond ((overlook-courier-agent member) nil)
                                                           ((member member (overlook-courier-offline)) "offline")
                                                           ((not (equal member overlook-courier-room-user)) "gone"))
                                                     (let ((wake (plist-get props :wake)))
                                                       (unless (eq wake 'mention) (symbol-name wake)))))))
                           (if tags (format "%s (%s)" member (string-join tags ", ")) member)))
                       (reverse (overlook-courier-room-members room)) ", "))))

(defun overlook-courier-room-present-p (id)
  "Non-nil when member ID can be woken: the user, a registered agent or a persona."
  (or (equal id overlook-courier-room-user) (overlook-courier-agent id) (member id (overlook-courier-offline))))

(defun overlook-courier-room-missed (name body)
  "What says which members of room NAME that BODY names it did not reach, or nil.
Those are the gone ones, and the personas that could not be started."
  (when-let* ((room (overlook-courier-room name)))
    (let (gone offline)
      (pcase-dolist (`(,id . ,_) (overlook-courier-room-members room))
        (when (overlook-courier-room--names-p body id)
          (cond ((member id (overlook-courier-offline)) (push id offline))
                ((not (overlook-courier-room-present-p id)) (push id gone)))))
      (when-let* ((lines (delq nil (list (when gone
                                           (format "Not delivered to %s: gone."
                                                   (string-join (nreverse gone) ", ")))
                                         (when offline
                                           (format "Not delivered to %s: could not start; \
see *Messages*." (string-join (nreverse offline) ", ")))))))
        (string-join lines "  ")))))

(defun overlook-courier-room--unheard (room id)
  "How many of ROOM's posts member ID has neither read nor been woken by."
  (if-let* ((member (overlook-courier-room-member room id)))
      (cl-loop for post in (overlook-courier-room-posts room)
               while (> (plist-get post :n) (plist-get member :read))
               count (not (or (equal (plist-get post :from) id)
                              (overlook-courier-room--wake-p member id (plist-get post :body)))))
    0))

(defun overlook-courier-room-note (id)
  "A line for agent ID's next prompt naming the rooms with posts it has not seen.
Posts that woke it came in its prompts, so they are not counted."
  (when-let* ((unread (delq nil (mapcar (pcase-lambda (`(,name . ,room))
                                          (let ((n (overlook-courier-room--unheard room id)))
                                            (and (> n 0) (format "#%s %d" name n))))
                                        overlook-courier-room--rooms))))
    (format "[courier] Unread in rooms: %s.  Read with `courier room read NAME`."
            (string-join unread ", "))))

(defun overlook-courier-room-cli (from args)
  "Run the room command ARGS for agent FROM and return its output."
  (let ((me (lambda () (or from (user-error "No COURIER_ID")))))
    (pcase args
      (`("post" ,name ,body)
       (let* ((post (overlook-courier-room-post name (funcall me) body))
              (missed (overlook-courier-room-missed name body)))
         (concat (format "Posted #%d in #%s." (plist-get post :n) (overlook-courier-room--check-name name))
                 (when missed (concat "  " missed)))))
      (`("read" ,name) (overlook-courier-room-read name (funcall me)))
      (`("read" ,name "--last" ,n) (overlook-courier-room-read name from (string-to-number n)))
      ((or `("join" ,name) `("join" ,name "--wake" ,wake))
       (let* ((room (overlook-courier-room-join name (funcall me) (and wake (intern wake))))
              (recent (overlook-courier-room-history (overlook-courier-room-name room) 20)))
         (concat (format "Joined #%s; posts that name you, @%s or @all, wake you."
                         (overlook-courier-room-name room) (funcall me))
                 (when recent
                   (concat "  Recent posts:\n" (mapconcat #'overlook-courier-room-format recent "\n"))))))
      ((and `("invite" . ,rest)
            (let `(,options ,name ,id) (overlook-courier-options rest '("--wake"))))
       (overlook-courier-room-invite name id from (overlook-courier-room--wake-option options))
       (format "Added %s to #%s." id (overlook-courier-room--check-name name)))
      ((and `("spawn" . ,rest)
            (let `(,options ,name ,agent ,directory . ,task)
              (overlook-courier-options rest '("--effort" "--worktree" "--wake")))
            (guard (and directory (<= (length task) 1))))
       (let ((id (overlook-courier-room-spawn name agent directory from
                                     (overlook-courier-option "--effort" options) (car task)
                                     :worktree (overlook-courier-option "--worktree" options)
                                     :wake (overlook-courier-room--wake-option options))))
         (format "Started %s in #%s." id (overlook-courier-room--check-name name))))
      (`("close" ,name)
       (overlook-courier-room-close name)
       (format "Closed #%s; its posts are archived." (overlook-courier-room--check-name name)))
      (`("leave" ,name)
       (overlook-courier-room-leave name (funcall me))
       (format "Left #%s." (overlook-courier-room--check-name name)))
      (`("list")
       (overlook-courier-or-empty (mapconcat (lambda (name) (overlook-courier-room--describe (overlook-courier-room name) from))
                      (overlook-courier-room-names) "\n")
           "No rooms."))
      (_ (user-error "Usage: courier room post NAME MESSAGE | read NAME [--last N] \
| join NAME [--wake mention|all|none] | invite [--wake W] NAME ID \
| spawn [--effort L] [--worktree BRANCH] [--wake W] NAME AGENT DIR [TASK] \
| leave NAME | close NAME | list")))))

(defun overlook-courier-room--wake-option (options)
  "The --wake value in OPTIONS as a symbol, or nil."
  (when-let* ((wake (overlook-courier-option "--wake" options))) (intern wake)))

(add-hook 'overlook-courier-prompt-functions #'overlook-courier-room-note)

(provide 'overlook-courier-room)
;;; overlook-courier-room.el ends here
