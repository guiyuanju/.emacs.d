;;; iuiw-swift.el --- Fixes for swift-development -*- lexical-binding: t; -*-

;;; Commentary:
;; Xcode 27 用 DeviceHub.app 取代了 Simulator.app，swift-development 仍按名字打开、激活和退出 Simulator。

;;; Code:

(require 'json)
(require 'subr-x)

(defvar current-simulator-id)
(declare-function ios-simulator-simulator-identifier "ios-simulator")

(defconst iuiw-swift-devicehub-p
  (file-directory-p
   (expand-file-name "../Applications/DeviceHub.app"
                     (string-trim (shell-command-to-string "xcode-select -p"))))
  "Non-nil when Xcode shows simulators in DeviceHub.")

(defun iuiw-swift-json-lists (fn &rest args)
  "Call FN with ARGS, reading JSON arrays as lists.
swiftui-preview-setup walks simctl's device arrays with `dolist'."
  (let ((json-array-type 'list))
    (apply fn args)))

(defun iuiw-swift-activate-devicehub (args)
  "Make the `make-process' ARGS that activate Simulator open DeviceHub."
  (if (equal (plist-get args :name) "activate-simulator")
      (plist-put (copy-sequence args) :command '("open" "-a" "DeviceHub"))
    args))

(defun iuiw-swift-start-simulator (id)
  "Boot simulator ID and show it in DeviceHub."
  (make-process
   :name "start-simulator"
   :command (list "sh" "-c" (format "xcrun simctl boot %s; open -a DeviceHub"
                                    (shell-quote-argument id)))
   :noquery t))

(defun iuiw-swift-restart-simulator ()
  "Quit DeviceHub, then boot the current simulator in it again."
  (interactive)
  (let ((id (or current-simulator-id (ios-simulator-simulator-identifier))))
    (call-process "osascript" nil nil nil "-e" "quit app \"DeviceHub\"")
    (run-with-timer 1.0 nil #'iuiw-swift-start-simulator id)))

(provide 'iuiw-swift)
;;; iuiw-swift.el ends here
