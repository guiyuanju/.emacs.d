EMACS ?= emacs

# Set OVERLOOK_INSTALL_DEPS=1 to install the dependencies into .elpa/ first;
# otherwise list their directories in OVERLOOK_LOAD_PATH.
DEPS = $(if $(OVERLOOK_INSTALL_DEPS),-l test/deps.el)

.PHONY: test lint
test:
	$(EMACS) -Q --batch $(DEPS) -l test/run.el

lint:
	$(EMACS) -Q --batch $(DEPS) -l test/lint.el
