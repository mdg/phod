defmodule Phod.Tool do
  @moduledoc """
  Registry of the agent's tools. Maps tool names (as the LLM knows them) to
  implementations and exposes LLM-facing tool specs.
  """

  import Rexult
  alias __MODULE__.Input

  @tools %{
    __MODULE__.ElixirScript => false,
    __MODULE__.Grep => true,
    __MODULE__.ReadFile => true,
    __MODULE__.ListFiles => true,
    __MODULE__.Patch => true,
    __MODULE__.Rustc => true,
  }

  @names Map.new(@tools, fn {tool, _} -> {tool.name(), tool} end)

  @spec all() :: [module()]
  def all, do: Map.keys(@tools)

  @primary "default"

  @worktree_doc "Which worktree to act on, by its name (\"user/tree\"). " <>
                  "Defaults to the first worktree when omitted."

  @spec specs([String.t()]) ::
          [
            %{
              required(:name) => String.t(),
              required(:description) => String.t(),
              required(:input_schema) => map()
            }
          ]
  def specs(worktree_names \\ []) do
    for {tool, true} <- @tools do
      schema = tool.params() |> Input.to_schema() |> with_worktree_property(worktree_names)
      %{name: tool.name(), description: tool.description(), input_schema: schema}
    end
  end

  # Only sessions with more than one worktree need to tell the tools which
  # one to use; with a single worktree the schema stays as the tool declares it.
  defp with_worktree_property(schema, [_, _ | _] = worktree_names) do
    property = %{"type" => "string", "enum" => worktree_names, "description" => @worktree_doc}
    Map.update!(schema, "properties", &Map.put(&1, "worktree", property))
  end

  defp with_worktree_property(schema, _worktree_names), do: schema

  @doc """
  Builds the `tools` array shape the Anthropic Messages API expects, from
  the registry — so callers never need their own copy of tool knowledge.
  `worktree_names` are the session's worktrees, see `specs/1`.
  """
  @spec anthropic_tools([String.t()]) :: [map()]
  def anthropic_tools(worktree_names \\ []) do
    for %{name: name, description: description, input_schema: schema} <- specs(worktree_names) do
      %{"name" => name, "description" => description, "input_schema" => schema}
    end
  end

  @doc """
  Runs a tool. `worktrees` is the session's `[{name, root}]`, primary first,
  or a single root path. The worktree is chosen by the input's `"worktree"`
  name, falling back to the first; see `select_worktree/2`.
  """
  @spec run(String.t(), [{String.t(), String.t()}] | String.t(), map()) ::
          __MODULE__.B.result()
  def run(name, root, input) when is_binary(root) do
    run(name, [{@primary, root}], input)
  end

  def run(name, worktrees, input) when is_list(worktrees) do
    with {:ok, tool} <- fetch_tool(name),
         {:ok, {_name, root}} <- select_worktree(worktrees, input) do
      session_opts = %{session_root: root, session_roots: Enum.map(worktrees, &elem(&1, 1))}

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

  @doc """
  Picks the worktree a tool call acts on. With one worktree it is always that
  one. With several, the input's `"worktree"` names it, and no name means the
  first. An unknown name is an error.
  """
  @spec select_worktree([{String.t(), String.t()}], map()) ::
          {:ok, {String.t(), String.t()}} | {:error, String.t()}
  def select_worktree([single], _input), do: {:ok, single}

  def select_worktree([first | _] = worktrees, input) do
    case Map.get(input, "worktree") do
      nil ->
        {:ok, first}

      name ->
        case List.keyfind(worktrees, name, 0) do
          nil ->
            names = Enum.map(worktrees, &elem(&1, 0))
            {:error, "unknown worktree #{inspect(name)}, expected one of #{inspect(names)}"}

          worktree ->
            {:ok, worktree}
        end
    end
  end
end
