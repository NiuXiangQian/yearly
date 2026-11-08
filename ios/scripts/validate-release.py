#!/usr/bin/env python3
"""Reject missing/placeholder publishing settings before contacting Apple."""
import os
import re
import ipaddress
from urllib.parse import urlsplit


def validate(values):
    if not re.fullmatch(r'[A-Z0-9]{10}', values.get('YEARLY_TEAM_ID', '')):
        raise ValueError('YEARLY_TEAM_ID must be your 10-character Apple Team ID')
    bundle = values.get('YEARLY_BUNDLE_ID', '')
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle) or bundle == 'family.yearly.app':
        raise ValueError('Use your own registered YEARLY_BUNDLE_ID')
    for key in ['YEARLY_SITE_URL', 'YEARLY_PRIVACY_URL', 'YEARLY_SUPPORT_URL']:
        value = values.get(key, '')
        url = urlsplit(value)
        host = (url.hostname or '').lower()
        if (url.scheme != 'https' or not host or url.username is not None or url.password is not None
                or any(ch.isspace() for ch in value) or any(ch in value for ch in '$()\\')
                or not 1 <= (url.port if url.port is not None else 443) <= 65535):
            raise ValueError(f'{key} must be a valid HTTPS URL without credentials')
        if any(host == domain or host.endswith('.' + domain) for domain in ['example.com', 'example.org', 'example.net', 'localhost']) or host.endswith(('.test', '.invalid', '.local')):
            raise ValueError(f'{key} still uses a placeholder or local domain')
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            address = None
        if address is not None and not address.is_global:
            raise ValueError(f'{key} uses a private or local IP address')
        if key == 'YEARLY_SITE_URL':
            valid_path = url.path in ['', '/'] or re.fullmatch(r'(/[A-Za-z0-9_-]+)+/?', url.path)
            if not valid_path or url.query or url.fragment:
                raise ValueError('YEARLY_SITE_URL must be a site URL with an optional installation path')
    for key, default in [('YEARLY_VERSION', '1.0'), ('YEARLY_BUILD_NUMBER', '1')]:
        if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', values.get(key, default)):
            raise ValueError(f'{key} must contain one to three numeric components')


if __name__ == '__main__':
    try:
        validate(os.environ)
    except ValueError as error:
        raise SystemExit(str(error))
    print('Release configuration validated. Public URL reachability and policy content still require review.')
