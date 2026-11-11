;;; iuiw-notify.el --- Send iPhone notifications via Bark -*- lexical-binding: t; -*-

;; Configure AES-128-CBC in Bark, then run M-x iuiw-notify-set-key
;; and M-x iuiw-notify-set-encryption-key with the matching keys.
;; Run M-x iuiw-notify-send to test.  Other callers can use:
;; (iuiw-notify-send "Emacs" "Hello" :group "emacs")

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url-parse)
(require 'gnutls)

(defgroup iuiw-notify nil
  "Send notifications to an iPhone."
  :group 'external)

(defcustom iuiw-notify-server "https://api.day.app"
  "Bark server base URL, without /push or a device key."
  :type 'string)

(defcustom iuiw-notify-key-file (locate-user-emacs-file "var/bark-key")
  "Local plaintext device key file, readable only by its owner.
Kept outside version control so unattended sending needs no Touch ID."
  :type 'file)

(defun iuiw-notify-set-key (key)
  "Save Bark device KEY locally with permissions 600."
  (interactive (list (read-passwd "Bark device key: ")))
  (unless (and (stringp key) (string-match-p "\\`[[:alnum:]_-]+\\'" key))
    (user-error "Enter the device key only, not the Bark URL"))
  (let* ((file (expand-file-name iuiw-notify-key-file))
         (directory (file-name-directory file)))
    (when (file-remote-p file) (user-error "Bark key must be stored locally"))
    (when (file-symlink-p file) (user-error "Bark key file must not be a symlink"))
    (make-directory directory t)
    (let ((temporary (make-temp-file (expand-file-name ".bark-key-" directory))))
      (unwind-protect
          (progn
            (with-temp-buffer
              (insert key "\n")
              (write-region (point-min) (point-max) temporary nil 'silent))
            (rename-file temporary file t))
        (when (file-exists-p temporary) (delete-file temporary))))
    (message "Bark device key saved")))

(defun iuiw-notify--key ()
  "Read the local Bark device key without authentication prompts."
  (let ((file (expand-file-name iuiw-notify-key-file)))
    (unless (and (not (file-remote-p file))
                 (not (file-symlink-p file))
                 (file-regular-p file) (file-readable-p file))
      (user-error "Configure Bark first with M-x iuiw-notify-set-key"))
    (unless (zerop (logand (file-modes file) #o077))
      (user-error "Bark key file permissions must be 600"))
    (let ((key (with-temp-buffer
                 (insert-file-contents-literally file)
                 (string-trim (buffer-string)))))
      (unless (string-match-p "\\`[[:alnum:]_-]+\\'" key)
        (user-error "Invalid Bark key; run M-x iuiw-notify-set-key"))
      key)))

(defcustom iuiw-notify-timeout 15
  "Maximum seconds to wait for a Bark request."
  :type 'natnum)

(defcustom iuiw-notify-encryption-key-file
  (locate-user-emacs-file "var/bark-encryption-key")
  "Local file containing the same AES-128-CBC key as the Bark app.
Notifications require encryption; missing keys never fall back to plaintext."
  :type 'file)

(defun iuiw-notify-set-encryption-key (key)
  "Save the Bark AES-128-CBC KEY locally with permissions 600.
KEY must encode to exactly 16 UTF-8 bytes, matching the iPhone setting."
  (interactive (list (read-passwd "Bark AES-128-CBC key (16 ASCII characters): ")))
  (setq key (apply #'string
                   (mapcar (lambda (char)
                             (pcase char
                               ((or #x2018 #x2019) ?')
                               ((or #x201c #x201d) ?\")
                               (_ char)))
                           (string-to-list key))))
  (unless (string-match-p "\\`[ -~]\\{16\\}\\'" key)
    (user-error "Bark AES-128-CBC key must be 16 printable ASCII characters"))
  (unless (= (string-bytes (encode-coding-string key 'utf-8-unix)) 16)
    (user-error "Bark AES-128-CBC key must be exactly 16 UTF-8 bytes"))
  (when (string-match-p "[\n\r]" key)
    (user-error "Bark encryption key must not contain newlines"))
  (let* ((file (expand-file-name iuiw-notify-encryption-key-file))
         (directory (file-name-directory file)))
    (when (or (file-remote-p file) (file-symlink-p file))
      (user-error "Bark encryption key must be a local file, not a symlink"))
    (make-directory directory t)
    (let ((temporary (make-temp-file (expand-file-name ".bark-crypto-" directory))))
      (unwind-protect
          (progn
            (with-temp-buffer
              (insert key)
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region (point-min) (point-max) temporary nil 'silent)))
            (rename-file temporary file t))
        (when (file-exists-p temporary) (delete-file temporary))))
    (message "Bark encryption key saved")))

(defun iuiw-notify--encryption-key ()
  "Read the private AES key as 16 bytes without authentication prompts."
  (let ((file (expand-file-name iuiw-notify-encryption-key-file)))
    (unless (and (not (file-remote-p file)) (not (file-symlink-p file))
                 (file-regular-p file) (file-readable-p file)
                 (zerop (logand (file-modes file) #o077)))
      (user-error "Configure encryption with M-x iuiw-notify-set-encryption-key"))
    (let ((key (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert-file-contents-literally file)
                 (buffer-string))))
      (unless (= (length key) 16)
        (user-error "Bark encryption key must be exactly 16 bytes"))
      key)))

(defun iuiw-notify--iv ()
  "Generate a fresh 16-character IV using OpenSSL's secure random source."
  (let ((openssl (executable-find "openssl")))
    (unless openssl (user-error "openssl is required to generate Bark IVs"))
    (with-temp-buffer
      (unless (eq 0 (call-process openssl nil t nil "rand" "-base64" "12"))
        (error "Could not generate a secure Bark IV"))
      (let ((iv (string-trim (buffer-string))))
        (unless (string-match-p "\\`[A-Za-z0-9+/]\\{16\\}\\'" iv)
          (error "Invalid secure random output"))
        iv))))

(defun iuiw-notify--encrypt (payload)
  "Encrypt PAYLOAD for Bark as AES-128-CBC with PKCS#7 padding."
  (let* ((key (iuiw-notify--encryption-key))
         (iv (iuiw-notify--iv))
         (input (encode-coding-string (json-encode payload) 'utf-8-unix))
         (padding (- 16 (% (length input) 16)))
         (padded (concat input (make-string padding padding)))
         ciphertext)
    (unwind-protect
        (setq ciphertext (gnutls-symmetric-encrypt 'AES-128-CBC key iv padded))
      (clear-string key))
    (when (consp ciphertext) (setq ciphertext (car ciphertext)))
    (unless ciphertext (error "Bark encryption failed"))
    `((ciphertext . ,(base64-encode-string ciphertext t)) (iv . ,iv))))

(defun iuiw-notify--finish (process _event)
  "Handle the completed Bark PROCESS."
  (when (memq (process-status process) '(exit signal))
    (let ((buffer (process-buffer process))
          (callback (process-get process 'iuiw-notify-callback))
          failure)
      (unwind-protect
          (setq failure
                (if (not (and (eq (process-status process) 'exit)
                              (zerop (process-exit-status process))))
                    (format "Bark request failed: %s (curl exit %s)"
                            (pcase (process-exit-status process)
                              (5 "cannot resolve proxy")
                              (6 "cannot resolve server")
                              (7 "cannot connect to server")
                              (22 "HTTP error; check server and device key")
                              (23 "cannot write response")
                              (26 "cannot read request")
                              (28 "request timed out")
                              (35 "TLS connection failed")
                              (56 "failed to receive network data")
                              (60 "TLS certificate verification failed")
                              (_ "transport error"))
                            (process-exit-status process))
                  (condition-case nil
                      (with-current-buffer buffer
                        (let* ((output (buffer-string))
                               (status (and (string-match "\n\\([0-9]\\{3\\}\\)\\'" output)
                                            (string-to-number (match-string 1 output))))
                               (body (and status (substring output 0 (match-beginning 0)))))
                          (if (not (and status (<= 200 status) (< status 300)))
                              (if status
                                  (if (and (= status 400) body
                                           (string-match-p "failed to get device token" body))
                                      "Bark device key is not registered on this server; run M-x iuiw-notify-set-key"
                                    (format "Bark returned HTTP %d" status))
                                "Bark returned an invalid response")
                            (let ((response (json-parse-string body :object-type 'alist)))
                              (unless (equal (alist-get 'code response) 200)
                                "Bark rejected the notification")))))
                    (error "Bark returned an invalid response"))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))
      (if callback
          (funcall callback (not failure) failure)
        (if failure
            (display-warning 'iuiw-notify failure :warning)
          (message "Bark accepted the notification"))))))

(cl-defun iuiw-notify-send (title body &key group url callback)
  "Asynchronously send TITLE and BODY to the iPhone via Bark.
GROUP groups notifications; URL opens when the notification is tapped.
CALLBACK, if non-nil, receives (SUCCESS ERROR-MESSAGE) on completion.
Without it, report acceptance in the echo area or warn on failure.
Return the curl process.  Acceptance does not confirm device delivery.
Missing credentials and invalid arguments signal errors immediately."
  (interactive (list (read-string "Notification title: " "Emacs")
                     (read-string "Notification body: ")))
  (unless (and (stringp title) (stringp body)
               (or (null group) (stringp group))
               (or (null url) (stringp url))
               (or (null callback) (functionp callback)))
    (user-error "Notification title, body, group and URL must be strings"))
  (unless (and (integerp iuiw-notify-timeout) (> iuiw-notify-timeout 0))
    (user-error "Notification timeout must be a positive integer"))
  (let* ((server (url-generic-parse-url iuiw-notify-server))
         (curl (executable-find "curl")))
    (unless (and (equal (url-type server) "https")
                 (url-host server)
                 (not (url-user server))
                 (not (url-password server))
                 (member (url-filename server) '("" "/"))
                 (not (url-target server)))
      (user-error "Bark server must be an HTTPS base URL"))
    (unless curl (user-error "curl is required for Bark notifications"))
    (let ((key (iuiw-notify--key)))
      (let* ((content `((title . ,title) (body . ,body)
                        ,@(when group `((group . ,group)))
                        ,@(when url `((url . ,url)))))
             (payload (cons (cons 'device_key key) (iuiw-notify--encrypt content)))
             (buffer (generate-new-buffer " *iuiw-notify*"))
             process)
        (unwind-protect
            (progn
              (setq process
                    (make-process
                     :name "iuiw-notify" :buffer buffer :noquery t
                     :connection-type 'pipe :coding 'utf-8-unix
                     :command (list curl "--disable" "--silent" "--show-error"
                                    "--proto" "=https" "--write-out" "\n%{http_code}"
                                    "--max-time" (number-to-string iuiw-notify-timeout)
                                    "--header" "Content-Type: application/json"
                                    "--data-binary" "@-"
                                    (concat (string-remove-suffix "/" iuiw-notify-server)
                                            "/push"))
                     :sentinel #'iuiw-notify--finish))
              (process-put process 'iuiw-notify-callback callback)
              (process-send-string process (json-encode payload))
              (process-send-eof process)
              process)
          (unless process (kill-buffer buffer)))))))

(provide 'iuiw-notify)
;;; iuiw-notify.el ends here
