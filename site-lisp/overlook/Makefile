EMACS ?= emacs

# Set OVERLOOK_INSTALL_DEPS=1 to install the dependencies into .elpa/ first;
# otherwise list their directories in OVERLOOK_LOAD_PATH.
DEPS = $(if $(OVERLOOK_INSTALL_DEPS),-l test/deps.el)

.PHONY: test lint
test:
	$(EMACS) -Q --batch $(DEPS) -l test/run.el
	@if command -v node >/dev/null; then node test/overlook-remote-ui-test.cjs; fi

lint:
	$(EMACS) -Q --batch $(DEPS) -l test/lint.el
