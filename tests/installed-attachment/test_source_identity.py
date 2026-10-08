import hashlib
import tempfile
import unittest
from pathlib import Path

from evidence import RunFault
from run import validate_source


class SourceIdentityTests(unittest.TestCase):
    def test_archive_checkout_requires_matching_explicit_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            root.mkdir()
            archive = Path(directory) / "source.zip"
            archive.write_bytes(b"source archive bytes")
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            self.assertEqual(validate_source(root, "a" * 40, archive, digest), digest)
            with self.assertRaisesRegex(RunFault, "differs from its explicit identity"):
                validate_source(root, "a" * 40, archive, "0" * 64)

    def test_archive_checkout_without_archive_identity_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            root.mkdir()
            with self.assertRaisesRegex(RunFault, "requires --source-archive"):
                validate_source(root, "a" * 40)


if __name__ == "__main__":
    unittest.main()
