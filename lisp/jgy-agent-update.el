;;; jgy-agent-update.el --- Keep agent-shell and its agents up to date -*- lexical-binding: t; -*-

;;; Commentary:
;; agent 由 acp.el + agent-shell 驱动，跑的是 npm 全局装的 ACP adapter 和 agent 本体。
;; 任何一层落后，ACP 握手、以及 overlook 读取 Claude 用量的 _meta 字段都可能对不上。
;; 启动后空闲时查一遍：npm 包问 registry，Homebrew cask 问 brew，Emacs 包 fetch 后比对 upstream；
;; 旧的和根本没装的一起提示，确认后 npm 装 @latest、brew 升级或安装、elpaca 拉新版。
;; 终端用的 claude 来自 Homebrew cask，与 adapter 自带的那份互不相干，所以两边都查。
;; claude 和 codex 本体是各自 ACP adapter 的依赖，随它一起更新，所以不单独列。

;;; Code:

(require 'seq)

(declare-function elpaca-get "elpaca")
(declare-function elpaca-pull "elpaca")
(declare-function elpaca-process-queues "elpaca")
(declare-function elpaca<-source-dir "elpaca")

(defconst jgy-agent-update-npm-packages
  '(("claude" "@agentclientprotocol/claude-agent-acp")
    ("codex" "@agentclientprotocol/codex-acp")
    ("pi" "pi-acp" "@earendil-works/pi-coding-agent"))
  "Agent name to the npm packages it runs on, its ACP adapter first.
Claude's and Codex's own CLIs ship as dependencies of their adapters, so
they are not listed.")

(defconst jgy-agent-update-brew-casks '("claude-code@latest")
  "Homebrew casks providing the agents' command-line tools.")

(defconst jgy-agent-update-elpaca-packages '(acp shell-maker agent-shell)
  "Emacs packages driving the agents, updated through elpaca.")

;; A finding is (KIND LABEL DETAIL PAYLOAD): KIND says how to install it, LABEL
;; and DETAIL are for the prompt, PAYLOAD is the npm package or the elpaca id.
(defvar jgy-agent-update--findings nil
  "What the check in progress has found so far.")

(defvar jgy-agent-update--pending 0
  "How many probes the check in progress is still waiting on.")

(defvar jgy-agent-update--verbose nil
  "Whether the check in progress should report having nothing to do.")

(defun jgy-agent-update--describe (findings)
  "Return a one-line summary of FINDINGS."
  (mapconcat (pcase-lambda (`(,_kind ,label ,detail ,_payload))
               (format "%s %s" label detail))
             findings ", "))

(defun jgy-agent-update--payloads (kind findings)
  "Return the payloads of the FINDINGS whose kind is KIND."
  (seq-keep (lambda (finding)
              (and (eq (car finding) kind) (nth 3 finding)))
            findings))

(defun jgy-agent-update--settle ()
  "Account for one finished probe, and offer the findings once none are left."
  (setq jgy-agent-update--pending (1- jgy-agent-update--pending))
  (when (zerop jgy-agent-update--pending)
    (let ((findings (sort jgy-agent-update--findings :key #'cadr :lessp #'string<)))
      (setq jgy-agent-update--findings nil)
      (cond (findings (jgy-agent-update--offer findings))
            (jgy-agent-update--verbose (message "Agents are up to date"))))))

(defun jgy-agent-update--probe (name command directory callback)
  "Run shell COMMAND in DIRECTORY as one probe of the check in progress.
CALLBACK is called with the command's output and exit status."
  (setq jgy-agent-update--pending (1+ jgy-agent-update--pending))
  (let ((buffer (generate-new-buffer (format " *%s*" name)))
        (default-directory (or directory default-directory)))
    (make-process
     :name name
     :buffer buffer
     :command (list shell-file-name shell-command-switch command)
     :sentinel (lambda (process _event)
                 (unless (process-live-p process)
                   (let ((output (with-current-buffer buffer (buffer-string))))
                     (kill-buffer buffer)
                     (funcall callback output (process-exit-status process))
                     (jgy-agent-update--settle)))))))

(defun jgy-agent-update--json (output)
  "Return OUTPUT parsed as a JSON object, or nil if npm printed nothing usable."
  (ignore-errors (json-parse-string output :object-type 'alist)))

(defun jgy-agent-update--npm-findings (installed outdated)
  "Return findings for the watched npm packages.
INSTALLED is the dependency alist of `npm ls', OUTDATED the report of
`npm outdated'; both cover every global package, not just ours."
  (seq-keep
   (lambda (name)
     (let ((entry (alist-get (intern name) outdated))
           (label (car (last (split-string name "/")))))
       (cond ((and entry (not (equal (alist-get 'current entry)
                                     (alist-get 'latest entry))))
              (list 'npm label (format "%s→%s" (alist-get 'current entry)
                                       (alist-get 'latest entry))
                    name))
             ;; npm outdated says nothing about packages that are not installed.
             ((alist-get (intern name) installed) nil)
             (t (list 'npm label "not installed" name)))))
   (apply #'append (mapcar #'cdr jgy-agent-update-npm-packages))))

(defun jgy-agent-update--check-npm ()
  "Ask npm which of the watched packages are missing or behind the registry."
  (jgy-agent-update--probe
   ;; Through a shell because npm warns on stderr, which would spoil the JSON,
   ;; and npm outdated exits non-zero precisely when something is outdated.
   "npm-ls" "npm ls --global --depth=0 --json 2>/dev/null" nil
   (lambda (output _status)
     (let ((installed (alist-get 'dependencies (jgy-agent-update--json output))))
       (jgy-agent-update--probe
        "npm-outdated" "npm outdated --global --json 2>/dev/null" nil
        (lambda (output _status)
          (dolist (finding (jgy-agent-update--npm-findings
                            installed (jgy-agent-update--json output)))
            (push finding jgy-agent-update--findings))))))))

(defun jgy-agent-update--brew-findings (casks)
  "Return findings for CASKS, the cask list of `brew info --json=v2'."
  (seq-keep
   (lambda (cask)
     (let ((token (alist-get 'token cask))
           (installed (alist-get 'installed cask))
           (latest (alist-get 'version cask)))
       (cond ((not (stringp installed))
              (list 'brew-install token "not installed" token))
             ;; Casks versioned "latest" cannot be compared.
             ((and (not (equal latest "latest")) (not (equal installed latest)))
              (list 'brew-upgrade token (format "%s→%s" installed latest) token)))))
   casks))

(defun jgy-agent-update--check-brew ()
  "Ask Homebrew which of the watched casks are missing or behind."
  (jgy-agent-update--probe
   "brew-info"
   (concat "brew info --cask --json=v2 "
           (mapconcat #'shell-quote-argument jgy-agent-update-brew-casks " ")
           " 2>/dev/null")
   nil
   (lambda (output _status)
     (dolist (finding (jgy-agent-update--brew-findings
                       (alist-get 'casks (jgy-agent-update--json output))))
       (push finding jgy-agent-update--findings)))))

(defun jgy-agent-update--check-elpaca ()
  "Fetch each watched Emacs package's remote and note the ones behind upstream."
  (when (featurep 'elpaca)
    (dolist (id jgy-agent-update-elpaca-packages)
      (when-let* ((e (elpaca-get id)))
        (jgy-agent-update--probe
         (format "elpaca-behind-%s" id)
         "git fetch --quiet && git rev-list --count 'HEAD..@{u}'"
         (elpaca<-source-dir e)
         (lambda (output status)
           (let ((behind (if (zerop status) (string-to-number output) 0)))
             (when (> behind 0)
               (push (list 'elpaca (symbol-name id)
                           (format "+%d commit%s" behind (if (= behind 1) "" "s"))
                           id)
                     jgy-agent-update--findings)))))))))

(defun jgy-agent-update--install (findings)
  "Install every update in FINDINGS, each at its latest version."
  (let ((ids (jgy-agent-update--payloads 'elpaca findings)))
    (message "Updating %s…%s" (jgy-agent-update--describe findings)
             (if ids "  Emacs packages report in M-x elpaca-log." ""))
    ;; The probe fetched already, but `elpaca-pull' is the supported entry
    ;; point and it also rebuilds the package after merging.
    (when ids
      (dolist (id ids) (elpaca-pull id))
      (elpaca-process-queues)))
  (let* ((npm (jgy-agent-update--payloads 'npm findings))
         (upgrade (jgy-agent-update--payloads 'brew-upgrade findings))
         (install (jgy-agent-update--payloads 'brew-install findings))
         (commands
          (delq nil
                (list (and npm (append '("npm" "install" "--global")
                                       (mapcar (lambda (name) (concat name "@latest"))
                                               npm)))
                      (and upgrade (append '("brew" "upgrade" "--cask") upgrade))
                      (and install (append '("brew" "install" "--cask") install))))))
    (when commands
      (with-current-buffer (get-buffer-create "*agent update*") (erase-buffer))
      (jgy-agent-update--run commands))))

(defun jgy-agent-update--run (commands)
  "Run COMMANDS one after another in the *agent update* buffer.
One at a time, since concurrent brew commands contend for brew's lock."
  (if (null commands)
      (message "Agents updated; restart any running agent shell")
    (let ((buffer (get-buffer "*agent update*"))
          (command (car commands)))
      (make-process
       :name (string-join (seq-take command 2) "-")
       :buffer buffer
       :command command
       :sentinel (lambda (process _event)
                   (unless (process-live-p process)
                     (if (zerop (process-exit-status process))
                         (jgy-agent-update--run (cdr commands))
                       (message "%s failed" (string-join (seq-take command 2) " "))
                       (display-buffer buffer))))))))

(defun jgy-agent-update--offer (findings)
  "Ask whether to install FINDINGS, waiting until the minibuffer is free."
  (if (active-minibuffer-window)
      (run-with-idle-timer 60 nil #'jgy-agent-update--offer findings)
    (when (y-or-n-p (format "Agent updates available (%s).  Update? "
                            (jgy-agent-update--describe findings)))
      (jgy-agent-update--install findings))))

(defun jgy-agent-update-check (&optional verbose)
  "Offer to install the agent updates npm and elpaca report.
Covers every agent in `jgy-agent-update-npm-packages', every cask in
`jgy-agent-update-brew-casks' and every Emacs package in
`jgy-agent-update-elpaca-packages', and offers packages that
are not installed at all for installation too.  With VERBOSE, also
report when there is nothing to do, as when called interactively."
  (interactive (list t))
  (cond
   ((> jgy-agent-update--pending 0)
    (when verbose (message "Already checking for agent updates")))
   (t
    (setq jgy-agent-update--verbose verbose
          jgy-agent-update--findings nil
          ;; Counted as a probe itself, so that the real ones cannot settle the
          ;; check before all of them are queued, and so that queueing none
          ;; still reports.
          jgy-agent-update--pending 1)
    (when verbose (message "Checking for agent updates…"))
    (when (executable-find "npm") (jgy-agent-update--check-npm))
    (when (executable-find "brew") (jgy-agent-update--check-brew))
    (jgy-agent-update--check-elpaca)
    (jgy-agent-update--settle))))

(provide 'jgy-agent-update)
;;; jgy-agent-update.el ends here
