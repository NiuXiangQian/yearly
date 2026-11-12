import os
import subprocess
import tempfile
import unittest
from pathlib import Path


class DeviceSigningTests(unittest.TestCase):
    def test_existing_signing_and_failure_never_enable_portal_updates(self):
        script = Path(__file__).resolve().parents[2] / 'scripts/ios.sh'
        for build_status in (0, 65):
            with self.subTest(build_status=build_status), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                xcrun = root / 'xcrun'
                xcrun.write_text('#!/bin/sh\nexit 0\n')
                xcrun.chmod(0o755)
                xcodebuild = root / 'xcodebuild'
                xcodebuild.write_text(
                    '#!/bin/sh\n'
                    'echo invocation >> "$YEARLY_TEST_CALLS"\n'
                    'printf "%s\\n" "$@" >> "$YEARLY_TEST_ARGS"\n'
                    'exit "$YEARLY_TEST_BUILD_STATUS"\n'
                )
                xcodebuild.chmod(0o755)
                arguments_file = root / 'arguments'
                calls_file = root / 'calls'
                environment = {
                    **os.environ,
                    'PATH': str(root) + os.pathsep + os.environ.get('PATH', ''),
                    'YEARLY_TEAM_ID': 'TESTTEAM',
                    'YEARLY_DEVICE_ID': 'test-device',
                    'YEARLY_BUNDLE_ID': 'test.yearly.app',
                    'YEARLY_TEST_ARGS': str(arguments_file),
                    'YEARLY_TEST_CALLS': str(calls_file),
                    'YEARLY_TEST_BUILD_STATUS': str(build_status),
                }
                result = subprocess.run(
                    ['/bin/bash', str(script), 'device'], env=environment,
                    capture_output=True, text=True, timeout=10,
                )
                arguments = arguments_file.read_text().splitlines()
                self.assertEqual(result.returncode, build_status, result.stderr)
                self.assertEqual(calls_file.read_text().splitlines(), ['invocation'])
                self.assertNotIn('-allowProvisioningUpdates', arguments)
                self.assertNotIn('-allowProvisioningDeviceRegistration', arguments)
                self.assertIn('DEVELOPMENT_TEAM=TESTTEAM', arguments)
                self.assertIn('YEARLY_APP_BUNDLE_ID=test.yearly.app', arguments)
                self.assertEqual(arguments[arguments.index('-destination') + 1], 'id=test-device')
                self.assertEqual('Built:' in result.stdout, build_status == 0)


if __name__ == '__main__':
    unittest.main()
