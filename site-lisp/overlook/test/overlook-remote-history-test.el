;;; overlook-remote-history-test.el --- Activity read positions and pages -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-remote)

(defmacro overlook-history-test-with-agent (&rest body)
  "Run BODY with an isolated live activity BUFFER."
  (declare (indent 0))
  `(let ((buffer (generate-new-buffer " *history-agent*"))
         (overlook-remote--seq 0)
         (overlook-remote--dashboard nil))
     (unwind-protect
         (progn
           (with-current-buffer buffer
             (setq overlook-agent-identity '((agent . "fake") (root . "/tmp/"))))
           (cl-letf (((symbol-function 'overlook-remote--wake) #'ignore))
             ,@body))
       (kill-buffer buffer))))

(ert-deftest overlook-history-timestamps-preserve-creation-across-stream ()
  (overlook-history-test-with-agent
    (let ((clock "2026-11-12T10:00:00.000Z"))
      (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) clock)))
        (overlook-remote--record buffer '(:type text :text "hello"))
        (setq clock "2026-11-12T10:00:01.000Z")
        (overlook-remote--record buffer '(:type text :text " world")))
      (let ((items (buffer-local-value 'overlook-remote--items buffer)))
        (should (= 1 (length items)))
        (should (equal (plist-get (car items) :createdAt) "2026-11-12T10:00:00.000Z"))
        (should (equal (plist-get (car items) :updatedAt) clock))
        (should (= 1 (overlook-remote--unread-count buffer)))))))

(ert-deftest overlook-history-read-position-does-not-clear-newer-stream ()
  (overlook-history-test-with-agent
    (overlook-remote--record buffer '(:type prompt :text "question"))
    (overlook-remote--record buffer '(:type text :text "first"))
    (let ((seen-seq overlook-remote--seq))
      (overlook-remote--record buffer '(:type text :text " second"))
      (should (= 1 (plist-get (overlook-remote--seen buffer seen-seq) :unreadCount)))
      (should (= seen-seq (buffer-local-value 'overlook-remote--read-through buffer)))
      (should (= 0 (plist-get (overlook-remote--seen buffer overlook-remote--seq) :unreadCount)))
      (overlook-remote--seen buffer 0)
      (should (= 3 (buffer-local-value 'overlook-remote--read-through buffer)))
      (overlook-remote--seen buffer 100000)
      (should (= 3 (buffer-local-value 'overlook-remote--read-through buffer))))))

(ert-deftest overlook-history-stale-epoch-cannot-clear-unread ()
  (overlook-history-test-with-agent
    (overlook-remote--record buffer '(:type text :text "unseen"))
    (should-error (overlook-remote--seen buffer 999 "previous") :type 'overlook-remote-api-error)
    (should (= 1 (overlook-remote--unread-count buffer)))))

(ert-deftest overlook-history-pages-use-item-not-time-or-update-sequence ()
  (overlook-history-test-with-agent
    (cl-letf (((symbol-function 'format-time-string) (lambda (&rest _) "2026-11-12T10:00:00.000Z")))
      (dotimes (i 7)
        (overlook-remote--record buffer (list :type 'prompt :text (number-to-string i)))))
    (let* ((page (overlook-remote--history-data buffer nil 3))
           (older (overlook-remote--history-data buffer (plist-get page :before) 3))
           (oldest (overlook-remote--history-data buffer (plist-get older :before) 3)))
      (should (equal '(5 6 7) (mapcar (lambda (item) (plist-get item :item)) (append (plist-get page :items) nil))))
      (should (equal '(2 3 4) (mapcar (lambda (item) (plist-get item :item)) (append (plist-get older :items) nil))))
      (should (eq t (plist-get older :hasMore)))
      (should (eq :false (plist-get oldest :hasMore)))
      (should (= 1 (length (plist-get oldest :items)))))))

(ert-deftest overlook-history-initial-news-is-bounded-and-expiry-is-explicit ()
  (overlook-history-test-with-agent
    (let ((overlook-remote-history 5)
          (overlook-remote-page-size 2))
      (dotimes (i 8)
        (overlook-remote--record buffer (list :type 'prompt :text (number-to-string i))))
      (let ((news (overlook-remote--news-data buffer 0)))
        (should (= 2 (length (plist-get news :items))))
        (should (eq t (plist-get (plist-get news :history) :hasMore)))
        (should (= 7 (plist-get (plist-get news :history) :before))))
      (should-error (overlook-remote--history-data buffer 3 2) :type 'overlook-remote-api-error)
      (should-error (overlook-remote--history-data buffer nil 2 "old") :type 'overlook-remote-api-error))))

(ert-deftest overlook-history-query-rejects-invalid-pages ()
  (dolist (query '((("id" "agent") ("before" "-1"))
                   (("id" "agent") ("limit" "0"))
                   (("id" "agent") ("limit" "101"))
                   (("id" "agent") ("limit" "1.5"))))
    (should-error (overlook-remote-contract-query "/api/history" query) :type 'overlook-remote-api-error)))

(ert-deftest overlook-history-deltas-present-only-changed-items ()
  (overlook-history-test-with-agent
    (dotimes (i 10)
      (overlook-remote--record buffer (list :type 'prompt :text (number-to-string i))))
    (let ((after overlook-remote--seq)
          (present (symbol-function 'overlook-remote--present))
          (calls 0))
      (overlook-remote--record buffer '(:type text :text "A new reply"))
      (cl-letf (((symbol-function 'overlook-remote--present)
                 (lambda (&rest args) (cl-incf calls) (apply present args))))
        (let ((news (overlook-remote--news-data buffer after)))
          (should (= 1 (length (plist-get news :items))))
          (should (= 1 calls)))))))

(provide 'overlook-remote-history-test)
;;; overlook-remote-history-test.el ends here
