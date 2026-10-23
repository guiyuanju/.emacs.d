;;; iuiw-vdiff.el --- vdiff window layout -*- lexical-binding: t; -*-

;;; Commentary:
;; 两栏 vdiff 打开后光标落在右边（新版本）的窗口。

;;; Code:

(declare-function vdiff-2way-layout-function-default "vdiff")

(defun iuiw-vdiff-layout (buffer-a buffer-b &optional rotate)
  "Lay out BUFFER-A and BUFFER-B as vdiff does, then select BUFFER-B.
ROTATE is passed on to `vdiff-2way-layout-function-default'."
  (vdiff-2way-layout-function-default buffer-a buffer-b rotate)
  (select-window (get-buffer-window buffer-b)))

(provide 'iuiw-vdiff)
;;; iuiw-vdiff.el ends here
