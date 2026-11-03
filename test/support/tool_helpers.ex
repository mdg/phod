defmodule Phod.Tool.TestHelpers do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  # Shared helpers for the tool tests: a per-test worktree in tmp, plus small
  # conveniences for writing files and creating symlinks.

  def setup_worktree(_ctx) do
    root =
      Path.join([System.tmp_dir!(), "phod-tool-test-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  def write(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    full
  end

  def symlink!(target, link) do
    assert :ok = :file.make_symlink(String.to_charlist(target), String.to_charlist(link))
  end
end
