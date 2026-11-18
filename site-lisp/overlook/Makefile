EMACS ?= emacs

# Set OVERLOOK_INSTALL_DEPS=1 to install the dependencies into .elpa/ first;
# otherwise list their directories in OVERLOOK_LOAD_PATH.
DEPS = $(if $(OVERLOOK_INSTALL_DEPS),-l test/deps.el)

HAVE_GO := $(shell command -v go 2>/dev/null)
HAVE_NODE := $(shell command -v node 2>/dev/null)
# The menu bar app (remote/menubar) is Swift and macOS only.
HAVE_SWIFT := $(and $(filter Darwin,$(shell uname)),$(shell command -v swift 2>/dev/null))
WEBTEST := cd remote/webtest && EMACS=$(EMACS) node

.PHONY: test test-elisp test-remote lint lint-elisp lint-remote
test: test-elisp test-remote

test-elisp:
	$(EMACS) -Q --batch $(DEPS) -l test/run.el

# The daemon's Go tests, the menu bar app's Swift tests and deploy.sh against a fake launchctl,
# then the page's unit, browser and end-to-end tests; browser tests skip themselves without Playwright.
test-remote:
ifdef HAVE_SWIFT
	swift test --package-path remote/menubar
else
	@echo "swift or macOS not found: skipping the menu bar app tests"
endif
ifdef HAVE_GO
	cd remote && go test ./...
	remote/deploy/deploy_test.sh
else
	@echo "go not found: skipping the overlook-remoted tests"
endif
ifdef HAVE_NODE
	$(WEBTEST) --import ./register.mjs --test unit.test.mjs
	@cd remote/webtest && node -e 'const r = require("./browser.cjs").unavailable(); if (r) console.log(r + ": the browser tests skip")'
	$(WEBTEST) --test --test-concurrency=1 browser.test.mjs usage.test.mjs daemon.test.mjs e2e-emacs.test.mjs
else
	@echo "node not found: skipping the page tests"
endif

lint: lint-elisp lint-remote

lint-elisp:
	$(EMACS) -Q --batch $(DEPS) -l test/lint.el

lint-remote:
ifdef HAVE_GO
	cd remote && go vet ./...
	sh -n remote/deploy/deploy.sh && sh -n remote/deploy/install.sh && sh -n remote/deploy/deploy_test.sh
	@cd remote && unformatted="$$(gofmt -l .)"; if [ -n "$$unformatted" ]; then echo "gofmt needed: $$unformatted"; exit 1; fi
else
	@echo "go not found: skipping go vet and gofmt"
endif
ifdef HAVE_SWIFT
	swift format lint --strict -r remote/menubar/Sources remote/menubar/Tests remote/menubar/Package.swift
endif
