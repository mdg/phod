defmodule Phod.Session.NetworkFileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Phod.Session

  # A fresh worktree; its config file is removed afterwards. The keys are
  # named `config_file` because ExUnit's own context has a `:file` key.
  setup do
    tree = "netfile-#{System.unique_integer([:positive])}"
    root = Session.worktree_root("tester", tree)
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm(root <> ".json")
      File.rm(root <> ".json.tmp")
      File.rm(root <> ".md")
    end)

    %{
      tree: tree,
      id: Session.session_id("tester", tree),
      config_file: root <> ".json"
    }
  end

  defp stop_session(id) do
    {:ok, pid} = Session.whereis(id)
    DynamicSupervisor.terminate_child(Phod.Session.Supervisor, pid)
  end

  test "a connection added to a session is saved beside the worktree, without the label", ctx do
    {:ok, _pid} = Session.ensure_started("tester", ctx.tree)

    :ok =
      Session.add_network(ctx.id, :http, "docs",
        %{base_url: "http://docs.internal:8080", headers: ["Accept: text/plain"]}
      )

    assert %{"http" => %{"docs" => saved}} = ctx.config_file |> File.read!() |> Jason.decode!()
    assert saved == %{"base_url" => "http://docs.internal:8080", "headers" => ["Accept: text/plain"], "read_only" => true}
  end

  test "the config file is readable only by its owner", ctx do
    {:ok, _pid} = Session.ensure_started("tester", ctx.tree)

    :ok =
      Session.add_network(ctx.id, :postgres, "db",
        %{host: "h", port: 1, database: "d", user: "u", password: "secret"}
      )

    assert File.stat!(ctx.config_file).mode |> Bitwise.band(0o777) == 0o600
  end

  test "a session loads its saved config when it starts again", ctx do
    {:ok, _pid} = Session.ensure_started("tester", ctx.tree)
    :ok = Session.add_network(ctx.id, :http, "docs", %{base_url: "http://d"})
    stop_session(ctx.id)

    {:ok, _pid} = Session.ensure_started("tester", ctx.tree)
    assert %{network: %{http: ["docs"]}} = Session.get_snapshot(ctx.id)
  end

  test "a session with no config file has no network, and creates no file", ctx do
    {:ok, _pid} = Session.ensure_started("tester", ctx.tree)

    assert %{network: %{http: [], postgres: []}} = Session.get_snapshot(ctx.id)
    refute File.exists?(ctx.config_file)
  end

  test "a config file that isn't valid JSON is logged, and the session starts with no connections",
       ctx do
    File.write!(ctx.config_file, "{not json")

    log =
      capture_log(fn ->
        assert {:ok, _pid} = Session.ensure_started("tester", ctx.tree)
      end)

    assert log =~ "invalid"
    assert %{network: %{http: [], postgres: []}} = Session.get_snapshot(ctx.id)
  end

  test "a config file with an unknown protocol is logged, and the session starts empty", ctx do
    File.write!(ctx.config_file, ~s({"ftp": {"files": {"host": "h"}}}))

    capture_log(fn ->
      assert {:ok, _pid} = Session.ensure_started("tester", ctx.tree)
    end)

    assert %{network: %{http: [], postgres: []}} = Session.get_snapshot(ctx.id)
  end

  test "a session with a bad config file won't overwrite it when a connection is added", ctx do
    broken = ~s({"http": {"docs": {"base_url": "not a url"}}})
    File.write!(ctx.config_file, broken)

    capture_log(fn -> {:ok, _pid} = Session.ensure_started("tester", ctx.tree) end)

    assert {:error, {:invalid_network_file, _}} =
             Session.add_network(ctx.id, :http, "other", %{base_url: "http://other"})

    assert File.read!(ctx.config_file) == broken
  end
end
