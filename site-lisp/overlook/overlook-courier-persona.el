;;; overlook-courier-persona.el --- Lasting identities for courier's agents -*- lexical-binding: t; -*-

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

;; A persona is an identity that outlives the agents running it: a
;; folder NAME/ in one of `overlook-courier-persona-directories' holding
;; persona.md, its role and settings, and memory/, what it has learned.
;; An agent started as persona NAME gets the courier id NAME, so it is
;; reached at the same address whatever engine runs it and however often
;; it restarts; one agent at most runs a persona, unless its multiple
;; is on: then each start beyond the first gets a further instance,
;; NAME-2, NAME-3 and on.  Messaging a persona nobody runs starts it.
;;
;; persona.md opens with front matter of `key: value' lines; a # after
;; a space starts a comment:
;;
;;   ---
;;   engine: claude, codex   the agents to run it, required; the first
;;                           whose plan is not near its limit starts it
;;   effort: medium          its reasoning effort
;;   directory: ~/src/shop   where it starts, else the folder above the personas
;;   description: one line shown in lists
;;   avatar: 🦉              shown beside its name
;;   personality: calm, exacting
;;   tone: terse
;;   memory: off             keeps no memory, as for an agent that cannot write files
;;   briefing: off           tells the agent nothing; it starts idle
;;   multiple: on            may run in several agents at once
;;   ---
;;
;; The rest, its role, rules and any background, is the persona's
;; briefing when an agent starts as it, with the personality, the tone
;; and the index of its memory.  The agent keeps that memory itself.
;; A persona with its briefing off is not told it is one, nor about
;; courier; its agent's own instruction files, like a CLAUDE.md in its
;; directory, carry its role instead.

;;; Code:

