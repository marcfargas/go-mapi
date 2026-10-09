"""Check real diagnostic decoding and host-adapter shape without claiming admission."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from baseline_identity import ALPHA7, BaselineIdentityError, classify_alpha7_native_admission
from run import alpha7_observation_from_diagnostic


def main() -> int:
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    observation = alpha7_observation_from_diagnostic(
        payload["native"], payload["msiSHA256"], payload["msiSize"], payload["portable"],
        "not-checked-by-native-policy; portable-explicit-time-CRL-warning-retained",
    )
    if observation.get("collectionComplete") is not True:
        raise SystemExit("real diagnostic collection was incomplete")
    expected = {
        "msiSHA256": ALPHA7["msiSHA256"], "msiSize": ALPHA7["msiSize"],
        "signerSHA1": ALPHA7["signerSHA1"], "timestampSHA1": ALPHA7["timestampSHA1"],
        "signerNotBeforeUtc": ALPHA7["signerNotBeforeUtc"], "signerNotAfterUtc": ALPHA7["signerNotAfterUtc"],
        "rfc3161GenTimeUtc": ALPHA7["rfc3161GenTimeUtc"],
        "rfc3161MessageImprintSHA256": ALPHA7["rfc3161MessageImprintSHA256"],
    }
    for field, value in expected.items():
        actual = observation.get(field)
        if field in {"signerNotBeforeUtc", "signerNotAfterUtc"}:
            from datetime import datetime, timezone
            try:
                actual = datetime.fromisoformat(str(actual).replace("Z", "+00:00")).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            except (TypeError, ValueError):
                pass
        if actual != value:
            raise SystemExit(f"real diagnostic adapter field {field} differs from the pinned MSI identity")

    try:
        classify_alpha7_native_admission(observation, kind=ALPHA7["kind"])
        gate_outcome = "expired-only-shape-matched"
    except BaselineIdentityError as exc:
        status_gate = str(exc).startswith("alpha.7 Authenticode status")
        trust_gate = str(exc).startswith("alpha.7 WinVerifyTrust result")
        if not (status_gate or trust_gate):
            raise
        if status_gate and observation.get("authenticodeStatus") == "UnknownError" and (
            "expir" in str(observation.get("authenticodeMessage", "")).lower()
            or "validity period" in str(observation.get("authenticodeMessage", "")).lower()
        ):
            raise SystemExit("classifier rejected at status despite the pinned expired-only message") from exc
        if trust_gate and observation.get("winVerifyTrustHResult") == "0x800B0101":
            raise SystemExit("classifier rejected the pinned CERT_E_EXPIRED HRESULT") from exc
        gate_outcome = "rejected-at-observed-native-status-or-hresult"

    print("ALPHA7_DECODER_ADAPTER_SHAPE_PASSED " + json.dumps({
        "nativeStatus": observation.get("authenticodeStatus"),
        "nativeStatusMessage": observation.get("authenticodeMessage"),
        "nativeWinVerifyTrustHResult": observation.get("winVerifyTrustHResult"),
        "gateOutcome": gate_outcome,
        "nativeAdmissionClaimed": False,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
