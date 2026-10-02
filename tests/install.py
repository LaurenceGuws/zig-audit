#!/usr/bin/env python3
"""Black-box package/install/update/rollback proof for zig-audit."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parents[1]


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


def receipt(manifest: dict, artifact: Path) -> dict:
    archive = manifest["archive"]
    assert archive["size"] == artifact.stat().st_size
    assert archive["sha256"] == hashlib.sha256(artifact.read_bytes()).hexdigest()
    return {
        "schema": "release-pm.stage/v1",
        "package": manifest["package"],
        "version": manifest["version"],
        "target": manifest["target"],
        "release_id": manifest["release_id"],
        "manifest_sha256": "11" * 32,
        "size": archive["size"],
        "sha256": archive["sha256"],
        "signature_namespace": "trove-release-consumer-v1",
        "trusted_key_fingerprint": "SHA256:fixture",
        "artifact": "payload",
        "manifest": "manifest.json",
        "activation": "not-performed",
        "freshness": "explicit-selection-only; no anti-rollback",
    }


def build_package(scratch: Path, version: str) -> tuple[Path, Path]:
    binary = scratch / f"zig-audit-{version}"
    fake_binary(binary, version, 3)
    out = scratch / f"package-{version}"
    result = run(
        [REPO / "tools/package", "--binary", binary, "--target", "x86_64-linux", "--output", out],
        cwd=REPO,
    )
    build = json.loads(result.stdout)
    artifact = Path(build["artifact"])
    manifest_path = Path(build["manifest"])
    manifest = json.loads(manifest_path.read_text())
    receipt_path = scratch / f"receipt-{version}.json"
    receipt_path.write_text(json.dumps(receipt(manifest, artifact), sort_keys=True) + "\n")
    return artifact, receipt_path


def identity(binary: Path) -> dict:
    result = run([binary, "--version"], cwd=binary.parent)
    assert result.stderr == ""
    return json.loads(result.stdout)


def main() -> None:
    assert len(sys.argv) == 1
    cache = REPO / ".zig-cache"
    cache.mkdir(exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="install-contract-", dir=cache))
    try:
        prefix = scratch / "prefix"
        first_artifact, first_receipt = build_package(scratch, "0.4.0")
        second_artifact, second_receipt = build_package(scratch, "0.4.1")

        missing_status = run(
            [REPO / "install", "--status", "--prefix", scratch / "missing-prefix"],
            cwd=REPO,
            expected=1,
        )
        assert json.loads(missing_status.stderr)["error"]["code"] == "PrefixUnavailable"
        assert not (scratch / "missing-prefix").exists()

        first = run(
            [REPO / "install", "--artifact", first_artifact, "--receipt", first_receipt, "--prefix", prefix],
            cwd=REPO,
        )
        first_result = json.loads(first.stdout)
        assert first.stderr == ""
        assert first_result["operation"] == "install"
        assert first_result["version"] == "0.4.0"
        assert first_result["previous"] is None
        assert identity(prefix / "bin/zig-audit")["version"] == "0.4.0"

        second = run(
            [REPO / "install", "--artifact", second_artifact, "--receipt", second_receipt, "--prefix", prefix],
            cwd=REPO,
        )
        second_result = json.loads(second.stdout)
        assert second_result["version"] == "0.4.1"
        assert second_result["previous"] == "releases/0.4.0"
        assert identity(prefix / "bin/zig-audit")["version"] == "0.4.1"

        status = json.loads(run([REPO / "install", "--status", "--prefix", prefix], cwd=REPO).stdout)
        assert status["active"] == "releases/0.4.1"
        assert status["previous"] == "releases/0.4.0"
        assert status["releases"] == ["0.4.0", "0.4.1"]

        rollback = json.loads(run([REPO / "install", "--rollback", "--prefix", prefix], cwd=REPO).stdout)
        assert rollback["version"] == "0.4.0"
        assert rollback["active"] == "releases/0.4.0"
        assert rollback["previous"] == "releases/0.4.1"
        assert identity(prefix / "bin/zig-audit")["version"] == "0.4.0"

        # Rollback is a swap, so a second rollback returns to the newer retained release.
        rollback_again = json.loads(run([REPO / "install", "--rollback", "--prefix", prefix], cwd=REPO).stdout)
        assert rollback_again["version"] == "0.4.1"
        assert identity(prefix / "bin/zig-audit")["version"] == "0.4.1"

        # Existing release trees are immutable from the installer's perspective.
        repeated = run(
            [REPO / "install", "--artifact", first_artifact, "--receipt", first_receipt, "--prefix", prefix],
            cwd=REPO,
            expected=1,
        )
        repeated_error = json.loads(repeated.stderr)
        assert repeated.stdout == ""
        assert repeated_error["error"]["code"] == "ReleaseExists"

        tampered = scratch / "tampered.tar.xz"
        shutil.copy2(second_artifact, tampered)
        with tampered.open("ab") as stream:
            stream.write(b"x")
        tampered_result = run(
            [REPO / "install", "--artifact", tampered, "--receipt", second_receipt, "--prefix", scratch / "tampered-prefix"],
            cwd=REPO,
            expected=1,
        )
        assert json.loads(tampered_result.stderr)["error"]["code"] == "ArtifactMismatch"

        assert (prefix / "releases/0.4.0/release-pm-receipt.json").is_file()
        assert (prefix / "releases/0.4.1/release-pm-receipt.json").is_file()
        print("PASS zig-audit package/install lifecycle")
    finally:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    main()
