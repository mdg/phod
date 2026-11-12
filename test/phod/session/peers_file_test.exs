defmodule Phod.Session.PeersFileTest do
  # Restarts the peer store, which is shared, so this runs alone.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Phod.Session

  setup do
    base = Application.fetch_env!(:phod, :worktree_base)
    file = Path.join(base, "peers.json")
    File.rm(file)
    restart_store()

    on_exit(fn ->
      File.rm(file)
      restart_store()
    end)

    %{peers_file: file}
  end

  # Restarts the store the way a restart of the application would: it loads
  # the file again.
  defp restart_store do
    :ok = Supervisor.terminate_child(Phod.Supervisor, Phod.Session.Connections)
    {:ok, _pid} = Supervisor.restart_child(Phod.Supervisor, Phod.Session.Connections)
  end

  defp fresh_session do
    tree = "peerfile-#{System.unique_integer([:positive])}"
    root = Session.worktree_root("tester", tree)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, _pid} = Session.ensure_started("tester", tree)
    Session.session_id("tester", tree)
  end

  test "connections are saved to peers.json", %{peers_file: file} do
    a = fresh_session()
    b = fresh_session()
    :ok = Session.connect(a, b)

    assert %{"links" => links} = file |> File.read!() |> Jason.decode!()
    assert Enum.sort(links) == Enum.sort([[a, b], [b, a]])
  end

  test "connections survive a restart of the store" do
    a = fresh_session()
    b = fresh_session()
    :ok = Session.connect(a, b, mode: :one_way)

    restart_store()

    assert Session.peers(a) == [b]
    assert Session.peers(b) == []
  end

  test "a saved connection needs no running session to load", %{peers_file: file} do
    File.write!(file, Jason.encode!(%{"links" => [["tester/ghost-a", "tester/ghost-b"]]}))

    restart_store()

    assert Session.peers("tester/ghost-a") == ["tester/ghost-b"]
  end

  test "disconnect is saved too", %{peers_file: file} do
    a = fresh_session()
    b = fresh_session()
    :ok = Session.connect(a, b)
    :ok = Session.disconnect(a, b)

    assert %{"links" => []} = file |> File.read!() |> Jason.decode!()
  end

  test "an invalid peers file is logged, the store starts empty, and changes are refused", %{peers_file: file} do
    File.write!(file, "{not json")

    log = capture_log(fn -> restart_store() end)
    assert log =~ "peers file"

    a = fresh_session()
    b = fresh_session()
    assert {:error, {:invalid_peers_file, _}} = Session.connect(a, b)

    assert File.read!(file) == "{not json"
  end

  test "a peers file of the wrong shape is treated as invalid", %{peers_file: file} do
    File.write!(file, ~s({"links": [["only-one"]]}))

    capture_log(fn -> restart_store() end)
    assert Session.peers("only-one") == []
    assert {:error, {:invalid_peers_file, :invalid_shape}} = Session.connect(fresh_session(), fresh_session())
  end
end
