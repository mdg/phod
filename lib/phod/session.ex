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

      iex> {:ok, _pid} = Phod.Session.ensure_started("manual-1", "/path/to/worktree")
      iex> Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:manual-1")
      iex> Phod.Session.send_message("manual-1", "List the files in the project root")
      iex> flush()   # watch {:session_snapshot, _} arrive as the real Zen API responds
      iex> Phod.Session.get_snapshot("manual-1")
  """

  use GenServer

  require Logger

  alias Phod.Session.Loop

  defstruct [
    :id,
    :worktree_root,
    :idle_timeout,
    messages: [],
    status: :idle,
    edits: [],
    last_error: nil,
    task_ref: nil
  ]

  @idle_timeout :timer.minutes(30)

  # Public API

  @doc """
  The on-disk worktree path for a session id (`"<owner>/<name>"`), rooted
  under the configured `:worktree_base` (e.g. `~/phod/tree/`).
  """
  @spec worktree_root(String.t()) :: String.t()
  def worktree_root(id) do
    Path.join(Application.fetch_env!(:phod, :worktree_base), id)
  end

  @doc """
  Starts a session for `worktree_root` under `id` if one isn't already
  running, otherwise returns the existing process. Idempotent.
  """
  @spec ensure_started(String.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(id, worktree_root, opts \\ []) do
    case Phod.Session.Supervisor.start_session(id, worktree_root, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec whereis(String.t()) :: {:ok, pid()} | :error
  def whereis(id) do
    case Registry.lookup(Phod.Session.Registry, id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Appends `text` as a user message and kicks off the agent loop. Returns
  immediately without waiting for the loop to finish.
  """
  @spec send_message(String.t(), String.t()) :: :ok | {:error, :busy} | {:error, :not_found}
  def send_message(id, text) do
    with {:ok, pid} <- whereis(id) do
      GenServer.call(pid, {:send_message, text})
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
        idle_timeout: idle_timeout
      }

      {:ok, state, idle_timeout}
    else
      {:stop, {:invalid_worktree_root, worktree_root}}
    end
  end

  @impl true
  def handle_call({:send_message, _text}, _from, %__MODULE__{status: :running} = state) do
    {:reply, {:error, :busy}, state, state.idle_timeout}
  end

  def handle_call({:send_message, text}, _from, %__MODULE__{status: :idle} = state) do
    user_msg = %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
    new_messages = state.messages ++ [user_msg]
    state = %{state | messages: new_messages, status: :running, last_error: nil}
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
