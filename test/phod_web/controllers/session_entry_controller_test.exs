defmodule PhodWeb.SessionEntryControllerTest do
  use PhodWeb.ConnCase, async: false

  test "GET / starts the hardcoded session and redirects to it", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/sessions/mdg/lucky"
    assert {:ok, _pid} = Phod.Session.whereis("mdg/lucky")
  end
end
