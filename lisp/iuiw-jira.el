;;; iuiw-jira.el --- Jira tickets of workspace projects through acli -*- lexical-binding: t; -*-

;;; Commentary:
;; project.md 的 front matter 用 jira: [KEY-1, KEY-2] 列出项目的 ticket，只追加不删；没有就不显示。
;; 看板上进行中项目的标题下，未完成的 ticket 各一行（状态类别的符号 ○ ◐、key、摘要，状态名在 tooltip），
;; 已完成的收进折叠的「✓ N done」行。
;; 进行中项目的 ticket 用一次 acli search 查完，渲染只读缓存，过期 `iuiw-jira-interval' 秒后在后台重查；
;; 一起查失败（有 key 不存在或没权限）时逐个查。
;; RET 用浏览器打开；`iuiw-jira-add-ticket' 追加到当前项目并 commit，`iuiw-jira-browse' 打开其中一个。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'iuiw-workspace)

(declare-function overlook-row "overlook-row")
(declare-function overlook-refresh "overlook")
(defvar overlook-project-functions)
(defvar overlook-data-functions)

(defgroup iuiw-jira nil
  "Jira tickets of workspace projects."
  :group 'tools
  :prefix "iuiw-jira-")

(defcustom iuiw-jira-interval 300
  "Seconds a fetched ticket stays fresh."
  :type 'integer)

(defcustom iuiw-jira-forbidden-workspaces '("me")
  "Workspaces whose project.md must not list tickets."
  :type '(repeat string))

(defvar iuiw-jira--tickets (make-hash-table :test #'equal)
  "Fetched tickets by key, each (TIME . PLIST).
PLIST has :summary :status :category :assignee, or :missing or :error.")

(defvar iuiw-jira--process nil
  "The running acli search, if any.")

(defconst iuiw-jira--key-regexp "\\`[A-Z][A-Z0-9_]*-[0-9]+\\'")

;;; Fetching

(defun iuiw-jira--ticket (item)
  "The plist of acli JSON work ITEM."
  (let-alist item
    (list :summary .fields.summary :status .fields.status.name
          :category .fields.status.statusCategory.key
          :assignee .fields.assignee.displayName)))

(defun iuiw-jira--parse (buffer)
  "Tickets of acli JSON in BUFFER as (KEY . PLIST).\nReturn :error when it is not JSON."
  (with-current-buffer buffer
    (goto-char (point-min))
    (condition-case nil
        (mapcar (lambda (item) (cons (alist-get 'key item) (iuiw-jira--ticket item)))
                (delq nil (json-parse-buffer :object-type 'alist :array-type 'list
                                             :null-object nil :false-object nil)))
      (error :error))))

(defun iuiw-jira--stale-p (key)
  "Non-nil when KEY was never fetched or is older than `iuiw-jira-interval'."
  (let ((entry (gethash key iuiw-jira--tickets)))
    (or (null entry) (> (- (float-time) (car entry)) iuiw-jira-interval))))

(defun iuiw-jira--ongoing-keys ()
  "Ticket keys of all ongoing projects."
  (delete-dups (seq-mapcat (lambda (card)
                             (and (iuiw-workspace--ongoing-p card) (plist-get card :jira)))
                           (iuiw-workspace--cards))))

(defun iuiw-jira--ensure ()
  "Fetch the stale tickets of ongoing projects, unless a fetch is running."
  (unless (or (process-live-p iuiw-jira--process) (not (executable-find "acli")))
    (when-let* ((keys (seq-filter #'iuiw-jira--stale-p (iuiw-jira--ongoing-keys))))
      (iuiw-jira--fetch keys))))

(defun iuiw-jira--fetch (keys &optional singly)
  "Look up KEYS in one acli search, then each of SINGLY alone."
  (let ((out (generate-new-buffer " *iuiw-jira*"))
        (err (generate-new-buffer " *iuiw-jira-err*")))
    (setq iuiw-jira--process
          (make-process
           :name "iuiw-jira" :buffer out :noquery t :connection-type 'pipe
           :stderr (make-pipe-process :name "iuiw-jira-err" :buffer err :noquery t)
           :command (list "acli" "jira" "workitem" "search" "--json"
                          "--limit" (number-to-string (length keys))
                          "--fields" "key,summary,status,assignee"
                          "--jql" (format "key in (%s)" (string-join keys ", ")))
           :sentinel (lambda (process _event)
                       (unless (process-live-p process)
                         (unwind-protect (iuiw-jira--fetched process keys singly out err)
                           (kill-buffer out)
                           (kill-buffer err))))))))

(defun iuiw-jira--fetched (process keys singly out err)
  "Store what PROCESS found of KEYS in OUT, then look up SINGLY one by one.
A failed search of several keys puts them all in SINGLY; ERR has the reason."
  (let ((now (float-time))
        (found (if (zerop (process-exit-status process)) (iuiw-jira--parse out) :error)))
    (cond
     ((not (eq found :error))
      (dolist (key keys)
        (puthash key (cons now (or (alist-get key found nil nil #'equal) '(:missing t)))
                 iuiw-jira--tickets)))
     ((cdr keys) (setq singly (append keys singly)))
     (t
      (let ((reason (string-trim (with-current-buffer err (buffer-string)))))
        (unless (equal reason (plist-get (cdr (gethash (car keys) iuiw-jira--tickets)) :error))
          (message "acli: %s: %s" (car keys) reason))
        (puthash (car keys) (list now :error reason) iuiw-jira--tickets))))
    (setq iuiw-jira--process nil)
    (if singly
        (iuiw-jira--fetch (list (car singly)) (cdr singly))
      (when (fboundp 'overlook-refresh) (overlook-refresh)))))

;;; Dashboard

(defun iuiw-jira--get (key)
  "The fetched plist of KEY, or nil."
  (cdr (gethash key iuiw-jira--tickets)))

(defun iuiw-jira--done-p (key)
  "Non-nil when KEY's status is in Jira's done category."
  (equal (plist-get (iuiw-jira--get key) :category) "done"))

(defun iuiw-jira--status (ticket)
  "What the dashboard says of TICKET's status."
  (cond ((plist-get ticket :error) "?")
        ((plist-get ticket :missing) "not found")
        ((plist-get ticket :status))
        (t "…")))

(defun iuiw-jira--glyph (ticket)
  "The glyph of TICKET's status category."
  (pcase (plist-get ticket :category)
    ("new" "○")
    ("indeterminate" "◐")
    ("done" "✓")
    (_ (if (or (plist-get ticket :error) (plist-get ticket :missing)) "?" "…"))))

(defun iuiw-jira--row (key project)
  "The row of ticket KEY under PROJECT; its tooltip names the status."
  (let ((ticket (iuiw-jira--get key)))
    (overlook-row
     :id (list 'jira key project)
     :content (list (iuiw-jira--glyph ticket) " " key
                    (and (plist-get ticket :summary)
                         (list :fit (plist-get ticket :summary) :before " ")))
     :face 'shadow
     :help (or (plist-get ticket :error) (iuiw-jira--status ticket))
     :action (lambda () (iuiw-jira-browse key)))))

(defun iuiw-jira--project-rows (name)
  "Rows of ongoing project NAME's tickets.
Open ones each have a row, then done ones fold under a line."
  (let ((card (iuiw-workspace--card name)))
    (when-let* (((iuiw-workspace--ongoing-p card))
                (keys (plist-get card :jira)))
      (iuiw-jira--ensure)
      (let ((done (seq-filter #'iuiw-jira--done-p keys)))
        (append (mapcar (lambda (key) (iuiw-jira--row key name))
                        (seq-remove #'iuiw-jira--done-p keys))
                (and done
                     (list (overlook-row
                            :id (list 'jira-done name)
                            :content (format "✓ %d done" (length done))
                            :face 'shadow
                            :folded t
                            :children (mapcar (lambda (key) (iuiw-jira--row key name))
                                              done)))))))))

(defun iuiw-jira-data (key)
  "Ticket data identified by KEY, for `overlook-data-functions'."
  (pcase key
    (`(jira ,ticket-key . ,_)
     (let ((ticket (iuiw-jira--get ticket-key)))
       (list :kind "ticket"
             :title (or (plist-get ticket :summary) ticket-key)
             :subtitle (concat ticket-key " · " (iuiw-jira--status ticket))
             :status (plist-get ticket :category))))))

;;; Commands

(defun iuiw-jira--current-card ()
  "The card of the current project."
  (or (iuiw-workspace--card (file-name-nondirectory
                             (directory-file-name (iuiw-workspace--current-card-root))))
      (user-error "No project.md for this project")))

;;;###autoload
(defun iuiw-jira-browse (key)
  "Open ticket KEY in a browser; interactively, one of the current project's."
  (interactive
   (let ((keys (or (plist-get (iuiw-jira--current-card) :jira)
                   (user-error "This project.md lists no jira tickets"))))
     (list (if (cdr keys)
               (car (split-string
                     (completing-read
                      "Ticket: "
                      (mapcar (lambda (key)
                                (string-join (delq nil (list key (plist-get (iuiw-jira--get key) :summary)))
                                             "  "))
                              keys)
                      nil t)))
             (car keys)))))
  (unless (executable-find "acli") (user-error "acli not found"))
  (make-process :name "iuiw-jira-web" :noquery t
                :command (list "acli" "jira" "workitem" "view" key "--web")))

(defun iuiw-jira--lookup (key)
  "Fetch ticket KEY now and cache it; return its plist."
  (with-temp-buffer
    (unless (zerop (call-process "acli" nil '(t nil) nil "jira" "workitem" "view" key
                                 "--json" "--fields" "key,summary,status,assignee"))
      (user-error "acli cannot find %s" key))
    (goto-char (point-min))
    (let ((ticket (iuiw-jira--ticket (json-parse-buffer :object-type 'alist :array-type 'list
                                                        :null-object nil :false-object nil))))
      (puthash key (cons (float-time) ticket) iuiw-jira--tickets)
      ticket)))

(defun iuiw-jira--write-keys (file keys)
  "Save KEYS as the jira: field of card FILE, leaving the rest untouched."
  (with-current-buffer (find-file-noselect file)
    (when (or (buffer-modified-p) (not (verify-visited-file-modtime (current-buffer))))
      (user-error "Save or revert project.md first"))
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (unless (looking-at "---[ \t]*\n") (user-error "project.md needs YAML front matter"))
        (forward-line 1)
        (let ((end (save-excursion
                     (unless (re-search-forward "^---[ \t]*$" nil t)
                       (user-error "Unclosed project.md front matter"))
                     (line-beginning-position))))
          (if (re-search-forward "^jira:.*\n" end t)
              (delete-region (match-beginning 0) (match-end 0))
            (goto-char end)))
        (insert (format "jira: [%s]\n" (string-join keys ", ")))
        (save-buffer)))))

;;;###autoload
(defun iuiw-jira-add-ticket (key)
  "Append ticket KEY to the current project's jira: list and commit project.md.
It is not committed when project.md already had other uncommitted changes."
  (interactive (list (upcase (string-trim (read-string "Jira ticket: ")))))
  (unless (string-match-p iuiw-jira--key-regexp key) (user-error "Not a ticket key: %s" key))
  (unless (executable-find "acli") (user-error "acli not found"))
  (let* ((card (iuiw-jira--current-card))
         (file (plist-get card :file))
         (default-directory (file-name-directory file)))
    (when (member (plist-get card :workspace) iuiw-jira-forbidden-workspaces)
      (user-error "Tickets are not written to the %s workspace" (plist-get card :workspace)))
    (when (member key (plist-get card :jira)) (user-error "%s is already listed" key))
    (let ((ticket (iuiw-jira--lookup key))
          (clean (zerop (call-process "git" nil nil nil "diff" "--quiet" "HEAD" "--" "project.md"))))
      (iuiw-jira--write-keys file (append (plist-get card :jira) (list key)))
      (let ((committed (and clean
                            (zerop (call-process "git" nil nil nil "commit" "-q" "-m"
                                                 (format "%s: jira 加 %s" (plist-get card :id) key)
                                                 "--" "project.md")))))
        (when (fboundp 'overlook-refresh) (overlook-refresh))
        (message "%s %s%s" key (or (plist-get ticket :summary) "")
                 (if committed "" "  (project.md not committed)"))))))

;;;###autoload
(define-minor-mode iuiw-jira-dashboard-mode
  "Show the Jira tickets of ongoing projects under their headings."
  :global t
  :group 'iuiw-jira
  (if iuiw-jira-dashboard-mode
      (progn
        (add-hook 'overlook-project-functions #'iuiw-jira--project-rows -60)
        (add-hook 'overlook-data-functions #'iuiw-jira-data))
    (remove-hook 'overlook-project-functions #'iuiw-jira--project-rows)
    (remove-hook 'overlook-data-functions #'iuiw-jira-data)))

(provide 'iuiw-jira)
;;; iuiw-jira.el ends here
