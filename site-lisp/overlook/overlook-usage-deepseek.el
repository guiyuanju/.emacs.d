;;; overlook-usage-deepseek.el --- DeepSeek balance -*- lexical-binding: t; -*-

;; Copyright (C) 2026 guiyuanju

;; Author: guiyuanju <guiyuanjune@outlook.com>
;; URL: https://github.com/guiyuanju/overlook
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A DeepSeek row in the dashboard's Usage section: the account balance
;; from /user/balance, with a bar of how much of the balance after the
;; last top-up is spent.  Loading this file adds the row; it shows once
;; `overlook-usage-deepseek-api-key' is set.  The key is sent to curl on
;; stdin, never in argv.

;;; Code:

(require 'overlook-usage)
(require 'json)

(defcustom overlook-usage-deepseek-api-key nil
  "DeepSeek API key, or a function returning it, or nil for no DeepSeek row."
  :type '(choice (const :tag "None" nil) string function)
  :group 'overlook)

(defcustom overlook-usage-deepseek-state-file
  (locate-user-emacs-file "overlook-deepseek-spending.json")
  "File keeping the DeepSeek balance after the last top-up across restarts."
  :type 'file
  :group 'overlook)

(defvar overlook-usage-deepseek--balance nil)
(defvar overlook-usage-deepseek--error nil)
(defvar overlook-usage-deepseek--process nil)
(defvar overlook-usage-deepseek--state nil)
(defvar overlook-usage-deepseek--loaded-key nil)

(defcustom overlook-usage-deepseek-usage-url "https://platform.deepseek.com/usage"
  "Page the dashboard's DeepSeek usage row opens on RET."
  :type 'string
  :group 'overlook)

(defun overlook-usage-deepseek-open-usage ()
  "Open DeepSeek's usage page in a browser."
  (interactive)
  (browse-url overlook-usage-deepseek-usage-url))

(defun overlook-usage-deepseek--key ()
  "The DeepSeek API key, or nil."
  (if (functionp overlook-usage-deepseek-api-key)
      (funcall overlook-usage-deepseek-api-key)
    overlook-usage-deepseek-api-key))

(defun overlook-usage-deepseek--load-state ()
  "Restore observations for this key, without storing the key itself."
  (let ((key (secure-hash 'sha256 (overlook-usage-deepseek--key))))
    (unless (equal key overlook-usage-deepseek--loaded-key)
      (setq overlook-usage-deepseek--loaded-key key
            overlook-usage-deepseek--state
            (condition-case nil
                (with-temp-buffer
                  (insert-file-contents overlook-usage-deepseek-state-file)
                  (let ((data (json-parse-buffer :object-type 'alist :array-type 'list)))
                    (when (and (equal (alist-get 'key data) key)
                               (seq-every-p
                                (lambda (top)
                                  (and (member (alist-get 'currency top) '("CNY" "USD"))
                                       (numberp (alist-get 'peak top))
                                       (numberp (alist-get 'last top))))
                                (alist-get 'tops data)))
                      data)))
              (error nil))))))

(defun overlook-usage-deepseek--top (currency)
  "The recorded peak and last balance of CURRENCY, or nil."
  (seq-find (lambda (top) (equal currency (alist-get 'currency top)))
            (alist-get 'tops overlook-usage-deepseek--state)))

(defun overlook-usage-deepseek--spent-percent (currency balance)
  "Percentage of CURRENCY's peak spent down to BALANCE, a decimal string."
  (let ((value (string-to-number balance))
        (peak (alist-get 'peak (overlook-usage-deepseek--top currency))))
    (cond ((not (and peak (> peak 0))) (if (> value 0) 0 100))
          (t (min 100 (max 0 (* 100 (- 1 (/ value (float peak))))))))))

(defun overlook-usage-deepseek--record (balance)
  "Record BALANCE, keeping each currency's balance after the last increase.
An increase is taken for a top-up; credit expiry makes this an estimate."
  (overlook-usage-deepseek--load-state)
  (setq overlook-usage-deepseek--state
        `((key . ,overlook-usage-deepseek--loaded-key)
          (tops . ,(mapcar
                    (lambda (pair)
                      (let* ((currency (car pair))
                             (value (string-to-number (cdr pair)))
                             (top (overlook-usage-deepseek--top currency)))
                        `((currency . ,currency)
                          (peak . ,(if (or (null top) (> value (alist-get 'last top)))
                                       value
                                     (alist-get 'peak top)))
                          (last . ,value))))
                    balance))))
  (let* ((dir (file-name-directory overlook-usage-deepseek-state-file))
         (temporary nil))
    (make-directory dir t)
    (unwind-protect
        (progn
          (setq temporary (make-temp-file (expand-file-name ".deepseek-" dir)))
          (with-temp-file temporary
            (insert (json-encode overlook-usage-deepseek--state)))
          (rename-file temporary overlook-usage-deepseek-state-file t))
      (when (and temporary (file-exists-p temporary)) (delete-file temporary)))))

(defun overlook-usage-deepseek--parse-balance (data)
  "Validate DATA and return currency/balance pairs, preserving decimal strings."
  (let ((rows (alist-get 'balance_infos data)))
    (unless (and rows (seq-every-p
                       (lambda (row)
                         (and (member (alist-get 'currency row) '("CNY" "USD"))
                              (stringp (alist-get 'total_balance row))
                              (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'"
                                              (alist-get 'total_balance row))))
                       rows))
      (error "Invalid balance response"))
    (mapcar (lambda (row) (cons (alist-get 'currency row)
                                (alist-get 'total_balance row))) rows)))

(defun overlook-usage-deepseek--fetch ()
  "Start a balance request unless one is running; non-nil when it did."
  (when-let* ((key (overlook-usage-deepseek--key))
              ((not (process-live-p overlook-usage-deepseek--process))))
    (let ((buffer (generate-new-buffer " *deepseek-balance*")))
      (condition-case nil
          (progn
            (setq overlook-usage-deepseek--process
                  (make-process
                   :name "deepseek-balance" :buffer buffer :noquery t
                   :connection-type 'pipe
                   :command '("curl" "-q" "--silent" "--fail" "--max-time" "15"
                              "--config" "-" "https://api.deepseek.com/user/balance")
                   :sentinel
                   (lambda (process _event)
                     (when (memq (process-status process) '(exit signal))
                       (unwind-protect
                           (condition-case nil
                               (with-current-buffer (process-buffer process)
                                 (unless (zerop (process-exit-status process))
                                   (error "Balance request failed"))
                                 (goto-char (point-min))
                                 (setq overlook-usage-deepseek--balance
                                       (overlook-usage-deepseek--parse-balance
                                        (json-parse-buffer :object-type 'alist :array-type 'list))
                                       overlook-usage-deepseek--error nil)
                                 (overlook-usage-deepseek--record overlook-usage-deepseek--balance))
                             (error (setq overlook-usage-deepseek--error t)))
                         (kill-buffer (process-buffer process)))
                       (overlook-usage-scan)))))
            ;; Only accept a single header value; no curl-config injection.
            (unless (string-match-p "\\`[A-Za-z0-9_-]+\\'" key)
              (error "Invalid key format"))
            (process-send-string overlook-usage-deepseek--process
                                 (concat "header = \"Authorization: Bearer "
                                         key "\"\n"))
            (process-send-eof overlook-usage-deepseek--process))
        (error
         (setq overlook-usage-deepseek--error t)
         (when (process-live-p overlook-usage-deepseek--process)
           (delete-process overlook-usage-deepseek--process))
         (when (buffer-live-p buffer) (kill-buffer buffer)))))
    t))

