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
          http: %{"docs" => %{base_url: "http://docs.internal:8080"}},
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
               network: %{http: %{"Bad Label" => %{base_url: "http://h"}}}
             )

    assert Session.whereis(Session.session_id("tester", tree)) == :error
  end

  test "a session with no network config has no network tools" do
    tree = fresh_tree()
    {:ok, _pid} = Session.ensure_started("tester", tree)

    assert %{network: %{http: [], postgres: []}} = Session.get_snapshot(Session.session_id("tester", tree))
  end

  describe "add_network/4" do
    test "adds an http connection to a running session" do
      tree = fresh_tree()
      {:ok, _pid} = Session.ensure_started("tester", tree)
      id = Session.session_id("tester", tree)

      assert :ok = Session.add_network(id, :http, "docs", %{base_url: "http://docs.internal:8080"})
      assert %{network: %{http: ["docs"]}} = Session.get_snapshot(id)
    end

    test "a label can only be used once" do
      tree = fresh_tree()
      {:ok, _pid} = Session.ensure_started("tester", tree)
      id = Session.session_id("tester", tree)

      :ok = Session.add_network(id, :http, "docs", %{base_url: "http://docs.internal"})

      assert {:error, :already_configured} =
               Session.add_network(id, :http, "docs", %{base_url: "http://other"})
    end

    test "a connection is checked before it's added" do
      tree = fresh_tree()
      {:ok, _pid} = Session.ensure_started("tester", tree)
      id = Session.session_id("tester", tree)

      assert {:error, {:invalid_connection, :http, "docs", {:bad_field, :base_url}}} =
               Session.add_network(id, :http, "docs", %{base_url: "docs.internal"})

      assert %{network: %{http: []}} = Session.get_snapshot(id)
    end

    test "an unknown protocol is an error" do
      tree = fresh_tree()
      {:ok, _pid} = Session.ensure_started("tester", tree)
      id = Session.session_id("tester", tree)

      assert {:error, {:unknown_protocols, [:ftp]}} =
               Session.add_network(id, :ftp, "files", %{host: "h"})
    end

    test "a session that isn't running is an error" do
      assert {:error, :not_found} =
               Session.add_network("tester/none", :http, "docs", %{base_url: "http://h"})
    end
  end
end
