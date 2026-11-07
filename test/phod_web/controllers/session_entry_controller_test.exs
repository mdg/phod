defmodule PhodWeb.SessionEntryControllerTest do
  use PhodWeb.ConnCase, async: false

  setup do
    # the hardcoded session's worktree must exist under the test worktree_base
    root = Phod.Session.worktree_root("mdg", "lucky")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(Path.dirname(root)) end)
    :ok
  end

  test "GET / starts the hardcoded session and redirects to it", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/sessions/mdg/lucky"
    assert {:ok, _pid} = Phod.Session.whereis("mdg/lucky")
  end
end
