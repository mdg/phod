defmodule Phod.Tool.Rustc do
  @moduledoc """
  Compiles a Rust source file by running `rustc <path>` in the worktree root.

  Because this is a full compile, rustc links the program: the binary is written
  to the worktree next to the source, and linking needs a system C linker (`cc`).
  Compile errors are a normal result (`{:ok, %{success: false, diagnostics: ...}}`)
  so the LLM can read them and fix the code. `{:error, _}` means rustc could not
  be run at all.
  """

  alias Phod.Tool

  @behaviour Tool.B

  @impl Tool.B
  def name do
    "rustc"
  end

  @impl Tool.B
  def description,
    do: """
    Compile a Rust source file in the worktree by running `rustc <path>`. The \
    compiler's output binary is written into the worktree. Use this after \
    editing a `.rs` file to check that it compiles; the result includes \
    `success` and the compiler's `diagnostics`.\
    """

  @impl Tool.B
  def params do
    [
      Tool.Input.path(),
    ]
  end

  @impl Tool.B
  def run(%{path: path}, %{session_root: root}) do
    case Rambo.run("rustc", [path], cd: root, log: false) do
      {:ok, %Rambo{err: err, out: out}} ->
        {:ok, %{path: path, success: true, diagnostics: String.trim(err <> out)}}

      {:error, %Rambo{err: err, out: out}} ->
        {:ok, %{path: path, success: false, diagnostics: String.trim(err <> out)}}

      {:error, reason} ->
        {:error, "could not run rustc: #{reason}"}
    end
  end
end
