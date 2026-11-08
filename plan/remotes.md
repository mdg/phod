# Remote Sessions

Let one session act on another. Once sessions are connected, the local session
can:

1. run tools in the remote session's worktrees, and
2. prompt the remote session to make a change, which its own agent carries out.

Each session keeps its own worktrees, sandbox, and transcript. A connection
only lets one session reach another; it doesn't merge them.

## Terms

- **local** — the session whose agent is making the call.
- **remote** — a session the local session is connected to. Connections are
  per session id (`"<user>/<tree>"`).
- **origin chain** — the sessions that led to a prompt. If A prompts B and B
  prompts C, C's run has origin `[A, B]`. Used to stop loops (see below).

## Step 1: connect sessions (Elixir call)

Add to `Phod.Session`:

```elixir
Phod.Session.connect(local_id, remote_id)     # :ok | {:error, reason}
Phod.Session.disconnect(local_id, remote_id)  # :ok | {:error, :not_connected}
Phod.Session.remotes(local_id)                # [remote_id]
```

- `connect/2` checks that both sessions are running (`whereis/1`), that they
  are different, and that the connection doesn't already exist. The remote is
  stored in the local session's state, next to `worktrees`.
- Connections are one way: A connecting to B lets A's agent use B. B gets no
  rights over A.
- The snapshot includes `remotes`, so the UI can show them.
- Connections are in memory. A connection ends when either session stops.

Tests: connect, duplicate, self, missing remote, disconnect, and the snapshot.

## Step 2: prompt tool

A tool the local agent can call to give a connected session a prompt:

- **Name:** `prompt_session`
- **Parameters:**
  - `remote` (required): one of the connected session ids. The enum is built
    per session, the same way the `worktree` enum is.
  - `prompt` (required, non-empty string): what the remote session should do.
  - `goal` (required, from the common goal parameter).
- **Behaviour:** calls `Session.send_message(remote, prompt, sender)`, where
  `sender` is the local session id. The prompt is shown in the remote's
  transcript from that sender, so anyone watching it can tell where it came
  from. If the remote is busy, the prompt queues, as any message does.
- **Result:** `{:ok, %{remote: id, status: :started | :queued}}`. The tool
  doesn't wait for the remote's reply. The reply appears in the remote's
  transcript, not in the local one.

### Loop guard

A prompt is refused when its target is already in the origin chain, or is the
session itself. The chain travels with the prompt: `send_message/3` takes an
`origin:` option, the remote's run carries it, and `prompt_session` passes it
on. A maximum chain length (start with 3) stops long chains.

Without this, A and B could prompt each other forever, or wait on each other
while both are running.

### Notes

- The prompt tool doesn't need a connection to run without one. With no
  remotes, the `remote` enum is absent and the tool isn't offered.
- The remote session's agent treats the prompt as a user message. Its own
  sandbox, tools, and round limit still apply. The local agent gets no more
  power over the remote's worktree than a user typing the same prompt.

Tests: a prompt starts or queues the remote run, the sender is shown in the
remote transcript, refusal on loops, refusal on unknown or unconnected
remotes, and the chain limit.

## Step 3: remote tool runs

Let a connected session's tools run against the remote's worktrees.

- Add an optional `remote` parameter to the existing tools, enumerating the
  connected session ids, the same way `worktree` works. Absent means the
  local session.
- `Tool.run/3` gets the remote's `[{name, root}]` (from a new
  `Session.worktrees/1`), then runs as it does now. `worktree` still chooses
  within the remote's worktrees.
- `allow_writes` still controls whether a remote command can write. The
  remote's sandbox is unchanged.
- Results and edits are attributed to the remote. The edit event gets a
  `remote` field, and the transcript shows which session a call ran in.

Open point: a write tool that runs in a remote while that remote is busy
could race with the remote's own agent. See the questions below.

## Questions to settle before building

1. **One way or mutual?** The plan above is one way: A → B. Mutual is two
   `connect` calls.
2. **Wait for the reply, or fire and forget?** The plan is fire and forget.
   Waiting would need a timeout, and it's the case most likely to deadlock
   if loops aren't guarded.
3. **Remote writes while the remote is busy:** refuse, queue, or allow?
   Refusing is safest. Queueing would mean a second queue, for tool calls.
4. **Limit on chain length:** is 3 right?
5. **Persist connections** across restarts, or in memory only? The plan says
   in memory, like worktrees.
6. **Who can connect?** Any logged-in user with a display name, or only the
   owner of the local session? The plan doesn't check, because sessions have
   no owners yet.

## Build order

1. Step 1 — `connect/2`, `disconnect/2`, `remotes/1`, snapshot, tests.
2. Step 2 — `send_message/3` with `origin:`, the `prompt_session` tool, the
   loop guard, UI for the sender, tests.
3. Step 3 — `Session.worktrees/1`, the `remote` parameter, remote routing in
   the loop, attribution in events and the transcript, tests.

Each step can be used on its own. Step 2 is what makes the sessions useful
together; step 3 is optional if prompts are enough.
