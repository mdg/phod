defmodule Phod.Tool.TestHelpers do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks

  # Shared helpers for the tool tests: a per-test worktree in tmp, plus small
  # conveniences for writing files and creating symlinks.

  # Worktrees use the real layout, `<worktree_base>/<user>/<tree>`, so each
  # test can also start a session on its worktree: `:id` is the session id
  # (`"<user>/<tree>"`), and `:user` / `:tree` are the pieces it was built from.
  def setup_worktree(_ctx) do
    n = System.unique_integer([:positive])
    user = "tester"
    tree = "wt-#{n}"
    root = Path.join([Application.fetch_env!(:phod, :worktree_base), user, tree])

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
      # sessions started on this worktree also write a session log beside it
      File.rm(root <> ".md")
      File.rm(root <> ".json")
    end)

    %{root: root, user: user, tree: tree, id: Phod.Session.session_id(user, tree)}
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
