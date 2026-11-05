;;; overlook-remote-test.el --- Tests for overlook-remote -*- lexical-binding: t; -*-

(require 'ert)
(require 'overlook-remote)

(defvar overlook-remote-test--submitted nil
  "Prompts the fake agent was given, newest first.")

(defvar overlook-remote-test--chosen nil
  "Answers the fake agent was given, newest first.")

(defmacro overlook-remote-test-with-agent (ready &rest body)
  "Run BODY with a token and a fake agent \"claude\", taking prompts when READY."
  (declare (indent 1))
  `(let* ((overlook-remote-token-file (make-temp-file "overlook-remote-token"))
          (overlook-remote-test--submitted nil)
          (overlook-remote-test--chosen nil)
          (agent (generate-new-buffer "claude@shop")))
     (delete-file overlook-remote-token-file)
     (unwind-protect
         (progn
           (with-current-buffer agent
             (insert "earlier output\nlatest output")
             (setq overlook-agent-identity
                   `((agent . "claude") (root . "/work/shop/")
                     (submit . ,(lambda (text) (push text overlook-remote-test--submitted)))
                     (ready . ,(lambda () ,ready))
                     (reply . ,(lambda () "Done: café"))
                     (choices . ,(lambda ()
                                   (list (list "y" "Allow" (lambda () (push "y" overlook-remote-test--chosen)))
                                         (list "n" "Reject" (lambda () (push "n" overlook-remote-test--chosen)))))))))
           ,@body)
       (kill-buffer agent)
       (when (file-exists-p overlook-remote-token-file)
         (delete-file overlook-remote-token-file)))))

