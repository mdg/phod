defmodule Phod.Tool.RustcTest do
  use ExUnit.Case, async: true

  alias Phod.Tool
  import Phod.Tool.TestHelpers

  setup {Phod.Tool.TestHelpers, :setup_worktree}

  test "reports success for a file that compiles", %{root: root} do
    write(root, "ok.rs", "fn main() {\n    println!(\"hi\");\n}\n")

    assert {:ok, %{path: "ok.rs", success: true}} =
             Tool.run("rustc", root, %{"path" => "ok.rs"})
  end

  test "returns compiler diagnostics as a normal result when the file does not compile", %{
    root: root
  } do
    write(root, "bad.rs", "fn main() {\n    let x: u32 = \"not a number\";\n}\n")

    assert {:ok, %{path: "bad.rs", success: false, diagnostics: diagnostics}} =
             Tool.run("rustc", root, %{"path" => "bad.rs"})

    assert diagnostics =~ "error"
    assert diagnostics =~ "mismatched types"
  end

  test "errors when the path does not exist", %{root: root} do
    assert {:error, _} = Tool.run("rustc", root, %{"path" => "missing.rs"})
  end

  test "does not leave compiler output in the worktree", %{root: root} do
    write(root, "ok.rs", "fn main() {}\n")

    assert {:ok, %{success: true}} = Tool.run("rustc", root, %{"path" => "ok.rs"})
    assert Enum.sort(File.ls!(root)) == ["ok.rs"]
  end
end
