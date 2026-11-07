defmodule Phod.Tool.ListFiles do
  @moduledoc false

  alias Phod.Tool

  @behaviour Tool.B

  @ignored_names [".git", ".", ".."]

  @impl Tool.B
  def name, do: "list_files"

  @impl Tool.B
  def description,
    do: """
    List the contents of a directory in the worktree. Returns a list of \
    entries, each with `name`, `type` (`"file"`, `"dir"`, or `"symlink"`), \
    `num_bytes`, `mime_type`, and `charset`. Set `all` to `true` to also \
    include hidden (dot) files. Use this to explore the project structure. \
    Paths are relative to the worktree root; defaults to the root. \
    Does not recurse — call it again on subdirectories.\
    """

  @impl Tool.B
  def params() do
    [
      Tool.Input.path(),
      Tool.Input.bool("all", "Include hidden (dot) files"),
    ]
  end

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" =>
            "Directory path relative to the worktree root. Defaults to the root (\".\") when omitted."
        },
        "all" => %{
          "type" => "boolean",
          "description" => "Include hidden (dot) files. Defaults to false."
        }
      },
      "required" => []
    }
  end

  @impl Tool.B
  def run(%{path: path, all: all}, %{session_root: root}) do
    full_path = Path.join(root, path)
    args = ["-lF"] ++ if(all, do: ["-A"], else: []) ++ [full_path]

    case Rambo.run("ls", args, log: false) do
      {:ok, %Rambo{out: output}} ->
        entries =
          output
          |> parse_ls()
          |> attach_mime_types(full_path)

        {:ok, %{path: path, entries: entries}}

      {:error, %Rambo{status: status, out: out, err: err}} ->
        {:error, "could not list #{inspect(path)}: #{status} #{String.trim(out <> err)}"}

      {:error, reason} ->
        {:error, "could not list #{inspect(path)}: #{reason}"}
    end
  end

  @doc """
  Parses `ls -lF` output into `name`/`type`/`num_bytes` entries (no
  `mime_type` yet — see `attach_mime_types/2`), dropping `.git`, `.`, and
  `..`.
  """
  @spec parse_ls(String.t()) :: [
          %{name: String.t(), type: String.t(), num_bytes: non_neg_integer()}
        ]
  def parse_ls(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&(is_nil(&1) or &1.name in @ignored_names))
  end

  @doc """
  Parses one line of `ls -lF` output into a `name`/`type`/`num_bytes` map,
  or `nil` if the line doesn't look like a listing row (e.g. the `total N`
  header). `type` is `"file"`, `"dir"`, or `"symlink"`, read from the
  permission bits (the first character of the line) rather than the `-F`
  suffix, since `-F` marks a symlink's *target*, not the link itself (e.g.
  `link -> target/` for a symlink to a directory).
  """
  @spec parse_line(String.t()) ::
          %{name: String.t(), type: String.t(), num_bytes: non_neg_integer()} | nil
  def parse_line(line) do
    case String.split(line, ~r/\s+/, trim: true, parts: 9) do
      [perms, _links, _owner, _group, size, _month, _day, _time, rest] ->
        case Integer.parse(size) do
          {num_bytes, ""} ->
            type = type_from_perms(perms)
            %{name: name_from_rest(rest, type), type: type, num_bytes: num_bytes}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp type_from_perms("d" <> _), do: "dir"
  defp type_from_perms("l" <> _), do: "symlink"
  defp type_from_perms(_), do: "file"

  defp name_from_rest(rest, "symlink") do
    rest |> String.split(" -> ", parts: 2) |> List.first()
  end

  defp name_from_rest(rest, "dir"), do: String.trim_trailing(rest, "/")

  defp name_from_rest(rest, "file") do
    if String.ends_with?(rest, ["*", "@", "=", "|"]) do
      String.slice(rest, 0..-2//1)
    else
      rest
    end
  end

  @default_mime_info %{mime_type: "application/octet-stream", charset: nil}

  @doc """
  Adds `mime_type` and `charset` to each entry by batching all of them into
  a single `file -i -f -` call (one call for every entry, instead of one
  call per entry), resolving names against `dir_abs`.
  """
  @spec attach_mime_types([map()], String.t()) :: [map()]
  def attach_mime_types([], _dir_abs), do: []

  def attach_mime_types(entries, dir_abs) do
    mime_by_name = fetch_mime_types(entries, dir_abs)

    Enum.map(entries, fn entry ->
      Map.get(mime_by_name, entry.name, @default_mime_info)
      |> Map.merge(entry)
    end)
  end

  # `System.cmd/3` has no option to pipe data to a command's stdin;
  # `Rambo.run/3`'s `:in` option does, so the file list goes straight to
  # `file -i -f -`'s stdin with no temp file involved.
  defp fetch_mime_types(entries, dir_abs) do
    input = entries |> Enum.map(&Path.join(dir_abs, &1.name)) |> Enum.join("\n")

    case Rambo.run("file", ["-i", "-f", "-"], in: input <> "\n", log: false) do
      {:ok, %Rambo{out: output}} -> parse_mime_output(output, dir_abs)
      _ -> %{}
    end
  end

  defp parse_mime_output(output, dir_abs) do
    output
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, ":", parts: 2) do
        [path, info] -> {Path.relative_to(String.trim(path), dir_abs), parse_mime_info(info)}
        _ -> {line, @default_mime_info}
      end
    end)
  end

  @doc """
  Extracts the mime type and charset from `file -i`'s
  `<mime_type>; charset=<charset>` output for one entry. `charset` is `nil`
  if no `charset=` segment is present.
  """
  @spec parse_mime_info(String.t()) :: %{mime_type: String.t(), charset: String.t() | nil}
  def parse_mime_info(info) do
    [mime_type | rest] = info |> String.split(";") |> Enum.map(&String.trim/1)
    %{mime_type: mime_type, charset: find_charset(rest)}
  end

  defp find_charset(segments) do
    Enum.find_value(segments, fn segment ->
      case String.split(segment, "charset=", parts: 2) do
        [_, charset] -> charset
        _ -> nil
      end
    end)
  end
end
