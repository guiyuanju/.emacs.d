;;; overlook-agent-update.el --- Keep agent-shell and its agents up to date -*- lexical-binding: t; -*-

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

;; Agents run on acp.el and agent-shell, through ACP adapters installed
;; globally with npm, Homebrew casks, or binaries from the ACP registry.
;; When any layer falls behind, the ACP handshake, or the _meta fields
;; overlook reads Claude's usage from, may stop matching.
;; `overlook-agent-update-check' asks npm, brew, elpaca and the registry
;; which of them are behind or missing, offers the lot in one prompt, and
;; installs what is accepted.  Run it from a timer to check daily.
;; Claude's and Codex's own CLIs come with their adapters; the claude in
;; the terminal is a separate cask, so both are checked.

;;; Code:

(require 'json)
(require 'seq)
(require 'subr-x)

(declare-function elpaca-get "elpaca")
(declare-function elpaca-pull "elpaca")
(declare-function elpaca-process-queues "elpaca")
(declare-function elpaca<-source-dir "elpaca")

(defcustom overlook-agent-update-npm-packages
  '(("claude" "@agentclientprotocol/claude-agent-acp")
    ("codex" "@agentclientprotocol/codex-acp")
    ("pi" "pi-acp" "@earendil-works/pi-coding-agent"))
  "Agent name to the npm packages it runs on, its ACP adapter first.
Claude's and Codex's own CLIs ship as dependencies of their adapters, so
they are not listed."
  :type '(alist :key-type string :value-type (repeat string))
  :group 'overlook)

(defcustom overlook-agent-update-brew-casks '("claude-code@latest")
  "Homebrew casks providing the agents' command-line tools."
  :type '(repeat string)
  :group 'overlook)

(defcustom overlook-agent-update-elpaca-packages '(acp shell-maker agent-shell)
  "Emacs packages driving the agents, updated through elpaca."
  :type '(repeat symbol)
  :group 'overlook)

(defcustom overlook-agent-update-acp-binaries
  '(("antigravity-acp" . agent-shell-antigravity-acp-command))
  "ACP registry agents shipped as binaries, each with its command variable.
They are installed under `overlook-agent-update-acp-directory', and
`overlook-agent-update-acp-use' points the variables at them."
  :type '(alist :key-type string :value-type variable)
  :group 'overlook)

(defcustom overlook-agent-update-acp-directory (locate-user-emacs-file "overlook-acp/")
  "Folder holding one folder per agent of `overlook-agent-update-acp-binaries'.
Each folder also keeps the registry entry it was installed from, as agent.json."
  :type 'directory
  :group 'overlook)

(defconst overlook-agent-update-acp-registry
  "https://raw.githubusercontent.com/agentclientprotocol/registry/main/%s/agent.json"
  "URL of an ACP registry entry, given the agent's id.")

;; A finding is (KIND LABEL DETAIL PAYLOAD): KIND says how to install it, LABEL
;; and DETAIL are for the prompt, PAYLOAD is the npm package, the elpaca id or,
;; for an ACP binary, its id and registry entry.
(defvar overlook-agent-update--findings nil
  "What the check in progress has found so far.")

(defvar overlook-agent-update--pending 0
  "How many probes the check in progress is still waiting on.")

(defvar overlook-agent-update--verbose nil
  "Whether the check in progress should report having nothing to do.")

(defvar overlook-agent-update--busy nil
  "Non-nil from when a check starts until its findings are declined or installed.
A pending `y-or-n-p' still lets timers run, so without this a later daily
check could stack a second prompt and a second, colliding install.")

(defun overlook-agent-update--describe (findings)
  "Return a one-line summary of FINDINGS."
  (mapconcat (pcase-lambda (`(,_kind ,label ,detail ,_payload))
               (format "%s %s" label detail))
             findings ", "))

(defun overlook-agent-update--payloads (kind findings)
  "Return the payloads of the FINDINGS whose kind is KIND."
  (seq-keep (lambda (finding)
              (and (eq (car finding) kind) (nth 3 finding)))
            findings))

(defun overlook-agent-update--settle ()
  "Account for one finished probe, and offer the findings once none are left."
  (setq overlook-agent-update--pending (1- overlook-agent-update--pending))
  (when (zerop overlook-agent-update--pending)
    (let ((findings (sort overlook-agent-update--findings
                          (lambda (a b) (string< (cadr a) (cadr b))))))
      (setq overlook-agent-update--findings nil)
      (cond (findings (overlook-agent-update--offer findings))
            (t (setq overlook-agent-update--busy nil)
               (when overlook-agent-update--verbose (message "Agents are up to date")))))))

(defun overlook-agent-update--probe (name command directory callback)
  "Run shell COMMAND in DIRECTORY as probe NAME of the check in progress.
CALLBACK is called with the command's output and exit status."
  (setq overlook-agent-update--pending (1+ overlook-agent-update--pending))
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
                     (overlook-agent-update--settle)))))))

