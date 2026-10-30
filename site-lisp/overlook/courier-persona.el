;;; courier-persona.el --- Lasting identities for courier's agents -*- lexical-binding: t; -*-

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
;; folder NAME/ in one of `courier-persona-directories' holding
;; persona.md, its role and settings, and memory/, what it has learned.
;; An agent started as persona NAME gets the courier id NAME, so it is
;; reached at the same address whatever engine runs it and however often
;; it restarts; one agent at most runs a persona.  Messaging a persona
;; nobody runs starts it.
;;
;; persona.md opens with front matter of `key: value' lines; a # after
;; a space starts a comment:
;;
;;   ---
;;   engine: claude          the agent to run it, required
;;   effort: medium          its reasoning effort
;;   directory: ~/src/shop   where it starts, else the folder above the personas
;;   description: one line shown in lists
;;   avatar: 🦉              shown beside its name
;;   personality: calm, exacting
;;   tone: terse
;;   ---
;;
;; The rest, its role, rules and any background, is the persona's
;; briefing when an agent starts as it, with the personality, the tone
;; and the index of its memory.  The agent keeps that memory itself.

;;; Code:

(require 'courier)

(defcustom courier-persona-directories nil
  "Directories holding a folder per persona; the first one is for new personas."
  :type '(repeat directory)
  :group 'courier)

(defcustom courier-persona-index-lines 200
  "Most lines of a persona's MEMORY.md given to an agent starting as it."
  :type 'natnum
  :group 'courier)

(defconst courier-persona-fields
  '(engine effort directory description avatar personality tone)
  "Fields persona.md's front matter may set.")

(defconst courier-persona-reserved '("all" "user")
  "Names rooms give other meanings, which no persona may have.")

(defun courier-persona-name-p (name)
  "Non-nil when NAME may name a persona."
  (and (string-match-p "\\`[a-z0-9][a-z0-9_-]*\\'" name)
       (not (member name courier-persona-reserved))))

(defun courier-persona--folders ()
  "Alist of each persona's name to its folder; the first directory wins a name."
  (let (folders)
    (dolist (directory courier-persona-directories)
      (when (file-directory-p directory)
        (dolist (file (directory-files directory t))
          (when (and (courier-persona-name-p (file-name-nondirectory file))
                     (file-exists-p (expand-file-name "persona.md" file)))
            (unless (assoc (file-name-nondirectory file) folders)
              (push (cons (file-name-nondirectory file) (file-name-as-directory file))
                    folders))))))
    (nreverse folders)))

(defun courier-persona-names ()
  "Names of all personas, sorted."
  (sort (mapcar #'car (courier-persona--folders)) #'string<))

(defun courier-persona--parse (text)
  "Plist of the front matter fields in persona.md's TEXT, and :body the rest."
  (let (fields (body text))
    (when (string-match "\\`---[ \t]*\n\\(\\(?:.*\n\\)*?\\)---[ \t]*\\(?:\n\\|\\'\\)" text)
      (setq body (substring text (match-end 0)))
      (dolist (line (split-string (match-string 1 text) "\n" t))
        (when (string-match "\\`\\([a-z]+\\):\\(.*\\)\\'" line)
          (let ((key (intern (match-string 1 line)))
                (value (string-trim (replace-regexp-in-string
                                     "\\(?:\\`\\|[ \t]\\)#.*" "" (match-string 2 line)))))
            (when (and (memq key courier-persona-fields) (not (string-empty-p value)))
              (setq fields (plist-put fields (intern (format ":%s" key)) value)))))))
    (plist-put fields :body (string-trim body))))

(defun courier-persona (name)
  "Persona NAME as a plist of its fields, :body, :name and :folder; or nil."
  (when-let* ((folder (alist-get name (courier-persona--folders) nil nil #'equal)))
    (append (list :name name :folder folder)
            (courier-persona--parse
             (with-temp-buffer
               (insert-file-contents (expand-file-name "persona.md" folder))
               (buffer-string))))))

(defun courier-persona-memory (persona)
  "Folder of PERSONA's memory."
  (expand-file-name "memory/" (plist-get persona :folder)))

(defun courier-persona-directory (persona)
  "Where PERSONA starts: its directory, else the folder above the personas."
  (if-let* ((directory (plist-get persona :directory)))
      (expand-file-name directory)
    (file-name-directory (directory-file-name
                          (file-name-directory (directory-file-name (plist-get persona :folder)))))))

(defun courier-persona--index (persona)
  "PERSONA's MEMORY.md, cut to `courier-persona-index-lines' lines, or nil."
  (let ((file (expand-file-name "MEMORY.md" (courier-persona-memory persona))))
    (when (file-readable-p file)
      (let* ((lines (with-temp-buffer
                      (insert-file-contents file)
                      (split-string (string-trim (buffer-string)) "\n")))
             (cut (- (length lines) courier-persona-index-lines)))
        (unless (equal lines '(""))
          (concat (string-join (take courier-persona-index-lines lines) "\n")
                  (when (> cut 0) (format "\n[… %d more lines in MEMORY.md]" cut))))))))

(defun courier-persona-briefing (persona engine)
  "What an agent of ENGINE starting as PERSONA is told."
  (let ((name (plist-get persona :name))
        (memory (courier-persona-memory persona))
        (index (courier-persona--index persona)))
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
            (format "Your memory is in %s: a file per fact, each listed with a line \
in MEMORY.md.  Read a file when it bears on your work.  When your user \
corrects you, or you learn something about your role or how your user \
wants it done that will hold beyond this task, save it there and add its \
line to MEMORY.md; fix or delete a memory that proves wrong.  Knowledge \
about the code or the domain goes to the project's own notes instead.  %s"
                    (abbreviate-file-name memory)
                    (if index (concat "MEMORY.md now:\n\n" index) "It is empty so far."))))
     "\n\n")))

(cl-defun courier-persona-start (name &key directory task from engine effort wait)
  "Start persona NAME and return its id, NAME.
It starts in DIRECTORY, else the persona's own, run by ENGINE at
reasoning EFFORT, else the persona's.  FROM is the agent starting it, its
parent.  It works on TASK if non-nil.  With WAIT non-nil it idles, and
learns who it is with the first message it gets; otherwise it says it
is ready."
  (let* ((persona (or (courier-persona name) (user-error "No persona %s" name)))
         (engine (or engine (plist-get persona :engine)
                     (user-error "Persona %s names no engine" name))))
    (make-directory (courier-persona-memory persona) t)
    (let* ((briefing (courier-persona-briefing persona engine))
           (id (courier-spawn engine (or directory (courier-persona-directory persona))
                              (unless wait
                                (concat briefing "\n\n"
                                        (or task "Say in one line that you are ready.")))
                              from (or effort (plist-get persona :effort)) name)))
      (when wait (courier-note id briefing))
      id)))

(defun courier-persona--start-offline (id from)
  "Start persona ID, which FROM is messaging, to take the message; or nil."
  (when (courier-persona id)
    (message "courier: started persona %s for %s" id (or from "the user"))
    (courier-persona-start id :wait t)))

(defun courier-persona--describe (name)
  "A line describing persona NAME for `courier persona list'."
  (let ((persona (courier-persona name)))
    (format "%s  %s, %s%s" name
            (if (courier-agent name) "running" "offline")
            (or (plist-get persona :engine) "no engine")
            (if-let* ((description (plist-get persona :description)))
                (concat "  " description)
              ""))))

(defun courier-persona--options (args options)
  "Split ARGS into the values of the leading OPTIONS and the rest.
Returns (ALIST . REST), ALIST mapping each option given to its value."
  (let (values)
    (while (member (car args) options)
      (let ((option (pop args)))
        (push (cons option (or (pop args) (user-error "%s needs a value" option))) values)))
    (cons values args)))

(defun courier-persona-cli (from args)
  "Run the persona command ARGS for agent FROM and return its output."
  (pcase args
    (`("list")
     (or (mapconcat #'courier-persona--describe (courier-persona-names) "\n")
         "No personas."))
    (`("start" . ,rest)
     (pcase-let* ((`(,options . ,rest) (courier-persona--options rest '("--engine" "--effort")))
                  (`(,name ,directory ,task) rest))
       (unless (and name (<= (length rest) 3))
         (user-error "Usage: courier persona start [--engine E] [--effort L] NAME [DIR [TASK]]"))
       (courier-persona-start name :directory directory :task task :from (and (courier-agent from) from)
                              :engine (cdr (assoc "--engine" options))
                              :effort (cdr (assoc "--effort" options)))
       (format "Started persona %s.%s" name
               (if (and task (courier-agent from))
                   "  It reports when done or stuck.  End your turn now."
                 ""))))
    (_ (user-error "Usage: courier persona list \
| start [--engine E] [--effort L] NAME [DIR [TASK]]"))))

(add-hook 'courier-offline-functions #'courier-persona-names)
(add-hook 'courier-start-functions #'courier-persona--start-offline)

(provide 'courier-persona)
;;; courier-persona.el ends here
