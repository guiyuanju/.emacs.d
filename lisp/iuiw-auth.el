;;; iuiw-auth.el --- Copy passwords from auth-source -*- lexical-binding: t; -*-

;;; Commentary:
;; 从 auth-source 选一个账号，把密码复制到剪贴板，过一会儿清掉。
;; port 为 totp 的条目是 totp-auth 存的 OTP 密钥，不在这里列出。
;; `iuiw-auth-ssh-master' 用它回答跳板机的 OTP，建好 ControlMaster 后 shell 里的 ssh、git 复用这条连接。
;; auth-source 会把解密后的整个文件一直缓存在内存里，这里到时清掉，下次读取重新解密。

;;; Code:

(require 'auth-source)

(defcustom iuiw-auth-clear-seconds 30
  "Seconds before a copied password is cleared from the clipboard."
  :type 'natnum
  :group 'auth-source)

(defcustom iuiw-auth-forget-seconds 900
  "Seconds after decryption before auth-source forgets everything it read."
  :type 'natnum
  :group 'auth-source)

(defvar iuiw-auth--clear-timer nil)

(defvar iuiw-auth--forget-timer nil)

(defun iuiw-auth--forget ()
  "Forget all auth-source data held in memory."
  (setq iuiw-auth--forget-timer nil)
  (auth-source-forget-all-cached))

(defun iuiw-auth-schedule-forget (&rest _)
  "Forget auth-source data `iuiw-auth-forget-seconds' after it was first read."
  (unless (timerp iuiw-auth--forget-timer)
    (setq iuiw-auth--forget-timer
          (run-at-time iuiw-auth-forget-seconds nil #'iuiw-auth--forget))))

(defun iuiw-auth-totp-storage-backends (orig &optional encrypted)
  "Call ORIG, counting .age files as encrypted as totp-auth does .gpg files.
With ENCRYPTED, return only encrypted backends."
  (let ((backends (funcall orig)))
    (dolist (backend backends)
      (let ((source (slot-value (alist-get :source backend) 'source)))
        (when (and (stringp source) (equal (file-name-extension source) "age"))
          (setf (alist-get :encrypted backend) t))))
    (if encrypted
        (seq-filter (lambda (backend) (alist-get :encrypted backend)) backends)
      backends)))

(defvar-keymap iuiw-auth-totp-mode-map
  "q" #'iuiw-auth-totp-quit)

(define-minor-mode iuiw-auth-totp-mode
  "Let q close a totp-auth token buffer."
  :keymap iuiw-auth-totp-mode-map)

(defun iuiw-auth-totp-quit ()
  "Close the token buffer, which stops its refresh timer."
  (interactive)
  (quit-window t))

(defun iuiw-auth-totp-setup (&rest _)
  "Turn on `iuiw-auth-totp-mode' in the token buffer totp-auth just showed."
  (iuiw-auth-totp-mode 1)
  (when (fboundp 'evil-normalize-keymaps)
    (evil-normalize-keymaps)))

(defconst iuiw-auth-otp-prompt-regexp
  "^(\\(?:\\(?1:[^@)]+\\)@\\)?\\(?2:[^)]+\\)) Verification code: ?$"
  "SSH keyboard-interactive OTP prompt; group 1 is the user, group 2 the host.")

(declare-function totp-auth-generate-otp "totp-auth")
(declare-function totp-auth-unwrap-otp-blob "totp-auth")

(defun iuiw-auth-totp-token (host &optional user)
  "Return the current TOTP token stored for USER at HOST, or nil."
  (require 'totp-auth)
  (when-let* ((entry (seq-find (lambda (entry) (equal (plist-get entry :port) "totp"))
                               (auth-source-search :host host :user user :max 50)))
              (secret (cdr (assq :secret (totp-auth-unwrap-otp-blob
                                          (auth-info-password entry))))))
    (let ((otp (totp-auth-generate-otp secret)))
      ;; 快过期的码可能到服务器时已失效，等下一个。
      (when (< (nth 1 otp) 3)
        (sleep-for (1+ (nth 1 otp)))
        (setq otp (totp-auth-generate-otp secret)))
      (car otp))))

(defun iuiw-auth-answer-otp (process string)
  "Answer the SSH OTP prompt in STRING from `auth-sources'; non-nil if sent.
Only the first prompt of PROCESS is answered, so a rejected code is not
retried."
  (when-let* (((not (process-get process 'iuiw-auth-otp-sent)))
              ((string-match iuiw-auth-otp-prompt-regexp string))
              (token (ignore-errors
                       (iuiw-auth-totp-token (match-string 2 string)
                                             (match-string 1 string)))))
    (process-put process 'iuiw-auth-otp-sent t)
    (process-send-string process (concat token "\n"))
    t))

(defun iuiw-auth-magit-otp-prompt (orig process string)
  "Answer an SSH OTP prompt in STRING, else call ORIG, which asks the user."
  (unless (iuiw-auth-answer-otp process string)
    (funcall orig process string)))

(defcustom iuiw-auth-ssh-master-timeout 300
  "Seconds `iuiw-auth-ssh-master' waits for authentication."
  :type 'natnum
  :group 'auth-source)

(defun iuiw-auth--ssh-master-live-p (host)
  "Return non-nil if an SSH ControlMaster connection to HOST is up."
  (zerop (call-process "ssh" nil nil nil "-O" "check" host)))

(defun iuiw-auth--ssh-master-filter (process string)
  "Insert STRING into PROCESS's buffer and answer the prompt it ends with."
  (with-current-buffer (process-buffer process)
    (goto-char (point-max))
    (insert string))
  (let ((line (car (last (split-string string "\n" t "[ \t\r]*")))))
    (when (and line (string-match-p ": ?$" line)
               (not (iuiw-auth-answer-otp process line)))
      (process-send-string process (concat (read-passwd line) "\n")))))

;;;###autoload
(defun iuiw-auth-ssh-master (host)
  "Open an SSH ControlMaster connection to HOST unless one is up.
Later ssh and git commands through HOST reuse it without prompting.  The
OTP comes from `auth-sources', else the user is asked.  Signal an error
on failure or after `iuiw-auth-ssh-master-timeout', so `emacsclient
--eval' exits non-zero."
  (unless (iuiw-auth--ssh-master-live-p host)
    (let* ((buffer (generate-new-buffer (format " *ssh-master %s*" host)))
           (process (make-process :name "ssh-master" :buffer buffer
                                  :command (list "ssh" "-MNf" host)
                                  :connection-type 'pty
                                  :filter #'iuiw-auth--ssh-master-filter
                                  :sentinel #'ignore))
           (deadline (+ (float-time) iuiw-auth-ssh-master-timeout)))
      (unwind-protect
          (progn
            (while (and (process-live-p process) (< (float-time) deadline))
              (accept-process-output process 0.1))
            (when (process-live-p process)
              (error "ssh %s timed out after %ds" host iuiw-auth-ssh-master-timeout))
            (unless (and (zerop (process-exit-status process))
                         (iuiw-auth--ssh-master-live-p host))
              (error "ssh %s failed:\n%s" host
                     (with-current-buffer buffer (string-trim (buffer-string))))))
        (delete-process process)
        (kill-buffer buffer))))
  host)

(defun iuiw-auth--label (entry)
  "Return a completion label for auth-source ENTRY."
  (let ((user (plist-get entry :user))
        (port (plist-get entry :port)))
    (concat (and user (concat user "@"))
            (plist-get entry :host)
            (and port (concat ":" port)))))

(defun iuiw-auth--clear (password)
  "Remove PASSWORD from the clipboard and the kill ring."
  (when (equal (gui-get-selection 'CLIPBOARD) password)
    (gui-set-selection 'CLIPBOARD ""))
  (setq kill-ring (delete password kill-ring)
        kill-ring-yank-pointer kill-ring))

;;;###autoload
(defun iuiw-auth-copy-password ()
  "Copy a password from `auth-sources' to the clipboard.
It is cleared after `iuiw-auth-clear-seconds'."
  (interactive)
  (let* ((candidates
          (mapcar (lambda (entry) (cons (iuiw-auth--label entry) entry))
                  (seq-remove (lambda (entry) (equal (plist-get entry :port) "totp"))
                              (auth-source-search :max 1000))))
         (label (if candidates
                    (completing-read "Password: " candidates nil t)
                  (user-error "No passwords in %s" auth-sources)))
         (password (auth-info-password (cdr (assoc label candidates)))))
    (gui-set-selection 'CLIPBOARD password)
    (when (timerp iuiw-auth--clear-timer)
      (cancel-timer iuiw-auth--clear-timer))
    (setq iuiw-auth--clear-timer
          (run-at-time iuiw-auth-clear-seconds nil #'iuiw-auth--clear password))
    (message "Copied password for %s, clearing in %ds" label iuiw-auth-clear-seconds)))

(provide 'iuiw-auth)
;;; iuiw-auth.el ends here
