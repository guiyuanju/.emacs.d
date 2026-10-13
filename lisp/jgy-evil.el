;;; jgy-evil.el --- Evil tweaks for keys and terminals -*- lexical-binding: t; -*-

;;; Commentary:
;; C-[ 与 ESC 分开解码，以及 evil-ghostel 光标定位的修正。

;;; Code:

(declare-function ghostel-cursor-point "ghostel")
(declare-function ghostel--viewport-row-at "ghostel")
(declare-function ghostel--send-encoded "ghostel")
(declare-function evil-ghostel--input-end "evil-ghostel")
(declare-function evil-ghostel--sync-render "evil-ghostel")
(defvar ghostel--term)

;; 图形界面里 C-[ 与 ESC 键是不同事件；拆开后 agent 把 ESC 留给终端，C-[ 仍回 normal。
(defun jgy-decode-control-bracket (&optional frame)
  "Make C-[ distinct from ESC on graphical FRAME."
  (when (display-graphic-p frame)
    (with-selected-frame (or frame (selected-frame))
      (define-key input-decode-map [?\C-\[] [control-bracketleft]))))

;; 普通态移动后 i/a 会把终端光标带到 point。
(defun jgy-evil-ghostel-goto-input-position (pos)
  "Drive the terminal cursor to POS, counting columns on the Emacs side.
Replaces `evil-ghostel-goto-input-position', which takes the terminal's
column and miscounts after wide prompt glyphs such as ➜."
  (when-let* ((cursor (and ghostel--term (ghostel-cursor-point))))
    (when (and (> pos cursor) (= (line-number-at-pos pos) (line-number-at-pos cursor)))
      (setq pos (min pos (or (evil-ghostel--input-end) pos))))
    (let* ((column (lambda (p) (save-excursion (goto-char p) (current-column))))
           (dy (- (or (ghostel--viewport-row-at pos) 0)
                  (or (ghostel--viewport-row-at cursor) 0)))
           (dx (- (funcall column pos) (funcall column cursor))))
      (dotimes (_ (abs dy)) (ghostel--send-encoded (if (> dy 0) "down" "up") ""))
      (dotimes (_ (abs dx)) (ghostel--send-encoded (if (> dx 0) "right" "left") ""))
      (unless (and (zerop dx) (zerop dy)) (evil-ghostel--sync-render))
      (goto-char pos)
      t)))

(provide 'jgy-evil)
;;; jgy-evil.el ends here
