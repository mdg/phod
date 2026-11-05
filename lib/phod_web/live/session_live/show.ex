defmodule PhodWeb.SessionLive.Show do
  @moduledoc """
  The three-pane multiplayer session view: chat transcript, file explorer,
  and a read-only editor pane, all driven by `Phod.Session`'s PubSub
  broadcasts on `"sessions:<id>"` plus a `PhodWeb.Presence` roster sharing
  that same topic.

  `/sessions/:owner/:tree` never auto-creates a session — there's no
  owner/tree -> worktree mapping to create one from (that's
  `PhodWeb.SessionEntryController`'s job, currently pointed at one hardcoded
  session). A client whose session cookie lacks a display name (set by
  `PhodWeb.SessionJoinController`) sees a join prompt instead.
  """

  use PhodWeb, :live_view

  alias Phod.Session
  alias PhodWeb.Presence
  alias PhodWeb.SessionLive.{Components, FileTree, Transcript}

  @impl true
  def mount(%{"owner" => owner, "tree" => tree}, session, socket) do
    id = "#{owner}/#{tree}"
    join_path = ~p"/sessions/#{owner}/#{tree}/join"

    case Session.whereis(id) do
      :error ->
        {:ok, assign(socket, id: id, view: :not_found)}

      {:ok, _pid} ->
        display_name = Map.get(session, "display_name")
        client_id = Map.get(session, "client_id")

        if display_name && client_id do
          {:ok, mount_session(socket, id, display_name, client_id)}
        else
          {:ok, assign(socket, id: id, join_path: join_path, view: :join)}
        end
    end
  end

  defp mount_session(socket, id, display_name, client_id) do
    topic = topic(id)
    snapshot = Session.get_snapshot(id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Phod.PubSub, topic)
      {:ok, _ref} = Presence.track(self(), topic, client_id, %{name: display_name})
    end

    assign(socket,
      id: id,
      view: :session,
      topic: topic,
      snapshot: snapshot,
      edits_marker: length(snapshot.edits),
      recent_edit_paths: [],
      presence: list_presence(topic),
      tree: FileTree.new(snapshot.worktree_root),
      selected_path: nil,
      selected_lines: nil,
      selected_error: nil,
      transcript: Transcript.build(snapshot.messages),
      form: to_form(%{"text" => ""}, as: :message)
    )
  end

  defp topic(id), do: "sessions:" <> id

  defp list_presence(topic) do
    topic
    |> Presence.list()
    |> Enum.map(fn {client_id, %{metas: [meta | _]}} ->
      %{client_id: client_id, name: meta.name}
    end)
    |> Enum.sort_by(& &1.name)
  end

  @impl true
  def render(%{view: :not_found} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <Components.not_found id={@id} />
    </Layouts.app>
    """
  end

  def render(%{view: :join} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <Components.join_form id={@id} join_path={@join_path} />
    </Layouts.app>
    """
  end

  def render(%{view: :session} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-col h-[calc(100vh-4rem)]">
        <Components.session_header id={@id} status={@snapshot.status} presence={@presence} />

        <div class="flex-1 grid grid-cols-[2fr_1fr_1fr] auto-rows-fr gap-2 p-2 min-h-0">
          <Components.chat_pane
            transcript={@transcript}
            form={@form}
            status={@snapshot.status}
            last_error={@snapshot.last_error}
          />
          <Components.file_tree_pane tree={@tree} recent_edit_paths={@recent_edit_paths} />
          <Components.editor_pane
            selected_path={@selected_path}
            selected_lines={@selected_lines}
            selected_error={@selected_error}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:session_snapshot, snapshot}, socket) do
    prev_status = socket.assigns.snapshot.status
    prev_edits = socket.assigns.snapshot.edits

    marker =
      Transcript.advance_edit_marker(
        prev_status,
        snapshot.status,
        socket.assigns.edits_marker,
        snapshot.edits
      )

    recent_edit_paths = Transcript.recent_edit_paths(snapshot.edits, marker)

    socket =
      socket
      |> assign(
        snapshot: snapshot,
        edits_marker: marker,
        recent_edit_paths: recent_edit_paths,
        transcript: Transcript.build(snapshot.messages)
      )
      |> refresh_tree_if_changed(prev_edits, snapshot.edits)
      |> refresh_selected_if_edited(recent_edit_paths)

    {:noreply, socket}
  end

  def handle_info(%{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :presence, list_presence(socket.assigns.topic))}
  end

  @impl true
  def handle_event("send_message", %{"message" => %{"text" => text}}, socket) do
    case String.trim(text) do
      "" -> :ok
      text -> Session.send_message(socket.assigns.id, text)
    end

    {:noreply, assign(socket, :form, to_form(%{"text" => ""}, as: :message))}
  end

  def handle_event("toggle_dir", %{"path" => path}, socket) do
    tree = FileTree.toggle(socket.assigns.tree, socket.assigns.snapshot.worktree_root, path)
    {:noreply, assign(socket, :tree, tree)}
  end

  def handle_event("open_file", %{"path" => path}, socket) do
    {:noreply, open_file(socket, path)}
  end

  defp open_file(socket, path) do
    root = socket.assigns.snapshot.worktree_root

    case Phod.Tool.run("read_file", root, %{"path" => path}) do
      {:ok, %{content: content}} ->
        assign(socket,
          selected_path: path,
          selected_lines: parse_numbered_lines(content),
          selected_error: nil
        )

      {:error, reason} ->
        assign(socket, selected_path: path, selected_lines: nil, selected_error: reason)
    end
  end

  @line_pattern ~r/^(\d+): (.*)$/

  defp parse_numbered_lines(content) do
    content
    |> String.split("\n")
    |> Enum.map(fn line ->
      case Regex.run(@line_pattern, line) do
        [_, number, text] -> {number, text}
        _ -> {"", line}
      end
    end)
  end

  defp refresh_tree_if_changed(socket, same_edits, same_edits), do: socket

  defp refresh_tree_if_changed(socket, _old_edits, _new_edits) do
    tree = FileTree.refresh_expanded(socket.assigns.tree, socket.assigns.snapshot.worktree_root)
    assign(socket, :tree, tree)
  end

  defp refresh_selected_if_edited(socket, recent_edit_paths) do
    if socket.assigns.selected_path && socket.assigns.selected_path in recent_edit_paths do
      open_file(socket, socket.assigns.selected_path)
    else
      socket
    end
  end
end
