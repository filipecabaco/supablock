defmodule Supablock.InstallScriptTest do
  @moduledoc """
  Exercises `docs/install.sh` — the script users pipe into `sh` — against a
  fake release served by a stub `curl` on PATH. Nothing here touches the
  network.

  The point of these tests is the integrity check: a mismatch must abort
  *before* the binary is made executable, and a release with no checksums
  must refuse rather than install blind.

  Intel macOS is not covered: the script rejects it outright (no prebuilt
  asset), and the project ships no such binary.
  """
  use ExUnit.Case, async: true

  @script "docs/install.sh"

  # Every asset the script may pick, so the fake release works on any runner.
  @assets ["supablock-linux-x86_64", "supablock-linux-aarch64", "supablock-macos-aarch64"]

  setup do
    base = Path.join(System.tmp_dir!(), "supablock-install-#{System.unique_integer([:positive])}")
    release = Path.join(base, "release")
    bin = Path.join(base, "bin")
    File.mkdir_p!(release)
    File.mkdir_p!(bin)

    bodies = Map.new(@assets, &{&1, "#!/bin/sh\necho #{&1}\n"})
    Enum.each(bodies, fn {name, body} -> File.write!(Path.join(release, name), body) end)

    curl = Path.join(bin, "curl")
    File.write!(curl, fake_curl())
    File.chmod!(curl, 0o755)

    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, base: base, release: release, bin: bin, bodies: bodies}
  end

  # Resolves a release URL to a file in the fake release dir. Exit 22 is what
  # `curl -f` gives on a 404, which is what the script branches on.
  defp fake_curl do
    """
    #!/bin/sh
    url=""; out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) out="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
      esac
    done
    src="$FAKE_RELEASE/${url##*/}"
    [ -f "$src" ] || exit 22
    if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
    """
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp write_sums!(release, bodies, overrides \\ %{}) do
    lines =
      bodies
      |> Enum.sort_by(fn {name, _body} -> name end)
      |> Enum.map_join("", fn {name, body} ->
        "#{Map.get(overrides, name, sha256(body))}  #{name}\n"
      end)

    File.write!(Path.join(release, "SHA256SUMS"), lines)
  end

  defp run(ctx, overrides \\ %{}) do
    install_dir = Path.join(ctx.base, "target")

    env =
      %{
        "PATH" => ctx.bin <> ":" <> System.get_env("PATH"),
        "FAKE_RELEASE" => ctx.release,
        "SUPABLOCK_INSTALL_DIR" => install_dir,
        "HOME" => ctx.base,
        # Cleared so a developer's own environment cannot change the outcome.
        "SUPABLOCK_VERSION" => nil,
        "SUPABLOCK_SHA256" => nil,
        "SUPABLOCK_SKIP_VERIFY" => nil
      }
      |> Map.merge(overrides)
      |> Map.to_list()

    {out, status} = System.cmd("sh", [@script], env: env, stderr_to_stdout: true)
    {out, status, Path.join(install_dir, "supablock")}
  end

  # Which asset this machine's uname resolves to, so assertions can compare
  # the installed bytes against the right fake binary.
  defp expected_asset do
    os = if match?({:unix, :darwin}, :os.type()), do: "macos", else: "linux"
    {machine, 0} = System.cmd("uname", ["-m"])

    arch =
      case String.trim(machine) do
        m when m in ["x86_64", "amd64"] -> "x86_64"
        m when m in ["aarch64", "arm64"] -> "aarch64"
        other -> other
      end

    "supablock-#{os}-#{arch}"
  end

  test "a matching SHA256SUMS installs the binary, executable", ctx do
    write_sums!(ctx.release, ctx.bodies)

    {out, status, installed} = run(ctx)

    assert status == 0, out
    assert out =~ "verified against SHA256SUMS"
    assert File.read!(installed) == ctx.bodies[expected_asset()]
    assert Bitwise.band(File.stat!(installed).mode, 0o777) == 0o755
  end

  test "a tampered binary aborts before anything is installed", ctx do
    tampered = String.duplicate("0", 64)
    write_sums!(ctx.release, ctx.bodies, %{expected_asset() => tampered})

    {out, status, installed} = run(ctx)

    assert status != 0
    assert out =~ "checksum mismatch"
    assert out =~ tampered
    refute File.exists?(installed), "a mismatched download must never be installed"
  end

  test "a release with no SHA256SUMS refuses rather than installing blind", ctx do
    {out, status, installed} = run(ctx)

    assert status != 0
    assert out =~ "could not fetch SHA256SUMS"
    assert out =~ "SUPABLOCK_SKIP_VERIFY=1"
    refute File.exists?(installed)
  end

  test "an asset absent from SHA256SUMS is refused", ctx do
    write_sums!(ctx.release, Map.drop(ctx.bodies, [expected_asset()]))

    {out, status, installed} = run(ctx)

    assert status != 0
    assert out =~ "not listed in"
    refute File.exists?(installed)
  end

  test "SUPABLOCK_SKIP_VERIFY=1 installs unverified but says so", ctx do
    {out, status, installed} = run(ctx, %{"SUPABLOCK_SKIP_VERIFY" => "1"})

    assert status == 0, out
    assert out =~ "skipping checksum verification"
    assert File.exists?(installed)
  end

  test "SUPABLOCK_SHA256 pins a digest without fetching SHA256SUMS", ctx do
    # No SHA256SUMS in this release at all: the pin must be self-sufficient.
    digest = sha256(ctx.bodies[expected_asset()])

    {out, status, installed} = run(ctx, %{"SUPABLOCK_SHA256" => digest})

    assert status == 0, out
    assert out =~ "verified against SUPABLOCK_SHA256"
    assert File.exists?(installed)
  end

  test "a wrong SUPABLOCK_SHA256 pin aborts", ctx do
    write_sums!(ctx.release, ctx.bodies)

    {out, status, installed} = run(ctx, %{"SUPABLOCK_SHA256" => String.duplicate("f", 64)})

    assert status != 0
    assert out =~ "checksum mismatch"

    refute File.exists?(installed),
           "an explicit pin must win over a SHA256SUMS the release also serves"
  end

  test "the resolved digest is printed so a user can compare it", ctx do
    write_sums!(ctx.release, ctx.bodies)

    {out, 0, _installed} = run(ctx)

    assert out =~ "sha256 #{sha256(ctx.bodies[expected_asset()])}"
  end

  test "provenance verification is advertised after install", ctx do
    write_sums!(ctx.release, ctx.bodies)

    {out, 0, _installed} = run(ctx)

    assert out =~ "gh attestation verify"
    assert out =~ "--repo filipecabaco/supablock"
  end
end
