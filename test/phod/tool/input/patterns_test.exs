defmodule Phod.Tool.Input.PatternsTest do
  use ExUnit.Case, async: true

  alias Phod.Tool.Input.Patterns

  test "name, schema type and item type" do
    assert Patterns.name() == :patterns
    assert Patterns.schema_type() == "array"
    assert Patterns.item_type() == "string"
    assert is_binary(Patterns.desc())
  end

  test "accepts a list of valid regular expressions" do
    patterns = ["foo", "^bar$", "\\d+", "[a-z]{2,}"]

    assert {:ok, ^patterns} = Patterns.validate(patterns, %{})
  end

  test "rejects an empty list" do
    assert {:error, "invalid empty patterns"} = Patterns.validate([], %{})
  end

  test "rejects a non-list" do
    assert {:error, "invalid patterns"} = Patterns.validate("foo", %{})
  end

  test "rejects empty or non-string entries" do
    assert {:error, "invalid empty pattern"} = Patterns.validate(["foo", ""], %{})
    assert {:error, "invalid pattern"} = Patterns.validate(["foo", 1], %{})
  end

  test "rejects an entry that is not a valid regular expression" do
    assert {:error, msg} = Patterns.validate(["ok", "(unclosed"], %{})
    assert msg =~ "invalid regex \"(unclosed\""
  end

  test "reports the first invalid regular expression" do
    assert {:error, msg} = Patterns.validate(["[bad", "(also bad"], %{})
    assert msg =~ "[bad"
    refute msg =~ "(also bad"
  end
end
