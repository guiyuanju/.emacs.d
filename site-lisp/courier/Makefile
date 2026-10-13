EMACS ?= emacs

# Set COURIER_INSTALL_DEPS=1 to install package-lint into .elpa/ first.
DEPS = $(if $(COURIER_INSTALL_DEPS),-l test/deps.el)

.PHONY: test lint
test:
	$(EMACS) -Q --batch -l test/run.el

lint:
	$(EMACS) -Q --batch $(DEPS) -l test/lint.el
