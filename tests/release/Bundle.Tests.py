# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Exercise the workflow's actual bundle assembler using inert package fixtures."""
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch

REPOSITORY = "marcfargas/go-mapi"
WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/release.yml"
AZURE = dict(endpoint="https://weu.codesigning.azure.net/", account="lachispa", certificateProfile="lachispa")
DERIVATIVE = dict(kind="production", metadataOrigin="https://go-mapi.app", artifactOrigin=f"https://github.com/{REPOSITORY}/releases/download/", checkIntervalSeconds=21600)
VERSION, SOURCE = "3.2.0-beta.2", "a" * 40


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value), encoding="utf-8")


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def assemble(root, version=VERSION, source=SOURCE, pin=""):
    workflow = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(r"(?ms)^          python3 - <<'PY'\n(.*?)^          PY\s*$", workflow)
    if not match:
        raise RuntimeError("Release workflow's actual bundle assembler is missing")
    code = textwrap.dedent(match.group(1))
    for key, value in {"github.sha": source, "github.repository": REPOSITORY, "github.run_id": "123", "github.run_attempt": "1"}.items():
        code = code.replace("${{ " + key + " }}", value)
    environment = dict(VERSION=version, SYSTEM_TAG="v3.2.0-beta.1" if pin else "", SYSTEM_MANIFEST_SHA256=pin, RUNNER_TEMP=str(root))
    previous = Path.cwd()
    try:
        with patch.dict(os.environ, environment):
            os.chdir(root)
            exec(compile(code, str(WORKFLOW) + ":bundle-assembler", "exec"), {})
    finally:
        os.chdir(previous)
    return read(root / "release/bundle/release.json")


