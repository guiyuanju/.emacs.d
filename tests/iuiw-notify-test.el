;;; iuiw-notify-test.el --- Bark transport tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'iuiw-notify)

(ert-deftest iuiw-notify-keeps-key-out-of-command ()
  (let (command payload eof)
    (cl-letf (((symbol-function 'iuiw-notify--key)
               (lambda () "test-device-key"))
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
      (should (equal (alist-get 'title data) "额度恢复"))
      (should (equal (alist-get 'body data) "第一行\n引号：\" & ?"))
      (should (equal (alist-get 'group data) "usage")))))

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
