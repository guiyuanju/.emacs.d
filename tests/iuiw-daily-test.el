;;; iuiw-daily-test.el --- Daily task checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'iuiw-daily)

(defmacro iuiw-daily-test--with-task (&rest body)
  "Run BODY with a task `test' writing into a fresh folder and a fresh sync folder."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "iuiw-daily" t)))
          (iuiw-sync-directory (file-name-as-directory (make-temp-file "iuiw-sync" t)))
          (iuiw-daily--tasks nil)
          (iuiw-daily--running nil)
          (iuiw-daily--seen (make-hash-table :test #'equal))
          (iuiw-daily--announced (make-hash-table :test #'eq))
          (iuiw-sync-host "this-mac")
          (iuiw-daily-schedule nil))
     (unwind-protect
         (progn
           (iuiw-daily-define 'test :title "Test" :directory (lambda () dir) :extension "md")
           ,@body)
       (delete-directory dir t)
       (delete-directory iuiw-sync-directory t))))

(ert-deftest iuiw-daily-due-follows-schedule ()
  (iuiw-daily-test--with-task
    (let* ((now (decode-time))
           (hour (decoded-time-hour now))
           (day (decoded-time-weekday now)))
      (cl-flet ((due (schedule)
                  (setq iuiw-daily-schedule (list (cons 'test schedule)))
                  (and (iuiw-daily--due-p 'test) t)))
        (should (due nil))
        (should (due `(:hour ,hour :days (,day) :hosts ("this-mac"))))
        (should-not (due `(:hour ,(1+ hour))))
        (should-not (due `(:days (,(% (1+ day) 7)))))
        (should-not (due '(:hosts ("other-mac"))))
        (setq iuiw-daily-schedule nil)
        (should-not (iuiw-daily--due-p 'test))
        (setq iuiw-daily-schedule '((test)))
        (with-temp-file (iuiw-daily-file 'test) (insert "done"))
        (should-not (iuiw-daily--due-p 'test))))))

(ert-deftest iuiw-daily-latest-ignores-other-files ()
  (iuiw-daily-test--with-task
    (dolist (name '("2026-11-10.md" "2026-11-11.md" "2026-11-12.org" "notes.md"))
      (with-temp-file (expand-file-name name dir)))
    (make-directory (expand-file-name "material" dir))
    (should (equal (mapcar #'file-name-nondirectory (iuiw-daily-files 'test))
                   '("2026-11-10.md" "2026-11-11.md")))
    (should (equal (file-name-nondirectory (iuiw-daily-latest 'test)) "2026-11-11.md"))))

(ert-deftest iuiw-daily-seen-reads-both-record-forms ()
  (iuiw-daily-test--with-task
    (make-directory (iuiw-sync-file "seen"))
    (with-temp-file (iuiw-sync-file "seen" "2026-11.jsonl")
      (insert "{\"t\":1,\"host\":\"a\",\"digest\":\"2026-11-10\"}\n"
              "{\"t\":2,\"host\":\"a\",\"task\":\"test\",\"key\":\"2026-11-11\"}\n"))
    (iuiw-daily--load-seen)
    (should (iuiw-daily--seen-p 'elfeed-digest "/x/2026-11-10.org"))
    (should (iuiw-daily--seen-p 'test "/x/2026-11-11.md"))
    (should-not (iuiw-daily--seen-p 'test "/x/2026-11-10.md"))))

;;; iuiw-daily-test.el ends here
