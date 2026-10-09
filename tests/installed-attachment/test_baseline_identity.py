import json
import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from baseline_identity import (
    ALPHA7,
    ASSET_HASHES,
    BaselineIdentityError,
    classify_alpha7_native_admission,
    require_candidate_current_valid,
    validate_alpha7_assets,
    validate_alpha7_portable_evidence,
)


def valid_alpha7_observation():
    return {
        "collectionComplete": True,
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
        "authenticodeStatus": "UnknownError",
        "authenticodeMessage": "A required certificate is not within its validity period when verifying against the current system clock or the timestamp in the signed file.",
        "winVerifyTrustHResult": "0x800B0101",
        "winVerifyTrustCloseHResult": "0x00000000",
        "digestVerified": True,
        "signatureVerified": True,
        "timestampVerified": True,
        "revocationCoverage": "not-checked-by-native-policy; portable-explicit-time-CRL-warning-retained",
        "ancillaryDiagnostic": {"diagnosticOnly": True, "chainStatus": ["NotSignatureValid"]},
    }


class Alpha7AdmissionTests(unittest.TestCase):
    def test_portable_evidence_uses_and_rejects_pinned_digest_observation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            signing_der = b"fixture signing root DER"
            timestamp_der = b"fixture timestamp root DER"
            overrides = {
                "signingRootSHA256": hashlib.sha256(signing_der).hexdigest(),
                "timestampRootSHA256": hashlib.sha256(timestamp_der).hexdigest(),
            }
            with patch.dict(ALPHA7, overrides):
                files = {
                    "alpha7-historical-verify.log": (
                        f"Calculated message digest        : {ALPHA7['msiSHA256'].upper()}\n"
                        "Signature verification: ok\nTimestamp Server Signature verification: ok\n"
                        "Timestamp Server Signature CRL verification: ok\nSignature CRL verification: ok\n"
                        "Warning: Ignoring 'certificate has expired' error for CRL validation\n"
                        "\tTimestamp time: Sep 28 17:32:29 2026 GMT\nnotAfter : Sep 30 10:11:51 2026 GMT\n"
                    ),
                    "alpha7-current-verify.log": "Timestamp Server Signature verification is disabled\nError: certificate has expired\nSignature verification: failed\n",
                    "alpha7-altered-verify.log": "Calculated DigitalSignature digest MISMATCH!!!\nSignature verification: failed\n",
                    "alpha7-altered.msi": "altered fixture",
                    "inputs/root-test.pem": "certificate fixture",
                    "inputs/microsoft-identity-root-2020.pem": "timestamp fixture",
                    "inputs/all-crls.pem": "CRL fixture",
                    "verifier/osslsigncode": "verifier fixture",
                    "provenance.txt": "fixture provenance",
                }
                for relative, content in files.items():
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(content, encoding="ascii")
                entries = []
                for relative in sorted(files):
                    digest = hashlib.sha256((root / relative).read_bytes()).hexdigest()
                    entries.append(f"{digest}  ./{relative}\n")
                sums = root / "SHA256SUMS"
                sums.write_text("".join(entries), encoding="ascii")
                ALPHA7["portableEvidenceSHA256SUMS"] = hashlib.sha256(sums.read_bytes()).hexdigest()
                decode = lambda path: signing_der if path.name == "root-test.pem" else timestamp_der
                with patch("baseline_identity.base64_decode_pem", side_effect=decode):
                    result = validate_alpha7_portable_evidence(root)
                self.assertTrue(result["historical"]["digestVerified"])
                self.assertTrue(result["historical"]["signatureVerified"])
                self.assertTrue(result["historical"]["timestampVerified"])
                self.assertTrue(result["historical"]["signingCrlWarning"])
                (root / "alpha7-historical-verify.log").write_text("changed", encoding="ascii")
                with patch("baseline_identity.base64_decode_pem", side_effect=decode):
                    with self.assertRaisesRegex(BaselineIdentityError, "file hash mismatch"):
                        validate_alpha7_portable_evidence(root)

    def test_exact_native_expired_only_admission_preserves_ancillary_chain_diagnostic(self):
        result = classify_alpha7_native_admission(valid_alpha7_observation(), kind=ALPHA7["kind"])
        self.assertEqual(result["admission"], "legacy-fixture-admitted:expired-lifetime-signing")
        self.assertEqual(result["nativeObservation"]["ancillaryDiagnostic"]["chainStatus"], ["NotSignatureValid"])
        self.assertIn("not current Valid", result["qualification"])

    def test_real_windows_validity_period_message_is_accepted_but_other_status_and_hresult_still_reject(self):
        observation = valid_alpha7_observation()
        self.assertEqual(classify_alpha7_native_admission(observation, kind=ALPHA7["kind"])["admission"],
                         "legacy-fixture-admitted:expired-lifetime-signing")
        wrong_status = dict(observation, authenticodeStatus="Valid")
        with self.assertRaisesRegex(BaselineIdentityError, "Authenticode status"):
            classify_alpha7_native_admission(wrong_status, kind=ALPHA7["kind"])
        wrong_hresult = dict(observation, winVerifyTrustHResult="0x800B0109")
        with self.assertRaisesRegex(BaselineIdentityError, "WinVerifyTrust result"):
            classify_alpha7_native_admission(wrong_hresult, kind=ALPHA7["kind"])

    def test_native_diagnostic_fractional_certificate_dates_normalize_to_pinned_seconds(self):
        observation = valid_alpha7_observation()
        observation["signerNotBeforeUtc"] = "2026-09-27T10:11:51.0000000Z"
        observation["signerNotAfterUtc"] = "2026-09-30T10:11:51.0000000Z"
        self.assertEqual(classify_alpha7_native_admission(observation, kind=ALPHA7["kind"])["admission"],
                         "legacy-fixture-admitted:expired-lifetime-signing")

    def test_pem_parser_accepts_openssl_subject_and_issuer_preamble(self):
        from baseline_identity import base64_decode_pem
        import base64
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "root-test.pem"
            der = b"certificate DER fixture"
            encoded = base64.b64encode(der).decode("ascii")
            path.write_text(f"subject=CN = fixture\nissuer=CN = root\n-----BEGIN CERTIFICATE-----\n{encoded}\n-----END CERTIFICATE-----\n", encoding="ascii")
            self.assertEqual(base64_decode_pem(path), der)

    def test_expiry_exception_is_unavailable_to_candidate_or_arbitrary_kind(self):
        for kind in ("candidate", "baseline", "historical", ""):
            with self.subTest(kind=kind), self.assertRaises(BaselineIdentityError):
                classify_alpha7_native_admission(valid_alpha7_observation(), kind=kind)

    def test_native_expired_only_gate_rejects_each_wrong_tuple_and_incomplete_collection(self):
        required_fields = (
            "msiSHA256", "msiSize", "signerSHA1", "timestampSHA1", "signerNotBeforeUtc",
            "signerNotAfterUtc", "lifetimeSigningEku", "timestampUtc", "signingRootSHA256",
            "timestampRootSHA256", "authenticodeStatus", "authenticodeMessage", "winVerifyTrustHResult",
            "winVerifyTrustCloseHResult", "digestVerified", "signatureVerified", "timestampVerified",
            "revocationCoverage", "rfc3161GenTimeUtc", "rfc3161MessageImprintSHA256",
        )
        for field in required_fields:
            observation = valid_alpha7_observation()
            observation[field] = "wrong" if isinstance(observation[field], str) else False
            with self.subTest(field=field), self.assertRaises(BaselineIdentityError):
                classify_alpha7_native_admission(observation, kind=ALPHA7["kind"])
        incomplete = valid_alpha7_observation()
        incomplete["collectionComplete"] = False
        with self.assertRaisesRegex(BaselineIdentityError, "incomplete"):
            classify_alpha7_native_admission(incomplete, kind=ALPHA7["kind"])

    def test_all_five_asset_pins_and_release_api_provenance_are_mandatory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = {}
            api_assets = []
            for key, (name, digest) in ASSET_HASHES.items():
                path = root / name
                path.write_bytes(b"pinned fixture")
                paths[key] = path
                api_assets.append({"name": name, "digest": f"sha256:{digest}"})
            api_path = root / "alpha7-release-api.json"
            api_path.write_text(json.dumps({"tag_name": ALPHA7["tag"], "published_at": "2026-09-28T17:33:00Z", "assets": api_assets}))
            proof = {
                "commit": ALPHA7["sourceCommit"], "workflowRevision": ALPHA7["sourceCommit"],
                "runId": ALPHA7["validationRunId"], "runAttempt": ALPHA7["validationAttempt"],
                "tag": ALPHA7["tag"], "assetName": ALPHA7["msiName"],
                "msi": {"sha256": ALPHA7["msiSHA256"], "size": ALPHA7["msiSize"]},
                "signatures": [{"file": ALPHA7["msiName"], "status": "Valid", "signerThumbprint": ALPHA7["signerSHA1"], "timestampThumbprint": ALPHA7["timestampSHA1"]}],
            }
            paths["validation"].write_text(json.dumps(proof))
            paths["msi"].write_bytes(b"x" * ALPHA7["msiSize"])
            hashes = {path: digest for path, (_, digest) in zip(paths.values(), ASSET_HASHES.values())}
            hashes[api_path] = ALPHA7["releaseApiSHA256"]
            with patch("baseline_identity._sha256", side_effect=lambda path: hashes[Path(path)]):
                with self.assertRaisesRegex(BaselineIdentityError, "proof asset hashes"):
                    validate_alpha7_assets(paths, release_api=api_path, kind=ALPHA7["kind"])

            with self.assertRaisesRegex(BaselineIdentityError, "all five"):
                validate_alpha7_assets({k: v for k, v in paths.items() if k != "targets"}, release_api=api_path, kind=ALPHA7["kind"])
            with self.assertRaisesRegex(BaselineIdentityError, "exact-alpha7"):
                validate_alpha7_assets(paths, release_api=api_path, kind="candidate")

    def test_candidate_validity_fails_closed_at_not_after(self):
        candidate = {
            "authenticodeStatus": "Valid", "signatureType": "Authenticode",
            "winVerifyTrustHResult": "0x00000000", "winVerifyTrustCloseHResult": "0x00000000",
            "msiSha256": "a" * 64, "signerSHA1": "1" * 40, "timestampSHA1": "2" * 40,
            "signerNotAfterUtc": "2026-10-12T10:00:00Z",
            "verdict": "candidate-current-valid", "error": None,
            "pinnedTestRoot": {"sha256": ALPHA7["signingRootSHA256"], "store": "LocalMachine/Root"},
            "signerChainRoot": [{"certificateSha256": ALPHA7["signingRootSHA256"]}],
            "verifier": {"powerShell": "5.1"}, "diagnostic": {"collectionComplete": True},
        }
        self.assertEqual(require_candidate_current_valid(candidate, checked_at_utc="2026-10-12T09:59:59Z")["status"], "candidate-current-valid")
        for checked in ("2026-10-12T10:00:00Z", "2026-10-12T10:00:01Z"):
            with self.subTest(checked=checked), self.assertRaisesRegex(BaselineIdentityError, "expired"):
                require_candidate_current_valid(candidate, checked_at_utc=checked)
        candidate["authenticodeStatus"] = "UnknownError"
        with self.assertRaisesRegex(BaselineIdentityError, "current native"):
            require_candidate_current_valid(candidate, checked_at_utc="2026-10-12T09:00:00Z")
        candidate["authenticodeStatus"] = "Valid"
        candidate["signerChainRoot"] = [{"certificateSha256": "wrong"}]
        with self.assertRaisesRegex(BaselineIdentityError, "current native"):
            require_candidate_current_valid(candidate, checked_at_utc="2026-10-12T09:00:00Z")

    def test_candidate_verdict_error_and_root_identity_are_mandatory(self):
        candidate = {
            "authenticodeStatus": "Valid", "signatureType": "Authenticode",
            "winVerifyTrustHResult": "0x00000000", "winVerifyTrustCloseHResult": "0x00000000",
            "msiSha256": "a" * 64, "signerSHA1": "1" * 40, "timestampSHA1": "2" * 40,
            "signerNotAfterUtc": "2026-10-12T10:00:00Z", "verdict": "candidate-current-valid", "error": None,
            "pinnedTestRoot": {"sha256": ALPHA7["signingRootSHA256"], "store": "LocalMachine/Root"},
            "signerChainRoot": [{"certificateSha256": ALPHA7["signingRootSHA256"]}],
            "verifier": {"powerShell": "5.1"}, "diagnostic": {"collectionComplete": True},
        }
        for field, value in (("verdict", "unknown"), ("error", {"message": "failed"}),
                             ("pinnedTestRoot", {"sha256": "0" * 64, "store": "LocalMachine/Root"}),
                             ("signerChainRoot", [{"certificateSha256": "wrong"}]),
                             ("diagnostic", {"collectionComplete": False})):
            broken = dict(candidate)
            broken[field] = value
            with self.subTest(field=field), self.assertRaises(BaselineIdentityError):
                require_candidate_current_valid(broken, checked_at_utc="2026-10-12T09:00:00Z")


if __name__ == "__main__":
    unittest.main()
