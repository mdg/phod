defmodule PhodWeb.SessionJoinControllerTest do
  use PhodWeb.ConnCase, async: true

  test "sets display_name and a stable client_id in the session cookie", %{conn: conn} do
    conn = post(conn, ~p"/sessions/mdg/lucky/join", %{"name" => "  Ada  "})

    assert redirected_to(conn) == ~p"/sessions/mdg/lucky"
    assert get_session(conn, :display_name) == "Ada"
    client_id = get_session(conn, :client_id)
    assert is_binary(client_id)

    # the cookie set on this response must survive into the next request
    # from the same browser
    conn = conn |> recycle() |> post(~p"/sessions/mdg/lucky/join", %{"name" => "Ada"})
    assert get_session(conn, :client_id) == client_id
  end

  test "defaults to Anonymous when no name is given", %{conn: conn} do
    conn = post(conn, ~p"/sessions/mdg/lucky/join", %{"name" => ""})

    assert get_session(conn, :display_name) == "Anonymous"
  end
end
