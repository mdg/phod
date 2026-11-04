# MVP Plan: Web-based Coding Agent

A multiplayer coding agent built with Phoenix LiveView. Users connect to a shared
session and the agent can read and edit code in the current **session worktree**.

### Directory layout

- `~/phod/repo/` — bare/cloned GitHub repositories. **Read-only for the agent:
  no tool may ever touch this directory.**
- `~/phod/tree/<owner>/<name>/` — git worktrees (e.g. `~/phod/tree/mdg/lucky/`)
  created from a repo. **All agent work happens in the worktree.**

Git checkout/worktree management is handled manually for now; worktrees are
pre-created by the user. A session is created by pointing it at an existing
worktree path; the plan focuses on **code editing**.

The agent is strictly sandboxed to the session's worktree. All tool paths are
resolved and validated against the worktree root before execution; any attempt
to escape the root (via `..`, symlinks, or absolute paths) is rejected. The
repo directory is outside the sandbox and never read or written by tools.

## 1. Agent Tools

The LLM gets the following tools (`snake_case` names). Every tool receives paths
relative to the session worktree root, and works only inside it.

### `list_files`

Lists files and directories at a given path.

- **Description (for the LLM):** "List the contents of a directory in the
  project. Returns names with a `/` suffix for directories. Use this to explore
  the project structure. Path is relative to the project root; defaults to the
  root. Does not recurse — call it again on subdirectories."
- Input: `{ path?: string }`
- Output: list of entries (`name`, `type: "file" | "dir"`), or an error if the
  path does not exist or is not a directory.

### `read_file`

Reads the contents of a single file.

- **Description (for the LLM):** "Read the full contents of one file in the
  worktree. Use `list_files` first to discover paths. Paths are relative to the
  worktree root. Reading a non-existent or directory path returns an error."
- Input: `{ path: string }`
- Output: the file's text (with line numbers, so the LLM can reference
  locations in diffs), or an error. Large files are truncated with a notice.

### `grep`

Searches project contents.

- **Description (for the LLM):** "Search file contents across the worktree with
  one or more regular expressions (implementation uses `ripgrep` internally).
  Provide a list of one or more patterns - matches are the union of all given
  patterns. Returns matching file paths, line numbers, and line contents. Use
  this to find where code lives before editing it. Paths in results are
  relative to the worktree root."
- Input: `{ patterns: [string], path?: string }`
- Output: list of matches (`path`, `line_number`, `line`), capped at N results,
  or an error if a pattern is invalid.

### `apply_diff`

The primary editing tool: applies a unified diff to a file.

- **Description (for the LLM):** "Apply a unified diff to a file in the
  worktree. Provide the diff in standard unified format with one or more
  `@@ -l,c +l,c @@` hunks. Context lines and line numbers are matched exactly
  against the current file contents; the whole apply is atomic — if any hunk
  fails to apply, nothing is written. To create a new file, use a diff against
  `/dev/null`. To verify your edit took effect as expected, follow up with
  `read_file`."
- Input: `{ path: string, diff: string }`
- Output: success message (e.g. "applied 2 hunks"), or a precise failure
  description ("hunk #3: context mismatch at line 42") so the LLM can re-read
  the file and retry.

## 2. Agent & Sessions

- **One session per worktree.** A session is created by pointing it at a
  worktree path (e.g. `~/phod/tree/mdg/lucky/`); it owns all agent runs and
  state for that worktree.
- **One GenServer per session.** A `Phod.Agent.Session` GenServer:
  - holds the transcript (messages, tool calls/results, streamed output),
  - runs the tool-calling loop, executing tools against its worktree,
  - is a named/registered process (via a `Registry` keyed by session id) so
    multiple LiveView clients for the same session talk to the same process,
  - broadcasts state changes over PubSub (`sessions:<id>`) for the UI.
  - Started on demand under a `DynamicSupervisor` and shut down when idle.
