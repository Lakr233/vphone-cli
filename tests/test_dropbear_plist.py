#!/usr/bin/env python3
"""Unit tests for CFW LaunchDaemon plist rewrites."""

import os
import sys
import unittest


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

from patchers.cfw_daemons import DROPBEAR_KEY_ARGS, patch_dropbear_daemon  # noqa: E402


class DropbearPlistTests(unittest.TestCase):
    def test_rewrites_readonly_root_key_generation(self):
        daemon = {
            "ProgramArguments": [
                "/iosbinpack64/usr/local/bin/dropbear",
                "--shell",
                "/iosbinpack64/bin/bash",
                "-R",
                "-E",
                "-F",
                "-p",
                "22222",
                "-a",
            ]
        }

        patch_dropbear_daemon(daemon)

        args = daemon["ProgramArguments"]
        self.assertNotIn("-R", args)
        self.assertEqual(args[-len(DROPBEAR_KEY_ARGS):], DROPBEAR_KEY_ARGS)

    def test_replaces_stale_explicit_key_paths(self):
        daemon = {
            "ProgramArguments": [
                "dropbear",
                "-r",
                "/etc/dropbear/dropbear_rsa_host_key",
                "-E",
                "-r",
                "/tmp/old_ecdsa_key",
                "-p",
                "22222",
            ]
        }

        patch_dropbear_daemon(daemon)

        args = daemon["ProgramArguments"]
        self.assertNotIn("/etc/dropbear/dropbear_rsa_host_key", args)
        self.assertNotIn("/tmp/old_ecdsa_key", args)
        self.assertEqual(args, ["dropbear", "-E", "-p", "22222", *DROPBEAR_KEY_ARGS])


if __name__ == "__main__":
    unittest.main()
