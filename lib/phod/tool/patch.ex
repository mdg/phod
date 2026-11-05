defmodule Phod.Tool.Patch do
  @moduledoc """
  Applies a unified diff to one file by piping the diff to the `patch` CLI
  on stdin (via `Rambo.run/3`'s `:in` option). The path is validated through
  `Phod.Tool.Input` like the other file tools, so it must stay inside the
  worktree; `allow_new_path` lets a diff against `/dev/null` create a file.
  """

  alias Phod.Tool

  @behaviour Tool.B

  @impl Tool.B
  def name, do: "patch"

  @impl Tool.B
  def description,
    do: """
    Apply a unified diff to one file in the worktree using the `patch` \
    utility. Provide the diff in standard unified format. To create a new \
    file, diff against /dev/null. After applying, verify the result with \
    read_file.\
    """

  @impl Tool.B
  def tool_fields do
    [:allow_new_path, :path, :diff]
  end

  @impl Tool.B
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "File path relative to the worktree root. May be a path that does not yet exist when creating a file."
        },
        "diff" => %{
          "type" => "string",
          "description" => "A unified diff to apply to the file."
        }
      },
      "required" => ["path", "diff"]
    }
  end

  @impl Tool.B
  def run(%Tool.Input{full_path: full_path, path: path, diff: diff}) do
    created? = not File.exists?(full_path)

    case Rambo.run("patch", ["--batch", "--forward", "--", full_path],
           in: diff <> "\n",
           log: false
         ) do
      {:ok, %Rambo{out: out}} ->
        {:ok,
         %{
           path: path,
           created?: created?,
           applied_hunks: count_hunks(diff),
           output: String.trim(out)
         }}

      {:error, %Rambo{status: status, out: out, err: err}} ->
        {:error, "patch failed (exit #{status}): #{String.trim(out <> err)}"}

      {:error, reason} ->
        {:error, "could not run patch: #{reason}"}
    end
  end

  # Every hunk must apply for `patch` to succeed, so the count of `@@` headers
  # in the diff is the number of hunks applied.
  defp count_hunks(diff) do
    diff |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "@@"))
  end
end
