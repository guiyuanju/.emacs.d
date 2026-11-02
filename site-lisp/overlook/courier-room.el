;;; courier-room.el --- Chat rooms for courier's agents and their user -*- lexical-binding: t; -*-

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
;; The user is the member `courier-room-user'.  A closed room's posts
;; move to an archive.

;;; Code:

(require 'courier)

(defcustom courier-room-directory (locate-user-emacs-file "courier-rooms/")
  "Directory keeping each room's posts and the rooms' members."
  :type 'directory
  :group 'courier)

(defcustom courier-room-wake-context 20
  "Most earlier posts that come along with a post waking or adding a member."
  :type 'natnum
  :group 'courier)

(defcustom courier-room-context-chars 6000
  "Most characters of the earlier posts that come along with one post."
  :type 'natnum
  :group 'courier)

(defconst courier-room-user "user"
  "Member id of the user.")

(defcustom courier-room-publish-fallback nil
  "Id of the agent told of an event that wakes no member, or nil.
An event may name another agent, or nobody, instead."
  :type '(choice (const nil) string)
  :group 'courier)

(declare-function courier-worktree-spawn "courier-worktree")

(defvar courier-room-post-functions nil
  "Functions of a room's NAME and a POST, called after each post.")

(defvar courier-room-close-functions nil
  "Functions of a room's NAME, called after it is closed.")

(cl-defstruct (courier-room (:constructor courier-room--make) (:copier nil))
  "A chat room."
  name
  (posts nil :documentation "Posts, newest first; each a plist of :n :time :from :body.")
  (count 0)
  (members nil :documentation "Alist of member id to a plist of :read and :wake."))

(defvar courier-room--rooms nil
  "Alist of room name to room, once loaded.")

(defvar courier-room--loaded nil)

;;; Storage

(defun courier-room--file (name)
  "File of room NAME's posts."
  (expand-file-name (concat name ".jsonl") courier-room-directory))

(defun courier-room--members-file ()
  "File of every room's members."
  (expand-file-name "members.eld" courier-room-directory))

(defun courier-room--read-posts (file)
  "Posts in FILE, newest first."
  (with-temp-buffer
    (insert-file-contents file)
    (let (posts)
      (dolist (line (split-string (buffer-string) "\n" t))
        (push (json-parse-string line :object-type 'plist) posts))
      posts)))

(defun courier-room--load ()
  "Load the rooms in `courier-room-directory', once."
  (unless courier-room--loaded
    (setq courier-room--loaded t)
    (let ((members (let ((file (courier-room--members-file)))
                     (and (file-readable-p file)
                          (with-temp-buffer
                            (insert-file-contents file)
                            (read (current-buffer)))))))
      (when (file-directory-p courier-room-directory)
        (dolist (file (directory-files courier-room-directory t "\\.jsonl\\'"))
          (let* ((name (file-name-base file))
                 (posts (courier-room--read-posts file)))
            (push (cons name (courier-room--make
                              :name name :posts posts :count (length posts)
                              :members (alist-get name members nil nil #'equal)))
                  courier-room--rooms)))))))

(defun courier-room--save-members ()
  "Write every room's members to disk."
  (make-directory courier-room-directory t)
  (let ((print-length nil) (print-level nil))
    (with-temp-file (courier-room--members-file)
      (prin1 (mapcar (lambda (entry) (cons (car entry) (courier-room-members (cdr entry))))
                     courier-room--rooms)
             (current-buffer)))))

;;; Rooms

(defun courier-room--check-name (name)
  "NAME without a leading #, checked to be a room name."
  (let ((name (string-remove-prefix "#" name)))
    (unless (string-match-p "\\`[a-z0-9][a-z0-9_-]\\{0,31\\}\\'" name)
      (user-error "Room names are lowercase letters, digits, - and _: %s" name))
    name))

(defun courier-room-name-for (text)
  "A room name made of TEXT, such as a branch name."
  (let ((name (string-trim (replace-regexp-in-string "[^a-z0-9_-]+" "-" (downcase text))
                           "[-_]+" "[-_]+")))
    (when (string-empty-p name) (user-error "No room name in %s" text))
    (string-trim-right (substring name 0 (min 32 (length name))) "[-_]+")))

(defun courier-room (name &optional create)
  "The room called NAME, made if CREATE is non-nil, or nil."
  (courier-room--load)
  (let ((name (courier-room--check-name name)))
    (or (alist-get name courier-room--rooms nil nil #'equal)
        (when create
          (make-directory courier-room-directory t)
          (write-region "" nil (courier-room--file name) t 'silent)
          (let ((room (courier-room--make :name name)))
            (push (cons name room) courier-room--rooms)
            room)))))

(defun courier-room-names ()
  "Names of all rooms, sorted."
  (courier-room--load)
  (sort (mapcar #'car courier-room--rooms) #'string<))

(defun courier-room-member (room id)
  "ID's membership plist in ROOM, or nil."
  (alist-get id (courier-room-members room) nil nil #'equal))

(defun courier-room-join (name id &optional wake)
  "Make ID a member of room NAME, made if missing, and return the room.
WAKE is `mention' (the default for a new member), `all' or `none': which
posts wake it.  A new member starts with every earlier post read."
  (let ((room (courier-room name t)))
    (unless (memq wake '(nil mention all none))
      (user-error "Wake is mention, all or none, not %s" wake))
    (if-let* ((member (courier-room-member room id)))
        (when wake (setf (plist-get member :wake) wake))
      (push (cons id (list :read (courier-room-count room) :wake (or wake 'mention)))
            (courier-room-members room)))
    (courier-room--save-members)
    (run-hooks 'courier-changed-hook)
    room))

(defun courier-room--fit (posts)
  "The latest of POSTS, newest first, that fit as context, oldest first.
Returns (SHOWN . HIDDEN): the posts within `courier-room-wake-context'
and `courier-room-context-chars', and how many of POSTS are left out."
  (let ((room courier-room-context-chars) shown)
    (cl-loop for post in posts
             for text = (courier-room-format post)
             while (and (< (length shown) courier-room-wake-context)
                        (<= (length text) room))
             do (setq room (- room (length text)))
             (push post shown))
    (cons shown (- (length posts) (length shown)))))

(defun courier-room--context (name posts heading)
  "POSTS of room NAME, newest first, as context under HEADING, or nil."
  (pcase-let ((`(,shown . ,hidden) (courier-room--fit posts)))
    (when shown
      (format "%s%s:\n%s"
              heading
              (if (> hidden 0)
                  (format " (%d earlier: `courier room read %s --last %d`)"
                          hidden name
                          (1+ (- (courier-room-count (courier-room name))
                                 (plist-get (car (last posts)) :n))))
                "")
              (mapconcat #'courier-room-format shown "\n")))))

(defun courier-room--invitation (name from &optional wake)
  "What an agent added to room NAME by member FROM is told.
WAKE is which posts wake it, as for `courier-room-join'."
  (let ((recent (courier-room--context name (courier-room-posts (courier-room name))
                                       "Recent posts")))
    (concat (format "[courier] %s added you to the chat room #%s.  %s  Post with \
`courier room post %s MESSAGE`; leave with `courier room leave %s`."
                    (if (or (null from) (equal from courier-room-user)) "Your user"
                      (format "Agent %s" from))
                    name
                    (pcase wake
                      ('all "Every post wakes you.")
                      ('none "No post wakes you; read them with `courier room read`.")
                      (_ "Posts naming you, @ and your id, or @all wake you."))
                    name name)
            (when recent (concat "  " recent)))))

(defun courier-room-invite (name id &optional from wake)
  "Make agent ID a member of room NAME for member FROM, and tell it so.
WAKE is which posts wake it, as for `courier-room-join'.  An offline
agent is not started; it learns of the room once named."
  (let ((agent (courier-agent id)))
    (unless (or agent (member id (courier-offline))) (user-error "No agent %s" id))
    (let ((room (courier-room-join name id wake)))
      (when agent
        (courier--enqueue agent from
                          (courier-room--invitation (courier-room-name room) from wake)
                          (courier--hops from) t))
      room)))

(cl-defun courier-room-spawn (name agent directory &optional from effort task
                                   &key worktree wake)
  "Start AGENT in DIRECTORY as a member of room NAME, for member FROM.
EFFORT is its reasoning effort level, or nil.  It works on TASK if
non-nil; otherwise it idles, and learns of the room with the first post
that wakes it.  WORKTREE and WAKE are as for `courier-spawn' and
`courier-room-join'.  Returns its id."
  (let* ((name (courier-room-name (courier-room name t)))
         (parent (and (courier-agent from) from))
         (task (and task (concat (courier-room--invitation name from wake) "\n\n" task)))
         (id (if worktree
                 (progn (require 'courier-worktree)
                        (courier-worktree-spawn agent directory worktree task parent effort))
               (courier-spawn agent directory task parent effort))))
    (courier-room-join name id wake)
    (unless task
      (courier-note id (courier-room--invitation name from wake)))
    id))

(defun courier-room-close (name)
  "Close room NAME: forget its members, and move its posts to the archive."
  (let* ((room (or (courier-room name) (user-error "No room #%s" name)))
         (name (courier-room-name room))
         (archive (expand-file-name "archive" courier-room-directory)))
    (make-directory archive t)
    (rename-file (courier-room--file name)
                 (expand-file-name (format-time-string (concat name "-%Y%m%d-%H%M%S.jsonl"))
                                   archive))
    (setq courier-room--rooms (assoc-delete-all name courier-room--rooms))
    (courier-room--save-members)
    (run-hook-with-args 'courier-room-close-functions name)
    (run-hooks 'courier-changed-hook)))

(defun courier-room-leave (name id)
  "Take ID out of room NAME."
  (let ((room (or (courier-room name) (user-error "No room #%s" name))))
    (setf (courier-room-members room)
          (cl-remove id (courier-room-members room) :key #'car :test #'equal))
    (courier-room--save-members)
    (run-hooks 'courier-changed-hook)))

(defun courier-room-unread (room id)
  "How many posts in ROOM member ID has not read."
  (if-let* ((member (courier-room-member room id)))
      (- (courier-room-count room) (plist-get member :read))
    0))

(defun courier-room-mark-read (name id)
  "Mark every post in room NAME read by member ID."
  (when-let* ((room (courier-room name))
              (member (courier-room-member room id))
              ((< (plist-get member :read) (courier-room-count room))))
    (setf (plist-get member :read) (courier-room-count room))
    (courier-room--save-members)
    (run-hooks 'courier-changed-hook)))

(defun courier-room-history (name &optional last)
  "The posts of room NAME, oldest first; only the LAST ones if non-nil."
  (when-let* ((room (courier-room name)))
    (reverse (if last (take last (courier-room-posts room)) (courier-room-posts room)))))

;;; Posting

(defun courier-room--names-p (body id)
  "Non-nil when BODY names ID with @ID."
  (string-match-p (concat "@" (regexp-quote id)
                          "\\(?:\\'\\|[^[:alnum:]_@.-]\\|\\.\\(?:\\'\\|[^[:alnum:]]\\)\\)")
                  body))

(defun courier-room-mentions-p (body id)
  "Non-nil when BODY names member ID with @ID or @all."
  (or (courier-room--names-p body id) (courier-room--names-p body "all")))

(defun courier-room--wake-p (member id body)
  "Non-nil when a post of BODY wakes member ID, of membership MEMBER."
  (pcase (plist-get member :wake)
    ('all t)
    ('none nil)
    (_ (courier-room-mentions-p body id))))

(defun courier-room--wake-text (name from body unread &optional event)
  "The prompt waking a member with BODY, posted by FROM in room NAME.
UNREAD are the member's unread posts before it, newest first; those
`courier-room--fit' allows come along.  EVENT non-nil means FROM is an
event source, not an agent."
  (let ((context (courier-room--context
                  name unread (format "[courier] Unread in #%s before the post for you" name))))
    (concat
     (when context (concat context "\n\n"))
     (format "[courier] #%s, from %s (answer with `courier room post %s MESSAGE`):\n\n%s"
             name
             (cond ((equal from courier-room-user) "your user")
                   (event (format "event source %s" from))
                   (t (format "agent %s, not from your user" from)))
             name body))))

(defun courier-room-post (name from body &optional event)
  "Post BODY from member FROM in room NAME, joining it first if need be.
Agents BODY names with @ID join the room.  Wakes the members the post is
for, and returns the post with :woke, their ids.  EVENT non-nil posts for
an event source FROM, which does not join."
  (let* ((room (courier-room name t))
         (name (courier-room-name room))
         (woke nil))
    (unless (or event (courier-room-member room from))
      (courier-room-join name from))
    (let ((added (cl-loop for id in (append (mapcar #'courier-agent-id (courier-agents))
                                            (courier-offline))
                          unless (or (equal id from) (courier-room-member room id))
                          when (courier-room--names-p body id)
                          collect id)))
      (dolist (id added) (courier-room-join name id))
    (let ((post (list :n (1+ (courier-room-count room)) :time (float-time)
                      :from from :body body)))
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region (concat (json-serialize post) "\n") nil
                      (courier-room--file name) t 'silent))
      (push post (courier-room-posts room))
      (cl-incf (courier-room-count room))
      ;; Someone who had read everything has read their own post too.
      (when-let* ((author (courier-room-member room from)))
        (when (= (plist-get author :read) (1- (courier-room-count room)))
          (setf (plist-get author :read) (courier-room-count room))
          (courier-room--save-members)))
      (let ((hops (courier--hops from)))
        (pcase-dolist (`(,id . ,member) (courier-room-members room))
          (when-let* (((not (equal id from)))
                      ((courier-room--wake-p member id body))
                      (agent (if (courier-room--names-p body id)
                                 (condition-case err
                                     (courier-reach id from)
                                   (error
                                    (message "courier: could not start %s: %s"
                                             id (error-message-string err))
                                    nil))
                               (courier-agent id))))
            (push id woke)
            (courier--enqueue agent from
                              (concat (courier-room--wake-text
                                       name from body
                                       (cl-loop for earlier in (cdr (courier-room-posts room))
                                                while (> (plist-get earlier :n) (plist-get member :read))
                                                unless (equal (plist-get earlier :from) id)
                                                collect earlier)
                                       event)
                                      (when (member id added)
                                        (format "\n\n[courier] Being named added you to \
#%s; leave with `courier room leave %s`." name name)))
                              hops t)
            (setf (plist-get member :read) (courier-room-count room))))
        (courier-room--save-members))
      (run-hook-with-args 'courier-room-post-functions name post)
      (run-hooks 'courier-changed-hook)
      (append post (list :woke (nreverse woke)))))))

(defun courier-room-publish (name source body &optional fallback)
  "Post BODY in room NAME for event SOURCE, such as \"ci\".
The members it wakes, those asking to be woken by every post, take it.
When it wakes nobody, agent FALLBACK, if non-nil, is sent it to find who
should.  Returns the ids it reached."
  (let* ((post (courier-room-post name source body t))
         (woke (plist-get post :woke)))
    (if (or woke (null fallback))
        woke
      (let ((name (courier-room--check-name name)))
        (condition-case err
            (progn
              (courier--enqueue
               (or (courier-reach fallback) (user-error "No agent %s" fallback))
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

(defun courier-room-format (post)
  "POST as one entry of a transcript."
  (format "[%s] %s: %s"
          (format-time-string "%m-%d %H:%M" (plist-get post :time))
          (plist-get post :from)
          (replace-regexp-in-string "\n" "\n    " (plist-get post :body))))

(defun courier-room-read (name id &optional last)
  "Transcript of room NAME for member ID: its unread posts, or the LAST ones.
Marks every post read."
  (let* ((room (or (courier-room name) (user-error "No room #%s" name)))
         (unread (courier-room-unread room id))
         (posts (courier-room-history name (or last (and (courier-room-member room id) unread)))))
    (courier-room-mark-read name id)
    (if posts
        (mapconcat #'courier-room-format posts "\n")
      (format "No %sposts in #%s." (if last "" "unread ") (courier-room-name room)))))

(defun courier-room--describe (room id)
  "A line describing ROOM for member ID."
  (let ((unread (courier-room-unread room id)))
    (format "#%s  %d posts%s  members: %s"
            (courier-room-name room) (courier-room-count room)
            (if (> unread 0) (format ", %d unread" unread) "")
            (mapconcat (pcase-lambda (`(,member . ,props))
                         (let ((tags (delq nil (list (cond ((courier-agent member) nil)
                                                           ((member member (courier-offline)) "offline")
                                                           ((not (equal member courier-room-user)) "gone"))
                                                     (let ((wake (plist-get props :wake)))
                                                       (unless (eq wake 'mention) (symbol-name wake)))))))
                           (if tags (format "%s (%s)" member (string-join tags ", ")) member)))
                       (reverse (courier-room-members room)) ", "))))

(defun courier-room-present-p (id)
  "Non-nil when member ID can be woken: the user, a registered agent or a persona."
  (or (equal id courier-room-user) (courier-agent id) (member id (courier-offline))))

(defun courier-room-missed (name body)
  "What says which members of room NAME that BODY names it did not reach, or nil.
Those are the gone ones, and the personas that could not be started."
  (when-let* ((room (courier-room name)))
    (let (gone offline)
      (pcase-dolist (`(,id . ,_) (courier-room-members room))
        (when (courier-room--names-p body id)
          (cond ((member id (courier-offline)) (push id offline))
                ((not (courier-room-present-p id)) (push id gone)))))
      (when-let* ((lines (delq nil (list (when gone
                                           (format "Not delivered to %s: gone."
                                                   (string-join (nreverse gone) ", ")))
                                         (when offline
                                           (format "Not delivered to %s: could not start; \
see *Messages*." (string-join (nreverse offline) ", ")))))))
        (string-join lines "  ")))))

(defun courier-room--unheard (room id)
  "How many of ROOM's posts member ID has neither read nor been woken by."
  (if-let* ((member (courier-room-member room id)))
      (cl-loop for post in (courier-room-posts room)
               while (> (plist-get post :n) (plist-get member :read))
               count (not (or (equal (plist-get post :from) id)
                              (courier-room--wake-p member id (plist-get post :body)))))
    0))

(defun courier-room-note (id)
  "A line for agent ID's next prompt naming the rooms with posts it has not seen.
Posts that woke it came in its prompts, so they are not counted."
  (when-let* ((unread (delq nil (mapcar (pcase-lambda (`(,name . ,room))
                                          (let ((n (courier-room--unheard room id)))
                                            (and (> n 0) (format "#%s %d" name n))))
                                        courier-room--rooms))))
    (format "[courier] Unread in rooms: %s.  Read with `courier room read NAME`."
            (string-join unread ", "))))

(defun courier-room-cli (from args)
  "Run the room command ARGS for agent FROM and return its output."
  (let ((me (lambda () (or from (user-error "No COURIER_ID")))))
    (pcase args
      (`("post" ,name ,body)
       (let* ((post (courier-room-post name (funcall me) body))
              (missed (courier-room-missed name body)))
         (concat (format "Posted #%d in #%s." (plist-get post :n) (courier-room--check-name name))
                 (when missed (concat "  " missed)))))
      (`("read" ,name) (courier-room-read name (funcall me)))
      (`("read" ,name "--last" ,n) (courier-room-read name from (string-to-number n)))
      ((or `("join" ,name) `("join" ,name "--wake" ,wake))
       (let* ((room (courier-room-join name (funcall me) (and wake (intern wake))))
              (recent (courier-room-history (courier-room-name room) 20)))
         (concat (format "Joined #%s; posts that name you, @%s or @all, wake you."
                         (courier-room-name room) (funcall me))
                 (when recent
                   (concat "  Recent posts:\n" (mapconcat #'courier-room-format recent "\n"))))))
      ((and `("invite" . ,rest)
            (let `(,options ,name ,id) (courier-options rest '("--wake"))))
       (courier-room-invite name id from (courier-room--wake-option options))
       (format "Added %s to #%s." id (courier-room--check-name name)))
      ((and `("spawn" . ,rest)
            (let `(,options ,name ,agent ,directory . ,task)
              (courier-options rest '("--effort" "--worktree" "--wake")))
            (guard (and directory (<= (length task) 1))))
       (let ((id (courier-room-spawn name agent directory from
                                     (courier-option "--effort" options) (car task)
                                     :worktree (courier-option "--worktree" options)
                                     :wake (courier-room--wake-option options))))
         (format "Started %s in #%s." id (courier-room--check-name name))))
      (`("close" ,name)
       (courier-room-close name)
       (format "Closed #%s; its posts are archived." (courier-room--check-name name)))
      (`("leave" ,name)
       (courier-room-leave name (funcall me))
       (format "Left #%s." (courier-room--check-name name)))
      (`("list")
       (courier-or-empty (mapconcat (lambda (name) (courier-room--describe (courier-room name) from))
                      (courier-room-names) "\n")
           "No rooms."))
      (_ (user-error "Usage: courier room post NAME MESSAGE | read NAME [--last N] \
| join NAME [--wake mention|all|none] | invite [--wake W] NAME ID \
| spawn [--effort L] [--worktree BRANCH] [--wake W] NAME AGENT DIR [TASK] \
| leave NAME | close NAME | list")))))

(defun courier-room--wake-option (options)
  "The --wake value in OPTIONS as a symbol, or nil."
  (when-let* ((wake (courier-option "--wake" options))) (intern wake)))

(add-hook 'courier-prompt-functions #'courier-room-note)

(provide 'courier-room)
;;; courier-room.el ends here
