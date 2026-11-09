defmodule Phod.Session do
  @moduledoc """
  One GenServer per worktree, holding the conversation with the LLM and
  driving the tool-calling loop against the sandboxed worktree.

  Multiple LiveView clients for the same session id reach the same
  process via `Phod.Session.Registry`; state changes are broadcast over
  `Phoenix.PubSub` on topic `"sessions:<id>"` as `{:session_snapshot,
  snapshot}`, where `snapshot` is exactly `get_snapshot/1`'s return value.

  Only one agent run is allowed per session at a time: a `send_message/2`
  call while a run is already in flight is rejected with `{:error, :busy}`
  rather than queued. The run itself executes in a supervised `Task` (not
  the GenServer's own process), so the GenServer stays responsive to
  `get_snapshot/1` for the whole run and can reliably reject concurrent
  attempts instead of just making them wait.

  ## Manual verification (no UI yet)

  With `OPENCODE_API_KEY` exported in the shell before `iex -S mix`:

      iex> {:ok, _pid} = Phod.Session.ensure_started("octocat", "manual-1")
      iex> Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:octocat/manual-1")
      iex> Phod.Session.send_message("octocat/manual-1", "List the files in the project root")
      iex> flush()   # watch {:session_snapshot, _} arrive as the real Zen API responds
      iex> Phod.Session.get_snapshot("octocat/manual-1")
  """

  use GenServer

  require Logger

  import Rexult, only: [rexult: 1, ok_and_then: 2, ok?: 1]

  alias Phod.Session.{Connections, Llm, Log, Loop, Network}

  defstruct [
    :id,
    :worktree_root,
    :idle_timeout,
    :log_path,
    # what this session is for, from DESCRIPTION.md; shown to its peers
    :description,
    # the network connections the session's tools may use (see Phod.Session.Network)
    network: Network.empty(),
    messages: [],
    # display name of each user-sent message, keyed by its index in `messages`
    senders: %{},
    # messages sent while a run was in progress, as `{text, sender}`, in order
    queue: [],
    status: :idle,
    edits: [],
    last_error: nil,
    task_ref: nil,
    # the task running the current run, and the peers whose reply it awaits
    task_pid: nil,
    awaiting: MapSet.new(),
  ]

  @idle_timeout :timer.minutes(30)

  # A session describes itself to its peers from this file in its worktree.
  @description_file "DESCRIPTION.md"
  @max_description_chars 500

  # Public API

  @doc """
  The session id for a GitHub user and worktree name: `"<user>/<tree>"`.
  """
  @spec session_id(String.t(), String.t()) :: String.t()
  def session_id(user, tree), do: "#{user}/#{tree}"

  @doc """
  The worktree path for a GitHub user and worktree name:
  `<worktree_base>/<user>/<tree>`. `worktree_base` always comes from config.
  """
  @spec worktree_root(String.t(), String.t()) :: String.t()
  def worktree_root(user, tree) do
    Path.join([Application.fetch_env!(:phod, :worktree_base), user, tree])
  end

  @doc """
  Starts a session for a GitHub user and worktree name, if one isn't already
  running, otherwise returns the existing process. Idempotent.

  The session id is `session_id/2` and the worktree is `worktree_root/2`. The
  worktree must be an existing directory in the `<worktree_base>/<user>/<tree>`
  layout; anything else returns `{:error, {:invalid_worktree_root, root}}`
  without starting a process.
  """
  @spec ensure_started(String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(user, tree, opts \\ []) do
    id = session_id(user, tree)
    root = Path.expand(worktree_root(user, tree))

    if valid_worktree_root?(root) do
      case Phod.Session.Supervisor.start_session(id, root, opts) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:invalid_worktree_root, root}}
    end
  end

  # GitHub usernames: alphanumerics and hyphens, at most 39 characters, not
  # starting with a hyphen. Worktree names: no leading dot, so hidden
  # directories and `..` never qualify.
  @github_user ~r/\A[A-Za-z0-9][A-Za-z0-9-]{0,38}\z/
  @worktree_name ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

  @doc """
  Pure check that `session_name` is `"<github_user>/<worktree_name>"`: exactly
  two segments, each matching its naming rule. Touches no filesystem.
  """
  @spec valid_session_name?(term()) :: boolean()
  def valid_session_name?(session_name) when is_binary(session_name) do
    case String.split(session_name, "/") do
      [user, name] ->
        Regex.match?(@github_user, user) and Regex.match?(@worktree_name, name)

      _ ->
        false
    end
  end

  def valid_session_name?(_session_name), do: false

  @doc """
  True when `root` is `<worktree_base>/<github_user>/<worktree_name>` and is an
  existing directory. Expects an absolute, expanded path.
  """
  @spec valid_worktree_root?(String.t()) :: boolean()
  def valid_worktree_root?(root) do
    base = Path.expand(Application.fetch_env!(:phod, :worktree_base))

    root
    |> Path.relative_to(base)
    |> Path.safe_relative(base)
    |> rexult()
    |> ok_and_then(fn rel ->
      if valid_session_name?(rel), do: {:ok, rel}, else: {:error, :invalid_name}
    end)
    |> ok_and_then(fn _rel ->
      if File.dir?(root), do: {:ok, root}, else: {:error, :not_a_directory}
    end)
    |> ok?()
  end

  @spec whereis(String.t()) :: {:ok, pid()} | :error
  def whereis(id) do
    case Registry.lookup(Phod.Session.Registry, id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Connects two running sessions, from the iex console. `mode: :mutual` (the
  default) lets each send messages to the other; `mode: :one_way` lets `a`
  send to `b` only. Both sessions' snapshots are updated to show the peers.
  """
  @spec connect(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def connect(a, b, opts \\ []) do
    mode = Keyword.get(opts, :mode, :mutual)

    cond do
      a == b -> {:error, :self}
      mode not in [:mutual, :one_way] -> {:error, {:invalid_mode, mode}}
      whereis(a) == :error -> {:error, {:not_found, a}}
      whereis(b) == :error -> {:error, {:not_found, b}}
      Connections.link?(a, b) -> {:error, :already_connected}
      true ->
        Connections.add_link(a, b)
        if mode == :mutual, do: Connections.add_link(b, a)
        notify(a)
        notify(b)
        :ok
    end
  end

  @doc """
  Removes the connection between two sessions, in both directions.
  """
  @spec disconnect(String.t(), String.t()) :: :ok | {:error, :not_connected}
  def disconnect(a, b) do
    if Connections.link?(a, b) or Connections.link?(b, a) do
      Connections.remove_link(a, b)
      Connections.remove_link(b, a)
      notify(a)
      notify(b)
      :ok
    else
      {:error, :not_connected}
    end
  end

  @doc """
  The sessions `id` may send messages to.
  """
  @spec peers(String.t()) :: [String.t()]
  def peers(id), do: Connections.peers(id)

  @doc """
  Delivers a prompt from peer `from` to session `to`. Returns `{:ok, :started}`
  if it starts a run, `{:ok, :queued}` if `to` is busy, or an error.
  """
  @spec deliver(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, :started | :queued} | {:error, term()}
  def deliver(to, from, prompt, want_reply) do
    case whereis(to) do
      {:ok, pid} -> GenServer.call(pid, {:peer_send, from, prompt, want_reply})
      :error -> {:error, {:not_found, to}}
    end
  end

  @doc """
  Delivers a reply from `from` to session `to`: into the run waiting for it, or
  as a new run if none is waiting.
  """
  @spec deliver_reply(String.t(), String.t(), String.t()) ::
          {:ok, :started | :queued} | {:error, term()}
  def deliver_reply(to, from, text) do
    case whereis(to) do
      {:ok, pid} -> GenServer.call(pid, {:peer_reply, from, text})
      :error -> {:error, {:not_found, to}}
    end
  end

  @doc """
  A session's description (from its `DESCRIPTION.md`), or `nil` if it has none.
  """
  @spec describe(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def describe(id) do
    case whereis(id) do
      {:ok, pid} -> GenServer.call(pid, :describe)
      :error -> {:error, {:not_found, id}}
    end
  end

  @doc """
  The session's worktrees as `[{name, root}]`. A session has one worktree, so
  this is always a single entry.
  """
  @spec worktrees(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def worktrees(id) do
    case whereis(id) do
      {:ok, pid} -> GenServer.call(pid, :worktrees)
      :error -> {:error, {:not_found, id}}
    end
  end

  @doc """
  Appends `text` as a user message from `sender` (the user's display name,
  used in the session log) and kicks off the agent loop. Returns immediately
  without waiting for the loop to finish.
  """
  @spec send_message(String.t(), String.t(), String.t()) ::
          :ok | {:error, :busy} | {:error, :not_found}
  def send_message(id, text, sender \\ "Anonymous") do
    with {:ok, pid} <- whereis(id) do
      GenServer.call(pid, {:send_message, text, sender})
    else
      :error -> {:error, :not_found}
    end
  end

  @spec get_snapshot(String.t()) :: map() | {:error, :not_found}
  def get_snapshot(id) do
    with {:ok, pid} <- whereis(id) do
      GenServer.call(pid, :get_snapshot)
    else
      :error -> {:error, :not_found}
    end
  end

  # Asks a session to re-broadcast its snapshot (e.g. after its peers change).
  defp notify(id) do
    with {:ok, pid} <- whereis(id), do: GenServer.cast(pid, :broadcast)
  end

  @doc false
  def start_link({id, worktree_root, opts}) do
    GenServer.start_link(__MODULE__, {id, worktree_root, opts}, name: via(id))
  end

  defp via(id), do: {:via, Registry, {Phod.Session.Registry, id}}

  # Callbacks

  @impl true
  def init({id, worktree_root, opts}) do
    with_network(Keyword.get(opts, :network), fn network ->
      if File.dir?(worktree_root) do
        idle_timeout = Keyword.get(opts, :idle_timeout, @idle_timeout)

        state = %__MODULE__{
          id: id,
          worktree_root: worktree_root,
          description: read_description(worktree_root),
          network: network,
          idle_timeout: idle_timeout,
          log_path: Log.path(worktree_root),
        }

        reset_log(state)

        {:ok, state, idle_timeout}
      else
        {:stop, {:invalid_worktree_root, worktree_root}}
      end
    end)
  end

  defp with_network(config, start) do
    case Network.normalize(config) do
      {:ok, network} -> start.(network)
      {:error, reason} -> {:stop, {:invalid_network, reason}}
    end
  end

  @impl true
  def handle_call(
        {:send_message, text, sender},
        _from,
        %__MODULE__{status: :running} = state
      ) do
    state = %{state | queue: state.queue ++ [user_item(text, sender)]}
    broadcast(state)
    {:reply, {:ok, :queued}, state, state.idle_timeout}
  end

  def handle_call({:send_message, text, sender}, _from, %__MODULE__{status: :idle} = state) do
    {:reply, :ok, start_run(state, user_item(text, sender)), state.idle_timeout}
  end

  # A message from a peer session starts a `:peer` run, or queues behind one.
  # The receiver checks the link too: a one-way connection only runs in one
  # direction, whatever the sender does.
  def handle_call({:peer_send, from, prompt, want_reply}, _from, state) do
    if Connections.link?(from, state.id) do
      item = %{
        text: peer_message_text(from, prompt, want_reply),
        sender: "peer #{from}",
        mode: :peer,
        from: from
      }

      accept(state, item)
    else
      {:reply, {:error, :not_connected}, state, state.idle_timeout}
    end
  end

  # A reply from a peer goes to the run that is waiting for it. Otherwise it
  # starts a run of its own, in `:user` mode: it's the sender's exchange, not a
  # request from a peer.
  def handle_call({:peer_reply, from, text}, _from, state) do
    if state.task_pid && MapSet.member?(state.awaiting, from) do
      send(state.task_pid, {:peer_reply, from, text})
      state = %{state | awaiting: MapSet.delete(state.awaiting, from)}
      {:reply, {:ok, :started}, state, state.idle_timeout}
    else
      accept(state, %{
        text: "Reply from #{from}:\n\n#{text}",
        sender: "reply from #{from}",
        mode: :user,
        from: nil
      })
    end
  end

  # Called by a running task just before it sends a prompt that wants a reply,
  # so the reply is recognised even if it arrives first.
  def handle_call({:expect_reply, peer}, _from, state) do
    {:reply, :ok, %{state | awaiting: MapSet.put(state.awaiting, peer)}, state.idle_timeout}
  end

  def handle_call({:unexpect_reply, peer}, _from, state) do
    {:reply, :ok, %{state | awaiting: MapSet.delete(state.awaiting, peer)}, state.idle_timeout}
  end

  def handle_call(:describe, _from, state) do
    {:reply, {:ok, state.description}, state, state.idle_timeout}
  end

  def handle_call(:worktrees, _from, state) do
    {:reply, {:ok, [{state.id, state.worktree_root}]}, state, state.idle_timeout}
  end

  def handle_call(:get_snapshot, _from, state) do
    {:reply, snapshot(state), state, state.idle_timeout}
  end

  @impl true
  def handle_cast(:broadcast, state) do
    broadcast(state)
    {:noreply, state, state.idle_timeout}
  end

  @impl true
  def handle_info({:loop_event, {:message_appended, msg}}, state) do
    log(state, Log.message_entries(msg, "user"))
    state = %{state | messages: state.messages ++ [msg]}
    broadcast(state)
    {:noreply, state, state.idle_timeout}
  end

  # A message the loop added on its own: a peer's reply, or a notice.
  def handle_info({:loop_event, {:peer_input, label, msg}}, state) do
    index = length(state.messages)
    log(state, Log.message_entries(msg, label))

    state = %{
      state
      | messages: state.messages ++ [msg],
        senders: Map.put(state.senders, index, label)
    }

    broadcast(state)
    {:noreply, state, state.idle_timeout}
  end

  def handle_info({:loop_event, {:edit_recorded, edit}}, state) do
    state = %{state | edits: state.edits ++ [edit]}
    broadcast(state)
    {:noreply, state, state.idle_timeout}
  end

  def handle_info({ref, result}, %__MODULE__{task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, _messages} ->
          finish_run(state)

        {:error, {reason, _messages}} ->
          log(state, Log.error_entry(reason))
          %{finish_run(state) | last_error: reason}
      end

    state = start_next(state)
    broadcast(state)
    {:noreply, state, state.idle_timeout}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{task_ref: ref} = state) do
    Logger.error("agent run crashed for session #{state.id}: #{inspect(reason)}")
    message = "agent run crashed: #{inspect(reason)}"
    log(state, Log.error_entry(message))

    state = %{finish_run(state) | last_error: "agent run crashed: #{inspect(reason)}"}

    broadcast(state)
    {:noreply, state, state.idle_timeout}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  defp user_item(text, sender), do: %{text: text, sender: sender, mode: :user, from: nil}

  defp peer_message_text(from, prompt, true) do
    "Message from peer #{from}. A reply is requested: when you are done, send your " <>
      "final response with the reply tool.\n\n" <> prompt
  end

  defp peer_message_text(from, prompt, false), do: "Message from peer #{from}.\n\n" <> prompt

  # Starts a run if the session is idle, otherwise queues the item.
  defp accept(%__MODULE__{status: :running} = state, item) do
    state = %{state | queue: state.queue ++ [item]}
    broadcast(state)
    {:reply, {:ok, :queued}, state, state.idle_timeout}
  end

  defp accept(state, item) do
    {:reply, {:ok, :started}, start_run(state, item), state.idle_timeout}
  end

  defp finish_run(state) do
    %{state | status: :idle, task_ref: nil, task_pid: nil, awaiting: MapSet.new()}
  end

  # Starts a run for a queue item: records the message, then runs the agent
  # loop in a supervised Task.
  defp start_run(state, item) do
    user_msg = %{"role" => "user", "content" => [%{"type" => "text", "text" => item.text}]}
    new_messages = state.messages ++ [user_msg]

    state = %{
      state
      | messages: new_messages,
        senders: Map.put(state.senders, length(state.messages), item.sender),
        status: :running,
        last_error: nil
    }

    log(state, Log.user_entry(item.sender, item.text))
    broadcast(state)

    parent = self()
    worktree_root = state.worktree_root

    opts = [
      mode: item.mode,
      peers: Connections.peers(state.id),
      peer: peer_call(self(), state.id, item.from),
      network: state.network
    ]

    task =
      Task.Supervisor.async_nolink(Phod.Session.TaskSupervisor, fn ->
        Loop.run(
          new_messages,
          worktree_root,
          fn event -> send(parent, {:loop_event, event}) end,
          opts
        )
      end)

    allow_req_test(task.pid)

    %{state | task_ref: task.ref, task_pid: task.pid}
  end

  # The peer work a run may ask for, as a function the loop calls from its task.
  # `session` is this session's process; `from` is who sent the message this run
  # is handling, if it was a peer.
  defp peer_call(session, id, from) do
    fn
      {:send, peer, prompt, want_reply} ->
        if want_reply, do: GenServer.call(session, {:expect_reply, peer})

        case deliver(peer, id, prompt, want_reply) do
          {:ok, status} ->
            {:ok, %{peer: peer, status: status}}

          {:error, _reason} = error ->
            if want_reply, do: GenServer.call(session, {:unexpect_reply, peer})
            error
        end

      {:reply, text} when is_binary(from) ->
        case deliver_reply(from, id, text) do
          {:ok, status} -> {:ok, %{to: from, status: status}}
          {:error, _reason} = error -> error
        end

      {:reply, _text} ->
        {:error, "there is no sender to reply to"}

      {:root, peer} ->
        case worktrees(peer) do
          {:ok, [{_name, root}]} -> {:ok, root}
          {:error, _reason} = error -> error
        end

      {:describe, peer} ->
        describe(peer)
    end
  end

  # The session's description: the start of its DESCRIPTION.md, trimmed and
  # capped. Read once when the session starts; `nil` if there is no file.
  defp read_description(worktree_root) do
    case File.read(Path.join(worktree_root, @description_file)) do
      {:ok, text} ->
        case text |> String.trim() |> String.slice(0, @max_description_chars) do
          "" -> nil
          description -> description
        end

      {:error, _reason} ->
        nil
    end
  end

  # When a run finishes, the next queued item (if any) starts its run.
  defp start_next(%{queue: []} = state), do: state

  defp start_next(%{queue: [item | rest]} = state) do
    start_run(%{state | queue: rest}, item)
  end

  defp snapshot(state) do
    %{
      id: state.id,
      worktree_root: state.worktree_root,
      status: state.status,
      messages: state.messages,
      senders: state.senders,
      edits: state.edits,
      last_error: state.last_error,
      queued: Enum.map(state.queue, & &1.text),
      peers: Connections.peers(state.id),
      network: Network.labels(state.network),
    }
  end

  # The session log is best-effort: a failed write is reported and the
  # session carries on without it.
  defp reset_log(state) do
    case Log.reset(state.log_path, Llm.system_prompt()) do
      :ok -> :ok
      {:error, reason} -> warn_log_failure(state, reason)
    end
  end

  defp log(state, entries) do
    case Log.append(state.log_path, entries) do
      :ok -> :ok
      {:error, reason} -> warn_log_failure(state, reason)
    end
  end

  defp warn_log_failure(state, reason) do
    Logger.warning(
      "session log #{state.log_path} write failed for #{state.id}: #{inspect(reason)}"
    )
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      Phod.PubSub,
      "sessions:" <> state.id,
      {:session_snapshot, snapshot(state)}
    )
  end

  # No-op in production (where `req_options` is `[]`); in test, propagates
  # the `Req.Test` stub ownership from this GenServer to the dynamically
  # spawned Task, since the stub is owned by the test process that started
  # the session, not by this process.
  defp allow_req_test(task_pid) do
    case get_in(Application.get_env(:phod, Phod.Session.Llm, []), [:req_options, :plug]) do
      {Req.Test, name} -> Req.Test.allow(name, self(), task_pid)
      _ -> :ok
    end
  end
end