(defun overlook-agent-update--json (output)
  "Return OUTPUT parsed as a JSON object, or nil if npm printed nothing usable."
  (ignore-errors (json-parse-string output :object-type 'alist)))

(defun overlook-agent-update--npm-findings (installed outdated)
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
   (apply #'append (mapcar #'cdr overlook-agent-update-npm-packages))))

(defun overlook-agent-update--check-npm ()
  "Ask npm which of the watched packages are missing or behind the registry."
  (overlook-agent-update--probe
   ;; Through a shell because npm warns on stderr, which would spoil the JSON,
   ;; and npm outdated exits non-zero precisely when something is outdated.
   "npm-ls" "npm ls --global --depth=0 --json 2>/dev/null" nil
   (lambda (output _status)
     (let ((installed (alist-get 'dependencies (overlook-agent-update--json output))))
       (overlook-agent-update--probe
        "npm-outdated" "npm outdated --global --json 2>/dev/null" nil
        (lambda (output _status)
          (dolist (finding (overlook-agent-update--npm-findings
                            installed (overlook-agent-update--json output)))
            (push finding overlook-agent-update--findings))))))))

(defun overlook-agent-update--brew-findings (casks)
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

(defun overlook-agent-update--check-brew ()
  "Ask Homebrew which of the watched casks are missing or behind."
  (overlook-agent-update--probe
   "brew-info"
   (concat "brew info --cask --json=v2 "
           (mapconcat #'shell-quote-argument overlook-agent-update-brew-casks " ")
           " 2>/dev/null")
   nil
   (lambda (output _status)
     (dolist (finding (overlook-agent-update--brew-findings
                       (alist-get 'casks (overlook-agent-update--json output))))
       (push finding overlook-agent-update--findings)))))

(defun overlook-agent-update--check-elpaca ()
  "Fetch each watched Emacs package's remote and note the ones behind upstream."
  (when (featurep 'elpaca)
    (dolist (id overlook-agent-update-elpaca-packages)
      (when-let* ((e (elpaca-get id)))
        (overlook-agent-update--probe
         (format "elpaca-behind-%s" id)
         "git fetch --quiet && git rev-list --count 'HEAD..@{u}'"
         (elpaca<-source-dir e)
         (lambda (output status)
           (let ((behind (if (zerop status) (string-to-number output) 0)))
             (when (> behind 0)
               (push (list 'elpaca (symbol-name id)
                           (format "+%d commit%s" behind (if (= behind 1) "" "s"))
                           id)
                     overlook-agent-update--findings)))))))))

;;;; ACP registry binaries

(defun overlook-agent-update--acp-platform ()
  "This machine's platform as the ACP registry names it, like darwin-aarch64."
  (format "%s-%s"
          (pcase system-type ('darwin "darwin") ('windows-nt "windows") (_ "linux"))
          (pcase (car (split-string system-configuration "-"))
            ((or "x86_64" "amd64") "x86_64")
            ((or "aarch64" "arm64") "aarch64")
            (arch arch))))

(defun overlook-agent-update--acp-folder (id)
  "The folder agent ID is installed in, without a trailing slash."
  (directory-file-name (expand-file-name id overlook-agent-update-acp-directory)))

(defun overlook-agent-update--acp-installed (id)
  "The registry entry agent ID was installed from, or nil if it is not installed."
  (let ((file (expand-file-name "agent.json" (overlook-agent-update--acp-folder id))))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (ignore-errors (json-parse-buffer :object-type 'alist))))))

(defun overlook-agent-update--acp-binary (entry)
  "The binary distribution of registry ENTRY for this platform."
  (alist-get (intern (overlook-agent-update--acp-platform))
             (alist-get 'binary (alist-get 'distribution entry))))

;;;###autoload
(defun overlook-agent-update-acp-use ()
  "Point the command variable of each installed ACP binary agent at it."
  (pcase-dolist (`(,id . ,variable) overlook-agent-update-acp-binaries)
    (when-let* ((binary (overlook-agent-update--acp-binary (overlook-agent-update--acp-installed id))))
      (set variable (cons (expand-file-name (alist-get 'cmd binary)
                                            (overlook-agent-update--acp-folder id))
                          (append (alist-get 'args binary) nil))))))

(defun overlook-agent-update--check-acp ()
  "Ask the ACP registry which of the watched binary agents are missing or behind."
  (pcase-dolist (`(,id . ,_variable) overlook-agent-update-acp-binaries)
    (overlook-agent-update--probe
     (format "acp-registry-%s" id)
     (concat "curl -fsSL " (shell-quote-argument (format overlook-agent-update-acp-registry id)))
     nil
     (lambda (output _status)
       (let* ((entry (overlook-agent-update--json output))
              (latest (alist-get 'version entry))
              (current (alist-get 'version (overlook-agent-update--acp-installed id))))
         (when (and latest (overlook-agent-update--acp-binary entry)
                    (not (equal current latest)))
           (push (list 'acp id (if current (format "%s→%s" current latest) "not installed")
                       (list id output))
                 overlook-agent-update--findings)))))))

(defconst overlook-agent-update--acp-install-script
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

(defun overlook-agent-update--acp-install-command (payload)
  "The command installing PAYLOAD, a list of the agent's id and its registry entry."
  (pcase-let* ((`(,id ,json) payload)
               (binary (overlook-agent-update--acp-binary (overlook-agent-update--json json))))
    (list "sh" "-c" overlook-agent-update--acp-install-script "sh"
          (alist-get 'archive binary) (overlook-agent-update--acp-folder id) json
          (alist-get 'cmd binary))))

;;;; Installing

(defun overlook-agent-update--install (findings)
  "Install every update in FINDINGS, each at its latest version."
  (let ((ids (overlook-agent-update--payloads 'elpaca findings)))
    (message "Updating %s…%s" (overlook-agent-update--describe findings)
             (if ids "  Emacs packages report in M-x elpaca-log." ""))
    ;; The probe fetched already, but `elpaca-pull' is the supported entry
    ;; point and it also rebuilds the package after merging.
    (when ids
      (dolist (id ids) (elpaca-pull id))
      (elpaca-process-queues)))
  (let* ((npm (overlook-agent-update--payloads 'npm findings))
         (upgrade (overlook-agent-update--payloads 'brew-upgrade findings))
         (install (overlook-agent-update--payloads 'brew-install findings))
         (commands
          (append
           (delq nil
                 (list (and npm (append '("npm" "install" "--global")
                                        (mapcar (lambda (name) (concat name "@latest"))
                                                npm)))
                       (and upgrade (append '("brew" "upgrade" "--cask") upgrade))
                       (and install (append '("brew" "install" "--cask") install))))
           (mapcar #'overlook-agent-update--acp-install-command
                   (overlook-agent-update--payloads 'acp findings)))))
    (if (null commands)
        (setq overlook-agent-update--busy nil)
      (with-current-buffer (get-buffer-create "*agent update*") (erase-buffer))
      (overlook-agent-update--run commands))))

(defun overlook-agent-update--run (commands)
  "Run COMMANDS one after another in the *agent update* buffer.
One at a time, since concurrent brew commands contend for brew's lock."
  (if (null commands)
      (progn
        (setq overlook-agent-update--busy nil)
        (overlook-agent-update-acp-use)
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
                         (overlook-agent-update--run (cdr commands))
                       (setq overlook-agent-update--busy nil)
                       (message "%s failed" (string-join (seq-take command 2) " "))
                       (display-buffer buffer))))))))

(defun overlook-agent-update--offer (findings)
  "Ask whether to install FINDINGS, waiting until the minibuffer is free."
  (if (active-minibuffer-window)
      (run-with-idle-timer 60 nil #'overlook-agent-update--offer findings)
    (let (accepted)
      (unwind-protect
          (setq accepted (y-or-n-p (format "Agent updates available (%s).  Update? "
                                           (overlook-agent-update--describe findings))))
        (unless accepted (setq overlook-agent-update--busy nil)))
      (when accepted (overlook-agent-update--install findings)))))

;;;###autoload
(defun overlook-agent-update-check (&optional verbose)
  "Offer to install the updates npm, brew, elpaca and the ACP registry report.
Covers every agent in `overlook-agent-update-npm-packages', every cask in
`overlook-agent-update-brew-casks', every Emacs package in
`overlook-agent-update-elpaca-packages' and every binary in
`overlook-agent-update-acp-binaries', and offers packages that
are not installed at all for installation too.  With VERBOSE, also
report when there is nothing to do, as when called interactively."
  (interactive (list t))
  (cond
   (overlook-agent-update--busy
    (when verbose (message "Already checking for or installing agent updates")))
   (t
    (setq overlook-agent-update--busy t
          overlook-agent-update--verbose verbose
          overlook-agent-update--findings nil
          ;; Counted as a probe itself, so that the real ones cannot settle the
          ;; check before all of them are queued, and so that queueing none
          ;; still reports.
          overlook-agent-update--pending 1)
    (when verbose (message "Checking for agent updates…"))
    (when (executable-find "npm") (overlook-agent-update--check-npm))
    (when (executable-find "brew") (overlook-agent-update--check-brew))
    (when (executable-find "curl") (overlook-agent-update--check-acp))
    (overlook-agent-update--check-elpaca)
    (overlook-agent-update--settle))))

(provide 'overlook-agent-update)
;;; overlook-agent-update.el ends here
