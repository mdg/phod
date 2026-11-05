defmodule Phod.Tool.Rustc do
  @moduledoc """
  Type-checks a Rust source file with `rustc`, without linking or running it.

  Uses `--emit=metadata`, a check-only build: rustc parses, type-checks and
  borrow-checks the file but produces no binary, so no linker (`cc`) is needed
  and nothing the LLM wrote is executed. Compiler artifacts go to a throwaway
  directory that is removed afterwards.

  A compile error is a normal result (`{:ok, %{success: false, diagnostics: ...}}`)
  so the LLM can read the diagnostics and fix them. `{:error, _}` means rustc
  could not be run at all.
  """

  alias Phod.Tool

  @behaviour Tool.B

  @impl Tool.B
  def name, do: "rustc"

  @impl Tool.B
  def description,
    do: """
    Type-check a Rust source file in the worktree with `rustc`. This is a check \
    only: the file is compiled to metadata, not linked or run, so it reports \
    compile errors and warnings without producing a binary. Use this after \
    editing a `.rs` file to confirm it compiles. The result includes `success` \
    and the compiler's `diagnostics`.\
    """

  @impl Tool.B
  def tool_fields, do: [:path]

  @impl Tool.B
  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to a Rust source file, relative to the worktree root."
        }
      },
      "required" => ["path"]
    }
  end

  @impl Tool.B
  def run(%Tool.Input{full_path: full_path, path: path}) do
    out_dir = Path.join(System.tmp_dir!(), "phod-rustc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(out_dir)

    try do
      args = ["--emit=metadata", "--crate-type=bin", "--out-dir", out_dir, "--", full_path]

      case Rambo.run("rustc", args, log: false) do
        {:ok, %Rambo{err: err}} ->
          {:ok, %{path: path, success: true, diagnostics: String.trim(err)}}

        {:error, %Rambo{err: err, out: out}} ->
          {:ok, %{path: path, success: false, diagnostics: String.trim(err <> out)}}

        {:error, reason} ->
          {:error, "could not run rustc: #{reason}"}
      end
    after
      File.rm_rf(out_dir)
    end
  end
end
