defmodule Phod.Session.NetworkSessionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Phod.Session

  # A fresh worktree; its config file is removed afterwards.
  defp fresh_tree do
    tree = "net-#{System.unique_integer([:positive])}"
    root = Session.worktree_root("tester", tree)
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm(root <> ".json")
    end)

    tree
  end

  # Writes a session's config file, as the session will read it at start.
  defp write_config(tree, config) do
    File.write!(Session.worktree_root("tester", tree) <> ".json", Jason.encode!(config))
  end

  test "a session starts with the connections in its config file, and the snapshot shows labels only" do
    tree = fresh_tree()

    write_config(tree, %{
      "http" => %{"docs" => %{"base_url" => "http://docs.internal:8080", "headers" => ["Authorization: Bearer s3cret"]}},
      "postgres" => %{
        "analytics" => %{"host" => "db", "port" => 5432, "database" => "app", "user" => "r", "password" => "hunter2"}
      }
    })

    {:ok, _pid} = Session.ensure_started("tester", tree)

    snapshot = Session.get_snapshot(Session.session_id("tester", tree))
    assert snapshot.network == %{http: ["docs"], postgres: ["analytics"]}
    refute inspect(snapshot) =~ "hunter2"
    refute inspect(snapshot) =~ "s3cret"
  end

  test "a session with an invalid config file starts with no connections" do
    tree = fresh_tree()
    write_config(tree, %{"http" => %{"Bad Label" => %{"base_url" => "http://h"}}})

    capture_log(fn ->
      assert {:ok, _pid} = Session.ensure_started("tester", tree)
    end)

    assert %{network: %{http: [], postgres: []}} = Session.get_snapshot(Session.session_id("tester", tree))
  end

  test "a session with no config file has no network tools" do
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

  describe "list_network/1" do
    test "lists each connection with its tool name, without passwords or header values" do
      tree = fresh_tree()

      write_config(tree, %{
        "http" => %{"docs" => %{"base_url" => "http://docs.internal:8080", "headers" => ["Authorization: Bearer s3cret"]}},
        "postgres" => %{"analytics" => %{"host" => "db", "port" => 5432, "database" => "app", "user" => "r", "password" => "hunter2"}}
      })

      {:ok, _pid} = Session.ensure_started("tester", tree)
      id = Session.session_id("tester", tree)
      assert {:ok, [http, postgres]} = Session.list_network(id)

      assert %{tool: "http_docs", protocol: :http, base_url: "http://docs.internal:8080", header_names: ["Authorization"], read_only: true} = http
      assert %{tool: "postgres_analytics", protocol: :postgres, host: "db", database: "app", user: "r"} = postgres

      refute inspect({:ok, [http, postgres]}) =~ "hunter2"
      refute inspect({:ok, [http, postgres]}) =~ "s3cret"
    end

    test "a session with no connections lists none" do
      tree = fresh_tree()
      {:ok, _pid} = Session.ensure_started("tester", tree)

      assert {:ok, []} = Session.list_network(Session.session_id("tester", tree))
    end

    test "a session that isn't running is an error" do
      assert {:error, :not_found} = Session.list_network("tester/none")
    end
  end
end
