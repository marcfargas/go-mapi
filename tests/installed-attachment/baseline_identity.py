"""Pins and validates the one permitted expired historical MSI fixture."""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path


class BaselineIdentityError(ValueError):
    pass


ALPHA7 = {
    "kind": "exact-alpha7-historical-fixture",
    "tag": "suite-v3.2.0-alpha.7",
    "sourceCommit": "3d33779ad21d28b5579fb638c0a31ee8f698da1c",
    "validationRunId": "36458319650",
    "validationAttempt": "1",
    "msiName": "go-mapi-suite-3.2.0-alpha.7-x64.msi",
    "msiSize": 12021760,
    "msiSHA256": "bcf00f8511b8f076582ff06f9ecb00a67aa9476dd3cbdebc5f6b975f4ec94a68",
    "signerSHA1": "076F98CC1928F8F8604B4A384A6BA27FA884F920",
    "timestampSHA1": "9D64791BDBA7AB705D8EEB6BC275951F512BC45C",
    "signerNotBeforeUtc": "2026-09-27T10:11:51Z",
    "signerNotAfterUtc": "2026-09-30T10:11:51Z",
    "lifetimeSigningEku": "1.3.6.1.4.1.311.10.3.13",
    "timestampUtc": "2026-09-28T17:32:29Z",
    "rfc3161GenTimeUtc": "2026-09-28T17:32:29.4750000Z",
    "rfc3161MessageImprintSHA256": "6642489753c751c14ceae5961828d0db45f38c22c23eed7ab264c258b811c885",
    "signingRootSHA256": "41c1fd9b83c54731c84375c07ec2585b61d032961d9c578c1784fca0e3c59f6e",
    "signingRootSHA1": "DFA0E53504EF5328FAEC21AD7DF14C10B07C4FCB",
    "timestampRootSHA256": "5367f20c7ade0e2bca790915056d086b720c33c1fa2a2661acf787e3292e1270",
    "validationName": "suite-3.2.0-alpha.7.validation.json",
    "validationSHA256": "3400ef558184216eef8c462fbfc2a3fbea85bb2c23f61403b3b5a922778d73f7",
    "manifestName": "go-mapi-suite-3.2.0-alpha.7.manifest.json",
    "manifestSHA256": "e4ff6e5d6e4159691aeeb9276a669afd91437829ed131b0fbdba5995d950fbf7",
    "targetsName": "suite-targets.json",
    "targetsSHA256": "8e879ea2542aa2ace7ddefc7c827e998091e517b1ecd2795abf95c85444961c3",
    "appArtifactsName": "app-artifacts.json",
    "appArtifactsSHA256": "a216c087967c25c6a74f2e8be6d6333af1182e8aabae5f04a4271fcb9e0a46e6",
    "appSHA256": "eb2b6b828af2f48bd9e3c866663ac01a92642fc9913b6bf927e076178afbc2c4",
    "x64DllSHA256": "51eb64a2faf60e048b473e2de0f0c7bee49dfaa77f35294fc380e0d5cde03764",
    "portableEvidenceSHA256SUMS": "05105cbe4d66db00be45231eadea0ffef256651c7579b7493dd1137cff1ea488",
    "releaseApiSHA256": "47a77ccf6cc9930abaf3fc61e1d241175367e00432921cf893dcb2a41b802c39",
}

