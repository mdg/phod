defmodule Phod.Tool.B do
  @moduledoc """
  Behaviour for tools made available to the coding agent's LLM.

  A tool is a small amount of functionality the agent can call: it takes a
  structured input, executes within the confines of the session worktree, and
  returns a result (or a precise error the LLM can act on).

  Every tool receives the worktree root as its first argument and receives all
  paths in its input **relative to the worktree root**. Implementations must go
  through `Phod.Tool.Lib.resolve_path/3` before touching the filesystem — it validates
  that the path stays inside the worktree (rejecting `..`, absolute paths, and
  symlinks that escape). Worktrees live under `~/phod/tree/`; the bare repos
  under `~/phod/repo/` are never touched by tools.
  """

  alias Phod.Tool

  @type result :: {:ok, term()} | {:error, String.t()}

  @callback name() :: atom()
  @callback description() :: String.t()
  @callback tool_fields() :: [atom()]
  @callback run(input :: Tool.Input.t()) :: result()

  @doc """
  A JSON Schema (string-keyed) describing this tool's LLM-facing input,
  e.g. `%{"type" => "object", "properties" => %{...}, "required" => [...]}`.

  Only fields the LLM actually supplies belong here. Internal capability
  flags consumed by `Phod.Tool.Input.validate/2` (such as `apply_diff`'s
  `:allow_new_path`) are not real inputs and must not appear in this schema.
  """
  @callback input_schema() :: map()
end
