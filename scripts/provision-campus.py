#!/usr/bin/env python3
"""Provision a campus through the local, authenticated bank operator endpoint.

Roster input contains names, IDs, roles and group IDs; passwords are prompted,
never written back to the input file or printed. Use Campus-specific passwords.
"""
import argparse
import getpass
import json
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('roster', type=Path)
    parser.add_argument('--operator-key-file', type=Path, required=True)
    parser.add_argument('--port', type=int, default=8080)
    args = parser.parse_args()
    data = json.loads(args.roster.read_text())
    for member in data['members']:
        password = getpass.getpass(f"Campus-only password for {member['id']}: ")
        if len(password) < 10:
            parser.error('Campus passwords must have at least 10 characters')
        member['password'] = password
    payload = json.dumps(data).encode()
    if len(payload) > 16384:
        parser.error('This operator endpoint accepts at most 16 KB per campus roster')
    request = Request(f'http://127.0.0.1:{args.port}/api/admin/campuses', data=payload,
                      headers={'Content-Type': 'application/json',
                               'Authorization': 'Bearer ' + args.operator_key_file.read_text().strip()})
    try:
        with urlopen(request, timeout=60) as response:
            print(json.dumps(json.load(response), indent=2))
    except HTTPError as error:
        raise SystemExit(f'Provisioning failed ({error.code}): {error.read().decode()}') from None


if __name__ == '__main__':
    main()
