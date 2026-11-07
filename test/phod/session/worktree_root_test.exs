defmodule Phod.Session.WorktreeRootTest do
  use ExUnit.Case, async: true

  alias Phod.Session

  describe "valid_session_name?/1" do
    test "accepts <github_user>/<worktree_name>" do
      assert Session.valid_session_name?("octocat/wt-1")
      assert Session.valid_session_name?("a-b/x.y_z")
      assert Session.valid_session_name?("A1/name_x")
    end

    test "accepts a 39-character user and rejects a 40-character one" do
      user39 = String.duplicate("a", 39)
      user40 = String.duplicate("a", 40)

      assert Session.valid_session_name?("#{user39}/wt")
      refute Session.valid_session_name?("#{user40}/wt")
    end

    test "rejects a user that starts with a hyphen or has other characters" do
      refute Session.valid_session_name?("-octocat/wt")
      refute Session.valid_session_name?("octo_cat/wt")
      refute Session.valid_session_name?("octo.cat/wt")
      refute Session.valid_session_name?("octo cat/wt")
    end

    test "rejects a worktree name that starts with a dot or has other characters" do
      refute Session.valid_session_name?("octocat/.hidden")
      refute Session.valid_session_name?("octocat/..")
      refute Session.valid_session_name?("octocat/wt name")
      refute Session.valid_session_name?("octocat/wt/extra")
    end

    test "rejects anything that is not exactly two non-empty segments" do
      refute Session.valid_session_name?("octocat")
      refute Session.valid_session_name?("octocat/")
      refute Session.valid_session_name?("/wt")
      refute Session.valid_session_name?("")
      refute Session.valid_session_name?("a/b/c")
    end

    test "rejects non-binary input" do
      refute Session.valid_session_name?(nil)
      refute Session.valid_session_name?(:octocat)
      refute Session.valid_session_name?(["octocat", "wt"])
    end
  end

  describe "valid_worktree_root?/1" do
    setup do
      base = Application.fetch_env!(:phod, :worktree_base)
      user_dir = Path.join(base, "wtcheck")
      on_exit(fn -> File.rm_rf!(user_dir) end)

      %{base: base, user_dir: user_dir}
    end

    test "accepts an existing directory at <base>/<user>/<name>", %{base: base} do
      root = Path.join([base, "wtcheck", "wt-ok"])
      File.mkdir_p!(root)

      assert Session.valid_worktree_root?(root)
    end

    test "rejects a well-formed path that does not exist", %{base: base} do
      refute Session.valid_worktree_root?(Path.join([base, "wtcheck", "no-such-wt"]))
    end

    test "rejects a path that is a file, not a directory", %{base: base} do
      file = Path.join([base, "wtcheck", "a-file"])
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "x")

      refute Session.valid_worktree_root?(file)
    end

    test "rejects a directory that is not exactly two levels under the base", %{base: base} do
      flat = Path.join(base, "wtcheck-flat")
      deep = Path.join([base, "wtcheck", "a", "b"])
      File.mkdir_p!(flat)
      File.mkdir_p!(deep)
      on_exit(fn -> File.rm_rf!(flat) end)

      refute Session.valid_worktree_root?(flat)
      refute Session.valid_worktree_root?(deep)
    end

    test "rejects the base itself", %{base: base} do
      refute Session.valid_worktree_root?(base)
    end

    test "rejects a directory outside the base" do
      outside = Path.join(System.tmp_dir!(), "wtcheck-outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf!(outside) end)

      refute Session.valid_worktree_root?(outside)
    end

    test "rejects a directory whose user or name fails the naming rules", %{base: base} do
      bad_user = Path.join([base, "-wtcheck", "wt-ok"])
      bad_name = Path.join([base, "wtcheck", ".hidden"])
      File.mkdir_p!(bad_user)
      File.mkdir_p!(bad_name)
      on_exit(fn -> File.rm_rf!(Path.join(base, "-wtcheck")) end)

      refute Session.valid_worktree_root?(bad_user)
      refute Session.valid_worktree_root?(bad_name)
    end

    test "rejects a relative path that resolves outside the base", %{base: base} do
      # not expanded by the caller: `..` climbs out of the base
      refute Session.valid_worktree_root?(Path.join([base, "wtcheck", "..", "..", "etc"]))
    end
  end
end
