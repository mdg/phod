defmodule Phod.Tool.Patch.HunksTest do
  use ExUnit.Case, async: true

  alias Phod.Tool.Patch.Hunks

  describe "parse/1" do
    test "reads the hunks and ignores headers and envelope lines" do
      diff = "*** Begin Patch\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n*** End Patch\n"

      assert {:ok, [%{index: 0, old: ["one", "two"], new: ["one", "TWO"]}]} =
               Hunks.parse(diff)
    end

    test "a bare @@ has no line index" do
      assert {:ok, [%{index: nil}]} = Hunks.parse("@@\n-a\n+b\n")
    end

    test "a pure insertion is indexed after the line in its header" do
      assert {:ok, [%{index: 2, old: [], new: ["x"]}]} = Hunks.parse("@@ -2,0 +3 @@\n+x\n")
    end

    test "a line without a diff prefix is read as context" do
      assert {:ok, [%{old: ["one", "two"], new: ["one", "TWO"]}]} =
               Hunks.parse("@@\none\n-two\n+TWO\n")
    end

    test "a blank context line is kept, but blank lines at the end are dropped" do
      assert {:ok, [%{old: ["a", "", "b"], new: ["a", "", "B"]}]} =
               Hunks.parse("@@\n a\n\n-b\n+B\n\n")
    end

    test "a diff with no @@ line is an error" do
      assert {:error, "no hunks found" <> _} = Hunks.parse("--- a/f\n+++ b/f\n")
    end
  end

  describe "apply_hunks/2" do
    test "applies a hunk without using its line number" do
      {:ok, hunks} = Hunks.parse("@@ -50,2 +50,2 @@\n one\n-two\n+TWO\n")

      assert Hunks.apply_hunks("zero\none\ntwo\n", hunks) == {:ok, "zero\none\nTWO\n"}
    end

    test "when text occurs twice, the match nearest the header line wins" do
      content = "x\nfoo\ny\nfoo\nz\n"
      {:ok, hunks} = Hunks.parse("@@ -4,1 +4,1 @@\n-foo\n+bar\n")

      assert Hunks.apply_hunks(content, hunks) == {:ok, "x\nfoo\ny\nbar\nz\n"}
    end

    test "an insertion goes at its header line" do
      {:ok, hunks} = Hunks.parse("@@ -1,0 +2 @@\n+new\n")

      assert Hunks.apply_hunks("a\nb\n", hunks) == {:ok, "a\nnew\nb\n"}
    end

    test "an insertion into an empty file creates its content" do
      {:ok, hunks} = Hunks.parse("@@ -0,0 +1 @@\n+hi\n")

      assert Hunks.apply_hunks("", hunks) == {:ok, "hi\n"}
    end

    test "hunks apply in order, each after the previous one" do
      content = "a\nb\na\nb\n"

      {:ok, hunks} =
        Hunks.parse("@@\n-a\n+A\n@@\n-a\n+AA\n")

      assert Hunks.apply_hunks(content, hunks) == {:ok, "A\nb\nAA\nb\n"}
    end

    test "matches when only the indentation differs" do
      {:ok, hunks} = Hunks.parse("@@\n-  two\n+TWO\n")

      assert Hunks.apply_hunks("one\n\ttwo\n", hunks) == {:ok, "one\nTWO\n"}
    end

    test "keeps a missing final newline missing" do
      {:ok, hunks} = Hunks.parse("@@\n-b\n+B\n")

      assert Hunks.apply_hunks("a\nb", hunks) == {:ok, "a\nB"}
    end

    test "reports the hunk whose context is missing, changing nothing" do
      {:ok, hunks} = Hunks.parse("@@\n-a\n+A\n@@\n-zzz\n+Z\n")

      assert {:error, msg} = Hunks.apply_hunks("a\nb\n", hunks)
      assert msg =~ "hunk 2 could not find its context"
    end
  end
end
