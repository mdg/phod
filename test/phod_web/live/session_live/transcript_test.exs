defmodule PhodWeb.SessionLive.TranscriptTest do
  use ExUnit.Case, async: true

  alias PhodWeb.SessionLive.Transcript

  @session "octocat/tree"

  describe "build/3" do
    test "renders plain user and assistant text messages" do
      messages = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]},
        %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "hello!"}]},
      ]

      assert Transcript.build(messages, %{}, @session) == [
               %{kind: :text, role: "user", label: "user", text: "hi"},
               %{kind: :text, role: "assistant", label: @session, text: "hello!"},
             ]
    end

    test "labels user messages with their sender's name" do
      messages = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]},
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "yo"}]},
      ]

      assert [
               %{kind: :text, role: "user", label: "Ada", text: "hi"},
               %{kind: :text, role: "user", label: "Grace", text: "yo"},
             ] = Transcript.build(messages, %{0 => "Ada", 1 => "Grace"}, @session)
    end

    test "pairs a tool_use block with its tool_result and decodes success JSON" do
      messages = [
        %{"role" => "user", "content" => [%{"type" => "text", "text" => "list files"}]},
        %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "tu_1",
              "name" => "list_files",
              "input" => %{"path" => "."},
            },
          ],
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "tu_1",
              "content" => Jason.encode!(%{"path" => ".", "entries" => []}),
            },
          ],
        },
        %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "empty dir"}]},
      ]

      assert [
               %{kind: :text, role: "user", label: "user", text: "list files"},
               %{kind: :tool_call, id: "tu_1", name: "list_files", result: result},
               %{kind: :text, role: "assistant", label: @session, text: "empty dir"},
             ] = Transcript.build(messages, %{}, @session)

      assert result == {:ok, %{"path" => ".", "entries" => []}}
    end

    test "surfaces tool_result errors as plain strings, not JSON-decoded" do
      messages = [
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "tool_use", "id" => "tu_1", "name" => "read_files", "input" => %{}},
          ],
        },
        %{
          "role" => "user",
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "tu_1",
              "content" => "\"nope.txt\" does not exist",
              "is_error" => true,
            },
          ],
        },
      ]

      assert [%{kind: :tool_call, result: {:error, "\"nope.txt\" does not exist"}}] =
               Transcript.build(messages, %{}, @session)
    end

    test "a tool_use block with no matching tool_result yet is :pending" do
      messages = [
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "tool_use", "id" => "tu_1", "name" => "grep", "input" => %{}},
          ],
        },
      ]

      assert [%{kind: :tool_call, result: :pending}] =
               Transcript.build(messages, %{}, @session)
    end
  end

  describe "advance_edit_marker/4" do
    test "advances on the idle -> running rising edge" do
      edits = [%{path: "a.ex"}, %{path: "b.ex"}]
      assert Transcript.advance_edit_marker(:idle, :running, 0, edits) == 2
    end

    test "holds steady on any other transition" do
      edits = [%{path: "a.ex"}]
      assert Transcript.advance_edit_marker(:running, :idle, 1, edits) == 1
      assert Transcript.advance_edit_marker(:running, :running, 1, edits) == 1
      assert Transcript.advance_edit_marker(:idle, :idle, 0, edits) == 0
    end
  end

  describe "recent_edit_paths/2" do
    test "returns distinct paths edited at or after the marker" do
      edits = [%{path: "a.ex"}, %{path: "b.ex"}, %{path: "a.ex"}]
      assert Transcript.recent_edit_paths(edits, 1) == ["b.ex", "a.ex"]
      assert Transcript.recent_edit_paths(edits, 0) == ["a.ex", "b.ex"]
    end
  end

  describe "tool call goals" do
    test "a tool call's goal is a phod message directly above the call" do
      messages = [
        %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "tu_1",
              "name" => "grep",
              "input" => %{"goal" => "find the route", "patterns" => ["nfl"]},
            },
          ],
        },
      ]

      assert [
               %{kind: :text, role: "phod", label: @session, text: "find the route"},
               %{kind: :tool_call, id: "tu_1", name: "grep"},
             ] = Transcript.build(messages, %{}, @session)
    end

    test "a tool call without a goal shows only the call" do
      messages = [
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "tool_use", "id" => "tu_1", "name" => "grep", "input" => %{}},
          ],
        },
      ]

      assert [%{kind: :tool_call}] = Transcript.build(messages, %{}, @session)
    end
  end
end
