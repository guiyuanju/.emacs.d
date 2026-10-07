# Agent notes

## Apply changes to the live Emacs

After editing, apply the change to the running Emacs with `emacsclient --eval` when it is safe:

- Self-contained files under `lisp/`: `(load-file "lisp/<file>.el")`.
- `init.el`: evaluate only the changed form; never reload the whole file, since elpaca and use-package would run again.
- When a change cannot be applied cleanly (package load order, mode toggles, hooks that would be added twice), leave it and say a restart is needed.

## Prefer packages over custom code

1. Use an existing popular package.
2. Use options and commands the packages already provide.
3. Write custom code only when neither works.
