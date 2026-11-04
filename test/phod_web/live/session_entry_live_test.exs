defmodule PhodWeb.SessionEntryLiveTest do
  use PhodWeb.ConnCase, async: true

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "renders the entry form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#session-entry-form")
  end

  test "a valid submit starts the session and navigates to /sessions/:id", %{
    conn: conn,
    root: root
  } do
    id = "entry-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, ~p"/")

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("#session-entry-form", session: %{id: id, worktree_root: root})
             |> render_submit()

    assert to == "/sessions/#{id}"
    assert {:ok, _pid} = Phod.Session.whereis(id)
  end

  test "an invalid worktree path surfaces an error without starting a session", %{conn: conn} do
    id = "entry-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#session-entry-form", session: %{id: id, worktree_root: "/does/not/exist"})
      |> render_submit()

    assert html =~ "is not a directory"
    assert Phod.Session.whereis(id) == :error
  end
end
