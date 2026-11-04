defmodule PhodWeb.SessionEntryLive do
  @moduledoc """
  Landing page: start or join a session by naming it and pointing it at an
  already-created worktree. `/sessions/:id` never auto-creates a session
  (there's no id -> worktree mapping to create one from), so this is the
  only place that calls `Phod.Session.ensure_started/2`.
  """

  use PhodWeb, :live_view

  import Ecto.Changeset

  @types %{id: :string, worktree_root: :string}
  @id_format ~r/^[a-zA-Z0-9_-]{1,64}$/

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(changeset(%{}), as: :session))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-md space-y-6 py-12">
        <div>
          <h1 class="text-2xl font-semibold">Phod</h1>
          <p class="text-sm opacity-70">
            Start or join a session by naming it and pointing it at a worktree.
          </p>
        </div>

        <.form
          for={@form}
          id="session-entry-form"
          phx-change="validate"
          phx-submit="start"
          class="space-y-4"
        >
          <.input field={@form[:id]} type="text" label="Session id" placeholder="lucky" />
          <.input
            field={@form[:worktree_root]}
            type="text"
            label="Worktree path"
            placeholder="/home/you/phod/tree/you/lucky"
          />
          <.button variant="primary" phx-disable-with="Starting...">
            Start / Join
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("validate", %{"session" => params}, socket) do
    form =
      params
      |> changeset()
      |> Map.put(:action, :validate)
      |> to_form(as: :session)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("start", %{"session" => params}, socket) do
    changeset = changeset(params)

    case apply_action(changeset, :insert) do
      {:ok, %{id: id, worktree_root: worktree_root}} ->
        start_session(socket, changeset, id, worktree_root)

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :session))}
    end
  end

  defp start_session(socket, changeset, id, worktree_root) do
    case Phod.Session.ensure_started(id, worktree_root) do
      {:ok, _pid} ->
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{id}")}

      {:error, {:invalid_worktree_root, _}} ->
        form =
          changeset
          |> add_error(:worktree_root, "is not a directory")
          |> Map.put(:action, :insert)
          |> to_form(as: :session)

        {:noreply, assign(socket, :form, form)}

      {:error, reason} ->
        form =
          changeset
          |> add_error(:id, "could not start session: #{inspect(reason)}")
          |> Map.put(:action, :insert)
          |> to_form(as: :session)

        {:noreply, assign(socket, :form, form)}
    end
  end

  defp changeset(params) do
    {%{}, @types}
    |> cast(params, Map.keys(@types))
    |> validate_required([:id, :worktree_root])
    |> validate_format(:id, @id_format, message: "only letters, numbers, - and _ allowed")
  end
end