(defun overlook-usage-deepseek-usage ()
  "Return the account balance, a bar per currency."
  (when (overlook-usage-deepseek--key)
    (cons (propertize "deepseek"
                      'overlook-action #'overlook-usage-deepseek-open-usage
                      'help-echo "RET opens DeepSeek's usage page")
          (if overlook-usage-deepseek--balance
              (progn
                (overlook-usage-deepseek--load-state)
                (mapcar
                 (pcase-lambda (`(,currency . ,amount))
                   (list (if (equal currency "CNY") "¥" "$")
                         (overlook-usage-deepseek--spent-percent currency amount)
                         (propertize
                          (concat amount (if overlook-usage-deepseek--error " stale" ""))
                          'face (if overlook-usage-deepseek--error 'warning 'shadow)
                          'help-echo "DeepSeek account balance; the bar is how much of the balance after the last top-up is spent. Refreshed every 5 minutes; stale means the last refresh failed.")))
                 overlook-usage-deepseek--balance))
            (list (list "balance"
                        (propertize (if overlook-usage-deepseek--error "unavailable" "loading")
                                    'face (if overlook-usage-deepseek--error 'warning 'shadow)
                                    'help-echo "DeepSeek account balance; refreshed every 5 minutes.")
                        nil))))))

(add-to-list 'overlook-usage-functions #'overlook-usage-deepseek-usage t)
(overlook-usage-add-poller #'overlook-usage-deepseek--fetch)

(provide 'overlook-usage-deepseek)
;;; overlook-usage-deepseek.el ends here
