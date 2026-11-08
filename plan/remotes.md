# Remote Sessions

Let one session send work to another. Sessions stay separate: each keeps its own
worktrees, sandbox, transcript, and queue. A connection only lets two sessions
exchange messages, and a session can run tools in a connected session's
worktrees.

## Terms

Two kinds of relationship, defined so they read the same from either side.

- **Connection** — a link between two sessions, made with the Elixir API. Its
  two ends are **peers**: from either session's point of view, the other one is
  its peer.
- **Message** — one communication from a **sender** session to a **receiver**
  session. A message has a **kind** (`send` or `reply`) and a flag
  `want_reply` for `send`.
- **Run** — one agent run: from a message arriving at an idle session until the
  model finishes, errors, or hits the round limit. The session is
  `status: :running` for the whole run, as it is now.
- **Run mode** — what a run is handling, set when the run starts:
  - `:user` — a prompt from the session's user. The run has all its tools.
  - `:peer` — a message from another session. The run can use its own worktree
    tools and `reply`, but not `send` or any tool that acts on another session
    (see below).

Words like "local" and "remote" are avoided. A session that sends a message is
the sender of that message, whatever session it is.

## Step 1: connect sessions (Elixir API only)

```elixir
Phod.Session.connect(a_id, b_id)                 # mutual (default): a <-> b
Phod.Session.connect(a_id, b_id, mode: :one_way) # a may message b; b may not message a
Phod.Session.disconnect(a_id, b_id)              # ends both directions
Phod.Session.peers(a_id)                         # [b_id]
```

- Mutual is the default. A mutual connection is two one-way links, and
  `disconnect/2` removes both.
- Only callable from iex for now. No LLM tool and no UI can create a connection.
- `connect/3` checks that both sessions are running, that they're different, and
  that the link doesn't exist yet.
- Connections live in memory. Keep the storage behind a small module
  (`Phod.Session.Connections`) so it can move to a database later without
  touching callers.
- The snapshot includes `peers`, so the UI can show them.

Tests: mutual and one-way links, duplicates, self, a missing session, disconnect
removing both directions, and the snapshot.

## Step 2: messaging between sessions

Two tools, offered only when the session has at least one peer that allows the
direction (a one-way peer can receive from the session but not be messaged by
it, so the tools are offered accordingly).

### `send`

Sends a prompt to a peer, the start of an exchange.

- **Parameters:**
  - `peer` (required): one of this session's peers, as an enum.
  - `prompt` (required, non-empty string): what the receiver should do.
  - `want_reply` (boolean, default `false`): whether the receiver should send a
    final reply when done.
  - `goal` (required, from the common goal parameter).
- **Behaviour:** the receiver gets the prompt as a message from the sender. If
  the receiver is busy, the message queues.
- **Result:** `{:ok, %{peer: id, status: :started | :queued}}`. A queued result
  tells the model its prompt is waiting behind the receiver's current run.

### `reply`

Sends the receiver's answer back to the sender of the message it's handling.

- **Parameters:**
  - `text` (required, non-empty string): the receiver's final response to the
    sender.
  - `goal` (required, from the common goal parameter).
- **Behaviour:** delivered to the session that sent the message being handled.
  The sender sees it as a message from the receiver, and its transcript shows
  the kind.
- **Result:** `{:ok, %{to: id, status: :started | :queued}}`.

### Peer mode

A run in `:peer` mode can't use `send` or any tool that acts on another session.
It can use its own worktree tools, and `reply`, and nothing else across
sessions. This takes the place of a chain: a message can't lead to a third
session, because the session that receives it has no way to contact one.

- The mode is set when the run starts, from the message that started it, and
  lasts for that run only.
- A `:peer` run's `reply` goes only to the session that sent the message.
- A session that sent a `send` is not in peer mode, since its own run started
  from its user. A session that received a `send` runs in peer mode, so its
  answer is a `reply`.

### Message shape

Each message carries its sender, kind, and `want_reply`. The receiver's
transcript shows the sender's session id, the kind, and the text. A `send` with
`want_reply: true` ends with a `reply` from the receiver. Nothing enforces
that beyond the prompt, so the receiver's round limit and goal rules still apply.

Tests: `send` starts or queues the receiver's run and the queued result is
returned; the sender appears in the receiver's transcript; a `:peer` run is not
offered `send`; a `:peer` run's `reply` goes to the sender only; a one-way peer
can't be messaged in the wrong direction; `send` and `reply` are shown differently.

## Step 3 (optional): run tools in a peer's worktrees

Lets a session's tools act on a peer's worktrees.

- An optional `peer` parameter on the existing tools, enumerating the session's
  peers, the same way `worktree` works. Absent means this session's own
  worktrees.
- `Tool.run/3` gets the peer's `[{name, root}]` from a new
  `Session.worktrees/1`, then runs as it does now. `worktree` still chooses
  within the peer's worktrees.
- Only read-only tools are offered for a peer. Writes go through `send`.
- `:peer` runs get no `peer` parameter.
- Results and edits are attributed to the peer: the edit event carries `peer`,
  and the transcript shows which session the call ran in.

Only read-only tools run in a peer's worktrees (see the decisions below).

## Decisions

1. **Peer mode has the worktree tools.** A `:peer` run can use its own worktree
   tools, read and write, like a `:user` run. Peer mode only removes the
   cross-session tools (`send`, and anything acting on another session).
2. **One reply per send.** A `send` gets zero or one replies. A `:peer` run
   ends when it calls `reply`, and its session returns to idle. A `send` with
   `want_reply: true` makes the sender's run wait for that reply before the run
   finishes. The wait has a timeout, so a reply that never comes doesn't keep the
   session running forever. Because a `:peer` run can't `send`, a wait can't form
   a cycle.
3. **No writes into a peer.** Step 3 runs read-only tools only in a peer's
   worktrees. Changes to a peer's files are made by sending it a message, so the
   peer's own run makes them, in its own sandbox.
4. **Persistence.** The storage module is the seam. The database shape waits
   until it's needed.

## Build order

1. Step 1 — `connect/3`, `disconnect/2`, `peers/1`, snapshot, tests (iex only).
2. Step 2 — message kinds and `want_reply` on messages, run modes for
   runs started by messages, the `send` and `reply` tools, queue reporting,
   UI for the sender and kind, tests.
3. Step 3 — `Session.worktrees/1`, the `peer` parameter, routing in the loop,
   attribution in events and the transcript, tests.

Step 2 is what makes sessions useful together. Step 3 can wait if messages are
enough.
