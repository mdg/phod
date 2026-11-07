defmodule Phod.Tool.Input.ValidateParamsTest do
  use ExUnit.Case, async: true

  alias Phod.Tool.Input

  @session %{session_root: "/unused"}

  defp params do
    [
      Input.string(:script, "Elixir source", required: true),
      Input.bool(:verbose, "Verbose output")
    ]
  end

  test "passes each LLM value to its type, keyed by param name" do
    llm = %{"script" => "IO.puts(1)", "verbose" => true}

    assert {:ok, %{script: "IO.puts(1)", verbose: true}} =
             Input.validate_params(llm, params(), @session)
  end

  test "an omitted optional param comes back as nil" do
    llm = %{"script" => "IO.puts(1)"}

    assert {:ok, %{script: "IO.puts(1)", verbose: nil}} =
             Input.validate_params(llm, params(), @session)
  end

  test "an omitted required param is an error" do
    assert {:error, "script is required"} =
             Input.validate_params(%{"verbose" => true}, params(), @session)
  end

  test "a value the type rejects is an error" do
    assert {:error, "script: invalid empty string"} =
             Input.validate_params(%{"script" => "  "}, params(), @session)

    assert {:error, msg} =
             Input.validate_params(%{"script" => "ok", "verbose" => "yes"}, params(), @session)

    assert msg =~ "invalid boolean"
  end
end
