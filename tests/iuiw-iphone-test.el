;;; iuiw-iphone-test.el --- Xcode discovery cache tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'iuiw-iphone)

(ert-deftest iuiw-iphone-discovery-cache-is-per-model-and-project ()
  (let ((overlook-sections nil)
        (overlook-before-render-hook nil)
        (overlook-after-model-hook nil)
        (overlook--model nil)
        (scans 0)
        found)
    (cl-letf (((symbol-function 'overlook-project-root)
               (lambda (project) (concat "/tmp/" project "/")))
              ((symbol-function 'file-expand-wildcards)
               (lambda (&rest _) (cl-incf scans) found)))
      (setq overlook-sections
            (list (lambda ()
                    (dolist (project '("a" "b"))
                      (should (equal (iuiw-iphone--xcodeproj project) (car found)))
                      (should (equal (iuiw-iphone--xcodeproj project) (car found))))
                    nil)))
      (overlook-model)
      (should (= scans 4))
      (setq found '("/tmp/a/App.xcodeproj"))
      (overlook-model)
      (should (= scans 6))
      (setq found nil)
      (should-not (iuiw-iphone--xcodeproj "a"))
      (should (= scans 8)))))

;;; iuiw-iphone-test.el ends here
