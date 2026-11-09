defmodule Phod.Session.NetworkSessionTest do
  use ExUnit.Case, async: true

  alias Phod.Session

  defp fresh_tree do
    tree = "net-#{System.unique_integer([:positive])}"
    root = Session.worktree_root("tester", tree)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    tree
  end

  test "a session starts with its network config, and the snapshot shows labels only" do
    tree = fresh_tree()

    {:ok, _pid} =
      Session.ensure_started("tester", tree,
        network: %{
          http: %{"docs" => %{host: "docs.internal", port: 8080}},
          postgres: %{"analytics" => %{host: "db", port: 5432, database: "app", user: "r", password: "hunter2"}}
        }
      )

    snapshot = Session.get_snapshot(Session.session_id("tester", tree))
    assert snapshot.network == %{http: ["docs"], postgres: ["analytics"]}
    refute inspect(snapshot) =~ "hunter2"
  end

  test "a session with an invalid network config doesn't start" do
    tree = fresh_tree()

    assert {:error, {:invalid_network, {:invalid_label, :http, "Bad Label"}}} =
             Session.ensure_started("tester", tree,
               network: %{http: %{"Bad Label" => %{host: "h", port: 80}}}
             )

    assert Session.whereis(Session.session_id("tester", tree)) == :error
  end

  test "a session with no network config has no network tools" do
    tree = fresh_tree()
    {:ok, _pid} = Session.ensure_started("tester", tree)

    assert %{network: %{http: [], postgres: []}} = Session.get_snapshot(Session.session_id("tester", tree))
  end
end