- LLM is driven by the GenServer via `Req` HTTP calls.
- Tool-calling loop: the model proposes tool calls, the GenServer executes them
  (sandboxed), and results are fed back into the conversation until the model
  produces a final answer.
- The system prompt instructs the model on the four tools above and the rule
  that all files are relative to the worktree root.
- All `apply_diff` edits are recorded per-file so the UI can highlight what the
  agent changed.
- Concurrency: one agent run per session at a time; queued or rejected when the
  user starts a second run.

## 3. Multiplayer

A shared "session" is the unit of access: multiple web users attach to the same
LiveView process and see the same state.

- **Architecture:** Phoenix PubSub as the shared backbone. The session
  GenServer (above) broadcasts its state; LiveViews subscribe to the session
  topic and render the same state, so no extra sync protocol is needed.
  `Phoenix.Presence` tracks connected users in a session (who is online).
- **Shared state:** transcript of agent run (messages, tool calls/results,
  streamed assistant output), current file listing, and editor pane contents.

#### Decision: Phoenix Presence vs PubSub (and alternatives)

Presence and PubSub are not competing options — Presence is built *on top of*
PubSub. It uses the same session topic but adds metadata (who the user is,
their custom payload), conflict-free distributed tracking, automatic presence
repair after network splits, and both `handle_info` callbacks *and* JS client
events (`phx-quick-look`-style presence diffs) with per-join/leave diff
lifecycles. Raw PubSub only delivers transient broadcast messages ("this event
happened now"); it has no persistent map of who is currently here, and if a
client connects late it misses everything that happened before.

**What Presence enables for the MVP session:**

- Live roster: avatars/names of everyone attached to the session, with join and
  leave differences arriving as diffs, so the UI doesn't need to handle "fetch
  full list then watch" logic.
- Per-user metadata: we can store things like `{user: "mdg", viewing_file:
  "lib/foo.ex", typing: true}` in the presence payload, enabling later
  multiplayer niceties (soft cursors, "X is viewing this file", typing
  indicators) without any extra transport.
- Crash-safe liveness: Presence automatically detects disconnected processes
  and reports them gone — this is what normally requires WebSocket heartbeats
  and timeouts if done manually.

**What Presence does NOT do (and PubSub continues to do):**

- State synchronization. The transcript, file listing, and tool results are
  server-owned state owned by the session GenServer and broadcast via PubSub.
  Presence would be the wrong tool for that — payloads are small metadata, not
  a transcript.

**Alternatives considered:**

1. **Raw PubSub only, inventory via GenServer state:** the session GenServer
   tracks connected LiveView pids itself (via `handle_info(:connected)` /
   monitor messages on Phoenix's `:DOWN`). Simpler stack but reimplements
   liveness by hand, requires manual cleanup on client disconnect/crash, and
   won't survive multi-node PubSub setups as cleanly.
2. **Client-only liveness (heartbeats / LiveSocket verify):** each client
   broadcasts "I'm here" every N seconds on the PubSub topic and the UI builds
   its roster from observed heartbeats with a timeout. Bundleable with no
   server state, but drift between clients, extra traffic, and no diffusion of
   server-side truth.
3. **External presence service** (e.g. a dedicated presencing library or a
   hosted service like Ably): unnecessary here — Phoenix Presence ships with
   Phoenix and is designed exactly for this.
4. **"No multiplayer roster":** track no users at all; everyone just renders
   the same GenServer state. Cheapest MVP, but loses typing indicators, user
   list and any real-time collaboration affordances users expect from a
   multiplayer coding tool.

**Decision:** use `Phoenix.Presence` on top of the existing session PubSub
topic. It's the idiomatic Phoenix primitive for exactly this need, comes with
the app already, requires no extra deps, and gives us user metadata for free.
PubSub remains responsible for the shared *state* (transcript, files);
Presence is responsible for *who* is in the session.
- **Simultaneity rules (MVP):**
  - Users take turns présence-aware: while the agent is running, everyone sees
    streaming output; typing is disabled.
  - Manual edits by web users on the editor pane are out of scope for the MVP;
    users interact via chat. The edit surface is agent-only for now.

#### Decision: connection loss while typing (offline submits)

- **What Phoenix gives us (LiveView ≥ 0.20, shipped with Phoenix 1.8):** when
  the client loses the WebSocket connection, the LiveView keeps running
  client-side, shows the reconnecting banner, and **buffers all DOM data and
  user events (`phx-change`, `phx-click`, `phx-submit`)** on the client. On
  reconnection the buffered events are replayed to the server in order — a
  form submitted while offline reaches the LiveView without any auth-required
  hookup. So a user typing a prompt who taps submit mid-disconnect does *not*
  lose the message by default.
- **Caveats we must design around:**
  1. **Stale-state risk:** the agent may have streamed output (or another user
     submitted) between disconnect and the buffered event replaying. The chat
     UI must make "your message was sent" explicit after reconnect so the user
     doesn't retype it.
  2. **Tab closes lose everything:** the client buffer is in memory only. For
     a safety net, a colocated JS hook should persist the chat draft to
     `localStorage` on `input`, and clear it once the submit is acknowledged
     by the server.
  3. **Dead-end reconnects:** after the client's reconnect window gives up, the
     user must see a clear "connection lost — your draft is saved" state
     rather than a silently dead input.
- **Decision:** rely on LiveView's built-in event buffering for the reconnect
  path; add the `localStorage` draft hook only if/when users actually hit the
  close-tab case. No server-side queue of "pending user prompts" is needed —
  the replayed submit is simply handled by the normal `handle_event("submit")`,
  which already respects the one-run-at-a-time rule.

## 4. UI (LiveView)

Three-pane layout:

1. **Chat pane** — transcript, user input box, streaming agent output, collapsible
   tool call blocks (`list_files`, `read_file`, `grep`, `apply_diff`) with results.
2. **File explorer** — live-updating tree of the worktree root (uses the same
   backend as the `list_files` tool).
3. **Editor pane** — view (and later edit) a selected file with line numbers;
   clicking a file path in a tool result opens it here. Highlights files touched
   by the agent's most recent run.

Header: session name, presence indicators (avatars of connected users), and a
"Run agent" / "Stop" control (only one active run).

## 5. Milestones

1. ✅ **M1 — Tools + sandbox:** implement `list_files`, `read_file`, `grep`,
   `apply_diff` as a `Phod.Tool.B` behaviour with shared worktree helpers in
   `Phod.Tool.Lib` (registry in `Phod.Tool`); done and tested.
2. ✅ **M2 — Agent loop + session GenServer:** `Phod.Session` GenServer with
   Registry naming, LLM provider via `Req` (Anthropic Messages API format,
   hosted by OpenCode Zen), tool-calling loop in `Phod.Session.Loop`, PubSub
   broadcasts, system prompt in `Phod.Session.Llm`. Manual iex harness
   documented in `Phod.Session`'s moduledoc; done and tested.
3. ✅ **M3 — Multiplayer session UI:** LiveView three-pane interface
   (`PhodWeb.SessionLive.Show`, chat/file-tree/editor), session entry form
   (`PhodWeb.SessionEntryLive`), join flow over a real Plug request
   (`PhodWeb.SessionJoinController`) for the per-browser display name,
   `PhodWeb.Presence` roster sharing the session's PubSub topic, transcript
   driven incrementally by `Phod.Session`'s existing broadcasts; done and
   tested.
4. **M4 — Polish:** error surfacing, edit highlighting, loading/stop controls,
   basic e2e tests (agent makes an edit visible in the editor pane).

## 6. Non-goals (for now)

- Git checkout / repo clone / worktree management (user does this manually).
- Reading from or writing to `~/phod/repo/` (repos are read-only and untouched).
- User-initiated editing of files in the UI.
- File deletion or renaming tools.
- One session owning multiple worktrees (strictly one session per tree).
- LLM-level auth/billing management.
