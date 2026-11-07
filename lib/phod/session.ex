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

  alias Phod.Session.{Llm, Log, Loop}

  defstruct [
    :id,
    :worktree_root,
    :idle_timeout,
    :log_path,
    messages: [],
    status: :idle,
    edits: [],
    last_error: nil,
    task_ref: nil
  ]

  @idle_timeout :timer.minutes(30)

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
      [user, name] -> Regex.match?(@github_user, user) and Regex.match?(@worktree_name, name)
      _ -> false
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

  @doc false
  def start_link({id, worktree_root, opts}) do
    GenServer.start_link(__MODULE__, {id, worktree_root, opts}, name: via(id))
  end

  defp via(id), do: {:via, Registry, {Phod.Session.Registry, id}}

  # Callbacks

  @impl true
  def init({id, worktree_root, opts}) do
    if File.dir?(worktree_root) do
      idle_timeout = Keyword.get(opts, :idle_timeout, @idle_timeout)

      state = %__MODULE__{
        id: id,
        worktree_root: worktree_root,
        idle_timeout: idle_timeout,
        log_path: Log.path(worktree_root)
      }

      reset_log(state)

      {:ok, state, idle_timeout}
    else
      {:stop, {:invalid_worktree_root, worktree_root}}
    end
  end

  @impl true
  def handle_call({:send_message, _text, _sender}, _from, %__MODULE__{status: :running} = state) do
    {:reply, {:error, :busy}, state, state.idle_timeout}
  end

  def handle_call({:send_message, text, sender}, _from, %__MODULE__{status: :idle} = state) do
    user_msg = %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
    new_messages = state.messages ++ [user_msg]
    state = %{state | messages: new_messages, status: :running, last_error: nil}
    log(state, Log.user_entry(sender, text))
    broadcast(state)

    parent = self()
    root = state.worktree_root

    task =
      Task.Supervisor.async_nolink(Phod.Session.TaskSupervisor, fn ->
        Loop.run(new_messages, root, fn event -> send(parent, {:loop_event, event}) end)
      end)

    allow_req_test(task.pid)

    {:reply, :ok, %{state | task_ref: task.ref}, state.idle_timeout}
  end

  def handle_call(:get_snapshot, _from, state) do
    {:reply, snapshot(state), state, state.idle_timeout}
  end

  @impl true
  def handle_info({:loop_event, {:message_appended, msg}}, state) do
    log(state, Log.message_entries(msg, "user"))
    state = %{state | messages: state.messages ++ [msg]}
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
        {:ok, _messages} -> %{state | status: :idle, task_ref: nil}
        {:error, reason, _messages} -> %{state | status: :idle, task_ref: nil, last_error: reason}
      end

    broadcast(state)
    {:noreply, state, state.idle_timeout}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{task_ref: ref} = state) do
    Logger.error("agent run crashed for session #{state.id}: #{inspect(reason)}")

    state = %{
      state
      | status: :idle,
        task_ref: nil,
        last_error: "agent run crashed: #{inspect(reason)}"
    }

    broadcast(state)
    {:noreply, state, state.idle_timeout}
  end

  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  defp snapshot(state) do
    %{
      id: state.id,
      worktree_root: state.worktree_root,
      status: state.status,
      messages: state.messages,
      edits: state.edits,
      last_error: state.last_error
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
