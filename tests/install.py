#!/usr/bin/env python3
"""Black-box source-pinned artifact install/update/rollback proof for zig-audit."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
import sys
import tempfile


REPO = Path(__file__).resolve().parents[1]
TARGET = {"x86_64": "x86_64-linux", "aarch64": "aarch64-linux"}[os.uname().machine]
OTHER_TARGET = "aarch64-linux" if TARGET == "x86_64-linux" else "x86_64-linux"


def run(argv: list[str | Path], *, cwd: Path, expected: int = 0) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(item) for item in argv],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == expected, (argv, result.returncode, result.stdout, result.stderr)
    return result


def fake_binary(path: Path, version: str, ruleset: int) -> None:
    path.write_text(
        "#!/usr/bin/env python3\n"
        "import json,sys\n"
        f"identity={{'schema':'zig-audit.version/v1','version':'{version}','stable_ruleset':{ruleset}}}\n"
        "if len(sys.argv)==2 and sys.argv[1] in ('-v','--version'):\n"
        " print(json.dumps(identity,separators=(',',':')))\n"
        " raise SystemExit(0)\n"
        "raise SystemExit(2)\n"
    )
    path.chmod(0o700)


def build_package(scratch: Path, version: str, revision: str, target: str = TARGET) -> tuple[Path, str, int]:
    binary = scratch / f"zig-audit-{version}-{target}"
    fake_binary(binary, version, 3)
    arguments = []
    if target != TARGET:
        native_companion = scratch / f"native-companion-{version}-{target}"
        fake_binary(native_companion, version, 3)
        # A cross compiler's output cannot execute here; the target's installer
        # performs real version probes on its own CPU.
        machine = 183 if target == "aarch64-linux" else 62
        header = bytearray(20)
        header[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", header, 18, machine)
        binary.write_bytes(header)
        arguments = ["--identity-from", str(native_companion)]
    out = scratch / f"package-{version}-{target}"
    result = run(
        [REPO / "tools/package", "--binary", binary, "--target", target, "--revision", revision, *arguments, "--output", out],
        cwd=REPO,
    )
    build = json.loads(result.stdout)
    assert build["revision"] == revision
    artifact = Path(build["artifact"])
    manifest = json.loads(Path(build["manifest"]).read_text())
    assert manifest["schema"] == "zig-audit.artifact-manifest/v1"
    assert manifest["revision"] == revision
    assert manifest["archive"]["size"] == artifact.stat().st_size
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    assert manifest["archive"]["sha256"] == digest
    return artifact, digest, artifact.stat().st_size


def selection(artifact: Path, revision: str, digest: str, size: int, prefix: Path) -> list[str | Path]:
    return [
        REPO / "install", "--promote-artifact", artifact, "--revision", revision,
        "--sha256", digest, "--size", str(size), "--prefix", prefix,
    ]


def identity(binary: Path) -> dict:
    result = run([binary, "--version"], cwd=binary.parent)
    assert result.stderr == ""
    return json.loads(result.stdout)


def error_code(argv: list[str | Path], code: str) -> None:
    result = run(argv, cwd=REPO, expected=1)
    assert json.loads(result.stderr)["error"]["code"] == code, result.stderr


def historical_release(prefix: Path) -> Path:
    """Model a retained release tree from before Paste-bin promotion."""
    target = prefix / "releases/0.4.1"
    (target / "bin").mkdir(parents=True)
    fake_binary(target / "bin/zig-audit", "0.4.1", 3)
    (target / "package.json").write_text('{"schema":"zig-audit.package/v1","version":"0.4.1"}\n')
    old_receipt = target / "release-pm-receipt.json"
    old_receipt.write_text('{"schema":"release-pm.stage/v1","historical":true}\n')
    (prefix / "current").symlink_to("releases/0.4.1")
    (prefix / "bin").mkdir()
    (prefix / "bin/zig-audit").symlink_to("../current/bin/zig-audit")
    return old_receipt


def main() -> None:
    assert len(sys.argv) == 1
    cache = REPO / ".zig-cache"
    cache.mkdir(exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="artifact-contract-", dir=cache))
    try:
        prefix = scratch / "prefix"
        revision = "3" * 40
        first_artifact, first_digest, first_size = build_package(scratch, "0.4.0", revision)
        second_artifact, second_digest, second_size = build_package(scratch, "0.4.2", revision)

        missing_status = run(
            [REPO / "install", "--status", "--prefix", scratch / "missing-prefix"],
            cwd=REPO,
            expected=1,
        )
        assert json.loads(missing_status.stderr)["error"]["code"] == "PrefixUnavailable"
        assert not (scratch / "missing-prefix").exists()

        first = json.loads(run(selection(first_artifact, revision, first_digest, first_size, prefix), cwd=REPO).stdout)
        assert first["operation"] == "install"
        assert first["version"] == "0.4.0"
        assert first["revision"] == revision
        assert first["previous"] is None
        assert identity(prefix / "bin/zig-audit")["version"] == "0.4.0"
        receipt = json.loads((prefix / "releases/0.4.0/artifact.json").read_text())
        assert receipt == {
            "schema": "zig-audit.artifact/v1", "package": "zig-audit",
            "version": "0.4.0", "target": TARGET, "revision": revision,
            "sha256": first_digest, "size": first_size,
            "trust": "operator-pinned-source-build-not-signed",
        }
        assert not (prefix / "releases/0.4.0/release-pm-receipt.json").exists()

        second = json.loads(run(selection(second_artifact, revision, second_digest, second_size, prefix), cwd=REPO).stdout)
        assert second["version"] == "0.4.2"
        assert second["previous"] == "releases/0.4.0"
        assert identity(prefix / "bin/zig-audit")["version"] == "0.4.2"

        status = json.loads(run([REPO / "install", "--status", "--prefix", prefix], cwd=REPO).stdout)
        assert status["active"] == "releases/0.4.2"
        assert status["previous"] == "releases/0.4.0"
        assert status["releases"] == ["0.4.0", "0.4.2"]

        rollback = json.loads(run([REPO / "install", "--rollback", "--prefix", prefix], cwd=REPO).stdout)
        assert rollback["version"] == "0.4.0"
        assert rollback["active"] == "releases/0.4.0"
        assert rollback["previous"] == "releases/0.4.2"
        assert identity(prefix / "bin/zig-audit")["version"] == "0.4.0"

        rollback_again = json.loads(run([REPO / "install", "--rollback", "--prefix", prefix], cwd=REPO).stdout)
        assert rollback_again["version"] == "0.4.2"
        assert identity(prefix / "bin/zig-audit")["version"] == "0.4.2"

        error_code(selection(first_artifact, revision, first_digest, first_size, prefix), "ReleaseExists")
        tampered = scratch / "tampered.tar.xz"
        shutil.copy2(second_artifact, tampered)
        with tampered.open("ab") as stream:
            stream.write(b"x")
        error_code(selection(tampered, revision, second_digest, second_size, scratch / "tampered-prefix"), "ArtifactMismatch")
        assert not (scratch / "tampered-prefix").exists()
        error_code(selection(second_artifact, revision, "f" * 64, second_size, scratch / "wrong-hash"), "ArtifactMismatch")
        error_code(selection(second_artifact, revision, second_digest, second_size + 1, scratch / "wrong-size"), "ArtifactMismatch")
        error_code(selection(second_artifact, "4" * 40, second_digest, second_size, scratch / "wrong-revision"), "RevisionMismatch")
        error_code(selection(second_artifact, revision, "incorrect", second_size, scratch / "bad-pins"), "InvalidSelection")
        other_artifact, other_digest, other_size = build_package(scratch, "0.4.3", revision, OTHER_TARGET)
        error_code(selection(other_artifact, revision, other_digest, other_size, scratch / "wrong-target"), "WrongTarget")

        no_pins = run(
            [REPO / "install", "--promote-artifact", second_artifact, "--prefix", scratch / "no-pins"],
            cwd=REPO, expected=1,
        )
        assert json.loads(no_pins.stderr)["error"]["code"] == "Arguments"
        assert not (scratch / "no-pins").exists()

        obsolete = run(
            [REPO / "install", "--artifact", second_artifact, "--receipt", second_artifact, "--prefix", scratch / "obsolete"],
            cwd=REPO, expected=2,
        )
        assert obsolete.returncode == 2
        assert not (scratch / "obsolete").exists()

        occupied = scratch / "occupied"
        (occupied / "bin").mkdir(parents=True)
        fake_binary(occupied / "bin/zig-audit", "0.0.1", 1)
        error_code(selection(second_artifact, revision, second_digest, second_size, occupied), "InvalidState")
        assert identity(occupied / "bin/zig-audit")["version"] == "0.0.1"

        old_prefix = scratch / "historical"
        history = historical_release(old_prefix)
        prior_bytes = history.read_bytes()
        newer = json.loads(run(selection(second_artifact, revision, second_digest, second_size, old_prefix), cwd=REPO).stdout)
        assert newer["previous"] == "releases/0.4.1"
        assert history.read_bytes() == prior_bytes
        run([REPO / "install", "--rollback", "--prefix", old_prefix], cwd=REPO)
        assert identity(old_prefix / "bin/zig-audit")["version"] == "0.4.1"
        assert history.read_bytes() == prior_bytes

        print("PASS zig-audit pinned-artifact/install lifecycle and historical rollback")
    finally:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    main()
