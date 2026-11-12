EMACS ?= emacs

# Packages installed by elpaca, joined as a load path; nothing is split by a shell.
BUILDS := $(subst $() ,:,$(strip $(wildcard $(CURDIR)/elpaca/builds/*/)))
export EMACSLOADPATH := $(CURDIR)/lisp:$(CURDIR)/site-lisp/overlook:$(BUILDS):
export OVERLOOK_LOAD_PATH := $(BUILDS)

TESTS := $(wildcard tests/*-test.el)

.PHONY: test test-config test-overlook lint

test: test-config test-overlook

test-config:
	$(EMACS) -Q --batch $(addprefix -l ,$(TESTS)) -f ert-run-tests-batch-and-exit

test-overlook:
	$(MAKE) -C site-lisp/overlook test

lint:
	$(MAKE) -C site-lisp/overlook lint
