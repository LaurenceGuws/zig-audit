#!/usr/bin/env python3
"""Black-box source-pinned artifact install/update/rollback proof for zig-audit."""

from __future__ import annotations

import hashlib
import io
import importlib.util
import importlib.machinery
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
import tarfile
import sys
import tempfile
from unittest import mock


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


def test_install() -> None:
    assert len(sys.argv) == 1
    cache = REPO / ".zig-cache"
    cache.mkdir(exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="flat-install-", dir=cache))
    try:
        revision = "3" * 40
        first_artifact, first_digest, first_size = build_package(scratch, "0.4.0", revision)
        second_artifact, second_digest, second_size = build_package(scratch, "0.4.2", revision)
        first_prefix = scratch / "prefix"

        missing_status = run([REPO / "install", "--status", "--prefix", scratch / "missing-prefix"], cwd=REPO, expected=1)
        assert json.loads(missing_status.stderr)["error"]["code"] == "PrefixUnavailable"
        assert not (scratch / "missing-prefix").exists()

        first = json.loads(run(selection(first_artifact, revision, first_digest, first_size, first_prefix), cwd=REPO).stdout)
        assert first["version"] == "0.4.0" and first["previous"] is None
        stable = first_prefix / "bin/zig-audit"
        data = first_prefix / "share/zig-audit"
        assert stable.is_file() and not stable.is_symlink()
        assert identity(stable)["version"] == "0.4.0"
        assert (data / "installed.json").is_file()
        assert not (first_prefix / "releases").exists()
        assert not (data / "previous").exists()

        second = json.loads(run(selection(second_artifact, revision, second_digest, second_size, first_prefix), cwd=REPO).stdout)
        assert second["version"] == "0.4.2"
        assert second["previous"] == str(data / "previous/zig-audit")
        assert identity(stable)["version"] == "0.4.2"
        old_bin = data / "previous/zig-audit"
        assert old_bin.is_file() and not old_bin.is_symlink()
        assert identity(old_bin)["version"] == "0.4.0"
        status = json.loads(run([REPO / "install", "--status", "--prefix", first_prefix], cwd=REPO).stdout)
        assert status["active"] == "0.4.2" and status["previous"] == "0.4.0"
        assert not (first_prefix / "current").exists()
        assert not (first_prefix / "releases").exists()
        assert not (data / ".transition").exists()

        rolled = json.loads(run([REPO / "install", "--rollback", "--prefix", first_prefix], cwd=REPO).stdout)
        assert rolled["version"] == "0.4.0"
        assert identity(stable)["version"] == "0.4.0"
        assert identity(old_bin)["version"] == "0.4.2"
        rolled_forward = json.loads(run([REPO / "install", "--rollback", "--prefix", first_prefix], cwd=REPO).stdout)
        assert rolled_forward["version"] == "0.4.2"
        assert identity(old_bin)["version"] == "0.4.0"
        error_code(selection(second_artifact, revision, second_digest, second_size, first_prefix), "ReleaseExists")

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
        # Rehashing a malformed package to satisfy the outer selection
        # must still fail the exact inventory and embedded binary gates.
        foreign_package = scratch / "extra-member.tar.xz"
        bad_internal = scratch / "bad-internal-hash.tar.xz"
        with tarfile.open(second_artifact, "r:xz") as source:
            members = [(item, source.extractfile(item).read()) for item in source.getmembers()]
        for forged, tamper_bin in ((foreign_package, False), (bad_internal, True)):
            with tarfile.open(forged, "w:xz") as target_archive:
                for item, payload in members:
                    if tamper_bin and item.name == "bin/zig-audit":
                        payload += b"# changed binary bytes\\n"
                    item_copy = tarfile.TarInfo(item.name)
                    item_copy.mode, item_copy.size = item.mode, len(payload)
                    target_archive.addfile(item_copy, io.BytesIO(payload))
                if not tamper_bin:
                    item_copy = tarfile.TarInfo("FOREIGN")
                    item_copy.size = 4
                    target_archive.addfile(item_copy, io.BytesIO(b"NOPE"))
            error_code(selection(
                forged, revision, hashlib.sha256(forged.read_bytes()).hexdigest(),
                forged.stat().st_size, scratch / f"rejected-{forged.stem}",
            ), "InvalidPackage")
        other_artifact, other_digest, other_size = build_package(scratch, "0.4.3", revision, OTHER_TARGET)
        error_code(selection(other_artifact, revision, other_digest, other_size, scratch / "wrong-target"), "WrongTarget")
        no_pins = run([REPO / "install", "--promote-artifact", second_artifact, "--prefix", scratch / "no-pins"], cwd=REPO, expected=1)
        assert json.loads(no_pins.stderr)["error"]["code"] == "Arguments"
        assert not (scratch / "no-pins").exists()
        obsolete = run([REPO / "install", "--artifact", second_artifact, "--receipt", second_artifact, "--prefix", scratch / "obsolete"], cwd=REPO, expected=2)
        assert obsolete.returncode == 2
        assert not (scratch / "obsolete").exists()

        occupied = scratch / "occupied"
        (occupied / "bin").mkdir(parents=True)
        fake_binary(occupied / "bin/zig-audit", "0.0.1", 1)
        error_code(selection(second_artifact, revision, second_digest, second_size, occupied), "InvalidLegacyInstall")
        assert identity(occupied / "bin/zig-audit")["version"] == "0.0.1"

        # Live Fleet legacy: an unrecorded regular 0.4.1 cutover is not
        # sufficient provenance; the old digest is independently pinned.
        source_prefix = scratch / "source-cutover"
        (source_prefix / "bin").mkdir(parents=True)
        source_binary = source_prefix / "bin/zig-audit"
        fake_binary(source_binary, "0.4.1", 3)
        source_sha = hashlib.sha256(source_binary.read_bytes()).hexdigest()
        selection_args = selection(second_artifact, revision, second_digest, second_size, source_prefix)
        error_code(selection_args, "AdoptionRequired")
        error_code(selection_args + ["--adopt-current-sha256", "a" * 64], "ExistingBinaryMismatch")
        source_status = json.loads(run([REPO / "install", "--status", "--prefix", source_prefix], cwd=REPO).stdout)
        assert source_status["adoption_required"] and source_status["observed_sha256"] == source_sha
        adopted = json.loads(run(selection_args + ["--adopt-current-sha256", source_sha], cwd=REPO).stdout)
        assert adopted["version"] == "0.4.2" and not source_binary.is_symlink()
        assert identity(source_prefix / "share/zig-audit/previous/zig-audit")["version"] == "0.4.1"
        run([REPO / "install", "--rollback", "--prefix", source_prefix], cwd=REPO)
        assert identity(source_binary)["version"] == "0.4.1"
        run([REPO / "install", "--rollback", "--prefix", source_prefix], cwd=REPO)
        assert identity(source_binary)["version"] == "0.4.2"

        old_prefix = scratch / "historical"
        history = historical_release(old_prefix)
        old_binary = old_prefix / "releases/0.4.1/bin/zig-audit"
        pinned_old_sha = hashlib.sha256(old_binary.read_bytes()).hexdigest()
        legacy_selection = selection(second_artifact, revision, second_digest, second_size, old_prefix)
        error_code(legacy_selection, "AdoptionRequired")
        newer = json.loads(run(legacy_selection + ["--adopt-current-sha256", pinned_old_sha], cwd=REPO).stdout)
        assert newer["version"] == "0.4.2"
        assert history.exists() is False
        assert not (old_prefix / "releases").exists()
        assert not (old_prefix / "current").exists()
        assert not (old_prefix / "previous").exists()
        assert identity(old_prefix / "share/zig-audit/previous/zig-audit")["version"] == "0.4.1"
        assert not (old_prefix / "bin/zig-audit").is_symlink()
        run([REPO / "install", "--rollback", "--prefix", old_prefix], cwd=REPO)
        assert identity(old_prefix / "bin/zig-audit")["version"] == "0.4.1"

        # Faults around the PATH rename must not masquerade as safe failures.
        loader = importlib.machinery.SourceFileLoader("zig_audit_release", str(REPO / "install"))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        fail_before = scratch / "fail-before"
        historical_release(fail_before)
        old_sha = hashlib.sha256((fail_before / "releases/0.4.1/bin/zig-audit").read_bytes()).hexdigest()
        original_replace = module.os.replace
        def reject_activation(source: Path, destination: Path) -> None:
            if Path(destination) == fail_before / "bin/zig-audit":
                raise OSError("injected rename failure")
            original_replace(source, destination)
        with mock.patch.object(module.os, "replace", side_effect=reject_activation):
            try:
                module.install_release(second_artifact, revision, second_digest, second_size, fail_before, old_sha)
                raise AssertionError("expected fault")
            except OSError as exc:
                assert "injected" in str(exc)
        assert (fail_before / "bin/zig-audit").is_symlink()
        assert module.status(fail_before)["adoption_required"]
        assert not (fail_before / "share/zig-audit/.transition").exists()

        fail_after = scratch / "fail-after"
        historical_release(fail_after)
        old_sha = hashlib.sha256((fail_after / "releases/0.4.1/bin/zig-audit").read_bytes()).hexdigest()
        with mock.patch.object(module, "remove_legacy_release_tree", side_effect=OSError("injected cleanup failure")):
            try:
                module.install_release(second_artifact, revision, second_digest, second_size, fail_after, old_sha)
                raise AssertionError("expected fault")
            except module.InstallError as exc:
                assert exc.code == "ActivationIncomplete"
        assert identity(fail_after / "bin/zig-audit")["version"] == "0.4.2"
        assert module.status(fail_after)["previous"] == "0.4.1"
        assert not (fail_after / "share/zig-audit/.transition").exists()
        assert not (fail_after / "releases").exists()

        print("PASS zig-audit fixed-path, selected artifact, source/legacy adoption, recovery and rollback")
    finally:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    test_install()
