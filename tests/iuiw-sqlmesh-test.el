;;; iuiw-sqlmesh-test.el --- SQLMesh lineage checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'iuiw-sqlmesh)

(ert-deftest iuiw-sqlmesh-label-lines ()
  (should (equal (iuiw-sqlmesh--label-lines "dwd.dwd_vendor_order_di")
                 '("dwd dwd_vendor_order_di")))
  (should (equal (iuiw-sqlmesh--label-lines "dws.dws_user_fee_daily_di")
                 '("dws" "dws_user_fee_daily_di")))
  (should (equal (iuiw-sqlmesh--label-lines "dwd.dwd_aircraft_order_open_snapshot_df")
                 '("dwd_aircraft_order_open_" "snapshot_df"))))

(ert-deftest iuiw-sqlmesh-reachable ()
  (let ((next (lambda (n) (cdr (assoc n '(("a" "b" "c") ("b" "d") ("c" "d")))))))
    (should (equal (iuiw-sqlmesh--reachable "a" next nil) '("a" "b" "c" "d")))
    (should (equal (iuiw-sqlmesh--reachable "a" next 1) '("a" "b" "c")))))

(ert-deftest iuiw-sqlmesh-render-buttons ()
  (let ((dag (make-hash-table :test #'equal)))
    (puthash "src.raw" (make-hash-table :test #'equal) dag)
    (puthash "dwd.mid" (let ((h (make-hash-table :test #'equal)))
                         (puthash "deps" '("src.raw") h) h)
             dag)
    (with-temp-buffer
      (let ((rendered (iuiw-sqlmesh--render dag "dwd.mid" nil)))
        (insert (cdr rendered))
        (iuiw-sqlmesh--buttonize (car rendered))
        (goto-char (point-min))
        (search-forward "src raw")
        (should (equal (get-text-property (1- (point)) 'iuiw-sqlmesh-model) "src.raw"))
        (search-forward "dwd mid")
        (should (equal (get-text-property (1- (point)) 'iuiw-sqlmesh-model) "dwd.mid"))))))

(ert-deftest iuiw-sqlmesh-narrow-arrows ()
  (should (equal (iuiw-sqlmesh--narrow-arrows "┌─▼▼─┐\n╔═▼▼═╗")
                 "┌─┴┴─┐\n╔═╩╩═╗")))
