#!/usr/bin/env python3
"""Create private PSIT Kanpur demo accounts and optionally export a public setup QR."""
import argparse
import json
import os
from pathlib import Path
import secrets
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, build_opener, ProxyHandler

CODE = 'PSIT-KANPUR'
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8090)
    parser.add_argument('--data-dir', type=Path, default=ROOT / 'data/campus-psit')
    parser.add_argument('--public-url', help='HTTPS campus ngrok origin; optional until the tunnel is running')
    args = parser.parse_args()
    os.umask(0o077)
    args.data_dir.mkdir(parents=True, exist_ok=True)
    credentials = args.data_dir / 'demo-credentials.json'
    # Only loopback requests are made here; no enrollment passwords go to ngrok.
    local = build_opener(ProxyHandler({}))
    base = f'http://127.0.0.1:{args.port}'
    key = (args.data_dir / 'admin-token.txt').read_text().strip()

    def request(path, body=None):
        req = Request(base + path, data=None if body is None else json.dumps(body).encode(),
                      headers={'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        with local.open(req, timeout=60) as response:
            return response.read()

    try:
        existing = json.loads(request('/api/campus/' + CODE))
    except HTTPError as error:
        if error.code != 404:
            raise
        existing = None
    if credentials.exists():
        data = json.loads(credentials.read_text())
        if data.get('code') != CODE:
            parser.error('Existing credentials are for another campus; refusing to overwrite')
    elif existing is not None:
        parser.error('PSIT already exists but its credentials file is missing. Restore the private file; passwords will not be reset.')
    else:
        groups = ['cse-a', 'cse-assignments', 'psit-notices']
        members = [dict(id=i, name=n, role=r, groups=groups, password=secrets.token_urlsafe(18)) for i, n, r in [
            ('PSIT-STUDENT-001', 'PSIT demo student A', 'student'),
            ('PSIT-STUDENT-002', 'PSIT demo student B', 'student'),
            ('PSIT-PROF-001', 'PSIT demo professor', 'professor'),
            ('PSIT-HOD-001', 'PSIT demo HOD', 'hod'),
            ('PSIT-ADMIN-001', 'PSIT demo campus authority', 'authority'),
        ]]
        data = dict(code=CODE, name='PSIT Kanpur', members=members, groups={
            'cse-a': dict(name='CSE Section A', kind='section'),
            'cse-assignments': dict(name='CSE assignments', kind='faculty'),
            'psit-notices': dict(name='PSIT campus notices', kind='authority'),
        })
        # Save before the API call so a failed response cannot lose passwords.
        with credentials.open('x') as output:
            json.dump(data, output, indent=2)
    credentials.chmod(0o600)
    if existing is None:
        result = json.loads(request('/api/admin/campuses', data))
        print('Created PSIT Kanpur campus:', result['code'])
    else:
        print('Existing PSIT Kanpur campus retained; credentials unchanged.')
    print('Private demo IDs, roles and passwords:', credentials)
    print('Local operator key:', args.data_dir / 'admin-token.txt')
    if args.public_url:
        query = '?' + urlencode({'campus_url': args.public_url})
        path = '/api/admin/campus/' + CODE + '/setup'
        setup = request(path + query)
        png = request(path + '.png' + query)
        (args.data_dir / 'campus-setup.json').write_bytes(setup)
        (args.data_dir / 'campus-setup.png').write_bytes(png)
        print('Public setup QR:', args.data_dir / 'campus-setup.png')
        print('Public setup details:', args.data_dir / 'campus-setup.json')
    print('Open the campus console on localhost:' + str(args.port) + ' to create the QR after starting ngrok.')


if __name__ == '__main__':
    main()
