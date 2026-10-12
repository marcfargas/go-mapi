"""Debug 773: the standard-user VHD proof must not depend on Get-DiskImage.Number.

The standard-user transaction binds its mount-point profile to the admin-prepared exact VHD path and volume GUID.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from evidence import RunFault  # noqa: E402
from run import require_vhd_binding  # noqa: E402

VHD = r"C:\crabbox\work\ticket569\profile-291-1001.vhdx"
VOLUME = "\\\\?\\Volume{a703422f-0000-0000-0000-100000000000}\\"
BINDING = {"VhdPath": VHD, "VolumeId": VOLUME}


def profile(**changes) -> dict:
    # Shape written by run-user.ps1 for the standard user: Number is null under that token (observed in 774).
    value = {"ProfileKind": "mount-point", "ReparseTag": "0xA0000003", "Volume": VOLUME,
             "Vhd": {"ImagePath": VHD, "Number": None, "Attached": True, "VolumeId": VOLUME}}
    vhd = dict(value["Vhd"], **changes.pop("vhd", {}))
    value.update(changes)
    value["Vhd"] = vhd
    return value


class VhdBindingTests(unittest.TestCase):
    def test_null_disk_number_with_matching_identity_is_accepted(self) -> None:
        require_vhd_binding(profile(), BINDING)
        require_vhd_binding(profile(Volume=VOLUME.rstrip("\\").upper()), BINDING)

    def rejected(self, value: dict, binding: dict | None = BINDING) -> None:
        with self.assertRaises(RunFault) as caught:
            require_vhd_binding(value, binding)
        self.assertEqual(caught.exception.kind, "profile-identity")

    def test_detached_image_is_rejected(self) -> None:
        self.rejected(profile(vhd={"Attached": False}))

    def test_wrong_volume_is_rejected(self) -> None:
        self.rejected(profile(Volume="\\\\?\\Volume{00000000-0000-0000-0000-000000000001}\\"))
        self.rejected(profile(Volume=None))

    def test_wrong_vhd_is_rejected(self) -> None:
        self.rejected(profile(vhd={"ImagePath": r"C:\crabbox\work\ticket569\other.vhdx"}))

    def test_missing_binding_fails_closed(self) -> None:
        self.rejected(profile(), None)
        self.rejected(profile(), {"VhdPath": VHD, "VolumeId": ""})

    def test_guest_scripts_use_the_admin_volume_not_the_disk_number(self) -> None:
        run_user = (HERE / "run-user.ps1").read_text(encoding="utf-8")
        launch_user = (HERE / "launch-user.ps1").read_text(encoding="utf-8")
        self.assertNotRegex(run_user, r"Get-Partition\s+-DiskNumber")
        self.assertIn("[string] $ExpectedVolumeId", run_user)
        self.assertIn("requires the admin-prepared VHD volume GUID", run_user)
        self.assertTrue(re.search(r"-ExpectedVolumeId '\s*\+", launch_user) or "' -ExpectedVolumeId '" in launch_user)


if __name__ == "__main__":
    unittest.main()
