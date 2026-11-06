# add a session log

add a log of messages to track what's being sent and received

## Location

The log is written next to the session's worktree directory: the worktree root
with `.md` appended. With `worktree_base` set to `/home/mdg/phod/tree` (in
`config/config.exs`) and session `mdg/lucky`, the worktree root is
`/home/mdg/phod/tree/mdg/lucky` and the log is:

    /home/mdg/phod/tree/mdg/lucky.md

The log is outside the worktree, so it never shows up in the project's git
status.

## What gets logged

- The system prompt, once, at the top of the log when the session starts.
- Every user message, with the sender's display name (the name from the join
  form; "Anonymous" when none was given).
- Every assistant text block, attributed to "phod".
- Every tool call (name and input) and its result, attributed to "phod".
- Tool schemas are not logged.
- Very long text (message bodies, tool results) is truncated, with a note saying
  how much was cut.

## Write Sequence

- A session starts when the server starts. Each start resets the log to empty
  and writes the system prompt at the top.
- Entries are appended as they happen, not written in a batch at the end.
- Log writes are best-effort: a failed write is reported (logged) but never
  stops or delays the session.

## Format

- Markdown.
- Each entry starts with a `###` header containing the sender ("phod" or the
  user's display name) and a timestamp in America/New_York, including the
  timezone abbreviation (for example `### mdg — 2026-11-06 09:15:02 EST`).
- The body follows the header. Message text, tool inputs and results are
  wrapped in fenced code blocks, so any `###` or ``` inside them cannot break
  the document structure. The fence is made longer than any backtick run in the
  content.

## Dependencies

- Converting to America/New_York needs a timezone database. The project has
  none yet, so this plan adds `tzdata` and configures it as the `Calendar`
  time zone database.
