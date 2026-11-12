# Remote interface

The remote page uses Framework7's iOS theme and serves its dependencies locally.
Business objects and capabilities come from protocol 2; presentation and
navigation state belong to the browser.

## Dashboard and project pages

Projects and personas appear before usage. Project siblings use a stable name
order; other domain ordering is preserved. An attention shortcut collects real
waiting/failed/attention conversations without moving the surrounding lists.

Project rows summarize the counts of working, waiting, failed and done agents,
including nested agents and counting each conversation once.

Project rows open details; touch-and-hold, right-click and Shift+F10 offer their
commands. The detail navigation bar exposes the same commands. Project pages
show counts and a new-conversation action when the server advertises one.
Long detail lists initially show six entries and retain their disclosure state.
Task dates distinguish today and overdue dates. Completion remains a server
command and shows a busy state while pending.

Usage accounts show compact consumed percentages. Expand an account to see
separate windows, reset times and advertised account actions. A successful
remote sync does not prove the underlying provider usage data is fresh.

Persona overview rows show a stable colored avatar, identity, status and
conversation count, without a description. A single running persona opens its
conversation. Multi-conversation personas open a dedicated conversation list.
Descriptions remain visible in the conversation and its information sheet.

## Conversations

The navigation title identifies the specific conversation; its subtitle retains
persona/provider/status context. Tap the title to inspect conversation details.
Context usage appears beside the session menu in the fixed header when available.
Returning to a conversation restores its reading position; returning to a list
restores its scroll position and focused row when that row still exists.

The composer disables empty sends. Busy sessions explain queueing and expose
Stop and Adjust now when the backend supports those controls. Failed sends keep
the draft and offer an inline retry using the same request identity. Concurrent
typing and drafts for other conversations are preserved.

Queued prompts can be removed or moved back to the draft. Editing first waits
for a successful server withdrawal, then appends the text to any existing draft.
A prompt already delivered by the server cannot be withdrawn.

Permission choices show their context and submission feedback. While a choice
is being submitted or awaiting the next agent update, duplicate buttons stay
disabled. A later permission request is enabled after the previous one clears.

Three or more adjacent completed tool actions collapse into a disclosure.
Running and failed actions remain visible. Code blocks have a copy action,
including a fallback for HTTP pages without the Clipboard API.

Long replies, tool output and code have bounded previews with an explicit
expansion control. Collapsing changes the presentation only; the complete text
remains available for copying. Conversation list summaries have a line limit.

Close Agent is separate from stopping the current response. Closing requires
confirmation and terminates the live agent; resumable sessions retain a saved
entry. Pending remote prompts are discarded. Agents without a resumable session
cannot be restored through that entry.

A running single-instance Persona offers Kill in its touch-and-hold action
menu. It requires confirmation and discards the live conversation, leaving
the Persona definition available to start again. Multiple-instance Personas
offer Kill on each conversation.

Session confirmation responses include the complete `confirmations` array bound
to their token. Clients replace their previous array with this value after
accepting the question, so a state change can restart the confirmation sequence.

Activity items carry UTC creation and update timestamps. The browser formats
message times locally. Unread counts come from the backend and count assistant
reply items still retained by Remote, rather than tokens or tool updates. A
streaming reply counts once and becomes unread again if updated beyond the
acknowledged sequence. Read
positions are shared by remote clients within the current Emacs lifetime.
Only a visible conversation at its latest messages acknowledges the received
sequence; opening a hidden tab or reading older messages does not clear it.

The initial activity snapshot is paged. Loading earlier messages prepends a
page while preserving the reading position. History is limited to activity
retained by Remote; it does not reconstruct messages from before Remote began
recording, and discarded history cannot be loaded.

Image uploads retain failed previews for retry or removal; the viewer can browse
multiple images. Attachments still use the server's existing returned-text
protocol. Removing an in-flight preview ignores its response; it cannot cancel
the server upload or delete an already uploaded server file.

Pending agent questions appear as forms supporting single or multiple choices,
free text, booleans and numbers, including an Other response. Submit or decline
the whole form; input stays intact across live updates. Unsupported question
types direct you to Emacs. Permission requests retain every offered option,
including options with the same permission kind.

## Feedback and state

Connection problems appear in a compact banner while loaded content remains
available. Missing conversations, expired credentials and incompatible protocol
versions offer distinct explanations. Loading and empty conversations have
explicit states. Resource command errors appear beside their controls.

Action sheets offer simple commands, sheets hold forms, and confirmation
buttons name the action. Unfinished form input is retained until successful
submission. Drafts, disclosure state and reading positions are memory-only;
reloading or closing the page clears them.

Navigation continues to use the existing query-string routes and browser
history. Framework7 Router is not enabled: the launch hash carries the
credential, and changing the route/lifecycle model requires a separate migration
of deep links, stream cancellation and draft ownership. No custom edge swipe is
added on top of Safari's native history gesture.

The UI does not infer provider freshness from display strings. Message times,
unread counts and history pages use explicit backend fields.
Real iPhone keyboard and gesture behavior still require device testing;
Chromium mobile emulation only verifies viewport and browser interactions.
