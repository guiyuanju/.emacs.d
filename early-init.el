(setq package-enable-at-startup nil)

;; log native-comp warnings instead of popping up *Warnings* on every one;
;; the redisplay churn is what makes a big JIT batch feel like a freeze
(setq native-comp-async-report-warnings-errors 'silent)
