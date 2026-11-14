# Remote page: differences from the old page

The page under `web/` follows `../../docs/remote-ui.md`; this lists only where
it behaves differently.

## Transport

The page loads a snapshot, then keeps one event stream open for what it
shows: the dashboard, or a conversation (and the dashboard behind it). Leaving
a page closes its stream and opens the next one with the cursors it holds, so
nothing unchanged is sent again. An unchanged Home Screen reopen revalidates
the page and fetches only the dashboard; scripts and styles come from the
browser cache.

## Read positions

Reading a streaming reply acknowledges it at most every two seconds; leaving
the conversation, or hiding the page, sends the latest position at once, so a
list never shows an unread badge for what was just read.

## Emacs and daemon

Emacs disconnecting shows "Emacs is not connected" while the dashboard and
conversations stay readable; writes fail with the same explanation. When the
daemon restarts, the page reconnects with its cursors and receives only what
changed meanwhile (the daemon restores its state file); a conversation without
retained activity shows its last reply and transcript tail, as before.
