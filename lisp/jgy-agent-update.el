;;; jgy-agent-update.el --- Keep agent-shell and its agents up to date -*- lexical-binding: t; -*-

;;; Commentary:
;; agent 由 acp.el + agent-shell 驱动，跑的是 npm 全局装的 ACP adapter 和 agent 本体。
;; 任何一层落后，ACP 握手、以及 overlook 读取 Claude 用量的 _meta 字段都可能对不上。
;; 启动后空闲时查一遍：npm 包问 registry，Homebrew cask 问 brew，Emacs 包 fetch 后比对 upstream，
;; 以二进制发布的 ACP agent（如 Antigravity）问 ACP registry；
;; 旧的和根本没装的一起提示，确认后 npm 装 @latest、brew 升级或安装、elpaca 拉新版、二进制下载解压。
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

(defconst jgy-agent-update-acp-binaries
  '(("antigravity-acp" . agent-shell-antigravity-acp-command))
  "ACP registry agents shipped as binaries, each with its command variable.
They are installed under `jgy-agent-update-acp-directory', and
`jgy-agent-update-acp-use' points the variables at them.")

(defvar jgy-agent-update-acp-directory (locate-user-emacs-file "var/acp/")
  "Folder holding one folder per agent of `jgy-agent-update-acp-binaries'.
Each folder also keeps the registry entry it was installed from, as agent.json.")

(defconst jgy-agent-update-acp-registry
  "https://raw.githubusercontent.com/agentclientprotocol/registry/main/%s/agent.json"
  "URL of an ACP registry entry, given the agent's id.")

;; A finding is (KIND LABEL DETAIL PAYLOAD): KIND says how to install it, LABEL
;; and DETAIL are for the prompt, PAYLOAD is the npm package, the elpaca id or,
;; for an ACP binary, its id and registry entry.
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

;;;; ACP registry binaries

(defun jgy-agent-update--acp-platform ()
  "This machine's platform as the ACP registry names it, like darwin-aarch64."
  (format "%s-%s"
          (pcase system-type ('darwin "darwin") ('windows-nt "windows") (_ "linux"))
          (pcase (car (split-string system-configuration "-"))
            ((or "x86_64" "amd64") "x86_64")
            ((or "aarch64" "arm64") "aarch64")
            (arch arch))))

(defun jgy-agent-update--acp-folder (id)
  "The folder agent ID is installed in, without a trailing slash."
  (directory-file-name (expand-file-name id jgy-agent-update-acp-directory)))

(defun jgy-agent-update--acp-installed (id)
  "The registry entry agent ID was installed from, or nil if it is not installed."
  (let ((file (expand-file-name "agent.json" (jgy-agent-update--acp-folder id))))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (ignore-errors (json-parse-buffer :object-type 'alist))))))

(defun jgy-agent-update--acp-binary (entry)
  "The binary distribution of registry ENTRY for this platform."
  (alist-get (intern (jgy-agent-update--acp-platform))
             (alist-get 'binary (alist-get 'distribution entry))))

(defun jgy-agent-update-acp-use ()
  "Point the command variable of each installed ACP binary agent at it."
  (pcase-dolist (`(,id . ,variable) jgy-agent-update-acp-binaries)
    (when-let* ((binary (jgy-agent-update--acp-binary (jgy-agent-update--acp-installed id))))
      (set variable (cons (expand-file-name (alist-get 'cmd binary)
                                            (jgy-agent-update--acp-folder id))
                          (append (alist-get 'args binary) nil))))))

(defun jgy-agent-update--check-acp ()
  "Ask the ACP registry which of the watched binary agents are missing or behind."
  (pcase-dolist (`(,id . ,_variable) jgy-agent-update-acp-binaries)
    (jgy-agent-update--probe
     (format "acp-registry-%s" id)
     (concat "curl -fsSL " (shell-quote-argument (format jgy-agent-update-acp-registry id)))
     nil
     (lambda (output _status)
       (let* ((entry (jgy-agent-update--json output))
              (latest (alist-get 'version entry))
              (current (alist-get 'version (jgy-agent-update--acp-installed id))))
         (when (and latest (jgy-agent-update--acp-binary entry)
                    (not (equal current latest)))
           (push (list 'acp id (if current (format "%s→%s" current latest) "not installed")
                       (list id output))
                 jgy-agent-update--findings)))))))

(defconst jgy-agent-update--acp-install-script
  "set -e
tmp=$(mktemp -d)
trap 'rm -rf \"$tmp\"' EXIT
curl -fsSL -o \"$tmp/archive\" \"$1\"
mkdir \"$tmp/agent\"
case \"$1\" in
  *.zip) unzip -q \"$tmp/archive\" -d \"$tmp/agent\" ;;
  *) tar -xf \"$tmp/archive\" -C \"$tmp/agent\" ;;
esac
chmod +x \"$tmp/agent/$4\"
printf '%s' \"$3\" > \"$tmp/agent/agent.json\"
mkdir -p \"$(dirname \"$2\")\"
rm -rf \"$2.old\"
if [ -e \"$2\" ]; then mv \"$2\" \"$2.old\"; fi
mv \"$tmp/agent\" \"$2\"
rm -rf \"$2.old\""
  "Install an ACP binary: $1 archive URL, $2 folder, $3 registry entry, $4 command.
The new folder replaces the old one whole, so running agents keep their binary.")

(defun jgy-agent-update--acp-install-command (payload)
  "The command installing PAYLOAD, a list of the agent's id and its registry entry."
  (pcase-let* ((`(,id ,json) payload)
               (binary (jgy-agent-update--acp-binary (jgy-agent-update--json json))))
    (list "sh" "-c" jgy-agent-update--acp-install-script "sh"
          (alist-get 'archive binary) (jgy-agent-update--acp-folder id) json
          (alist-get 'cmd binary))))

;;;; Installing

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
          (append
           (delq nil
                 (list (and npm (append '("npm" "install" "--global")
                                        (mapcar (lambda (name) (concat name "@latest"))
                                                npm)))
                       (and upgrade (append '("brew" "upgrade" "--cask") upgrade))
                       (and install (append '("brew" "install" "--cask") install))))
           (mapcar #'jgy-agent-update--acp-install-command
                   (jgy-agent-update--payloads 'acp findings)))))
    (when commands
      (with-current-buffer (get-buffer-create "*agent update*") (erase-buffer))
      (jgy-agent-update--run commands))))

(defun jgy-agent-update--run (commands)
  "Run COMMANDS one after another in the *agent update* buffer.
One at a time, since concurrent brew commands contend for brew's lock."
  (if (null commands)
      (progn
        (jgy-agent-update-acp-use)
        (message "Agents updated; restart any running agent shell"))
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
  "Offer to install the updates npm, brew, elpaca and the ACP registry report.
Covers every agent in `jgy-agent-update-npm-packages', every cask in
`jgy-agent-update-brew-casks', every Emacs package in
`jgy-agent-update-elpaca-packages' and every binary in
`jgy-agent-update-acp-binaries', and offers packages that
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
    (when (executable-find "curl") (jgy-agent-update--check-acp))
    (jgy-agent-update--check-elpaca)
    (jgy-agent-update--settle))))

(provide 'jgy-agent-update)
;;; jgy-agent-update.el ends here
