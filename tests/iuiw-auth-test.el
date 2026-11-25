;;; iuiw-auth-test.el --- Tests for iuiw-auth -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'iuiw-auth)

(defun iuiw-auth-test--ask (prompt caller)
  "Call `iuiw-auth-askpass' as the askpass script does; return the answer."
  (base64-decode-string
   (iuiw-auth-askpass (base64-encode-string prompt t) caller)))

(ert-deftest iuiw-auth-askpass-answers-otp-once-per-caller ()
  (let ((iuiw-auth--askpass-answered nil)
        (lookups nil)
        (asked nil))
    (cl-letf (((symbol-function 'iuiw-auth-totp-token)
               (lambda (host user) (push (list host user) lookups) "123456"))
              ((symbol-function 'read-passwd)
               (lambda (prompt &rest _) (push prompt asked) "typed")))
      (let ((prompt "(me@10.0.0.1) Verification code: "))
        (should (equal (iuiw-auth-test--ask prompt "42") "123456"))
        (should (equal lookups '(("10.0.0.1" "me"))))
        ;; A second prompt from the same ssh means the code was rejected.
        (should (equal (iuiw-auth-test--ask prompt "42") "typed"))
        (should (equal asked (list prompt)))
        (should (equal (iuiw-auth-test--ask prompt "43") "123456"))))))

(ert-deftest iuiw-auth-askpass-asks-when-no-token ()
  (let ((iuiw-auth--askpass-answered nil))
    (cl-letf (((symbol-function 'iuiw-auth-totp-token)
               (lambda (&rest _) (error "Touch ID cancelled")))
              ((symbol-function 'read-passwd) (lambda (&rest _) "654321")))
      (should (equal (iuiw-auth-test--ask "(me@h) Verification code: " "7") "654321"))
      (should-not iuiw-auth--askpass-answered))))

(ert-deftest iuiw-auth-askpass-quit-propagates ()
  (let ((iuiw-auth--askpass-answered nil))
    (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (signal 'quit nil))))
      (should (eq (car (should-error (iuiw-auth-test--ask "Password: " "7")
                                     :type 'quit))
                  'quit)))))

(provide 'iuiw-auth-test)
;;; iuiw-auth-test.el ends here
