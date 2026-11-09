defmodule Phod.Tool.HttpTest do
  use ExUnit.Case, async: true

  alias Phod.Tool.Http

  defp conn(read_only \\ true) do
    %{base_url: "http://docs.internal:8080", headers: [], label: "docs", read_only: read_only}
  end

  defp call(input, connection \\ conn()) do
    Http.run(
      %{path: "/", method: "GET", query: nil, body: nil} |> Map.merge(input),
      %{connection: connection}
    )
  end

  test "a GET goes to the configured host and port, with the query string" do
    Req.Test.stub(Phod.Tool.HttpStub, fn conn ->
      assert conn.host == "docs.internal"
      assert conn.port == 8080
      assert conn.request_path == "/guide"
      assert conn.query_string == "lang=en"
      Req.Test.text(conn, "hello from docs")
    end)

    assert {:ok, %{status: 200, body: "hello from docs"}} =
             call(%{path: "/guide", query: "lang=en"})
  end

  test "configured headers are sent with every request" do
    connection = %{conn() | headers: ["Authorization: Bearer abc123", "Accept: text/plain"]}

    Req.Test.stub(Phod.Tool.HttpStub, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer abc123"]
      assert Plug.Conn.get_req_header(conn, "accept") == ["text/plain"]
      Req.Test.text(conn, "ok")
    end)

    assert {:ok, %{status: 200}} = call(%{path: "/secure"}, connection)
  end

  test "the base URL's path is kept, and the request path is added to it" do
    connection = %{conn() | base_url: "http://docs.internal:8080/api/"}

    Req.Test.stub(Phod.Tool.HttpStub, fn conn ->
      assert conn.request_path == "/api/v1/items"
      Req.Test.text(conn, "ok")
    end)

    assert {:ok, _} = call(%{path: "/v1/items"}, connection)
  end

  test "the connection's headers stay out of its description" do
    description = Http.describe(%{conn() | headers: ["Authorization: Bearer abc123"]})
    refute description =~ "abc123"
    assert description =~ "http://docs.internal:8080"
  end

  test "a read-only connection refuses anything but GET, and sends nothing" do
    Req.Test.stub(Phod.Tool.HttpStub, fn _conn -> flunk("a refused request was sent") end)

    assert {:error, msg} = call(%{path: "/x", method: "POST", body: "{}"})
    assert msg == "http_docs is read-only: only GET is allowed"
  end

  test "a connection that isn't read-only allows the other methods" do
    Req.Test.stub(Phod.Tool.HttpStub, fn conn ->
      assert conn.method == "POST"
      Req.Test.text(conn, "created")
    end)

    assert {:ok, %{status: 200, body: "created"}} =
             call(%{path: "/items", method: "post", body: "{}"}, conn(false))
  end

  test "the path must start with /, and the method must be known" do
    assert {:error, "path must start with /"} = call(%{path: "guide"})
    assert {:error, "unsupported method TRACE"} = call(%{path: "/", method: "TRACE"}, conn(false))
  end

  test "redirects are not followed" do
    Req.Test.stub(Phod.Tool.HttpStub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://elsewhere.example/")
      |> Plug.Conn.resp(302, "")
    end)

    assert {:ok, %{status: 302}} = call(%{path: "/moved"})
  end

  test "a long body is capped" do
    big = String.duplicate("a", 30_000)
    Req.Test.stub(Phod.Tool.HttpStub, fn conn -> Req.Test.text(conn, big) end)

    assert {:ok, %{body: body}} = call(%{path: "/big"})
    assert body =~ "truncated"
    assert byte_size(body) < 21_000
  end

  test "params default the method to GET" do
    assert %{method: "GET"} = Phod.Tool.Input.validate_params(%{"path" => "/"}, Http.params(), %{}) |> then(fn {:ok, args} -> args end)
  end
end
