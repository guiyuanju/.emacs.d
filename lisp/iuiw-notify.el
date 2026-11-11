;;; iuiw-notify.el --- Send iPhone notifications via Bark -*- lexical-binding: t; -*-

;; Install Bark on the iPhone, then run M-x iuiw-notify-set-key.
;; Run M-x iuiw-notify-send to test.  Other callers can use:
;; (iuiw-notify-send "Emacs" "Hello" :group "emacs")

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url-parse)

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
      (let* ((payload `((device_key . ,key) (title . ,title) (body . ,body)
                        ,@(when group `((group . ,group)))
                        ,@(when url `((url . ,url)))))
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
