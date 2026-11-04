# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Portable refusal tests with inert packages; these do not establish Windows trust."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


verifier = module("reused_release_verifier", "Verify-ReusedRelease.py")
fixtures = module("release_bundle_fixtures", "Bundle.Tests.py")
VERSION, SOURCE = "3.2.0-beta.3", "a" * 40


def write(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def create_case(root):
    """Extend existing assembler's inert fixtures with actual receipt structure."""
    prior_root = root / "prior"
    fixtures.prepare(prior_root, "3.2.0-beta.2", "b" * 40)
    prior = fixtures.assemble(prior_root, "3.2.0-beta.2", "b" * 40)
    prior_path = prior_root / "release/bundle/release.json"
    pin = verifier.digest(prior_path)
    fixtures.prepare(root, VERSION, SOURCE, prior=prior["system"], pin=pin)
    receipts = root / "release"
    machine, app = receipts / "machine", receipts / "app"
    proof_path = machine / f"suite-{VERSION}.validation.json"
    proof = verifier.load(proof_path)
    inputs_path = machine / f"go-mapi-suite-{VERSION}.manifest.json"
    inputs = verifier.load(inputs_path)
    requirements = dict(component="interceptor", minInclusive="4.0.0")
    for distribution, path, unsigned in (
            ("standalone", app / "standalone-app-artifacts.json", "6" * 64),
            ("machine", machine / "machine-app-artifacts.json", "7" * 64)):
        build = verifier.load(path)
        build.update(schema="go-mapi-app-artifacts-v2", component="app", queueProtocol="queue-v1", requires=requirements,
            artifact=dict(filename="go-mapi-machine.exe" if distribution == "machine" else "go-mapi.exe",
                          peProductVersion=VERSION, sha256=unsigned),
            build=dict(command="just build-user-machine" if distribution == "machine" else "just build-user-release",
                       go="go1.25", wails="v2.12.0", node="v20", npm="10"))
        write(path, build)
    build_hash = verifier.digest(machine / "machine-app-artifacts.json")
    inputs.update(schema="go-mapi-machine-signed-input-v1",
                  appBuild=dict(manifest="machine-app-artifacts.json", sha256=build_hash, unsignedSha256="7" * 64))
    write(inputs_path, inputs)
    proof.update(schema="go-mapi-machine-validation-provenance-v1", sequence=203, productVersion="3.2.203",
        signedInputManifest=dict(file=inputs_path.name, sha256=verifier.digest(inputs_path)),
        appBuildManifest=dict(file="machine-app-artifacts.json", sha256=build_hash),
        contained=[dict(component=part["component"], version=part["version"]) for part in inputs["components"]])
    proof["componentSources"]["app"].update(buildId=build_hash)
    sources = {part["component"]: part for part in prior["system"]["components"]}
    expected_hashes = []
    for part in inputs["components"]:
        for artifact in part["artifacts"]:
            unsigned = "7" * 64 if part["component"] == "app" else next(
                entry["unsignedSha256"] for entry in sources[part["component"]]["artifacts"]
                if entry["filename"] == artifact["filename"])
            expected_hashes.append(dict(component=part["component"], architecture=artifact["architecture"],
                filename=artifact["filename"], unsignedSha256=unsigned, signedSha256=artifact["sha256"]))
            key = "signedSha256" if part["component"] == "service" else artifact["architecture"] + "SignedSha256"
            if part["component"] != "app":
                proof["componentSources"][part["component"]][key] = artifact["sha256"]
    proof["peHashes"] = expected_hashes
    for signature, name in zip(proof["signatures"], [entry["filename"] for entry in expected_hashes] + [proof["assetName"]], strict=True):
        signature["file"] = name
    target_path = machine / "suite-targets.json"
    target = verifier.load(target_path)
    target.update(version=VERSION, productCode=proof["productCode"], upgradeCode=proof["upgradeCode"],
                  sequence=proof["sequence"], contained=proof["contained"])
    write(target_path, target)
    proof["targets"] = dict(file="suite-targets.json", sha256=verifier.digest(target_path),
                            sequence=proof["sequence"], artifactUrl=target["artifact"]["url"])
    write(proof_path, proof)
    distribution_path = app / "app-distribution.json"
    distribution = verifier.load(distribution_path)
    distribution["provenance"].update(repository=verifier.REPOSITORY, runId="123")
    write(distribution_path, distribution)
    with tempfile.TemporaryDirectory(dir=root) as temporary:
        assembled = Path(temporary)
        verifier.assemble(receipts, assembled, VERSION, prior["tag"], pin, SOURCE, "123", "1")
        shutil.copytree(assembled / "release/bundle", root / "downloaded")
        shutil.copyfile(assembled / "release-notes.txt", root / "draft-notes.txt")
    return dict(prior_release=prior_path, bundle=root / "downloaded", receipts=receipts,
                notes=root / "draft-notes.txt", source=SOURCE, run_id="123", run_attempt="1")


class ReusedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="go-mapi-reuse-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.args = create_case(self.root)

    def mutate(self, relative, change):
        path = self.root / relative
        value = verifier.load(path)
        change(value)
        write(path, value)

    def verify(self, **changes):
        return verifier.verify(**dict(self.args, **changes))

    def test_valid_reuse_binds_downloads_and_preserves_original_system(self):
        result = self.verify()
        self.assertEqual(result["result"], "passed")
        self.assertEqual(result["system"]["version"], "3.2.0-beta.2")
        self.assertEqual(result["version"], VERSION)
        self.assertEqual(len(result["assets"]), 4)
        self.assertEqual(result["priorReleaseSha256"], verifier.digest(self.args["prior_release"]))
        self.assertIn("v3.2.0-beta.2/go-mapi-system-3.2.0-beta.2-x64.msi", result["systemUrl"])
        self.assertTrue(result["limits"])

    def test_candidate_context_must_match_actual_receipts(self):
        for changes in (dict(source="f" * 40), dict(run_id="999"), dict(run_attempt="2")):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(**changes)

    def test_hosted_lf_manifest_passes_on_every_host(self):
        manifest = self.args["bundle"] / "release.json"
        hosted = (json.dumps(verifier.load(manifest), indent=2) + "\n").encode("utf-8")
        manifest.write_bytes(hosted)
        self.assertNotIn(b"\r", hosted)
        result = self.verify()
        self.assertEqual(result["releaseSha256"], verifier.digest(manifest))

    def test_downloaded_manifest_line_ending_changes_are_byte_tamper(self):
        manifest = self.args["bundle"] / "release.json"
        hosted = (json.dumps(verifier.load(manifest), indent=2) + "\n").encode("utf-8")
        manifest.write_bytes(hosted.replace(b"\n", b"\r\n"))
        with self.assertRaisesRegex(ValueError, "Downloaded draft bytes differ: release.json"):
            self.verify()

    def test_downloaded_manifest_extra_whitespace_is_byte_tamper(self):
        manifest = self.args["bundle"] / "release.json"
        manifest.write_bytes(manifest.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "Downloaded draft bytes differ: release.json"):
            self.verify()

    def test_downloaded_assets_are_exactly_the_accepted_bytes(self):
        installer = self.args["bundle"] / f"go-mapi-user-{VERSION}-x64.exe"
        installer.write_bytes(installer.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "Downloaded draft bytes differ"):
            self.verify()

    def test_new_system_asset_is_refused(self):
        (self.args["bundle"] / f"go-mapi-system-{VERSION}-x64.msi").write_bytes(b"unexpected")
        with self.assertRaisesRegex(ValueError, "exactly four"):
            self.verify()

    def test_notes_must_resolve_retained_system(self):
        self.args["notes"].write_text(f"System: {verifier.ORIGIN}v{VERSION}/go-mapi-system-{VERSION}-x64.msi\n")
        with self.assertRaisesRegex(ValueError, "Draft notes differ"):
            self.verify()

    def test_original_manifest_pin_is_byte_bound(self):
        path = self.args["prior_release"]
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "manifest pin differs"):
            self.verify()

    def test_machine_receipt_mutations_are_rejected(self):
        mutations = {
            "signed-payload": lambda p: p["peHashes"][0].update(signedSha256="0" * 64),
            "unsigned-payload": lambda p: p["peHashes"][1].update(unsignedSha256="0" * 64),
            "payload-architecture": lambda p: p["peHashes"][2].update(architecture="x86"),
            "payload-duplicate": lambda p: p["peHashes"].append(copy.deepcopy(p["peHashes"][0])),
            "app-unsigned-hash": lambda p: p["peHashes"][3].update(unsignedSha256="0" * 64),
            "component-source": lambda p: p["componentSources"]["interceptor"].update(commit="f" * 40),
            "component-build": lambda p: p["componentSources"]["service"].update(buildId="999.1:service"),
            "component-source-hash": lambda p: p["componentSources"]["service"].update(signedSha256="0" * 64),
            "machine-app-build": lambda p: p["componentSources"]["app"].update(buildId="0" * 64),
            "component-version": lambda p: p["contained"][0].update(version=VERSION),
            "signing-profile": lambda p: p["azure"].update(certificateProfile="lachispa-test"),
            "test-trust": lambda p: p.update(testTrust={"root": "fixture"}),
            "validation-trust": lambda p: p.update(validationTrust="imported-test-root"),
            "signature-status": lambda p: p["signatures"][0].update(status="UnknownError"),
            "signature-timestamp": lambda p: p["signatures"][0].update(timestampThumbprint=""),
            "signature-duplicate": lambda p: p["signatures"][0].update(file=p["signatures"][1]["file"]),
            "target-receipt": lambda p: p["targets"].update(sequence=1),
            "run-attempt": lambda p: p.update(runAttempt="2"),
        }
        proof_path = self.root / f"release/machine/suite-{VERSION}.validation.json"
        original = verifier.load(proof_path)
        for name, change in mutations.items():
            with self.subTest(name=name):
                value = copy.deepcopy(original)
                change(value)
                write(proof_path, value)
                with self.assertRaises(ValueError):
                    self.verify()
        write(proof_path, original)

    def test_receipt_package_tamper_is_rejected(self):
        path = self.root / f"release/machine/go-mapi-suite-{VERSION}-x64.msi"
        path.write_bytes(b"different signed container")
        with self.assertRaisesRegex(ValueError, "assembler rejected"):
            self.verify()

    def test_compact_metadata_must_match_receipts(self):
        self.mutate("downloaded/release.json", lambda r: r["app"].update(exeSha256="0" * 64))
        with self.assertRaisesRegex(ValueError, "compact manifest differs"):
            self.verify()

    def test_imported_system_receipt_cannot_replace_original_provenance(self):
        self.mutate("release/machine/reused-system.json", lambda r: r.update(commit="f" * 40))
        with self.assertRaisesRegex(ValueError, "Imported System receipt differs"):
            self.verify()

    def test_rehashed_input_receipt_does_not_hide_unsigned_app_mismatch(self):
        inputs_path = self.root / f"release/machine/go-mapi-suite-{VERSION}.manifest.json"
        inputs = verifier.load(inputs_path)
        inputs["appBuild"]["unsignedSha256"] = "0" * 64
        write(inputs_path, inputs)
        self.mutate(f"release/machine/suite-{VERSION}.validation.json",
                    lambda p: p["signedInputManifest"].update(sha256=verifier.digest(inputs_path)))
        with self.assertRaisesRegex(ValueError, "unsigned build binding differs"):
            self.verify()

    def test_rehashed_machine_build_still_requires_machine_build_command(self):
        build_path = self.root / "release/machine/machine-app-artifacts.json"
        self.mutate("release/machine/machine-app-artifacts.json", lambda b: b["build"].update(command="just build-user-release"))
        build_hash = verifier.digest(build_path)
        inputs_path = self.root / f"release/machine/go-mapi-suite-{VERSION}.manifest.json"
        self.mutate(str(inputs_path.relative_to(self.root)), lambda i: i["appBuild"].update(sha256=build_hash))
        def rebind_proof(proof):
            proof["signedInputManifest"]["sha256"] = verifier.digest(inputs_path)
            proof["appBuildManifest"]["sha256"] = build_hash
            proof["componentSources"]["app"]["buildId"] = build_hash
        self.mutate(f"release/machine/suite-{VERSION}.validation.json", rebind_proof)
        with self.assertRaisesRegex(ValueError, "machine App build provenance"):
            self.verify()

    def test_standalone_build_provenance_and_distribution_must_match(self):
        build_path = self.root / "release/app/standalone-app-artifacts.json"
        original = verifier.load(build_path)
        for mutate in (lambda b: b.update(distribution="machine"),
                       lambda b: b["build"].update(command="go build"),
                       lambda b: b["artifact"].update(filename="go-mapi-machine.exe"),
                       lambda b: b["build"].update(wails=""),
                       lambda b: b["artifact"].update(sha256="7" * 64)):
            value = copy.deepcopy(original)
            mutate(value)
            write(build_path, value)
            with self.assertRaises(ValueError):
                self.verify()

    def test_cli_rejects_tamper_and_writes_failure_evidence(self):
        (self.args["bundle"] / f"go-mapi-{VERSION}-x64.msix").write_bytes(b"changed")
        output = self.root / "evidence/result.json"
        arguments = [sys.executable, str(Path(__file__).with_name("Verify-ReusedRelease.py"))]
        for key, value in dict(self.args, output=output).items():
            arguments.extend(["--" + key.replace("_", "-"), str(value)])
        process = subprocess.run(arguments, capture_output=True, text=True, timeout=60)
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertEqual(verifier.load(output)["result"], "failed")


if __name__ == "__main__":
    unittest.main()
