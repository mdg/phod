defmodule Phod.Session.LogTest do
  use ExUnit.Case, async: true

  alias Phod.Session.Log

  @now ~U[2026-01-15 14:30:00Z]

  defp text(entries), do: entries |> IO.iodata_to_binary()

  test "path/1 appends .md to the worktree root" do
    assert Log.path("/home/mdg/phod/tree/mdg/lucky") == "/home/mdg/phod/tree/mdg/lucky.md"
  end

  test "timestamps are in America/New_York with the timezone abbreviation" do
    # 14:30 UTC on Jan 15 is 09:30 EST
    assert Log.timestamp(@now) == "2026-01-15 09:30:00 EST"
  end

  test "timestamps switch to EDT in summer" do
    assert Log.timestamp(~U[2026-07-15 14:30:00Z]) == "2026-07-15 10:30:00 EDT"
  end

  test "user entries are headed by the sender's name and fenced" do
    entry = Log.user_entry("Ada", "hello", @now) |> text()

    assert entry =~ "### Ada · 2026-01-15 09:30:00 EST"
    assert entry =~ "```text\nhello\n```"
  end

  test "a body containing markdown headers or fences cannot break the fence" do
    entry = Log.user_entry("Ada", "### not a header\n```\ncode\n```", @now) |> text()

    # the fence is longer than the longest backtick run in the body
    assert entry =~ "````text\n### not a header\n```\ncode\n```\n````"
  end

  test "long bodies are truncated with a note giving the sizes" do
    long = String.duplicate("a", 10_000)
    entry = Log.user_entry("Ada", long, @now) |> text()

    assert entry =~ "[truncated: showing 4000 of 10000 bytes]"
    refute entry =~ String.duplicate("a", 4_001)
  end

  test "truncation never splits a UTF-8 character" do
    long = String.duplicate("é", 5_000)
    entry = Log.user_entry("Ada", long, @now) |> text()

    assert String.valid?(entry)
  end

  test "assistant text becomes a phod entry" do
    [entry] =
      Log.message_entries(
        %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "done"}]},
        "Ada",
        @now
      )

    entry = text(entry)
    assert entry =~ "### phod · 2026-01-15 09:30:00 EST"
    assert entry =~ "done"
  end

  test "tool calls become phod entries showing the name and input" do
    [entry] =
      Log.message_entries(
        %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "tu_1",
              "name" => "grep",
              "input" => %{"patterns" => ["x"]}
            }
          ]
        },
        "Ada",
        @now
      )

    entry = text(entry)
    assert entry =~ "### phod"
    assert entry =~ "`grep`"
    assert entry =~ ~s("patterns")
  end

  test "tool results become phod entries, labelled as errors when they are" do
    [ok] =
      Log.message_entries(
        %{
          "role" => "user",
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "tu_1", "content" => "{\"ok\":true}"}
          ]
        },
        "Ada",
        @now
      )

    [err] =
      Log.message_entries(
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "tu_2",
              "content" => "no such file",
              "is_error" => true
            }
          ]
        },
        "Ada",
        @now
      )

    assert text(ok) =~ "**tool result:**"
    assert text(err) =~ "**tool error:**"
    assert text(err) =~ "no such file"
  end

  test "reset/3 writes a fresh log containing only the system prompt" do
    path = Path.join(System.tmp_dir!(), "log-test-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(path) end)

    File.write!(path, "stale content from an earlier session")

    assert :ok = Log.reset(path, "You are a test prompt.", @now)

    contents = File.read!(path)
    assert contents =~ "# Session log"
    assert contents =~ "You are a test prompt."
    refute contents =~ "stale content"
  end

  test "append/2 adds to the end of the log" do
    path = Path.join(System.tmp_dir!(), "log-test-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(path) end)

    :ok = Log.reset(path, "prompt", @now)
    :ok = Log.append(path, Log.user_entry("Ada", "first", @now))
    :ok = Log.append(path, Log.user_entry("Ada", "second", @now))

    contents = File.read!(path)
    assert contents =~ ~r/first.*second/s
  end

  test "append/2 reports a failed write instead of raising" do
    missing_dir =
      Path.join(System.tmp_dir!(), "no-such-dir-#{System.unique_integer([:positive])}")

    assert {:error, _} = Log.append(Path.join(missing_dir, "x.md"), "entry")
  end

  test "error_entry/2 records a run error as its own entry" do
    entry = IO.iodata_to_binary(Phod.Session.Log.error_entry("tool loop exceeded max rounds (25)"))

    assert entry =~ "### phod · "
    assert entry =~ "**run error:**"
    assert entry =~ "tool loop exceeded max rounds (25)"
  end
end
