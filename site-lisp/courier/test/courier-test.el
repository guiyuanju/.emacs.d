;;; courier-test.el --- Tests for courier -*- lexical-binding: t; -*-

(require 'ert)
(require 'courier)

(defvar courier-test--inbox nil
  "Alist of agent id to the prompts delivered to it, newest first.")

(defvar courier-test--busy nil
  "Ids of the fake agents not ready for a prompt.")

(defvar courier-test--replies nil
  "Alist of agent id to its last reply.")

(defmacro courier-test-with-agents (ids &rest body)
  "Run BODY with fresh fake agents IDS registered."
  (declare (indent 1))
  `(let ((courier--agents (make-hash-table :test #'equal))
         (courier--retry-timer nil)
         (courier-test--inbox nil)
         (courier-test--busy nil)
         (courier-test--replies nil))
     (unwind-protect
         (progn
           (mapc #'courier-test--register ,ids)
           ,@body)
       (when (timerp courier--retry-timer) (cancel-timer courier--retry-timer)))))

(defun courier-test--register (id &optional parent)
  "Register fake agent ID, spawned by PARENT."
  (courier-register id
                    :parent parent
                    :deliver (lambda (text) (push text (alist-get id courier-test--inbox nil nil #'equal)))
                    :ready (lambda () (not (member id courier-test--busy)))
                    :reply (lambda () (alist-get id courier-test--replies nil nil #'equal))))

(defun courier-test--received (id)
  "Prompts delivered to ID, oldest first."
  (reverse (alist-get id courier-test--inbox nil nil #'equal)))

(ert-deftest courier-send-waits-until-the-agent-is-ready ()
  (courier-test-with-agents '("a@p" "b@p")
    (push "b@p" courier-test--busy)
    (courier-send "b@p" "one" "a@p")
    (courier-send "b@p" "two" "a@p")
    (courier-deliver)
    (should-not (courier-test--received "b@p"))
    (should (timerp courier--retry-timer))
    (setq courier-test--busy nil)
    (courier-deliver)
    (let ((prompts (courier-test--received "b@p")))
      (should (= (length prompts) 1))
      (should (string-match-p "From a@p.*courier send a@p" (car prompts)))
      (should (string-match-p "one\\(.\\|\n\\)*two" (car prompts))))
    (should-not courier--retry-timer)))

(ert-deftest courier-delivers-once-per-turn ()
  (courier-test-with-agents '("a@p" "b@p")
    (courier-send "b@p" "one" "a@p")
    (courier-deliver)
    (courier-send "b@p" "two" "a@p")
    (courier-deliver)
    (should (= (length (courier-test--received "b@p")) 1))
    (courier-turn-started "b@p")
    (courier-turn-finished "b@p")
    (courier-deliver)
    (should (= (length (courier-test--received "b@p")) 2))))

(ert-deftest courier-send-to-unknown-agent-errors ()
  (courier-test-with-agents '("a@p")
    (should-error (courier-send "nobody@p" "hi" "a@p") :type 'user-error)))

(ert-deftest courier-monitor-tells-once-with-the-reply ()
  (courier-test-with-agents '("a@p" "b@p")
    (courier-monitor "a@p" "b@p")
    (setf (alist-get "b@p" courier-test--replies nil nil #'equal) "all done")
    (courier-turn-finished "b@p")
    (courier-deliver)
    (should (string-match-p "b@p finished its turn.*\n\nall done"
                            (car (courier-test--received "a@p"))))
    (courier-turn-started "a@p")
    (courier-turn-finished "a@p")
    (courier-turn-finished "b@p")
    (courier-deliver)
    (should (= (length (courier-test--received "a@p")) 1))))

(ert-deftest courier-monitor-passes-a-long-reply-whole ()
  (courier-test-with-agents '("a@p" "b@p")
    (courier-monitor "a@p" "b@p")
    (let ((reply (concat (make-string 10000 ?x) "end")))
      (setf (alist-get "b@p" courier-test--replies nil nil #'equal) reply)
      (courier-turn-finished "b@p")
      (courier-deliver)
      (should (string-suffix-p reply (car (courier-test--received "a@p")))))))

(ert-deftest courier-monitor-hears-when-the-agent-is-gone ()
  (courier-test-with-agents '("a@p")
    (let ((buffer (generate-new-buffer "b")))
      (courier-register "b@p" :buffer buffer :deliver #'ignore)
      (courier-monitor "a@p" "b@p")
      (kill-buffer buffer)
      (should-not (courier-agent "b@p"))
      (courier-deliver)
      (should (string-match-p "b@p is gone" (car (courier-test--received "a@p")))))))

(ert-deftest courier-spawn-briefs-the-child-and-reports-back ()
  (courier-test-with-agents '("a@p")
    (let ((courier-spawn-function
           (lambda (name directory parent)
             (let ((id (courier-new-id name directory)))
               (courier-test--register id parent)
               id))))
      (should (equal (courier-spawn "codex" "/work/p/" "review foo.go" "a@p") "codex@p"))
      (courier-deliver)
      (let ((brief (car (courier-test--received "codex@p"))))
        (should (string-match-p "You are codex@p" brief))
        (should (string-match-p "a@p started you" brief))
        (should (string-suffix-p "review foo.go" brief)))
      (should (equal (courier-agent-parent (courier-agent "codex@p")) "a@p"))
      (courier-turn-started "codex@p")
      (setf (alist-get "codex@p" courier-test--replies nil nil #'equal) "looks fine")
      (courier-turn-finished "codex@p")
      (courier-deliver)
      (should (string-match-p "looks fine" (car (courier-test--received "a@p")))))))

(ert-deftest courier-new-id-stays-unique ()
  (courier-test-with-agents '("claude@shop")
    (should (equal (courier-new-id "claude" "/x/shop/") "claude@shop-2"))
    (should (equal (courier-new-id "codex" "/x/shop") "codex@shop"))))

(ert-deftest courier-drops-messages-past-max-hops ()
  (courier-test-with-agents '("a@p" "b@p")
    (let ((courier-max-hops 3)
          (inhibit-message t))
      ;; Two agents answering each other forever.
      (courier-send "b@p" "ping" "a@p")
      (dotimes (_ 10)
        (courier-deliver)
        (dolist (pair '(("a@p" . "b@p") ("b@p" . "a@p")))
          (when (courier-agent-delivered (courier-agent (car pair)))
            (courier-turn-started (car pair))
            (courier-send (cdr pair) "again" (car pair))
            (courier-turn-finished (car pair)))))
      (should (= (+ (length (courier-test--received "a@p"))
                    (length (courier-test--received "b@p")))
                 courier-max-hops)))))

(ert-deftest courier-human-turn-restarts-the-hops ()
  (courier-test-with-agents '("a@p" "b@p")
    (courier-send "b@p" "hi" "a@p")
    (courier-deliver)
    (courier-turn-started "b@p")
    (should (= (courier-agent-hops (courier-agent "b@p")) 1))
    (courier-turn-finished "b@p")
    (courier-turn-started "b@p")
    (should (= (courier-agent-hops (courier-agent "b@p")) 0))))

(ert-deftest courier-cli-decodes-arguments-and-writes-output ()
  (courier-test-with-agents '("a@p" "b@p")
    (let ((output (make-temp-file "courier-out"))
          (encode (lambda (s) (base64-encode-string (encode-coding-string s 'utf-8) t))))
      (unwind-protect
          (progn
            (should (courier-cli output (funcall encode "a@p") (funcall encode "send")
                                 (funcall encode "b@p") (funcall encode "看一下 \"x\"\n")))
            (courier-deliver)
            (should (string-match-p "看一下 \"x\"" (car (courier-test--received "b@p"))))
            (should-not (courier-cli output (funcall encode "a@p") (funcall encode "send")
                                     (funcall encode "zz@p") (funcall encode "hi")))
            (should (string-prefix-p "error: No agent zz@p"
                                     (with-temp-buffer (insert-file-contents output)
                                                       (buffer-string))))
            (courier-cli output "" (funcall encode "whoami"))
            (should (string-prefix-p "Not a courier agent"
                                     (with-temp-buffer (insert-file-contents output)
                                                       (buffer-string)))))
        (delete-file output)))))

;;; courier-test.el ends here
