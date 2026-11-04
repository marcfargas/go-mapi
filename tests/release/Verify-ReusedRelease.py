# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Bind downloaded reused-System draft bytes to published inputs and CI receipts.

This checks recorded Windows signing observations, not local Authenticode trust,
installation, source-diff eligibility, hosted run status, or live metadata.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap

REPOSITORY = "marcfargas/go-mapi"
ORIGIN = f"https://github.com/{REPOSITORY}/releases/download/"
WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/release.yml"
AZURE = {"endpoint": "https://weu.codesigning.azure.net/", "account": "lachispa", "certificateProfile": "lachispa"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def hash_value(value):
    return isinstance(value, str) and re.fullmatch(r"[a-f0-9]{64}", value) is not None


def indexed(records, field):
    result = {record[field]: record for record in records}
    require(len(result) == len(records), f"Duplicate {field} receipt")
    return result


def assemble(receipts, destination, version, system_tag, pin, source, run_id, run_attempt):
    """Execute the maintained assembler unchanged, on copied receipt artifacts."""
    workflow = WORKFLOW.read_text(encoding="utf-8")
    matches = re.findall(r"(?ms)^          python3 - <<'PY'\n(.*?)^          PY\s*$", workflow)
    require(len(matches) == 1, "Expected one maintained release assembler")
    code = textwrap.dedent(matches[0])
    for key, value in {"github.sha": source, "github.repository": REPOSITORY,
                       "github.run_id": str(run_id), "github.run_attempt": str(run_attempt)}.items():
        code = code.replace("${{ " + key + " }}", value)
    require("${{" not in code, "Unresolved assembler context")
    for name in ("app", "machine"):
        shutil.copytree(receipts / name, destination / "release" / name)
    environment = dict(os.environ, VERSION=version, SYSTEM_TAG=system_tag,
                       SYSTEM_MANIFEST_SHA256=pin, RUNNER_TEMP=str(destination))
    # Do not inherit PYTHONOPTIMIZE: the production assembler uses assertions.
    environment.pop("PYTHONOPTIMIZE", None)
    completed = subprocess.run([sys.executable, "-c", code], cwd=destination, env=environment,
                               capture_output=True, text=True, timeout=60)
    require(completed.returncode == 0, "Maintained assembler rejected CI receipts:\n" + completed.stderr)
    manifest = destination / "release/bundle/release.json"
    # The production stage job runs on Ubuntu. Preserve its exact LF output
    # when replaying Path.write_text on Windows, which otherwise writes CRLF.
    # Only the temporary expected file changes; downloaded bytes stay exact.
    manifest.write_bytes(manifest.read_bytes().replace(b"\r\n", b"\n"))
    return load(manifest)


def validate_app_build(build, distribution, version, source):
    filename = "go-mapi-machine.exe" if distribution == "machine" else "go-mapi.exe"
    command = "just build-user-machine" if distribution == "machine" else "just build-user-release"
    require(build["schema"] == "go-mapi-app-artifacts-v2" and build["component"] == "app"
            and build["queueProtocol"] == "queue-v1", f"Invalid {distribution} App build schema")
    require(build["version"] == version and build["source"]["commit"] == source
            and build.get("distribution", "standalone") == distribution,
            f"Invalid {distribution} App version/source/distribution")
    require(build["artifact"]["filename"] == filename and build["artifact"]["peProductVersion"] == version
            and hash_value(build["artifact"]["sha256"]), f"Invalid {distribution} App artifact")
    require(build["build"]["command"] == command
            and all(isinstance(build["build"][key], str) and build["build"][key].strip()
                    for key in ("go", "wails", "node", "npm")), f"Invalid {distribution} App build provenance")


def verify(prior_release, bundle, receipts, notes, source, run_id, run_attempt):
    require(re.fullmatch(r"[a-f0-9]{40}", source) is not None, "Expected full lowercase source SHA")
    require(all(re.fullmatch(r"[1-9][0-9]*", str(value)) for value in (run_id, run_attempt)),
            "Expected positive run ID and attempt")
    prior, release = load(prior_release), load(bundle / "release.json")
    pin = digest(prior_release)
    old = prior["system"]
    version = release["version"]
    require(re.fullmatch(r"\d+\.\d+\.\d+(-(alpha|beta|nightly)\.[1-9][0-9]*)?", version) is not None,
            "Invalid candidate release version")
    require(prior["schema"] == "go-mapi-release-v1" and prior["repository"] == REPOSITORY
            and prior["tag"] == "v" + prior["version"] and prior["signing"] == {"azure": AZURE, "validationTrust": "windows-default"},
            "Invalid original published release identity/signing receipt")
    require(old["reused"] is False and old["manifestSha256"] is None
            and all(old[key] == prior[key] for key in ("version", "tag", "commit", "runId", "runAttempt")),
            "Expected an original published System release")
    require(re.fullmatch(r"[a-f0-9]{40}", old["commit"]) is not None
            and old["artifact"]["file"] == f"go-mapi-system-{old['version']}-x64.msi"
            and hash_value(old["artifact"]["sha256"]) and old["artifact"]["size"] > 0,
            "Invalid original System source/artifact identity")
    require(release["system"] == dict(old, reused=True, manifestSha256=pin),
            "Retained System or original manifest pin differs")
    require(version != old["version"] and release["suite"]["sequence"] > old["sequence"],
            "App/Suite must advance beyond retained System")
    require(release["suite"]["upgradeCode"] != old["upgradeCode"]
            and release["suite"]["productCode"] != old["productCode"], "System and Suite families must differ")
    names = {"release.json", f"go-mapi-{version}-x64.msix", f"go-mapi-user-{version}-x64.exe",
             f"go-mapi-suite-{version}-x64.msi"}
    require({path.name for path in bundle.iterdir()} == names
            and all(path.is_file() and not path.is_symlink() for path in bundle.iterdir()),
            "Downloaded draft must contain exactly four flat reuse assets")
    require(load(receipts / "machine/reused-system.json") == old, "Imported System receipt differs from published input")
    with tempfile.TemporaryDirectory(prefix="go-mapi-reuse-receipts-") as temporary:
        assembled_root = Path(temporary)
        assembled = assemble(receipts, assembled_root, version, old["tag"], pin, source, run_id, run_attempt)
        require(release == assembled, "Downloaded compact manifest differs from actual CI receipt assembly")
        for name in names:
            expected = assembled_root / "release/bundle" / name
            require((bundle / name).stat().st_size == expected.stat().st_size
                    and digest(bundle / name) == digest(expected), f"Downloaded draft bytes differ: {name}")
        require(notes.read_text(encoding="utf-8").strip()
                == (assembled_root / "release-notes.txt").read_text(encoding="utf-8").strip(),
                "Draft notes differ from retained-System release notes")

    machine = receipts / "machine"
    proof = load(machine / f"suite-{version}.validation.json")
    inputs = load(machine / f"go-mapi-suite-{version}.manifest.json")
    target = load(machine / "suite-targets.json")
    builds = {"standalone": load(receipts / "app/standalone-app-artifacts.json"),
              "machine": load(machine / "machine-app-artifacts.json")}
    for distribution, build in builds.items():
        validate_app_build(build, distribution, version, source)
    require(builds["standalone"]["requires"] == builds["machine"]["requires"], "App counterpart contracts differ")
    require(builds["standalone"]["artifact"]["sha256"] != builds["machine"]["artifact"]["sha256"],
            "Standalone and machine App unsigned bytes must differ")
    require(proof["schema"] == "go-mapi-machine-validation-provenance-v1"
            and inputs["schema"] == "go-mapi-machine-signed-input-v1", "Invalid machine receipt schema")
    components = indexed(inputs["components"], "component")
    hashes = indexed(proof["peHashes"], "filename")
    expected_hashes = {}
    for component in old["components"]:
        name = component["component"]
        for artifact in component["artifacts"]:
            require(hash_value(artifact["unsignedSha256"]) and hash_value(artifact["sha256"]), "Invalid retained PE hash")
            expected_hashes[artifact["filename"]] = {"component": name, "architecture": artifact["architecture"],
                "filename": artifact["filename"], "unsignedSha256": artifact["unsignedSha256"], "signedSha256": artifact["sha256"]}
            field = "signedSha256" if name == "service" else artifact["architecture"] + "SignedSha256"
            require(proof["componentSources"][name][field] == artifact["sha256"], "Retained component source hash differs")
    app_artifact = components["app"]["artifacts"][0]
    expected_hashes["go-mapi-machine.exe"] = {"component": "app", "architecture": "x64", "filename": "go-mapi-machine.exe",
        "unsignedSha256": builds["machine"]["artifact"]["sha256"], "signedSha256": app_artifact["sha256"]}
    require(hashes == expected_hashes, "Extracted PE signed/unsigned hash receipts differ")
    require(inputs["appBuild"] == {"manifest": "machine-app-artifacts.json", "sha256": digest(machine / "machine-app-artifacts.json"),
            "unsignedSha256": builds["machine"]["artifact"]["sha256"]}, "Machine App unsigned build binding differs")
    require(proof["componentSources"]["app"] == {"commit": source, "buildId": digest(machine / "machine-app-artifacts.json"),
            "signedSha256": app_artifact["sha256"]}, "Machine App source/build binding differs")
    require(proof["contained"] == [{"component": part["component"], "version": part["version"]} for part in inputs["components"]],
            "Contained component receipt differs")
    require(all(target[key] == proof[key] for key in ("productCode", "upgradeCode", "sequence"))
            and target["version"] == version and target["contained"] == proof["contained"], "Suite target package identity differs")
    require(proof["targets"] == {"file": "suite-targets.json", "sha256": digest(machine / "suite-targets.json"),
            "sequence": proof["sequence"], "artifactUrl": target["artifact"]["url"]}, "Suite target receipt differs")
    signatures = load(receipts / "app/signatures.json")
    app_signed = indexed(signatures["signatures"], "file")
    require(set(app_signed) == {"go-mapi.exe", f"go-mapi-{version}-x64.msix", f"go-mapi-user-{version}-x64.exe"},
            "Standalone signature receipt file set differs")
    require(set(indexed(proof["signatures"], "file")) == set(expected_hashes) | {f"go-mapi-suite-{version}-x64.msi"},
            "Machine signature receipt file set differs")
    require(hash_value(app_signed["go-mapi.exe"]["sha256"])
            and app_signed["go-mapi.exe"]["sha256"] != app_artifact["sha256"], "Signed App distribution bytes must differ")
    distribution = load(receipts / "app/app-distribution.json")
    require(distribution["provenance"]["repository"] == REPOSITORY
            and str(distribution["provenance"]["runId"]) == str(run_id), "Standalone distribution run identity differs")
    system_url = ORIGIN + old["tag"] + "/" + old["artifact"]["file"]
    return {"result": "passed", "source": source, "version": version, "runId": str(run_id), "runAttempt": str(run_attempt),
        "priorReleaseSha256": pin, "releaseSha256": digest(bundle / "release.json"), "notesSha256": digest(notes), "systemUrl": system_url,
        "system": release["system"], "assets": [dict(file=name, size=(bundle / name).stat().st_size, sha256=digest(bundle / name)) for name in sorted(names)],
        "receipts": [dict(file=str(path.relative_to(receipts)).replace("\\", "/"), sha256=digest(path))
                     for path in sorted(receipts.rglob("*.json"))],
        "assemblerSha256": digest(WORKFLOW),
        "limits": ["Signing trust is a recorded CI observation; this tool does not verify Windows Authenticode.",
                   "Hosted run status, source/input eligibility, installation, offline behavior and live metadata need separate evidence."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("prior-release", "bundle", "receipts", "notes", "source", "run-id", "run-attempt", "output"):
        parser.add_argument("--" + name, required=True, type=Path if name in ("prior-release", "bundle", "receipts", "notes", "output") else str)
    args = parser.parse_args()
    for input_path in (args.bundle, args.receipts):
        require(not args.output.resolve().is_relative_to(input_path.resolve()), "Evidence output must be outside input directories")
    require(args.output.resolve() not in (args.prior_release.resolve(), args.notes.resolve()), "Evidence output must not replace an input")
    try:
        evidence = verify(args.prior_release, args.bundle, args.receipts, args.notes, args.source, args.run_id, args.run_attempt)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        evidence = {"result": "failed", "error": str(error), "source": args.source, "runId": args.run_id, "runAttempt": args.run_attempt}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(f"Reused release receipt verification {evidence['result']}: {args.output}")
    return 0 if evidence["result"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
