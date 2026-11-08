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

  defp fetch_tool(name) do
    case Map.fetch(@names, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, "unknown tool: #{inspect(name)}"}
    end
  end
end
