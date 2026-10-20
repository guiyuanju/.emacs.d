;;; jgy-review.el --- Review a GitLab merge request in the review project -*- lexical-binding: t; -*-

;;; Commentary:
;; `jgy-review-mr' 把一组 MR 的仓库 clone 进 review 项目，清掉其余仓库；
;; `jgy-review-add-mr' 往进行中的 review 里再加 MR。参考仓库用 `jgy-workspace-clone-repo'。
;; HEAD 停在 MR 的 base、工作区是 MR 的 head，于是 MR 的改动就是未提交的改动：
;; overlook 列出改动的文件，RET 打开 ediff，agent 用 `git diff HEAD' 看。
;; 要在上面自己改代码时用 `jgy-review-edit' 把 HEAD 移到 MR 的 head。
;; 给 agent 的 prompt 只放进输入框，由你发送。

;;; Code:

(require 'jgy-workspace)
(require 'subr-x)

(declare-function agent-shell--start "agent-shell")
(declare-function agent-shell-buffers "agent-shell")
(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-unsubscribe "agent-shell")
(declare-function shell-maker-busy "shell-maker")
(declare-function overlook-agent-perspective "overlook-agent")
(declare-function agent-shell-anthropic-make-claude-code-config "agent-shell-anthropic")
(declare-function overlook-refresh "overlook")

(defcustom jgy-review-project "review"
  "Id of the project merge requests are reviewed in."
  :type 'string
  :group 'jgy-workspace)

(defcustom jgy-review-prompt "Review 这些 MR，多个时是一组相关改动：\n%s"
  "Prompt put in a new agent's input once the repos are ready.
%s lists the MR URLs."
  :type 'string
  :group 'jgy-workspace)

(defcustom jgy-review-add-prompt "加入这些相关的 MR，和前面的一起 review：\n%s"
  "Prompt put in the agent's input when MRs are added; %s lists their URLs."
  :type 'string
  :group 'jgy-workspace)

(defun jgy-review--api (host path)
  "Parsed JSON of GitLab API PATH on HOST."
  (json-parse-string (jgy-workspace--cli-output "glab" "api" "--hostname" host path)
                     :object-type 'alist :array-type 'list :null-object nil))

(defun jgy-review--read-mr (url)
  "The merge request at URL, as a plist."
  (unless (string-match "\\`https?://\\([^/]+\\)/\\(.+?\\)/-/merge_requests/\\([0-9]+\\)" url)
    (user-error "Not a merge request URL: %s" url))
  (let* ((host (match-string 1 url))
         (project (url-hexify-string (match-string 2 url)))
         (iid (match-string 3 url))
         (mr (jgy-review--api host (format "projects/%s/merge_requests/%s" project iid)))
         (repo (jgy-review--api host (format "projects/%s" project)))
         (ssh (equal (string-trim (jgy-workspace--cli-output
                                   "glab" "config" "get" "git_protocol" "--host" host))
                     "ssh"))
         (refs (alist-get 'diff_refs mr)))
    (list :url (alist-get 'web_url mr)
          :iid iid
          :title (alist-get 'title mr)
          :project (alist-get 'path repo)
          :path (alist-get 'path repo)
          :clone (alist-get (if ssh 'ssh_url_to_repo 'http_url_to_repo) repo)
          :base (alist-get 'base_sha refs)
          :head (alist-get 'head_sha refs))))

(defun jgy-review--git (dir &rest args)
  "Output of git ARGS in DIR, trimmed, or nil when it fails."
  (with-temp-buffer
    (let ((default-directory dir))
      (when (zerop (apply #'call-process "git" nil '(t nil) nil args))
        (string-trim (buffer-string))))))

(defun jgy-review--pristine-p (dir)
  "Non-nil when repo DIR holds nothing that is not on its remote.
The working tree, untracked files included, must match the recorded MR
head, or HEAD outside a review, with no unpushed commit or stash."
  (let* ((expected (or (jgy-review--git dir "config" "--get" "jgy.review.head") "HEAD"))
         (index (make-temp-file "jgy-review-index"))
         (tree (unwind-protect
                   (let ((process-environment
                          (cons (concat "GIT_INDEX_FILE=" index) process-environment))
                         (real (expand-file-name ".git/index" dir)))
                     ;; The real index's stat cache spares hashing unchanged files.
                     (when (file-exists-p real) (copy-file real index t))
                     (and (jgy-review--git dir "add" "-A")
                          (jgy-review--git dir "write-tree")))
                 (delete-file index))))
    (and tree
         (equal tree (jgy-review--git dir "rev-parse" (concat expected "^{tree}")))
         (equal "" (jgy-review--git dir "log" "--branches" "--not" "--remotes" "--oneline"))
         (equal "" (jgy-review--git dir "stash" "list")))))

(defun jgy-review--clear (root)
  "Delete the repos in project folder ROOT, asking about any with local work."
  (dolist (dir (directory-files root t directory-files-no-dot-files-regexp))
    (when (file-exists-p (expand-file-name ".git" dir))
      (unless (or (jgy-review--pristine-p dir)
                  (yes-or-no-p (format "%s has local changes; delete it anyway? "
                                       (file-name-nondirectory dir))))
        (user-error "Kept %s" dir))
      (dolist (buffer (buffer-list))
        (when (file-in-directory-p (buffer-local-value 'default-directory buffer) dir)
          (kill-buffer buffer)))
      (delete-directory dir t))))

(defun jgy-review--front-matter-end ()
  "Position of the line closing the current buffer's front matter."
  (save-excursion
    (goto-char (point-min))
    (forward-line 1)
    (re-search-forward "^---[ \t]*$")
    (line-beginning-position)))

(defun jgy-review--mrs (root)
  "URLs in the mrs field of ROOT's project.md."
  (with-current-buffer (find-file-noselect (expand-file-name "project.md" root))
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward "^mrs:[ \t]*" (jgy-review--front-matter-end) t)
        (json-parse-buffer :array-type 'list)))))

(defun jgy-review--write-card (root mrs fresh)
  "Record MRS in ROOT's project.md: their repos, the mrs field and Todos.
FRESH replaces the repos and mrs; otherwise MRS are added to them."
  (let ((repos (mapcar (lambda (mr) `((path . ,(plist-get mr :path))
                                      (url . ,(plist-get mr :clone))))
                       mrs))
        (urls (mapcar (lambda (mr) (plist-get mr :url)) mrs)))
    (jgy-workspace--write-repos
     root (if fresh repos (append (jgy-workspace--read-repos root) repos)))
    (unless fresh (setq urls (append (jgy-review--mrs root) urls)))
    (with-current-buffer (find-file-noselect (expand-file-name "project.md" root))
      (save-excursion
        (let ((end (copy-marker (jgy-review--front-matter-end))))
          (goto-char (point-min))
          (while (re-search-forward "^mrs?:" end t)
            (let ((beg (line-beginning-position)))
              (forward-line 1)
              (while (and (< (point) end) (looking-at "[ \t]+"))
                (forward-line 1))
              (delete-region beg (point))))
          (goto-char end)
          (insert "mrs: [" (mapconcat (lambda (url) (concat "\n  " (json-encode url))) urls ",")
                  "\n  ]\n"))
        (dolist (mr mrs)
          (goto-char (point-min))
          (unless (search-forward (plist-get mr :url) nil t 2)
            (goto-char (point-min))
            (when (re-search-forward "^## Todo[ \t]*\n" nil t)
              (insert (format "- [ ] %s !%s %s #now %s\n" (plist-get mr :project) (plist-get mr :iid)
                              (plist-get mr :title) (plist-get mr :url))))))
        (save-buffer)))))

(defun jgy-review--run (steps done)
  "Run git STEPS one after another, then call DONE.
Each step is (DIR . ARGS).  On failure show the log and stop."
  (let ((log (get-buffer-create "*jgy-review*")))
    (if (null steps)
        (funcall done)
      (pcase-let ((`(,dir . ,args) (car steps)))
        (with-current-buffer log
          (goto-char (point-max))
          (insert "$ git " (string-join args " ") "\n"))
        (let ((default-directory dir))
          (make-process
           :name "jgy-review" :buffer log :noquery t
           :command (cons "git" args)
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (if (zerop (process-exit-status process))
                   (jgy-review--run (cdr steps) done)
                 (message "Review setup failed at git %s" (car args))
                 (display-buffer log))))))))))

(defun jgy-review--steps (root mr)
  "Git steps that set up MR's repo in ROOT: HEAD at its base, the tree at its head."
  (let ((repo (expand-file-name (plist-get mr :path) root))
        (head (plist-get mr :head)))
    `((,root "clone" "--filter=blob:none" "--" ,(plist-get mr :clone) ,repo)
      ;; GitLab keeps every MR's head here, fork or not.
      (,repo "fetch" "origin" ,(format "refs/merge-requests/%s/head" (plist-get mr :iid)))
      (,repo "checkout" "--detach" ,head)
      (,repo "reset" "-q" ,(plist-get mr :base))
      ;; Intent-to-add counts the MR's new files in `git diff HEAD'.
      (,repo "add" "-N" ".")
      (,repo "config" "jgy.review.head" ,head))))

(defun jgy-review--name-folders (root mrs)
  "MRS, each given a folder name free in ROOT: its repo's, else with the MR number."
  (let (taken)
    (dolist (mr mrs mrs)
      (let ((path (plist-get mr :path)))
        (when (or (member path taken) (file-exists-p (expand-file-name path root)))
          (setq path (format "%s-%s" path (plist-get mr :iid))))
        (when (or (member path taken) (file-exists-p (expand-file-name path root)))
          (user-error "%s is already in %s" path root))
        (push path taken)
        (plist-put mr :path path)))))

(defun jgy-review--agent ()
  "The agent of the review project's perspective, or nil."
  (when (fboundp 'agent-shell-buffers)
    (seq-find (lambda (buffer)
                (equal (overlook-agent-perspective buffer) jgy-review-project))
              (agent-shell-buffers))))

(defun jgy-review--start-agent (root)
  "Start a Claude agent in project folder ROOT and return its buffer."
  (require 'agent-shell)
  (require 'agent-shell-anthropic)
  (let ((default-directory root))
    (agent-shell--start :config (agent-shell-anthropic-make-claude-code-config)
                        :new-session t :session-strategy 'new :cwd root)))

(defun jgy-review--insert (agent text)
  "Put TEXT in AGENT's input for you to send."
  (agent-shell-insert :text text :no-focus t :shell-buffer agent)
  (message "Review prompt is in %s; RET there sends it" (buffer-name agent)))

(defun jgy-review--prompt (agent template mrs)
  "Put TEMPLATE filled with the URLs of MRS in AGENT's input, unsent.
A busy AGENT gets it once its turn is done."
  (when (buffer-live-p agent)
    (let ((text (format template (mapconcat (lambda (mr) (concat "- " (plist-get mr :url)))
                                            mrs "\n"))))
      (if (with-current-buffer agent (shell-maker-busy))
          (let (token)
            (setq token (agent-shell-subscribe-to
                         :shell-buffer agent :event 'turn-complete
                         :on-event (lambda (_event)
                                     (agent-shell-unsubscribe :subscription token)
                                     (jgy-review--insert agent text)))))
        (jgy-review--insert agent text)))))

(defun jgy-review--read-urls (prompt)
  "Merge request URLs read with PROMPT, separated by whitespace."
  (or (split-string (read-string prompt (thing-at-point 'url t)))
      (user-error "No merge request URL")))

(defun jgy-review--setup (urls fresh)
  "Set up the merge requests at URLS in the review project.
FRESH clears the project first and starts a new agent; otherwise the
project's agent is told about them."
  (let* ((root (or (jgy-workspace-project-dir jgy-review-project)
                   (user-error "No project %s" jgy-review-project)))
         (mrs (mapcar #'jgy-review--read-mr urls))
         (agent (unless fresh (jgy-review--agent))))
    (when fresh (jgy-review--clear root))
    (let ((mrs (jgy-review--name-folders root mrs)))
      (jgy-review--write-card root mrs fresh)
      (jgy-workspace-open-project jgy-review-project)
      (unless agent (setq agent (jgy-review--start-agent root)))
      (message "Cloning %s..." (mapconcat (lambda (mr) (plist-get mr :path)) mrs ", "))
      (jgy-review--run
       (seq-mapcat (lambda (mr) (jgy-review--steps root mr)) mrs)
       (lambda ()
         (message "Reviewing %s" (mapconcat (lambda (mr) (concat "!" (plist-get mr :iid))) mrs " "))
         (when (fboundp 'overlook-refresh) (overlook-refresh))
         (jgy-review--prompt agent (if fresh jgy-review-prompt jgy-review-add-prompt) mrs))))))

;;;###autoload
(defun jgy-review-mr (urls)
  "Review the GitLab merge requests at URLS in the `jgy-review-project' project.
Replace the project's repos with a clone of each MR's repo, HEAD at the
MR's base and the working tree at its head, record the MRs in
project.md, and start an agent that reviews them once the clones are done."
  (interactive (list (jgy-review--read-urls "Merge request URLs: ")))
  (jgy-review--setup urls t))

;;;###autoload
(defun jgy-review-add-mr (urls)
  "Add the merge requests at URLS to the review in progress.
Their repos are cloned next to the others and the agent is told."
  (interactive (list (jgy-review--read-urls "Add merge request URLs: ")))
  (jgy-review--setup urls nil))

;;;###autoload
(defun jgy-review-edit ()
  "Move HEAD of the reviewed repo to the MR's head, keeping the working tree.
Only your own edits are then uncommitted, ready for a branch and a commit."
  (interactive)
  (let* ((dir (or (locate-dominating-file default-directory ".git")
                  (user-error "Not in a repo")))
         (head (or (jgy-review--git dir "config" "--get" "jgy.review.head")
                   (user-error "%s is not set up by jgy-review-mr" dir))))
    (unless (jgy-review--git dir "reset" "-q" head)
      (user-error "git reset %s failed" head))
    (when (fboundp 'overlook-refresh) (overlook-refresh))
    (message "HEAD is at the MR's head; only your edits are uncommitted")))

(provide 'jgy-review)
;;; jgy-review.el ends here