def prepare(root, version=VERSION, source=SOURCE, prior=None, pin=""):
    app, machine = root / "release/app", root / "release/machine"
    app.mkdir(parents=True)
    machine.mkdir()
    names = {"msix": f"go-mapi-{version}-x64.msix", "standalone": f"go-mapi-user-{version}-x64.exe"}
    for name in names.values():
        (app / name).write_bytes(("inert " + name).encode())
    write(app / "app-distribution.json", dict(version=version, provenance=dict(commit=source), **{key: dict(file=name, sha256=digest(app / name)) for key, name in names.items()}))
    write(app / "standalone-app-artifacts.json", dict(version=version, source=dict(commit=source)))
    signature = dict(status="Valid", signerSubject="inert publisher", signerThumbprint="inert signer", timestampThumbprint="inert timestamp")
    signatures = [dict(signature, file=name, sha256=digest(app / name)) for name in names.values()]
    signatures.append(dict(signature, file="go-mapi.exe", sha256="e" * 64))
    write(app / "signatures.json", dict(commit=source, sourceRef="refs/tags/v" + version, runId="123", runAttempt="1", azure=AZURE, validationTrust="windows-default", testTrust=None, signatures=signatures))
    write(machine / "machine-app-artifacts.json", dict(version=version, source=dict(commit=source), distribution="machine"))
    selection = dict(version=prior["version"] if prior else version, tag=prior["tag"] if prior else "v" + version, commit=prior["commit"] if prior else source, reused=bool(prior), manifestSha256=pin if prior else None)
    write(machine / "system-selection.json", selection)
    if prior:
        write(machine / "reused-system.json", prior)
    for sku in (["suite"] if prior else ["system", "suite"]):
        asset = f"go-mapi-{sku}-{version}-x64.msi"
        manifest, proof_name, targets = f"go-mapi-{sku}-{version}.manifest.json", f"{sku}-{version}.validation.json", f"{sku}-targets.json"
        (machine / asset).write_bytes(("inert " + asset).encode())
        components = copy.deepcopy(prior["components"]) if prior else [
            dict(component="service", version=version, artifacts=[dict(architecture="x64", filename="go-mapi-service.exe", sha256="1" * 64)]),
            dict(component="interceptor", version=version, artifacts=[dict(architecture=arch, filename=f"go-mapi-{arch}.dll", sha256=mark * 64) for arch, mark in (("x86", "2"), ("x64", "3"))]),
        ]
        sources = {}
        for component in components:
            sources[component["component"]] = component.pop("source", dict(commit=selection["commit"], buildId="123.1:" + component["component"]))
            for artifact in component["artifacts"]:
                artifact.pop("unsignedSha256", None)
        if sku == "suite":
            components.append(dict(component="app", version=version, distribution="machine", artifacts=[dict(architecture="x64", filename="go-mapi-machine.exe", sha256="4" * 64)]))
            sources["app"] = dict(commit=source, buildId="machine-build", signedSha256="4" * 64)
        inputs = dict(sku=sku, packageRelease=version, commit=source, components=components)
        if sku == "suite":
            inputs["appBuild"] = dict(sha256=digest(machine / "machine-app-artifacts.json"))
        write(machine / manifest, inputs)
        msi = dict(signed=True, size=(machine / asset).stat().st_size, sha256=digest(machine / asset))
        write(machine / targets, dict(sku=sku, artifact=dict(url=f"https://github.com/{REPOSITORY}/releases/download/v{version}/{asset}", size=msi["size"], sha256=msi["sha256"])))
        proof = dict(publishable=True, sku=sku, packageRelease=version, repository=REPOSITORY, commit=source, sourceRef="refs/tags/v" + version, tag="v" + version, runId="123", runAttempt="1", assetName=asset, productCode=sku + "-code", productVersion="3.2.202", upgradeCode=sku + "-family", sequence=202, derivative=DERIVATIVE, signedInputManifest=dict(file=manifest, sha256=digest(machine / manifest)), msi=msi, targets=dict(sha256=digest(machine / targets)), azure=AZURE, testTrust=None, validationTrust="windows-default", signatures=[dict(signature, file=str(i)) for i in range(5 if sku == "suite" else 4)], systemPackage=selection, componentSources=sources)
        proof["peHashes"] = [dict(component=component["component"], filename=artifact["filename"], signedSha256=artifact["sha256"], unsignedSha256="5" * 64) for component in components for artifact in component["artifacts"]]
        if sku == "suite":
            proof["appBuildManifest"] = dict(file="machine-app-artifacts.json", sha256=digest(machine / "machine-app-artifacts.json"))
        write(machine / proof_name, proof)


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="go-mapi-release-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def change(self, filename, mutate):
        path = self.root / "release/machine" / filename
        value = read(path)
        mutate(value)
        write(path, value)
        if filename.endswith(".manifest.json"):
            proof_path = path.with_name(f"suite-{VERSION}.validation.json")
            proof = read(proof_path)
            proof["signedInputManifest"]["sha256"] = digest(path)
            write(proof_path, proof)

    def test_new_and_reused_system_publish_only_packages_and_one_manifest(self):
        prior_root = self.root / "prior"
        prepare(prior_root, "3.2.0-beta.1", "b" * 40)
        prior = assemble(prior_root, "3.2.0-beta.1", "b" * 40)
        self.assertEqual({p.name for p in (prior_root / "release/bundle").iterdir()}, {
            "release.json", "go-mapi-3.2.0-beta.1-x64.msix", "go-mapi-user-3.2.0-beta.1-x64.exe",
            "go-mapi-system-3.2.0-beta.1-x64.msi", "go-mapi-suite-3.2.0-beta.1-x64.msi",
        })
        pin = digest(prior_root / "release/bundle/release.json")
        prepare(self.root, prior=prior["system"], pin=pin)
        result = assemble(self.root, pin=pin)
        expected = {"release.json", f"go-mapi-{VERSION}-x64.msix", f"go-mapi-user-{VERSION}-x64.exe", f"go-mapi-suite-{VERSION}-x64.msi"}
        self.assertEqual({p.name for p in (self.root / "release/bundle").iterdir()}, expected)
        self.assertEqual(result["system"], dict(prior["system"], reused=True, manifestSha256=pin))
        self.assertEqual(result["commit"], SOURCE)
        self.assertNotEqual(result["system"]["commit"], SOURCE)

    def test_reused_record_mismatches_refuse_assembly(self):
        prior_root = self.root / "prior"
        prepare(prior_root, "3.2.0-beta.1", "b" * 40)
        prior = assemble(prior_root, "3.2.0-beta.1", "b" * 40)
        pin = digest(prior_root / "release/bundle/release.json")
        for fault in ("pin", "source", "run", "payload", "derivative"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory(dir=self.root) as directory:
                case = Path(directory)
                prepare(case, prior=prior["system"], pin=pin)
                path = case / "release/machine/reused-system.json"
                system = read(path)
                if fault == "source":
                    system["commit"] = "f" * 40
                elif fault == "run":
                    system["runId"] = "456"
                elif fault == "payload":
                    system["components"][0]["artifacts"][0]["sha256"] = "0" * 64
                elif fault == "derivative":
                    system["derivative"]["checkIntervalSeconds"] = 1
                write(path, system)
                with self.assertRaises(AssertionError):
                    assemble(case, pin="0" * 64 if fault == "pin" else pin)

    def test_invalid_inputs_refuse_assembly(self):
        faults = ("bytes", "missing", "source", "tag", "run", "pin", "payload", "component-version", "component-source", "derivative")
        for fault in faults:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory(dir=self.root) as directory:
                case = Path(directory)
                prepare(case)
                saved, self.root = self.root, case
                try:
                    if fault == "bytes":
                        (case / f"release/app/go-mapi-{VERSION}-x64.msix").write_bytes(b"altered")
                    elif fault == "missing":
                        (case / f"release/machine/go-mapi-system-{VERSION}-x64.msi").unlink()
                    elif fault == "pin":
                        self.change("system-selection.json", lambda value: value.update(manifestSha256="0" * 64))
                    elif fault in ("payload", "component-version"):
                        def change_component(value):
                            component = value["components"][0]
                            if fault == "payload":
                                component["artifacts"][0]["sha256"] = "0" * 64
                            else:
                                component["version"] = "3.1.0"
                        self.change(f"go-mapi-suite-{VERSION}.manifest.json", change_component)
                    elif fault == "component-source":
                        self.change(f"suite-{VERSION}.validation.json", lambda value: value["componentSources"]["service"].update(buildId="different-build"))
                    elif fault == "derivative":
                        self.change(f"system-{VERSION}.validation.json", lambda value: value.update(derivative=dict(DERIVATIVE, checkIntervalSeconds=1)))
                    else:
                        field = {"source": "commit", "tag": "tag", "run": "runId"}[fault]
                        self.change(f"suite-{VERSION}.validation.json", lambda value: value.update({field: "wrong"}))
                    with self.assertRaises((AssertionError, KeyError, FileNotFoundError)):
                        assemble(case)
                finally:
                    self.root = saved

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is required for the stable-channel consumer")
    def test_stable_consumer_checks_actual_bytes_and_signature_failures(self):
        step = WORKFLOW.read_text(encoding="utf-8").split("- name: Verify accepted public stable bytes", 1)[1].split("- name:", 1)[0]
        consumer = textwrap.dedent(step.split("run: |\n", 1)[1])
        consumer = consumer[consumer.index("$root = "):].replace("${{ github.sha }}", SOURCE).replace("${{ github.repository }}", REPOSITORY)
        for fault in ("none", "source", "hash", "signature", "timestamp", "signature-type"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory(dir=self.root) as directory:
                root = Path(directory)
                prepare(root, "4.2.0")
                manifest = assemble(root, "4.2.0")
                accepted = root / "release/accepted"
                shutil.copytree(root / "release/bundle", accepted)
                if fault == "source":
                    manifest["commit"] = "b" * 40
                    write(accepted / "release.json", manifest)
                elif fault == "hash":
                    (accepted / manifest["app"]["artifacts"]["msix"]["file"]).write_bytes(b"changed")
                # Only signature observations are doubled; hashes and the consumer
                # are real. These cases do not qualify Windows signing trust.
                header = "$ErrorActionPreference='Stop';$version='4.2.0';$env:RELEASE_TAG='v4.2.0'\n"
                status = "NotSigned" if fault == "signature" else "Valid"
                kind = "Catalog" if fault == "signature-type" else "Authenticode"
                timestamp = "$null" if fault == "timestamp" else "$true"
                header += "function Get-AuthenticodeSignature { [pscustomobject]@{Status='" + status + "';SignatureType='" + kind + "';SignerCertificate=$true;TimeStamperCertificate=" + timestamp + "} }\n"
                script = root / "stable.ps1"
                script.write_text(header + consumer, encoding="utf-8")
                result = subprocess.run([shutil.which("pwsh"), "-NoProfile", "-File", str(script)], cwd=root,
                    env=dict(os.environ, GITHUB_OUTPUT=str(root / "accepted-output")), capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode == 0, fault == "none", result.stdout + result.stderr)
                self.assertEqual((root / "accepted-output").exists(), fault == "none")

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is required for the System import consumer")
    def test_import_checks_the_pinned_original_release_before_extraction(self):
        workflow = WORKFLOW.with_name("admin-release.yml").read_text(encoding="utf-8")
        step = workflow.split("- name: Import pinned published System", 1)[1].split("- name:", 1)[0]
        consumer = textwrap.dedent(step.split("run: |\n", 1)[1]).split("git fetch --no-tags", 1)[0]
        consumer = consumer.replace("${{ github.repository }}", REPOSITORY)
        for fault in ("none", "pin", "source", "reused", "signing", "msi", "timers"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory(dir=self.root) as directory:
                root = Path(directory)
                prepare(root, "3.2.0-beta.1")
                manifest = assemble(root, "3.2.0-beta.1")
                package = root / "release/bundle" / manifest["system"]["artifact"]["file"]
                if fault == "source":
                    manifest["system"]["commit"] = "b" * 40
                elif fault == "reused":
                    manifest["system"]["reused"] = True
                elif fault == "signing":
                    manifest["signing"]["azure"]["certificateProfile"] = "lachispa-test"
                elif fault == "msi":
                    package.write_bytes(b"changed")
                elif fault == "timers":
                    manifest["system"]["derivative"]["timers"] = {"checkInterval": 1}
                write(root / "release/bundle/release.json", manifest)
                pin = "0" * 64 if fault == "pin" else digest(root / "release/bundle/release.json")
                header = "$ErrorActionPreference='Stop';$env:VERSION='3.2.0-beta.2';$env:SYSTEM_TAG='v3.2.0-beta.1'\n"
                header += "$env:SYSTEM_MANIFEST_SHA256='" + pin + "'\n"
                header += "function go { $global:LASTEXITCODE=0;'track=development' }\n"
                header += "function gh { $global:LASTEXITCODE=0;if ($args[0] -eq 'api') { '{\"draft\":false,\"tag_name\":\"v3.2.0-beta.1\"}' } else { Copy-Item release/bundle/* reuse-input } }\n"
                script = root / "import.ps1"
                script.write_text(header + consumer + "\n'validated' | Set-Content import-accepted", encoding="utf-8")
                result = subprocess.run([shutil.which("pwsh"), "-NoProfile", "-File", str(script)], cwd=root,
                    capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode == 0, fault == "none", result.stdout + result.stderr)
                self.assertEqual((root / "import-accepted").exists(), fault == "none")


if __name__ == "__main__":
    unittest.main()
