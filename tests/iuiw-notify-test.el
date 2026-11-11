;;; iuiw-notify-test.el --- Bark transport tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'iuiw-notify)

(ert-deftest iuiw-notify-keeps-key-out-of-command ()
  (let (command payload content eof)
    (cl-letf (((symbol-function 'iuiw-notify--key)
               (lambda () "test-device-key"))
              ((symbol-function 'iuiw-notify--encrypt)
               (lambda (data)
                 (setq content data)
                 '((ciphertext . "encrypted-test-data") (iv . "1234567890123456"))))
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq command (plist-get args :command)) 'fake-process))
              ((symbol-function 'process-put) #'ignore)
              ((symbol-function 'process-send-string)
               (lambda (_ data) (setq payload data)))
              ((symbol-function 'process-send-eof)
               (lambda (_) (setq eof t))))
      (let ((buffers (buffer-list)))
        (unwind-protect
            (iuiw-notify-send "额度恢复" "第一行\n引号：\" & ?"
                              :group "usage" :url "https://example.org")
          (dolist (buffer (cl-set-difference (buffer-list) buffers))
            (kill-buffer buffer)))))
    (should eof)
    (should-not (string-match-p "test-device-key" (prin1-to-string command)))
    (should (equal (car (last command)) "https://api.day.app/push"))
    (let ((data (json-parse-string payload :object-type 'alist)))
      (should (equal (alist-get 'device_key data) "test-device-key"))
      (should (equal (alist-get 'ciphertext data) "encrypted-test-data"))
      (should-not (alist-get 'title data))
      (should-not (alist-get 'body data))
      (should-not (alist-get 'group data))
      (should-not (alist-get 'url data))
      (should (equal (alist-get 'title content) "额度恢复"))
      (should (equal (alist-get 'body content) "第一行\n引号：\" & ?"))
      (should (equal (alist-get 'group content) "usage")))))

(ert-deftest iuiw-notify-encryption-is-openssl-compatible ()
  (let* ((content '((title . "测试") (body . "Hello\n世界")))
         (key "1234567890123456")
         (iv "abcdefghijklmnop")
         (hex (lambda (value) (mapconcat (lambda (byte) (format "%02x" byte)) value ""))))
    (cl-letf (((symbol-function 'iuiw-notify--encryption-key) (lambda () (copy-sequence key)))
              ((symbol-function 'iuiw-notify--iv) (lambda () iv)))
      (let ((encrypted (iuiw-notify--encrypt content)))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert (base64-decode-string (alist-get 'ciphertext encrypted)))
          (let ((coding-system-for-read 'no-conversion)
                (coding-system-for-write 'no-conversion))
            (should (eq 0 (call-process-region
                           (point-min) (point-max) "openssl" t t nil
                           "enc" "-d" "-aes-128-cbc" "-K" (funcall hex key)
                           "-iv" (funcall hex iv)))))
          (should (equal (decode-coding-string (buffer-string) 'utf-8-unix)
                         (json-encode content))))))))

(ert-deftest iuiw-notify-encryption-key-normalizes-smart-quotes ()
  (let* ((directory (make-temp-file "bark-crypto-test-" t))
         (iuiw-notify-encryption-key-file (expand-file-name "key" directory)))
    (unwind-protect
        (progn
          (should-error (iuiw-notify--encryption-key) :type 'user-error)
          (iuiw-notify-set-encryption-key "1234567’90123456")
          (should (equal (iuiw-notify--encryption-key) "1234567'90123456"))
          (should (= (file-modes iuiw-notify-encryption-key-file) #o600))
          (should-error (iuiw-notify-set-encryption-key "short") :type 'user-error))
      (delete-directory directory t))))

(ert-deftest iuiw-notify-ivs-are-fresh ()
  (let ((first (iuiw-notify--iv)) (second (iuiw-notify--iv)))
    (should (= (length first) 16))
    (should (= (length second) 16))
    (should-not (equal first second))))

(ert-deftest iuiw-notify-never-falls-back-to-plaintext ()
  (let ((iuiw-notify-encryption-key-file "/nonexistent/bark-encryption-key"))
    (cl-letf (((symbol-function 'iuiw-notify--key) (lambda () "test-device-key"))
              ((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "Must not send unencrypted data"))))
      (should-error (iuiw-notify-send "Private title" "Private body") :type 'user-error))))

(ert-deftest iuiw-notify-refuses-missing-key-and-unsafe-server ()
  (cl-letf (((symbol-function 'iuiw-notify--key)
             (lambda () (user-error "Missing key")))
            ((symbol-function 'make-process)
             (lambda (&rest _) (ert-fail "Must not send a request"))))
    (should-error (iuiw-notify-send "Test" "Body") :type 'user-error)
    (dolist (iuiw-notify-server '("http://api.day.app" "https://api.day.app/key"
                                "https://user:secret@api.day.app"))
      (should-error (iuiw-notify-send "Test" "Body") :type 'user-error))))

(ert-deftest iuiw-notify-key-is-private-and-needs-no-auth-source ()
  (let* ((directory (make-temp-file "bark-test-" t))
         (iuiw-notify-key-file (expand-file-name "var/key" directory)))
    (unwind-protect
        (progn
          (should-error (iuiw-notify--key) :type 'user-error)
          (iuiw-notify-set-key "test-key")
          (should (= (file-modes iuiw-notify-key-file) #o600))
          (should (equal (iuiw-notify--key) "test-key"))
          (set-file-modes iuiw-notify-key-file #o644)
          (should-error (iuiw-notify--key) :type 'user-error)
          (iuiw-notify-set-key "replacement-key")
          (should (equal (iuiw-notify--key) "replacement-key")))
      (delete-directory directory t))))

(ert-deftest iuiw-notify-checks-service-and-transport-results ()
  (dolist (case '((0 "{\"code\":200}" t nil)
                  (0 "{\"code\":400,\"message\":\"secret\"}" nil
                     "Bark rejected the notification")
                  (0 "not JSON" nil "Bark returned an invalid response")
                  (0 "{\"code\":400,\"message\":\"failed to get device token: secret\"}" nil
                     "Bark device key is not registered on this server; run M-x iuiw-notify-set-key" 400)
                  (0 "service unavailable" nil "Bark returned HTTP 503" 503)
                  (22 "" nil "Bark request failed: HTTP error; check server and device key (curl exit 22)")
                  (28 "" nil "Bark request failed: request timed out (curl exit 28)")))
    (let* ((buffer (generate-new-buffer " *notify-test*"))
           (process (make-process :name "notify-test" :buffer buffer
                                  :command (list "sh" "-c"
                                                 (format "exit %d" (car case)))
                                  :sentinel #'ignore))
           result)
      (while (process-live-p process) (accept-process-output process 0.1))
      (with-current-buffer buffer
        (insert (nth 1 case) "\n" (number-to-string (or (nth 4 case) 200))))
      (process-put process 'iuiw-notify-callback
                   (lambda (success error-message)
                     (setq result (list success error-message))))
      (iuiw-notify--finish process "finished")
      (should (equal result (list (nth 2 case) (nth 3 case))))
      (should-not (buffer-live-p buffer)))))

;;; iuiw-notify-test.el ends here
