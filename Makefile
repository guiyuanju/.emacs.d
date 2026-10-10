EMACS ?= emacs

.PHONY: test
test:
	$(EMACS) -Q --batch -l test/run.el
