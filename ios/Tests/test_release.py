import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'scripts/validate-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.values = {
            'YEARLY_TEAM_ID': 'ABCDE12345', 'YEARLY_BUNDLE_ID': 'com.acme.yearly',
            'YEARLY_SITE_URL': 'https://family.acme.com',
            'YEARLY_PRIVACY_URL': 'https://acme.com/privacy',
            'YEARLY_SUPPORT_URL': 'https://acme.com/support',
        }

    def test_valid_settings(self):
        release.validate(self.values)

    def test_every_required_setting(self):
        for key in self.values:
            values = self.values.copy()
            del values[key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                release.validate(values)

    def test_reject_insecure_credentials_and_invalid_ports(self):
        for value in ['http://family.acme.com', 'https://user@family.acme.com',
                      'https://family.acme.com:0', 'https://family.acme.com:65536',
                      'https://family.acme.com:bad', 'https://family.acme.com/$(COMMAND)',
                      'https://family.acme.com/with space']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.validate({**self.values, 'YEARLY_SITE_URL': value})

    def test_reject_placeholder_and_local_hosts(self):
        for host in ['example.com', 'family.example.com', 'localhost', 'family.local',
                     '127.0.0.1', '192.168.1.2', '[::1]']:
            with self.subTest(host=host), self.assertRaises(ValueError):
                release.validate({**self.values, 'YEARLY_PRIVACY_URL': 'https://' + host})

    def test_site_is_root_but_policy_allows_path(self):
        for suffix in ['/upload', '?secret=1', '#page']:
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                release.validate({**self.values, 'YEARLY_SITE_URL': self.values['YEARLY_SITE_URL'] + suffix})
        release.validate(self.values)

    def test_bundle_and_version(self):
        for key, value in [('YEARLY_BUNDLE_ID', 'family.yearly.app'), ('YEARLY_BUNDLE_ID', 'no spaces allowed'),
                           ('YEARLY_TEAM_ID', 'placeholder'), ('YEARLY_VERSION', 'v1.0'),
                           ('YEARLY_BUILD_NUMBER', '1.2.3.4')]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                release.validate({**self.values, key: value})


if __name__ == '__main__':
    unittest.main()
