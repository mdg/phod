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

  # How often the file explorer re-lists its expanded directories, so files
  # added or removed outside the agent's own edits show up.
  @tree_refresh_ms 2_000

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
      schedule_tree_refresh()
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
      selected_image: nil,
      selected_binary?: false,
      selected_symlink?: false,
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
            selected_image={@selected_image}
            selected_binary?={@selected_binary?}
            selected_symlink?={@selected_symlink?}
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

  def handle_info(:refresh_tree, socket) do
    schedule_tree_refresh()
    {:noreply, refresh_tree(socket)}
  end

  defp schedule_tree_refresh do
    Process.send_after(self(), :refresh_tree, @tree_refresh_ms)
  end

  defp refresh_tree(socket) do
    tree = FileTree.refresh_expanded(socket.assigns.tree, socket.assigns.snapshot.worktree_root)
    assign(socket, :tree, tree)
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

  def handle_event("open_file", %{"path" => path} = params, socket) do
    type_hint = blank_to_nil(params["type"])
    mime_hint = blank_to_nil(params["mime-type"])
    charset_hint = blank_to_nil(params["charset"])
    {:noreply, open_file(socket, path, type_hint, mime_hint, charset_hint)}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # `type_hint`/`mime_hint`/`charset_hint` come from the button that
  # triggered this (set from the `list_files` tool's own `type`/
  # `mime_type`/`charset`, both in the file tree and in the chat
  # transcript). Clicks with no such tool result nearby (e.g. a `grep`
  # match or `read_file`'s own link) arrive with all three `nil` and just
  # fall back to the code viewer — we don't run `file` again to find out.
  #
  # Symlinks are handled before path resolution: `Tool.Input`'s
  # `Path.safe_relative/2` call silently follows symlinks to their target
  # (that's what keeps the sandbox safe), which would otherwise swap the
  # displayed path out from under the "this is a symlink" notice.
  defp open_file(socket, path, type_hint \\ nil, mime_hint \\ nil, charset_hint \\ nil)

  defp open_file(socket, path, "symlink", _mime_hint, _charset_hint) do
    assign_selected(socket, path: path, symlink?: true)
  end

  defp open_file(socket, path, _type_hint, mime_hint, charset_hint) do
    root = socket.assigns.snapshot.worktree_root

    case Phod.Tool.Input.from_map(%{"path" => path}, root)
         |> Phod.Tool.Input.validate_fields([:path]) do
      {:ok, input} ->
        render_selected_file(socket, input, mime_hint, charset_hint)

      {:error, reason} ->
        assign_selected(socket, path: path, error: reason)
    end
  end

  defp render_selected_file(socket, input, mime_type, charset) do
    cond do
      is_binary(mime_type) and String.starts_with?(mime_type, "image/") ->
        data_uri = "data:#{mime_type};base64," <> Base.encode64(File.read!(input.full_path))
        assign_selected(socket, path: input.path, image: data_uri)

      charset == "binary" ->
        assign_selected(socket, path: input.path, binary?: true)

      true ->
        root = socket.assigns.snapshot.worktree_root

        case Phod.Tool.run("read_file", root, %{"path" => input.path}) do
          {:ok, %{content: content}} ->
            assign_selected(socket, path: input.path, lines: parse_numbered_lines(content))

          {:error, reason} ->
            assign_selected(socket, path: input.path, error: reason)
        end
    end
  end

  # Every call sets all six `selected_*` assigns explicitly (defaulting
  # absent ones), so switching between a symlink, an image, a binary file,
  # a text file, and an error never leaves a stale value from the previous
  # selection behind.
  defp assign_selected(socket, opts) do
    assign(socket,
      selected_path: Keyword.fetch!(opts, :path),
      selected_lines: Keyword.get(opts, :lines),
      selected_error: Keyword.get(opts, :error),
      selected_image: Keyword.get(opts, :image),
      selected_binary?: Keyword.get(opts, :binary?, false),
      selected_symlink?: Keyword.get(opts, :symlink?, false)
    )
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

  defp refresh_tree_if_changed(socket, _old_edits, _new_edits), do: refresh_tree(socket)

  defp refresh_selected_if_edited(socket, recent_edit_paths) do
    if socket.assigns.selected_path && socket.assigns.selected_path in recent_edit_paths do
      open_file(socket, socket.assigns.selected_path)
    else
      socket
    end
  end
end