ASSET_HASHES = {
    "msi": (ALPHA7["msiName"], ALPHA7["msiSHA256"]),
    "validation": (ALPHA7["validationName"], ALPHA7["validationSHA256"]),
    "manifest": (ALPHA7["manifestName"], ALPHA7["manifestSHA256"]),
    "targets": (ALPHA7["targetsName"], ALPHA7["targetsSHA256"]),
    "appArtifacts": (ALPHA7["appArtifactsName"], ALPHA7["appArtifactsSHA256"]),
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_alpha7_assets(paths: dict[str, Path], *, release_api: Path, kind: str) -> dict:
    """Require the complete public asset tuple; arbitrary baseline inputs fail closed."""
    if kind != ALPHA7["kind"]:
        raise BaselineIdentityError("expiry admission is available only for exact-alpha7-historical-fixture")
    if set(paths) != set(ASSET_HASHES):
        raise BaselineIdentityError("all five pinned alpha.7 release assets are required")
    observed = {}
    for key, (name, expected_hash) in ASSET_HASHES.items():
        path = Path(paths[key])
        if not path.is_file() or path.name != name or _sha256(path) != expected_hash:
            raise BaselineIdentityError(f"pinned alpha.7 {key} asset identity mismatch")
        observed[key] = {"name": name, "sha256": expected_hash, "path": str(path)}
    if paths["msi"].stat().st_size != ALPHA7["msiSize"]:
        raise BaselineIdentityError("pinned alpha.7 MSI size mismatch")

    api_path = Path(release_api)
    if not api_path.is_file() or _sha256(api_path) != ALPHA7["releaseApiSHA256"]:
        raise BaselineIdentityError("alpha.7 GitHub release API provenance hash mismatch")
    api = json.loads(api_path.read_text(encoding="utf-8"))
    if api.get("tag_name") != ALPHA7["tag"] or api.get("published_at") != "2026-09-28T17:33:00Z":
        raise BaselineIdentityError("alpha.7 release API tag/publication identity mismatch")
    api_assets = {item.get("name"): item for item in api.get("assets", [])}
    for name, expected_hash in ASSET_HASHES.values():
        asset = api_assets.get(name)
        if not asset or asset.get("digest") != f"sha256:{expected_hash}":
            raise BaselineIdentityError(f"alpha.7 release API asset provenance mismatch: {name}")
    proof = json.loads(Path(paths["validation"]).read_text(encoding="utf-8"))
    expected_proof = {
        "commit": ALPHA7["sourceCommit"],
        "workflowRevision": ALPHA7["sourceCommit"],
        "runId": ALPHA7["validationRunId"],
        "runAttempt": ALPHA7["validationAttempt"],
        "tag": ALPHA7["tag"],
        "assetName": ALPHA7["msiName"],
    }
    for field, expected in expected_proof.items():
        if str(proof.get(field)) != expected:
            raise BaselineIdentityError(f"alpha.7 validation proof {field} mismatch")
    if proof.get("msi", {}).get("sha256") != ALPHA7["msiSHA256"] or proof.get("msi", {}).get("size") != ALPHA7["msiSize"]:
        raise BaselineIdentityError("alpha.7 validation proof MSI identity mismatch")
    if (
        proof.get("signedInputManifest", {}).get("sha256") != ALPHA7["manifestSHA256"]
        or proof.get("targets", {}).get("sha256") != ALPHA7["targetsSHA256"]
        or proof.get("appBuildManifest", {}).get("sha256") != ALPHA7["appArtifactsSHA256"]
    ):
        raise BaselineIdentityError("alpha.7 validation proof asset hashes mismatch")
    app_parts = [item for item in proof.get("peHashes", []) if item.get("component") == "app" and item.get("architecture") == "x64"]
    dll_parts = [item for item in proof.get("peHashes", []) if item.get("component") == "interceptor" and item.get("architecture") == "x64"]
    if (
        len(app_parts) != 1
        or app_parts[0].get("signedSha256") != ALPHA7["appSHA256"]
        or len(dll_parts) != 1
        or dll_parts[0].get("signedSha256") != ALPHA7["x64DllSHA256"]
        or proof.get("componentSources", {}).get("app", {}).get("commit") != ALPHA7["sourceCommit"]
        or proof.get("componentSources", {}).get("interceptor", {}).get("commit") != ALPHA7["sourceCommit"]
    ):
        raise BaselineIdentityError("alpha.7 component source/build proof mismatch")
    signature = [entry for entry in proof.get("signatures", []) if entry.get("file") == ALPHA7["msiName"]]
    if len(signature) != 1 or signature[0].get("status") != "Valid" or signature[0].get("signerThumbprint", "").upper() != ALPHA7["signerSHA1"] or signature[0].get("timestampThumbprint", "").upper() != ALPHA7["timestampSHA1"]:
        raise BaselineIdentityError("alpha.7 validation proof signer/timestamp tuple mismatch")
    return {"kind": ALPHA7["kind"], "tuple": dict(ALPHA7), "assets": observed, "releaseApi": {"path": str(api_path), "sha256": ALPHA7["releaseApiSHA256"]}, "historicalProofStatus": "Valid-at-validation-run-only"}


def validate_alpha7_portable_evidence(directory: Path) -> dict:
    """Verify the pinned portable evidence bundle and its historical/tamper observations."""
    root = Path(directory).resolve()
    sums_path = root / "SHA256SUMS"
    if not sums_path.is_file() or _sha256(sums_path) != ALPHA7["portableEvidenceSHA256SUMS"]:
        raise BaselineIdentityError("alpha.7 portable SHA256SUMS identity mismatch")
    listed: dict[str, str] = {}
    for line in sums_path.read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  \./([^\r\n]+)", line)
        if not match:
            raise BaselineIdentityError("alpha.7 portable SHA256SUMS contains a malformed entry")
        digest, relative = match.groups()
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts or relative in listed:
            raise BaselineIdentityError("alpha.7 portable SHA256SUMS contains an unsafe or duplicate path")
        candidate = (root / path).resolve()
        if root not in candidate.parents or not candidate.is_file() or _sha256(candidate) != digest:
            raise BaselineIdentityError(f"alpha.7 portable evidence file hash mismatch: {relative}")
        listed[relative] = digest
    required = {
        "alpha7-historical-verify.log", "alpha7-current-verify.log", "alpha7-altered-verify.log",
        "alpha7-altered.msi", "inputs/root-test.pem", "inputs/microsoft-identity-root-2020.pem",
        "inputs/all-crls.pem", "verifier/osslsigncode", "provenance.txt",
    }
    if not required.issubset(listed):
        raise BaselineIdentityError("alpha.7 portable evidence bundle omits required verifier, root, CRL or run logs")
    historical = (root / "alpha7-historical-verify.log").read_text(encoding="utf-8", errors="replace")
    current = (root / "alpha7-current-verify.log").read_text(encoding="utf-8", errors="replace")
    altered = (root / "alpha7-altered-verify.log").read_text(encoding="utf-8", errors="replace")
    expected_digest = ALPHA7["msiSHA256"].upper()
    if (f"Calculated message digest        : {expected_digest}" not in historical
            or "Signature verification: ok" not in historical
            or "Timestamp Server Signature verification: ok" not in historical
            or "Timestamp Server Signature CRL verification: ok" not in historical
            or "Signature CRL verification: ok" not in historical
            or "Warning: Ignoring 'certificate has expired' error for CRL validation" not in historical
            or not re.search(r"(?m)^[ \t]+Timestamp time: Sep 28 17:32:29 2026 GMT[ \t]*$", historical)
            or "notAfter : Sep 30 10:11:51 2026 GMT" not in historical):
        raise BaselineIdentityError("alpha.7 historical portable log does not prove the pinned digest, signature, timestamp, CRL warning and leaf tuple")
    if ("Timestamp Server Signature verification is disabled" not in current
            or "Error: certificate has expired" not in current or "Signature verification: failed" not in current):
        raise BaselineIdentityError("alpha.7 current-time portable negative control is incomplete")
    if ("Calculated DigitalSignature" not in altered or "MISMATCH!!!" not in altered
            or "Signature verification: failed" not in altered):
        raise BaselineIdentityError("alpha.7 altered-file tamper control is incomplete")
    root_test = base64_decode_pem(root / "inputs/root-test.pem")
    timestamp_root = base64_decode_pem(root / "inputs/microsoft-identity-root-2020.pem")
    if hashlib.sha256(root_test).hexdigest() != ALPHA7["signingRootSHA256"]:
        raise BaselineIdentityError("alpha.7 portable signing-root certificate identity mismatch")
    if hashlib.sha256(timestamp_root).hexdigest() != ALPHA7["timestampRootSHA256"]:
        raise BaselineIdentityError("alpha.7 portable timestamp-root certificate identity mismatch")
    timestamp_match = re.search(r"(?m)^[ \t]+Timestamp time:[ \t]*(.+?)[ \t]*$", historical)
    if not timestamp_match:
        raise BaselineIdentityError("alpha.7 portable historical timestamp observation is malformed")
    timestamp_observed = datetime.strptime(timestamp_match.group(1), "%b %d %H:%M:%S %Y GMT").replace(tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")
    return {
        "sha256Sums": ALPHA7["portableEvidenceSHA256SUMS"], "verifiedFileCount": len(listed),
        "historical": {"msiSha256": expected_digest.lower(), "timestampUtc": timestamp_observed,
                       "signingRootSHA256": ALPHA7["signingRootSHA256"], "timestampRootSHA256": ALPHA7["timestampRootSHA256"],
                       "digestVerified": f"Calculated message digest        : {expected_digest}" in historical,
                       "signatureVerified": "Signature verification: ok" in historical,
                       "timestampVerified": "Timestamp Server Signature verification: ok" in historical and "Timestamp Server Signature CRL verification: ok" in historical,
                       "signingCrlWarning": "Warning: Ignoring 'certificate has expired' error for CRL validation" in historical},
        "currentControl": "signer-expired-with-timestamp-disabled", "alteredControl": "msi-digest-mismatch",
        "limitation": "osslsigncode reports it ignored the expired-leaf CRL validation error; this is qualified portable evidence, not Windows revocation proof",
    }


def base64_decode_pem(path: Path) -> bytes:
    import base64
    text = path.read_text(encoding="ascii")
    # osslsigncode's exported root bundle may prepend OpenSSL subject/issuer
    # metadata before the actual PEM block.
    lines = text.splitlines()
    while lines and (not lines[0].strip() or lines[0].startswith(("subject=", "issuer="))):
        lines.pop(0)
    normalized = "\n".join(lines)
    match = re.fullmatch(r"\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\r\n]+)-----END CERTIFICATE-----\s*", normalized)
    if not match:
        raise BaselineIdentityError(f"alpha.7 portable certificate is malformed: {path.name}")
    try:
        return base64.b64decode("".join(match.group(1).split()), validate=True)
    except ValueError as exc:
        raise BaselineIdentityError(f"alpha.7 portable certificate is malformed: {path.name}") from exc


def classify_alpha7_native_admission(observation: dict, *, kind: str) -> dict:
    """Admit only the exact native expiry observation; diagnostics stay ancillary."""
    if kind != ALPHA7["kind"]:
        raise BaselineIdentityError("candidate or other package cannot request alpha.7 expiry admission")
    if not isinstance(observation, dict) or observation.get("collectionComplete") is not True:
        raise BaselineIdentityError("alpha.7 native admission collection is incomplete")
    expected = {
        "msiSHA256": ALPHA7["msiSHA256"],
        "msiSize": ALPHA7["msiSize"],
        "signerSHA1": ALPHA7["signerSHA1"],
        "timestampSHA1": ALPHA7["timestampSHA1"],
        "signerNotBeforeUtc": ALPHA7["signerNotBeforeUtc"],
        "signerNotAfterUtc": ALPHA7["signerNotAfterUtc"],
        "lifetimeSigningEku": ALPHA7["lifetimeSigningEku"],
        "timestampUtc": ALPHA7["timestampUtc"],
        "rfc3161GenTimeUtc": ALPHA7["rfc3161GenTimeUtc"],
        "rfc3161MessageImprintSHA256": ALPHA7["rfc3161MessageImprintSHA256"],
        "signingRootSHA256": ALPHA7["signingRootSHA256"],
        "timestampRootSHA256": ALPHA7["timestampRootSHA256"],
    }
    for field, value in expected.items():
        actual = observation.get(field)
        if field in {"signerNotBeforeUtc", "signerNotAfterUtc"}:
            try:
                actual = datetime.fromisoformat(str(actual).replace("Z", "+00:00")).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            except (TypeError, ValueError):
                pass
        if actual != value:
            raise BaselineIdentityError(f"alpha.7 native observation {field} mismatch")
    status_message = str(observation.get("authenticodeMessage", "")).lower()
    if observation.get("authenticodeStatus") != "UnknownError" or not ("expir" in status_message or "validity period" in status_message):
        raise BaselineIdentityError("alpha.7 Authenticode status is not the observed leaf-expiry result")
    if observation.get("winVerifyTrustHResult") != "0x800B0101" or observation.get("winVerifyTrustCloseHResult") != "0x00000000":
        raise BaselineIdentityError("alpha.7 WinVerifyTrust result is not the exact observed CERT_E_EXPIRED result")
    if observation.get("digestVerified") is not True or observation.get("signatureVerified") is not True or observation.get("timestampVerified") is not True:
        raise BaselineIdentityError("alpha.7 digest/signature/timestamp verification did not succeed independently")
    if observation.get("revocationCoverage") != "not-checked-by-native-policy; portable-explicit-time-CRL-warning-retained":
        raise BaselineIdentityError("alpha.7 native revocation coverage is missing or changed")
    return {
        "admission": "legacy-fixture-admitted:expired-lifetime-signing",
        "kind": ALPHA7["kind"],
        "tuple": dict(ALPHA7),
        "nativeObservation": observation,
        "qualification": "Historical test fixture only; not current Valid; native policy did not check revocation; portable CRL warning remains disclosed.",
    }


def require_candidate_current_valid(observation: dict, *, checked_at_utc: str) -> dict:
    """Candidate never inherits the baseline expiry exception."""
    if (
        not isinstance(observation, dict)
        or observation.get("verdict") != "candidate-current-valid"
        or observation.get("error") is not None
        or observation.get("authenticodeStatus") != "Valid"
        or observation.get("signatureType") != "Authenticode"
        or observation.get("winVerifyTrustHResult") != "0x00000000"
        or observation.get("winVerifyTrustCloseHResult") != "0x00000000"
        or not observation.get("msiSha256")
        or not observation.get("signerSHA1")
        or not observation.get("timestampSHA1")
        or observation.get("pinnedTestRoot", {}).get("sha256") != ALPHA7["signingRootSHA256"]
        or observation.get("pinnedTestRoot", {}).get("store") != "LocalMachine/Root"
        or not isinstance(observation.get("signerChainRoot"), list)
        or len(observation.get("signerChainRoot", [])) != 1
        or not isinstance(observation.get("signerChainRoot", [None])[0], dict)
        or observation["signerChainRoot"][0].get("certificateSha256") != ALPHA7["signingRootSHA256"]
        or not observation.get("verifier", {}).get("powerShell")
        or not observation.get("diagnostic", {}).get("collectionComplete")
    ):
        raise BaselineIdentityError("candidate must pass current native Authenticode and WinVerifyTrust verification")
    try:
        checked = datetime.fromisoformat(checked_at_utc.replace("Z", "+00:00")).astimezone(timezone.utc)
        not_after = datetime.fromisoformat(str(observation["signerNotAfterUtc"]).replace("Z", "+00:00")).astimezone(timezone.utc)
    except (KeyError, TypeError, ValueError) as exc:
        raise BaselineIdentityError("candidate current-valid window evidence is incomplete") from exc
    if checked >= not_after:
        raise BaselineIdentityError("candidate signer has expired; a fresh signed candidate is required")
    return {"status": "candidate-current-valid", "checkedAtUtc": checked.isoformat().replace("+00:00", "Z"), "signerNotAfterUtc": not_after.isoformat().replace("+00:00", "Z"), "observation": observation}