(require 'overlook-courier)

(defcustom overlook-courier-persona-directories nil
  "Directories holding a folder per persona; the first one is for new personas."
  :type '(repeat directory)
  :group 'overlook-courier)

(defcustom overlook-courier-persona-index-lines 200
  "Most lines of a persona's MEMORY.md given to an agent starting as it."
  :type 'natnum
  :group 'overlook-courier)

(defconst overlook-courier-persona-fields
  '(engine effort directory description avatar personality tone memory briefing multiple
    backend model tools)
  "Fields persona.md's front matter may set.
backend, model and tools are for the engines in
`overlook-courier-persona-engines'.")

(defvar overlook-courier-persona-engines nil
  "Alist of engines that are no agent program to functions starting personas.
The function takes the persona, a plist from `overlook-courier-persona',
the task or nil, and the id of the agent starting it or nil; it
registers the persona with courier under its name.")

(defvar overlook-courier-persona-engine-available-functions nil
  "Functions telling whether an engine may start a persona now.
Each is called with the engine's name; one returning nil, such as for an
engine whose plan is near its limit, makes a persona listing several
engines start on its next.")

(defun overlook-courier-persona-name-p (name)
  "Non-nil when NAME may name a persona."
  (string-match-p "\\`[a-z0-9][a-z0-9_-]*\\'" name))

(defun overlook-courier-persona--folders ()
  "Alist of each persona's name to its folder; the first directory wins a name."
  (let (folders)
    (dolist (directory overlook-courier-persona-directories)
      (when (file-directory-p directory)
        (dolist (file (directory-files directory t))
          (when (and (overlook-courier-persona-name-p (file-name-nondirectory file))
                     (file-exists-p (expand-file-name "persona.md" file)))
            (unless (assoc (file-name-nondirectory file) folders)
              (push (cons (file-name-nondirectory file) (file-name-as-directory file))
                    folders))))))
    (nreverse folders)))

(defun overlook-courier-persona-names ()
  "Names of all personas, sorted."
  (sort (mapcar #'car (overlook-courier-persona--folders)) #'string<))

(defun overlook-courier-persona--parse (text)
  "Plist of the front matter fields in persona.md's TEXT, and :body the rest."
  (let (fields (body text))
    (when (string-match "\\`---[ \t]*\n\\(\\(?:.*\n\\)*?\\)---[ \t]*\\(?:\n\\|\\'\\)" text)
      (setq body (substring text (match-end 0)))
      (dolist (line (split-string (match-string 1 text) "\n" t))
        (when (string-match "\\`\\([a-z]+\\):\\(.*\\)\\'" line)
          (let ((key (intern (match-string 1 line)))
                (value (string-trim (replace-regexp-in-string
                                     "\\(?:\\`\\|[ \t]\\)#.*" "" (match-string 2 line)))))
            (when (and (memq key overlook-courier-persona-fields) (not (string-empty-p value)))
              (setq fields (plist-put fields (intern (format ":%s" key)) value)))))))
    (plist-put fields :body (string-trim body))))

(defun overlook-courier-persona (name)
  "Persona NAME as a plist of its fields, :body, :name and :folder; or nil."
  (when-let* ((folder (alist-get name (overlook-courier-persona--folders) nil nil #'equal)))
    (append (list :name name :folder folder)
            (overlook-courier-persona--parse
             (with-temp-buffer
               (insert-file-contents (expand-file-name "persona.md" folder))
               (buffer-string))))))

(defun overlook-courier-persona-engine-names (persona)
  "Engines PERSONA's front matter lists, first preferred."
  (split-string (or (plist-get persona :engine) "") "[ \t]*,[ \t]*" t))

(defun overlook-courier-persona-engine (persona)
  "The engine to start PERSONA on: the first of its engines free to start it.
When none is, the first, saying so."
  (let* ((engines (or (overlook-courier-persona-engine-names persona)
                      (user-error "Persona %s names no engine" (plist-get persona :name))))
         (engine (seq-find (lambda (engine)
                             (run-hook-with-args-until-failure
                              'overlook-courier-persona-engine-available-functions engine))
                           engines)))
    (cond ((null (cdr engines)) (car engines))
          ((null engine)
           (message "Persona %s: every engine is near its limit; starting %s"
                    (plist-get persona :name) (car engines))
           (car engines))
          (t (unless (equal engine (car engines))
               (message "Persona %s: %s is near its limit; starting %s"
                        (plist-get persona :name) (car engines) engine))
             engine))))

(defun overlook-courier-persona-memory (persona)
  "Folder of PERSONA's memory."
  (expand-file-name "memory/" (plist-get persona :folder)))

(defun overlook-courier-persona-directory (persona)
  "Where PERSONA starts: its directory, else the folder above the personas."
  (if-let* ((directory (plist-get persona :directory)))
      (expand-file-name directory)
    (file-name-directory (directory-file-name
                          (file-name-directory (directory-file-name (plist-get persona :folder)))))))

(defun overlook-courier-persona--index (persona)
  "PERSONA's MEMORY.md, or nil.
It is cut to `overlook-courier-persona-index-lines' lines."
  (let ((file (expand-file-name "MEMORY.md" (overlook-courier-persona-memory persona))))
    (when (file-readable-p file)
      (let* ((lines (with-temp-buffer
                      (insert-file-contents file)
                      (split-string (string-trim (buffer-string)) "\n")))
             (cut (- (length lines) overlook-courier-persona-index-lines)))
        (unless (equal lines '(""))
          (concat (string-join (take overlook-courier-persona-index-lines lines) "\n")
                  (when (> cut 0) (format "\n[… %d more lines in MEMORY.md]" cut))))))))

(defun overlook-courier-persona-remembers-p (persona)
  "Non-nil unless PERSONA's front matter turns its memory off."
  (not (member (plist-get persona :memory) '("off" "no" "false"))))

(defun overlook-courier-persona-briefed-p (persona)
  "Non-nil unless PERSONA's front matter turns its briefing off."
  (not (member (plist-get persona :briefing) '("off" "no" "false"))))

(defun overlook-courier-persona-multiple-p (persona)
  "Non-nil when PERSONA's front matter lets it run in several agents at once."
  (member (plist-get persona :multiple) '("on" "yes" "true")))

(defun overlook-courier-persona-of (id)
  "Name of the persona the agent of courier ID runs, or nil.
NAME-N is an instance of persona NAME when its multiple is on."
  (cond ((overlook-courier-persona id) id)
        ((and id (string-match "\\`\\(.+\\)-\\([0-9]+\\)\\'" id))
         (let ((name (match-string 1 id)))
           (when-let* ((persona (overlook-courier-persona name))
                       ((overlook-courier-persona-multiple-p persona)))
             name)))))

(defun overlook-courier-persona-instances (name)
  "Ids of the running agents of persona NAME, first started first."
  (let ((ids (seq-filter (lambda (id) (equal (overlook-courier-persona-of id) name))
                         (mapcar #'overlook-courier-agent-id (overlook-courier-agents)))))
    (sort ids (lambda (a b) (< (overlook-courier-persona--number a)
                               (overlook-courier-persona--number b))))))

(defun overlook-courier-persona--number (id)
  "Number of instance ID, 1 for the persona's own id."
  (if (string-match "-\\([0-9]+\\)\\'" id)
      (string-to-number (match-string 1 id))
    1))

(defun overlook-courier-persona--free-id (name)
  "The id for a new agent of persona NAME: NAME, else NAME-N for the lowest free N."
  (let ((id name) (n 1))
    (while (overlook-courier-agent id)
      (setq id (format "%s-%d" name (cl-incf n))))
    id))

(defun overlook-courier-persona-briefing (persona engine)
  "What an agent of ENGINE starting as PERSONA is told."
  (let ((name (plist-get persona :name))
        (memory (overlook-courier-persona-memory persona))
        (index (overlook-courier-persona--index persona)))
    (string-join
     (delq nil
           (list
            (format "[courier] You are %s, a persona: a lasting identity with its own \
memory, run this time by %s.  Agents and your user reach you as %s, and \
messaging you starts you when nobody runs you." name engine name)
            (let ((body (plist-get persona :body)))
              (unless (string-empty-p body) body))
            (let ((traits (delq nil (list (when-let* ((p (plist-get persona :personality)))
                                            (concat "Personality: " p))
                                          (when-let* ((tone (plist-get persona :tone)))
                                            (concat "Tone: " tone))))))
              (when traits (string-join traits "\n")))
            (when (overlook-courier-persona-remembers-p persona)
             (format "Your memory is in %s: a file per fact, each listed with a line \
in MEMORY.md.  Read a file when it bears on your work.  When your user \
corrects you, or you learn something about your role or how your user \
wants it done that will hold beyond this task, save it there and add its \
line to MEMORY.md; fix or delete a memory that proves wrong.  Knowledge \
about the code or the domain goes to the project's own notes instead.  %s"
                    (abbreviate-file-name memory)
                    (if index (concat "MEMORY.md now:\n\n" index) "It is empty so far.")))))
     "\n\n")))

(cl-defun overlook-courier-persona-start (name &key directory task from engine effort wait)
  "Start persona NAME and return its id, NAME or NAME-N for a further instance.
It starts in DIRECTORY, else the persona's own, run by ENGINE at
reasoning EFFORT, else by the engine `overlook-courier-persona-engine'
picks at the persona's effort.  FROM is the agent starting it, its
parent.  It works on TASK if non-nil.  With WAIT non-nil it idles, and
learns who it is with the first message it gets; otherwise it says it
is ready."
  (let* ((persona (or (overlook-courier-persona name) (user-error "No persona %s" name)))
         (engine (or engine (overlook-courier-persona-engine persona)))
         (start (cdr (assoc engine overlook-courier-persona-engines)))
         (id (if (and (not start) (overlook-courier-persona-multiple-p persona))
                 (overlook-courier-persona--free-id name)
               name)))
    (when (overlook-courier-agent id) (user-error "%s is running already" name))
    (if start
        (progn (funcall start persona task from) name)
      (when (overlook-courier-persona-remembers-p persona)
        (make-directory (overlook-courier-persona-memory persona) t))
      (let* ((briefing (when (overlook-courier-persona-briefed-p persona)
                         (overlook-courier-persona-briefing persona engine)))
             (id (overlook-courier-spawn engine (or directory (overlook-courier-persona-directory persona))
                                         (cond (wait nil)
                                               (briefing
                                                (concat briefing "\n\n"
                                                        (or task "Say in one line that you are ready.")))
                                               (t task))
                                         from (or effort (plist-get persona :effort)) id
                                         (not briefing))))
        (when (and wait briefing) (overlook-courier-note id briefing))
        id))))

(defun overlook-courier-persona--start-offline (id from)
  "Start persona ID, which FROM is messaging, to take the message; or nil."
  (when (overlook-courier-persona id)
    (message "courier: started persona %s for %s" id (or from "the user"))
    (overlook-courier-persona-start id :wait t)))

(defun overlook-courier-persona--describe (name)
  "A line describing persona NAME for `courier persona list'."
  (let ((persona (overlook-courier-persona name)))
    (format "%s  %s, %s%s" name
            (pcase (length (overlook-courier-persona-instances name))
              (0 "offline")
              (1 "running")
              (n (format "%d running" n)))
            (or (plist-get persona :engine) "no engine")
            (if-let* ((description (plist-get persona :description)))
                (concat "  " description)
              ""))))

(defun overlook-courier-persona-cli (from args)
  "Run the persona command ARGS for agent FROM and return its output."
  (pcase args
    (`("list")
     (overlook-courier-or-empty (mapconcat #'overlook-courier-persona--describe (overlook-courier-persona-names) "\n")
         "No personas."))
    (`("start" . ,rest)
     (pcase-let* ((`(,options . ,rest) (overlook-courier-options rest '("--engine" "--effort")))
                  (`(,name ,directory ,task) rest))
       (unless (and name (<= (length rest) 3))
         (user-error "Usage: courier persona start [--engine E] [--effort L] NAME [DIR [TASK]]"))
       (overlook-courier-persona-start name :directory directory :task task :from (and (overlook-courier-agent from) from)
                              :engine (overlook-courier-option "--engine" options)
                              :effort (overlook-courier-option "--effort" options))
       (format "Started persona %s.%s" name
               (if (and task (overlook-courier-agent from))
                   "  It reports when done or stuck.  End your turn now."
                 ""))))
    (_ (user-error "Usage: courier persona list \
| start [--engine E] [--effort L] NAME [DIR [TASK]]"))))

(add-hook 'overlook-courier-offline-functions #'overlook-courier-persona-names)
(add-hook 'overlook-courier-start-functions #'overlook-courier-persona--start-offline)

(provide 'overlook-courier-persona)
;;; overlook-courier-persona.el ends here
