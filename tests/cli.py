#!/usr/bin/env python3
"""Black-box contract tests for the zig-audit executable."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parents[1]


def run(executable: Path, args: list[str], *, cwd: Path, expected: int) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(executable), *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == expected, (
        args,
        result.returncode,
        result.stdout,
        result.stderr,
    )
    return result


def records(text: str) -> list[dict]:
    return [json.loads(line) for line in text.splitlines() if line]


def one_error(result: subprocess.CompletedProcess[str], code: str) -> dict:
    assert result.stdout == ""
    docs = records(result.stderr)
    assert len(docs) == 1, docs
    assert docs[0]["schema"] == "zig-audit.error/v1"
    assert docs[0]["ok"] is False
    assert docs[0]["error"]["code"] == code
    return docs[0]["error"]


def project(root: Path, source: str, *, schema: int = 2, baseline: str | None = None) -> Path:
    root.mkdir(parents=True)
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    (root / "src").mkdir()
    (root / "src/main.zig").write_text(source)
    config: dict[str, object] = {
        "schema": schema,
        "source": "git",
        "minimum_ruleset": 3,
        "include": ["src"],
    }
    if baseline is not None:
        config["baseline"] = baseline
    path = root / ".zig-audit.json"
    path.write_text(json.dumps(config) + "\n")
    return path


def main() -> None:
    assert len(sys.argv) == 2, "usage: cli.py /path/to/zig-audit"
    executable = Path(sys.argv[1]).resolve()
    assert executable.is_file()

    cache = REPO / ".zig-cache"
    cache.mkdir(exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="cli-contract-", dir=cache))
    try:
        bare = run(executable, [], cwd=REPO, expected=0)
        short_help = run(executable, ["-h"], cwd=REPO, expected=0)
        long_help = run(executable, ["--help"], cwd=REPO, expected=0)
        assert bare.stderr == short_help.stderr == long_help.stderr == ""
        assert bare.stdout == short_help.stdout == long_help.stdout
        assert "Usage:" in bare.stdout and "Exit status:" in bare.stdout

        check_help = run(executable, ["check", "--help"], cwd=REPO, expected=0)
        help_check = run(executable, ["help", "check"], cwd=REPO, expected=0)
        assert check_help.stderr == help_check.stderr == ""
        assert check_help.stdout == help_check.stdout
        assert "config file's parent directory is the project root" in check_help.stdout

        versions = [
            run(executable, argv, cwd=REPO, expected=0)
            for argv in (["version"], ["--version"], ["-v"])
        ]
        assert all(result.stderr == "" for result in versions)
        assert versions[0].stdout == versions[1].stdout == versions[2].stdout
        version = records(versions[0].stdout)
        assert len(version) == 1
        assert version[0]["schema"] == "zig-audit.version/v1"
        assert isinstance(version[0]["version"], str)
        assert version[0]["stable_ruleset"] == 3

        unknown = one_error(run(executable, ["chek"], cwd=REPO, expected=2), "Usage")
        assert unknown["argument"] == "chek"
        one_error(run(executable, ["check", "--bogus"], cwd=REPO, expected=2), "Usage")
        one_error(run(executable, ["check", ".zig-audit.json"], cwd=REPO, expected=2), "Usage")

        scan_file = scratch / "scan.zig"
        scan_file.write_text("_ = value;\n")
        scan = run(executable, ["scan", str(scan_file)], cwd=REPO, expected=0)
        assert scan.stderr == ""
        scan_docs = records(scan.stdout)
        assert len(scan_docs) == 1
        assert scan_docs[0] == {
            "schema": "zig-audit.scan/v1",
            "path": str(scan_file),
            "line": 1,
            "kind": "discard",
            "source": "_ = value;",
        }

        dash_file = scratch / "-generated.zig"
        dash_file.write_text("_ = generated;\n")
        dash = run(executable, ["scan", "--", "-generated.zig"], cwd=scratch, expected=0)
        assert records(dash.stdout)[0]["path"] == "-generated.zig"
        one_error(run(executable, ["scan", "-generated.zig"], cwd=scratch, expected=2), "Usage")
        missing_scan = one_error(run(executable, ["scan", "missing.zig"], cwd=scratch, expected=2), "PathNotFound")
        assert missing_scan["path"] == "missing.zig"
        multiple_scan = one_error(
            run(executable, ["scan", "scan.zig", "second-missing.zig"], cwd=scratch, expected=2),
            "PathNotFound",
        )
        assert multiple_scan["path"] == "second-missing.zig"

        clean_root = scratch / "clean"
        clean_config = project(clean_root, "const value = 1;\n")
        clean = run(executable, ["check"], cwd=clean_root, expected=0)
        assert clean.stderr == ""
        clean_docs = records(clean.stdout)
        assert clean_docs == [{
            "schema": "zig-audit.check/v1",
            "type": "summary",
            "result": "pass",
            "acknowledged": 0,
            "files_checked": 1,
        }]

        acknowledged_root = scratch / "acknowledged"
        project(
            acknowledged_root,
            "// zig-audit: acknowledge discard\n"
            "// reason: The value is intentionally ignored in this fixture.\n"
            "_ = value;\n",
        )
        verbose = run(executable, ["check", "-v"], cwd=acknowledged_root, expected=0)
        assert verbose.stderr == ""
        verbose_docs = records(verbose.stdout)
        assert [doc["type"] for doc in verbose_docs] == ["acknowledgement", "summary"]
        assert verbose_docs[0]["rule"] == "discard"
        assert verbose_docs[0]["line"] == 3
        assert verbose_docs[1]["acknowledged"] == 1

        failing_root = scratch / "failing"
        failing_config = project(failing_root, "_ = value;\n")
        failing = run(executable, ["check"], cwd=failing_root, expected=1)
        assert failing.stderr == ""
        failing_docs = records(failing.stdout)
        assert [doc["type"] for doc in failing_docs] == ["finding", "summary"]
        assert failing_docs[0]["rule"] == "discard"
        assert failing_docs[0]["line"] == 1
        assert failing_docs[-1]["result"] == "fail"

        # The explicit config owns project scope. Running from a different clean Git
        # repository must still audit the failing project's source.
        scoped = run(
            executable,
            ["check", "--config", str(failing_config)],
            cwd=clean_root,
            expected=1,
        )
        assert scoped.stderr == ""
        scoped_docs = records(scoped.stdout)
        assert scoped_docs[0]["path"] == "src/main.zig"
        assert scoped_docs[0]["rule"] == "discard"

        missing_config = scratch / "missing-project/.zig-audit.json"
        missing = one_error(
            run(executable, ["check", "--config", str(missing_config)], cwd=clean_root, expected=2),
            "ConfigNotFound",
        )
        assert missing["path"] == str(missing_config)

        malformed = scratch / "malformed.json"
        malformed.write_text("{not-json}\n")
        invalid = one_error(
            run(executable, ["check", "--config", str(malformed)], cwd=clean_root, expected=2),
            "InvalidConfig",
        )
        assert invalid["path"] == str(malformed)

        nongit_root = scratch / "nongit"
        nongit_root.mkdir()
        nongit_config = nongit_root / ".zig-audit.json"
        nongit_config.write_text(json.dumps({
            "schema": 2,
            "source": "git",
            "minimum_ruleset": 3,
            "include": ["src"],
        }) + "\n")
        discovery = one_error(
            run(executable, ["check", "--config", str(nongit_config)], cwd=clean_root, expected=2),
            "ProjectRootMismatch",
        )
        assert discovery["path"] == str(nongit_root)

        legacy_root = scratch / "legacy"
        legacy_config = project(legacy_root, "_ = value;\n", schema=1, baseline="reviewed.txt")
        (legacy_root / "reviewed.txt").write_text("src/main.zig|discard|_ = value;\n")
        legacy = run(
            executable,
            ["check", "--config", str(legacy_config)],
            cwd=clean_root,
            expected=0,
        )
        assert legacy.stderr == ""
        assert records(legacy.stdout) == [{
            "schema": "zig-audit.check/v1",
            "type": "summary",
            "result": "pass",
            "legacy_schema": 1,
        }]

        schema2_accept = run(
            executable,
            ["accept", "--config", str(clean_config)],
            cwd=failing_root,
            expected=2,
        )
        accept_error = one_error(schema2_accept, "SourceAcknowledgementsRequired")
        assert accept_error["path"] == str(clean_config)

        print("PASS zig-audit CLI contract")
    finally:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    main()