(defun overlook-remote-test--call (method path &optional body token query)
  "Answer METHOD on PATH with JSON BODY, carrying TOKEN or the right one.
QUERY is the parsed query.  Return (STATUS . DATA) with DATA parsed."
  (pcase-let ((`(,status ,_ ,text)
               (overlook-remote--respond
                method path query
                `((,method ,path "HTTP/1.1")
                  ("Authorization" ,(concat "Bearer " (or token (overlook-remote--token))))
                  ,@(when body
                      `(("Content" ,(encode-coding-string (json-encode body) 'utf-8))))))))
    (cons status (json-parse-string text :object-type 'alist :array-type 'list))))

(ert-deftest overlook-remote-token-is-kept-private-and-reused ()
  (overlook-remote-test-with-agent t
    (let ((token (overlook-remote--token)))
      (should (= (length token) 64))
      (should (= (file-modes overlook-remote-token-file) #o600))
      (should (equal (overlook-remote--token) token))
      (should-not (equal (overlook-remote-new-token) token)))))

(ert-deftest overlook-remote-page-needs-no-token-but-calls-do ()
  (overlook-remote-test-with-agent t
    (pcase-let ((`(,status ,mime ,_) (overlook-remote--respond "GET" "/overlook/" nil nil)))
      (should (= status 200))
      (should (equal mime "text/html")))
    (pcase-let ((`(,status ,mime ,body)
                 (overlook-remote--respond "GET" "/overlook/vendor/purify.js" nil nil)))
      (should (= status 200))
      (should (equal mime "text/javascript"))
      (should (string-match-p "DOMPurify" body)))
    (should (= (car (overlook-remote--respond "GET" "/overlook/vendor/../overlook-remote.el" nil nil))
               401))
    (should (= (car (overlook-remote-test--call "GET" "/overlook/api/agents" nil "wrong")) 401))))

(ert-deftest overlook-remote-lists-agents-with-their-choices ()
  (overlook-remote-test-with-agent t
    (pcase-let* ((`(,status . ,data) (overlook-remote-test--call "GET" "/overlook/api/agents"))
                 (agent (seq-find (lambda (a) (equal (alist-get 'id a) "claude@shop"))
                                  (alist-get 'agents data))))
      (should (= status 200))
      (should (equal (alist-get 'project agent) "shop"))
      (should (equal (alist-get 'status agent) "idle"))
      (should (equal (mapcar (lambda (c) (alist-get 'key c)) (alist-get 'choices agent))
                     '("y" "n"))))))

(ert-deftest overlook-remote-shows-an-agents-reply-and-transcript ()
  (overlook-remote-test-with-agent t
    (pcase-let ((`(,status . ,agent) (overlook-remote-test--call
                                      "GET" "/overlook/api/agent" nil nil
                                      '(("id" "claude@shop")))))
      (should (= status 200))
      (should (equal (alist-get 'reply agent) "Done: café"))
      (should (string-suffix-p "latest output" (alist-get 'transcript agent))))
    (should (= (car (overlook-remote-test--call "GET" "/overlook/api/agent" nil nil
                                                '(("id" "nobody"))))
               409))))

(ert-deftest overlook-remote-prompts-a-ready-agent ()
  (overlook-remote-test-with-agent t
    (should (= (car (overlook-remote-test--call "POST" "/overlook/api/prompt"
                                                '((id . "claude@shop") (text . " 继续 "))))
               200))
    (should (equal overlook-remote-test--submitted '("继续")))))

(ert-deftest overlook-remote-refuses-to-prompt-a-busy-agent ()
  (overlook-remote-test-with-agent nil
    (pcase-let ((`(,status . ,data) (overlook-remote-test--call
                                     "POST" "/overlook/api/prompt"
                                     '((id . "claude@shop") (text . "go on")))))
      (should (= status 409))
      (should (string-match-p "busy" (alist-get 'error data))))
    (should-not overlook-remote-test--submitted)))

(ert-deftest overlook-remote-answers-what-an-agent-asks ()
  (overlook-remote-test-with-agent t
    (should (= (car (overlook-remote-test--call "POST" "/overlook/api/choose"
                                                '((id . "claude@shop") (key . "n"))))
               200))
    (should (equal overlook-remote-test--chosen '("n")))
    (should (= (car (overlook-remote-test--call "POST" "/overlook/api/choose"
                                                '((id . "claude@shop") (key . "!"))))
               409))))

(ert-deftest overlook-remote-keeps-one-item-per-reply-and-tool-call ()
  (overlook-remote-test-with-agent t
    (let ((overlook-remote--seq 0)
          (overlook-remote--waiting nil))
      (overlook-remote--record agent '(:type prompt :text "fix it"))
      (overlook-remote--record agent '(:type text :text "On "))
      (overlook-remote--record agent '(:type tool :id "t1" :title "Edit a.el" :status "pending"))
      (overlook-remote--record agent '(:type text :text "it"))
      (overlook-remote--record agent '(:type text :text " now"))
      (overlook-remote--record agent '(:type tool :id "t1" :status "completed"
                                       :diffs ((:file "a.el" :old "x\n" :new "y\n"))))
      (let ((items (reverse (buffer-local-value 'overlook-remote--items agent))))
        (should (equal (mapcar (lambda (item) (plist-get item :type)) items)
                       '("prompt" "text" "tool" "text")))
        (should (equal (plist-get (nth 3 items) :text) "it now"))
        (should (equal (plist-get (nth 2 items) :title) "Edit a.el"))
        (should (equal (plist-get (nth 2 items) :status) "completed"))
        (should (string-match-p "^-x$" (plist-get (nth 2 items) :diff)))
        (should (string-match-p "^\\+y$" (plist-get (nth 2 items) :diff)))
        (should (= (plist-get (nth 2 items) :seq) 6))))))

(ert-deftest overlook-remote-sends-news-since-the-pages-last-change ()
  (overlook-remote-test-with-agent t
    (let ((overlook-remote--seq 0)
          (overlook-remote--waiting nil))
      (overlook-remote--record agent '(:type prompt :text "fix it"))
      (overlook-remote--record agent '(:type text :text "On it"))
      (pcase-let* ((`(,status . ,news) (overlook-remote-test--call
                                        "GET" "/overlook/api/events" nil nil
                                        '(("id" "claude@shop") ("after" "0"))))
                   (known (alist-get 'known news)))
        (should (= status 200))
        (should (= (alist-get 'seq news) 2))
        (should (equal (mapcar (lambda (item) (alist-get 'type item)) (alist-get 'items news))
                       '("prompt" "text")))
        (should (equal (alist-get 'status (alist-get 'agent news)) "idle"))
        (should (eq (alist-get 'reset news) :false))
        ;; Nothing new: the call is held.
        (should (equal (overlook-remote--respond
                        "GET" "/overlook/api/events"
                        `(("id" "claude@shop") ("after" "2") ("known" ,known))
                        `(("GET" "/overlook/api/events" "HTTP/1.1")
                          ("Authorization" ,(concat "Bearer " (overlook-remote--token)))))
                       (list :hold agent 2 known)))
        ;; Its state changed: news at once, with no items.
        (should (equal (alist-get 'items (cdr (overlook-remote-test--call
                                                "GET" "/overlook/api/events" nil nil
                                                '(("id" "claude@shop") ("after" "2")
                                                  ("known" "stale")))))
                       nil))
        ;; A page from before Emacs restarted gets everything again.
        (let ((news (cdr (overlook-remote-test--call
                          "GET" "/overlook/api/events" nil nil
                          `(("id" "claude@shop") ("after" "99") ("known" ,known))))))
          (should (eq (alist-get 'reset news) t))
          (should (= (length (alist-get 'items news)) 2)))))))

(ert-deftest overlook-remote-answers-a-held-call-when-news-comes ()
  (overlook-remote-test-with-agent t
    (let* ((overlook-remote--seq 0)
           (overlook-remote--waiting nil)
           (overlook-remote--wake-timer nil)
           (sent nil)
           (proc (make-pipe-process :name "overlook-remote-test" :noquery t))
           (known (cdr (overlook-remote--state agent))))
      (unwind-protect
          (cl-letf (((symbol-function 'overlook-remote--send)
                     (lambda (p response) (push (cons p response) sent))))
            (overlook-remote--hold proc agent 0 known)
            (overlook-remote--answer-news)
            (should-not sent)
            (overlook-remote--record agent '(:type text :text "hi"))
            (should overlook-remote--wake-timer)
            (overlook-remote--answer-news)
            (should (eq (caar sent) proc))
            (should (= (nth 1 (car sent)) 200))
            (should-not overlook-remote--waiting))
        (delete-process proc)))))

(defconst overlook-remote-test--png "\x89PNG\r\n\x1a\nfake"
  "Bytes passing for a PNG image.")

(defmacro overlook-remote-test-with-images (&rest body)
  "Run BODY with `dir' a folder holding a.png, \"my shot.png\" and shots/b.png."
  (declare (indent 0))
  `(let ((dir (file-name-as-directory (make-temp-file "overlook-remote-images" t)))
         (overlook-remote--images nil)
         (overlook-remote--image-count 0)
         (overlook-remote--image-directory nil)
         (coding-system-for-write 'no-conversion))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "shots" dir))
           (dolist (name '("a.png" "my shot.png" "shots/b.png"))
             (write-region overlook-remote-test--png nil (expand-file-name name dir) nil 'silent))
           ,@body)
       (delete-directory dir t)
       (when overlook-remote--image-directory
         (delete-directory overlook-remote--image-directory t)))))

(ert-deftest overlook-remote-finds-the-images-text-names ()
  (overlook-remote-test-with-images
    (should (equal (overlook-remote--image-files
                    (format "截图在%sa.png。另见 @\"%smy shot.png\"、file://%sa.png、![x](shots/b.png)、gone.png"
                            dir dir dir)
                    dir)
                   (list (concat dir "a.png") (concat dir "my shot.png")
                         (concat dir "shots/b.png"))))))

(ert-deftest overlook-remote-numbers-each-picture-once ()
  (overlook-remote-test-with-images
    (let ((a (overlook-remote--image (concat dir "a.png")))
          (coding-system-for-write 'no-conversion))
      ;; Same bytes under another name.
      (should (equal (overlook-remote--image (concat dir "shots/b.png")) a))
      (should (equal (overlook-remote--image (concat dir "a.png")) a))
      (write-region (concat overlook-remote-test--png "more") nil (concat dir "a.png") nil 'silent)
      (should-not (equal (overlook-remote--image (concat dir "a.png")) a))
      (should-not (overlook-remote--image (concat dir "gone.png")))
      (should-not (overlook-remote--image dir)))))

(ert-deftest overlook-remote-serves-the-images-of-a-tool-call ()
  (overlook-remote-test-with-agent t
    (overlook-remote-test-with-images
      (let ((overlook-remote--seq 0)
            (overlook-remote--waiting nil))
        (overlook-remote--record
         agent `(:type tool :id "t1" :title "Screenshot" :status "completed"
                 :output ,(format "Saved to %sa.png" dir)
                 :images ((:data ,(base64-encode-string overlook-remote-test--png) :mime "image/png")
                          (:data "bm90IGFuIGltYWdl" :mime "image/png"))))
        (let* ((news (cdr (overlook-remote-test--call "GET" "/overlook/api/events" nil nil
                                                      '(("id" "claude@shop") ("after" "0")))))
               (item (car (alist-get 'items news)))
               (images (alist-get 'images item)))
          (should-not (assq 'files item))
          ;; The data that is no image is left out, and the image sent as data
          ;; is the same picture as a.png.
          (should (= (length images) 1))
          (pcase-let ((`(,status ,mime ,body)
                       (overlook-remote--respond
                        "GET" "/overlook/api/image" `(("n" ,(number-to-string (car images))))
                        `(("GET" "/x" "HTTP/1.1")
                          ("Authorization" ,(concat "Bearer " (overlook-remote--token)))))))
            (should (= status 200))
            (should (equal mime "image/png"))
            (should (equal body overlook-remote-test--png))
            (should-not (multibyte-string-p body)))
          (should (= (car (overlook-remote-test--call "GET" "/overlook/api/image" nil nil
                                                      '(("n" "999"))))
                     409)))))))

(ert-deftest overlook-remote-takes-images-from-the-phone ()
  (overlook-remote-test-with-agent t
    (let ((attached nil))
      (with-current-buffer agent
        (push (cons 'attach (lambda (name data) (push (cons name data) attached) "@/shots/x.png"))
              overlook-agent-identity))
      (pcase-let ((`(,status . ,data)
                   (overlook-remote-test--call
                    "POST" "/overlook/api/upload"
                    `((id . "claude@shop") (mime . "image/png")
                      (data . ,(base64-encode-string overlook-remote-test--png))))))
        (should (= status 200))
        (should (equal (alist-get 'text data) "@/shots/x.png"))
        (should (string-match-p "\\`phone-.*\\.png\\'" (caar attached)))
        (should (equal (cdar attached) overlook-remote-test--png)))
      (should (= (car (overlook-remote-test--call
                       "POST" "/overlook/api/upload"
                       '((id . "claude@shop") (mime . "image/png") (data . "bm90IGFuIGltYWdl"))))
                 409))
      (let ((overlook-remote-image-size 4))
        (should (= (car (overlook-remote-test--call
                         "POST" "/overlook/api/upload"
                         `((id . "claude@shop") (mime . "image/png")
                           (data . ,(base64-encode-string overlook-remote-test--png)))))
                   409)))
      (should (= (length attached) 1)))))

(ert-deftest overlook-remote-turns-off-after-a-while-on-the-network ()
  (let ((overlook-remote-host "0.0.0.0")
        (overlook-remote-network-minutes 120)
        (overlook-remote-token-file (make-temp-file "overlook-remote-token"))
        (httpd-serve-files nil)
        (overlook-remote--off-timer nil))
    (unwind-protect
        (cl-letf (((symbol-function 'httpd-start) #'ignore)
                  ((symbol-function 'httpd-stop) #'ignore))
          (overlook-remote-mode 1)
          (should (timerp overlook-remote--off-timer))
          (overlook-remote-mode -1)
          (should-not overlook-remote--off-timer)
          (let ((overlook-remote-host "127.0.0.1"))
            (overlook-remote-mode 1)
            (should-not overlook-remote--off-timer)
            (overlook-remote-mode -1)))
      (delete-file overlook-remote-token-file))))

;;; overlook-remote-test.el ends here
