defmodule PhodWeb.SessionLive.Components do
  @moduledoc """
  Stateless function components for the three-pane session view.
  """

  use PhodWeb, :html

  alias PhodWeb.SessionLive.FileTree

  # -- Header ------------------------------------------------------------

  attr :id, :string, required: true
  attr :status, :atom, required: true
  attr :presence, :list, required: true

  def session_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between border-b px-4 py-2" data-role="session-header">
      <div class="flex items-center gap-3">
        <h1 class="font-semibold">{@id}</h1>
        <span class={[
          "text-xs rounded px-2 py-0.5",
          @status == :running && "bg-amber-100 text-amber-800",
          @status == :idle && "bg-green-100 text-green-800"
        ]}>
          {@status}
        </span>
      </div>

      <div class="flex items-center gap-3">
        <div class="flex items-center gap-1" data-role="presence-roster">
          <span
            :for={user <- @presence}
            class="text-xs rounded-full bg-base-200 px-2 py-1"
            title={user.name}
          >
            {user.name}
          </span>
        </div>

        <button
          type="button"
          disabled
          title="Cancelling a run isn't supported yet"
          class="opacity-50 cursor-not-allowed text-sm border rounded px-2 py-1"
        >
          Stop
        </button>
      </div>
    </div>
    """
  end

  # -- Join / not-found ---------------------------------------------------

  attr :id, :string, required: true
  attr :join_path, :string, required: true

  def join_form(assigns) do
    ~H"""
    <div class="mx-auto max-w-md space-y-6 py-12" data-role="join-form">
      <h1 class="text-2xl font-semibold">Join "{@id}"</h1>
      <p class="text-sm opacity-70">Enter your name to join this session.</p>

      <form method="post" action={@join_path} class="space-y-4" id="join-form">
        <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
        <.input
          type="text"
          name="name"
          id="join-name"
          value={nil}
          label="Your name"
          placeholder="Ada"
        />
        <.button variant="primary">Join</.button>
      </form>
    </div>
    """
  end

  attr :id, :string, required: true

  def not_found(assigns) do
    ~H"""
    <div class="mx-auto max-w-md space-y-4 py-12 text-center" data-role="not-found">
      <h1 class="text-xl font-semibold">Session "{@id}" hasn't been started</h1>
      <p class="opacity-70">Start it from the home page by pointing it at a worktree.</p>
      <.button navigate={~p"/"} variant="primary">Go to home</.button>
    </div>
    """
  end

  # -- Chat pane -----------------------------------------------------------

  attr :transcript, :list, required: true
  attr :form, :any, required: true
  attr :status, :atom, required: true
  attr :last_error, :string, default: nil

  def chat_pane(assigns) do
    ~H"""
    <div class="flex flex-col h-full min-h-0" data-role="chat">
      <div class="flex-1 min-h-0 overflow-auto space-y-2 p-2" id="transcript" data-role="transcript">
        <div :for={{item, idx} <- Enum.with_index(@transcript)} id={"transcript-item-#{idx}"}>
          <.message_block :if={item.kind == :text} item={item} />
          <.tool_call_block :if={item.kind == :tool_call} item={item} />
        </div>
      </div>

      <p :if={@last_error} class="text-red-600 px-2 text-sm" data-role="last-error">
        {@last_error}
      </p>

      <.form
        for={@form}
        id="message-form"
        phx-submit="send_message"
        class="flex gap-2 p-2 border-t"
      >
        <div class="flex-1">
          <.input
            field={@form[:text]}
            type="text"
            class="w-full input"
            placeholder="Message the agent…"
            disabled={@status == :running}
          />
        </div>
        <.button
          variant="primary"
          disabled={@status == :running}
          phx-disable-with="Sending..."
        >
          Send
        </.button>
      </.form>
    </div>
    """
  end

  attr :item, :map, required: true

  def message_block(assigns) do
    ~H"""
    <div class={[
      "rounded px-3 py-2 max-w-prose",
      @item.role == "user" && "bg-base-200 ml-auto",
      @item.role == "assistant" && "bg-base-100"
    ]}>
      <p class="text-xs opacity-50">{@item.role}</p>
      <p class="whitespace-pre-wrap">{@item.text}</p>
    </div>
    """
  end

  attr :item, :map, required: true

  def tool_call_block(assigns) do
    ~H"""
    <details class="border rounded px-2 py-1 text-sm" data-role="tool-call" data-name={@item.name}>
      <summary class="cursor-pointer font-mono">{@item.name} · {tool_summary(@item)}</summary>
      <div class="mt-2 space-y-1 pl-2">
        <%= case @item.result do %>
          <% :pending -> %>
            <p class="italic opacity-60">running…</p>
          <% {:error, reason} -> %>
            <p class="text-red-600">{reason}</p>
          <% {:ok, payload} -> %>
            <.tool_result_body name={@item.name} payload={payload} />
        <% end %>
      </div>
    </details>
    """
  end

  attr :name, :string, required: true
  attr :payload, :map, required: true

  def tool_result_body(%{name: "list_files"} = assigns) do
    ~H"""
    <ul class="space-y-0.5">
      <li :for={entry <- @payload["entries"]}>
        <%= if entry["type"] == "dir" do %>
          <span>{entry["name"]}/</span>
        <% else %>
          <button
            type="button"
            phx-click="open_file"
            phx-value-path={join_path(@payload["path"], entry["name"])}
            class="hover:underline"
          >
            {entry["name"]}
          </button>
        <% end %>
        <span class="opacity-50 text-xs">{entry["mime_type"]}</span>
      </li>
    </ul>
    """
  end

  def tool_result_body(%{name: "grep"} = assigns) do
    ~H"""
    <ul class="space-y-0.5">
      <li :for={match <- @payload["matches"]}>
        <button
          type="button"
          phx-click="open_file"
          phx-value-path={match["path"]}
          class="hover:underline"
        >
          {match["path"]}:{match["line_number"]}
        </button>
        <span class="opacity-70">{match["line"]}</span>
      </li>
    </ul>
    <p :if={@payload["truncated?"]} class="italic opacity-60">(truncated)</p>
    """
  end

  def tool_result_body(%{name: "read_file"} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_file"
      phx-value-path={@payload["path"]}
      class="hover:underline"
    >
      open {@payload["path"]}
    </button>
    """
  end

  def tool_result_body(%{name: "apply_diff"} = assigns) do
    ~H"""
    <p>
      <%= if @payload["created?"] do %>
        created
      <% else %>
        applied {@payload["applied_hunks"]} hunk(s) to
      <% end %>
      <button
        type="button"
        phx-click="open_file"
        phx-value-path={@payload["path"]}
        class="hover:underline font-mono"
      >
        {@payload["path"]}
      </button>
    </p>
    """
  end

  def tool_result_body(assigns) do
    ~H"""
    <pre class="whitespace-pre-wrap">{Jason.encode!(@payload)}</pre>
    """
  end

  defp tool_summary(%{input: input}) do
    cond do
      is_binary(input["path"]) -> input["path"]
      is_list(input["patterns"]) -> Enum.join(input["patterns"], ", ")
      true -> ""
    end
  end

  # -- File explorer pane ---------------------------------------------------

  attr :tree, FileTree, required: true
  attr :recent_edit_paths, :list, default: []

  def file_tree_pane(assigns) do
    ~H"""
    <div
      class="border rounded h-full min-h-0 overflow-auto p-2 text-sm font-mono"
      id="file-tree"
      data-role="file-tree"
    >
      <.file_tree_node path="." tree={@tree} recent_edit_paths={@recent_edit_paths} depth={0} />
    </div>
    """
  end

  attr :path, :string, required: true
  attr :tree, FileTree, required: true
  attr :recent_edit_paths, :list, required: true
  attr :depth, :integer, required: true

  def file_tree_node(assigns) do
    assigns = assign(assigns, :entries, Map.get(assigns.tree.entries, assigns.path))

    ~H"""
    <div style={"padding-left: #{@depth * 12}px"}>
      <%= case @entries do %>
        <% {:error, reason} -> %>
          <span class="text-red-600">{reason}</span>
        <% {:ok, entries} -> %>
          <div :for={entry <- entries}>
            <% child = join_path(@path, entry.name) %>
            <%= if entry.type == "dir" do %>
              <button
                type="button"
                phx-click="toggle_dir"
                phx-value-path={child}
                class="hover:underline"
              >
                {if MapSet.member?(@tree.expanded, child), do: "▾", else: "▸"} {entry.name}/
              </button>
              <.file_tree_node
                :if={MapSet.member?(@tree.expanded, child)}
                path={child}
                tree={@tree}
                recent_edit_paths={@recent_edit_paths}
                depth={@depth + 1}
              />
            <% else %>
              <button
                type="button"
                phx-click="open_file"
                phx-value-path={child}
                class={[
                  "hover:underline",
                  child in @recent_edit_paths && "text-amber-600 font-semibold"
                ]}
              >
                {entry.name}
              </button>
            <% end %>
          </div>
        <% nil -> %>
      <% end %>
    </div>
    """
  end

  defp join_path(".", name), do: name
  defp join_path(nil, name), do: name
  defp join_path(dir, name), do: Path.join(dir, name)

  # -- Editor pane ----------------------------------------------------------

  attr :selected_path, :string, default: nil
  attr :selected_lines, :list, default: nil
  attr :selected_error, :string, default: nil

  def editor_pane(assigns) do
    ~H"""
    <div class="border rounded h-full min-h-0 overflow-auto p-2 text-sm font-mono" data-role="editor">
      <%= cond do %>
        <% @selected_path == nil -> %>
          <p class="opacity-60 italic p-2">Select a file to view it here.</p>
        <% @selected_error -> %>
          <p class="text-red-600 p-2">{@selected_error}</p>
        <% true -> %>
          <p class="px-2 py-1 font-semibold border-b" data-role="editor-path">{@selected_path}</p>
          <div :for={{number, text} <- @selected_lines} class="flex gap-2">
            <span class="opacity-50 select-none w-10 text-right shrink-0">{number}</span>
            <span class="whitespace-pre">{text}</span>
          </div>
      <% end %>
    </div>
    """
  end
end
