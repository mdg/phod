defmodule Phod.Tool do
  @moduledoc """
  Registry of the agent's tools. Maps tool names (as the LLM knows them) to
  implementations and exposes LLM-facing tool specs.
  """

  import Rexult
  alias __MODULE__.Input

  # Keep these in alphabetical order
  @tools %{
    __MODULE__.Exec => true,
    __MODULE__.Grep => true,
    __MODULE__.ListFiles => true,
    __MODULE__.Patch => true,
    __MODULE__.ReadFiles => true,
    __MODULE__.Rm => true,
    __MODULE__.Rustc => true,
    __MODULE__.WriteFile => true,
  }

  @remote_tools [
    __MODULE__.Grep,
    __MODULE__.ListFiles,
    __MODULE__.ReadFiles,
  ]

  @names Map.new(@tools, fn {tool, _} -> {tool.name(), tool} end)

  @spec all() :: [module()]
  def all, do: Map.keys(@tools)

  @spec specs() ::
          [
            %{
              required(:name) => String.t(),
              required(:description) => String.t(),
              required(:input_schema) => map(),
            },
          ]
  def specs do
    for {tool, true} <- @tools do
      schema = Input.to_schema([goal_param() | tool.params()])

      %{name: tool.name(), description: tool.description(), input_schema: schema}
    end
  end

  # Every call must say what it is for. The loop enforces it (see
  # `Phod.Session.Loop`); it's declared here so the model sees it in the schema.
  defp goal_param do
    Input.string(:goal, "One line: what this call is for.", required: true)
  end

  @doc """
  Builds the `tools` array shape the Anthropic Messages API expects, from
  the registry — so callers never need their own copy of tool knowledge.
  """
  @spec anthropic_tools() :: [map()]
  def anthropic_tools do
    for %{name: name, description: description, input_schema: schema} <- specs() do
      %{"name" => name, "description" => description, "input_schema" => schema}
    end
  end

  @doc """
  Runs a tool against the worktree at `root`. Every path in `input` is
  relative to `root`.
  """
  @spec run(String.t(), String.t(), map()) :: __MODULE__.B.result()
  def run(name, root, input) do
    with {:ok, tool} <- fetch_tool(name) do
      session_opts = %{session_root: root}

      input
      |> Input.validate_params(tool.params(), session_opts)
      |> ok_and_then(&tool.run(&1, session_opts))
    end
  end

  @doc """
  The tools offered for one agent run, in the shape the Messages API expects:

    * `:send_to`: `[{peer id, description | nil}]`. Non-empty offers `send`,
      with these as its `peer` choices.
    * `:reply`: offers `reply`.
    * `:peer_reads`: `[{peer id, description | nil}]`. Non-empty adds an optional `peer` to the
      read-only tools (see `peer_readable?/1`), with these as its choices.
  """
  @spec loop_tools(keyword()) :: [map()]
  def loop_tools(opts \\ []) do
    send_to = Keyword.get(opts, :send_to, [])
    reply? = Keyword.get(opts, :reply, false)
    peer_reads = Keyword.get(opts, :peer_reads, [])

    base =
      for {tool, true} <- @tools do
        spec(tool, if(peer_readable?(tool.name()), do: peer_reads, else: []))
      end

    send = if send_to == [], do: [], else: [spec(__MODULE__.Send, send_to)]
    reply = if reply?, do: [spec(__MODULE__.Reply, [])], else: []

    base ++ send ++ reply
  end

  @doc """
  True for the read-only tools, which may run in a peer's worktree. Writes into
  a peer go through a `send` instead.
  """
  @spec peer_readable?(String.t()) :: boolean()
  def peer_readable?(name), do: Enum.any?(@remote_tools, &(&1.name() == name))

  defp spec(tool, peers) do
    schema =
      [goal_param() | tool.params()]
      |> Input.to_schema()
      |> add_peer_choices(peers)

    %{"name" => tool.name(), "description" => tool.description(), "input_schema" => schema}
  end

  defp add_peer_choices(schema, []), do: schema

  # `peers` is `[{id, description | nil}]`. The enum keeps the choices exact; the
  # description lists what each peer is for.
  defp add_peer_choices(schema, peers) do
    peers = Enum.map(peers, fn {id, description} -> {id, description}; id -> {id, nil} end)
    props = schema["properties"]
    existing = Map.get(props, "peer", %{})
    base = Map.get(existing, "description", "The peer session.")

    lines =
      for {id, description} <- peers do
        if description, do: "- #{id}: #{description}", else: "- #{id}"
      end

    prop = %{
      "type" => "string",
      "enum" => Enum.map(peers, &elem(&1, 0)),
      "description" => Enum.join([base, "Peers:" | lines], "\n")
    }

    Map.put(schema, "properties", Map.put(props, "peer", prop))
  end

  defp fetch_tool(name) do
    case Map.fetch(@names, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, "unknown tool: #{inspect(name)}"}
    end
  end
end
