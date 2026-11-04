defmodule PhodWeb.SessionLive.ShowTest do
  use PhodWeb.ConnCase, async: true

  import Phod.Session.TestHelpers, only: [start_and_allow: 2]

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  setup do
    %{id: "show-#{System.unique_integer([:positive])}"}
  end

  defp with_identity(conn, name \\ "Ada") do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:display_name, name)
    |> Plug.Conn.put_session(:client_id, Ecto.UUID.generate())
  end

  defp text_response(text, stop_reason \\ "end_turn") do
    fn conn ->
      Req.Test.json(conn, %{
        "content" => [%{"type" => "text", "text" => text}],
        "stop_reason" => stop_reason
      })
    end
  end

  test "renders a not-found view for a session that hasn't been started", %{conn: conn, id: id} do
    {:ok, view, _html} = live(with_identity(conn), ~p"/sessions/#{id}")
    assert has_element?(view, "[data-role=not-found]")
  end

  test "renders a join prompt when the browser has no display name yet", %{
    conn: conn,
    id: id,
    root: root
  } do
    Phod.Session.ensure_started(id, root)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{id}")
    assert has_element?(view, "[data-role=join-form]")
  end

  test "renders the three-pane view once joined", %{conn: conn, id: id, root: root} do
    Phod.Session.ensure_started(id, root)
    {:ok, view, _html} = live(with_identity(conn), ~p"/sessions/#{id}")

    assert has_element?(view, "[data-role=session-header]")
    assert has_element?(view, "[data-role=chat]")
    assert has_element?(view, "[data-role=file-tree]")
    assert has_element?(view, "[data-role=editor]")
  end

  test "sending a message drives a stubbed LLM round trip and updates the transcript", %{
    conn: conn,
    id: id,
    root: root
  } do
    Req.Test.expect(Phod.Session.LlmStub, text_response("hello!"))

    pid = start_and_allow(id, root)
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{id}")

    {:ok, view, _html} = live(with_identity(conn), ~p"/sessions/#{id}")

    view
    |> form("#message-form", message: %{text: "hi"})
    |> render_submit()

    Req.Test.allow(Phod.Session.LlmStub, self(), pid)

    assert_receive {:session_snapshot, %{status: :idle}}, 1000
    assert render(view) =~ "hello!"
  end

  test "expanding a directory in the file tree lists its contents", %{
    conn: conn,
    id: id,
    root: root
  } do
    Phod.Tool.TestHelpers.write(root, "lib/foo.ex", "hi")
    Phod.Session.ensure_started(id, root)

    {:ok, view, _html} = live(with_identity(conn), ~p"/sessions/#{id}")

    refute render(view) =~ "foo.ex"

    view |> element("button[phx-click=toggle_dir][phx-value-path=lib]") |> render_click()

    assert render(view) =~ "foo.ex"
  end

  test "clicking a tool-result path opens the editor pane", %{conn: conn, id: id, root: root} do
    Phod.Tool.TestHelpers.write(root, "new.txt", "hello")

    Req.Test.expect(Phod.Session.LlmStub, fn conn ->
      Req.Test.json(conn, %{
        "content" => [
          %{
            "type" => "tool_use",
            "id" => "tu_1",
            "name" => "read_file",
            "input" => %{"path" => "new.txt"}
          }
        ],
        "stop_reason" => "tool_use"
      })
    end)

    Req.Test.expect(Phod.Session.LlmStub, text_response("read it"))

    pid = start_and_allow(id, root)
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{id}")

    {:ok, view, _html} = live(with_identity(conn), ~p"/sessions/#{id}")

    view |> form("#message-form", message: %{text: "read new.txt"}) |> render_submit()
    Req.Test.allow(Phod.Session.LlmStub, self(), pid)

    assert_receive {:session_snapshot, %{status: :idle}}, 1000
    render(view)

    refute has_element?(view, "[data-role=editor-path]")

    view
    |> element("#transcript button[phx-click=open_file][phx-value-path='new.txt']")
    |> render_click()

    assert has_element?(view, "[data-role=editor-path]", "new.txt")
    assert has_element?(view, "[data-role=editor] span", "hello")
  end

  test "a second connection joining updates the first view's presence roster", %{
    conn: conn,
    id: id,
    root: root
  } do
    Phod.Session.ensure_started(id, root)

    {:ok, view1, _html} = live(with_identity(conn, "Ada"), ~p"/sessions/#{id}")
    Phoenix.PubSub.subscribe(Phod.PubSub, "sessions:#{id}")

    conn2 = with_identity(Phoenix.ConnTest.build_conn(), "Grace")
    {:ok, _view2, _html} = live(conn2, ~p"/sessions/#{id}")

    assert_receive %{event: "presence_diff"}, 1000
    assert render(view1) =~ "Grace"
  end
end
