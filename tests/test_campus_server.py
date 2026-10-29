"""Live isolated campus profile, private provisioning and encrypted sync regression tests."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid

import httpx
import pytest
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from scripts.test_postgres import environment, drop_schema
from tests.support.wire_oracle import b64, unb64, canonical, public, sign, verify

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def campus_server(tmp_path):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    runtime = {**environment(), 'KARO_DATA_DIR': str(tmp_path)}
    with (tmp_path / 'startup.log').open('w') as output:
        process = subprocess.Popen(['java', '-jar', str(ROOT / 'backend/target/bank-1.3.3.jar'),
                                    '--spring.profiles.active=campus', f'--server.port={port}'],
                                   cwd=ROOT, env=runtime, stdout=output, stderr=output)
    client = httpx.Client(base_url=f'http://127.0.0.1:{port}', timeout=20, trust_env=False)
    try:
        for _ in range(200):
            try:
                if client.get('/api/campus-health').status_code == 200:
                    break
            except httpx.HTTPError:
                pass
            if process.poll() is not None:
                pytest.fail((tmp_path / 'startup.log').read_text()[-3000:])
            time.sleep(.1)
        else:
            pytest.fail('Campus startup timed out')
        command = [os.environ.get('BEYONDNET_TEST_PYTHON', str(ROOT / '.venv/bin/python')), str(ROOT / 'scripts/setup-psit.py'),
                   '--port', str(port), '--data-dir', str(tmp_path)]
        subprocess.run(command, cwd=ROOT, check=True, capture_output=True)
        yield client, tmp_path, command
    finally:
        client.close()
        process.terminate()
        process.wait(timeout=15)
        drop_schema(runtime)


def test_campus_profile_excludes_bank_and_protects_operator(campus_server):
    client, directory, _ = campus_server
    assert client.get('/api/campus-health').json()['database'] == 'postgresql'
    assert client.get('/api/health').status_code == 404
    assert client.post('/api/signup', json={}).status_code == 404
    assert not (directory / 'bank-keys.json').exists()
    assert client.get('/').status_code == 200
    assert client.get('/', headers={'X-Forwarded-For': '192.0.2.9'}).status_code == 403
    path = '/api/admin/campus/PSIT-KANPUR/setup'
    params = {'campus_url': 'https://campus.example'}
    assert client.get(path, params=params).status_code == 401
    headers = {'Authorization': 'Bearer ' + (directory / 'admin-token.txt').read_text().strip()}
    assert client.get(path, params=params, headers={**headers, 'X-Forwarded-For': '192.0.2.9'}).status_code == 403
    assert client.get(path, params={'campus_url': 'http://campus.example'}, headers=headers).status_code == 422
    setup = client.get(path, params=params, headers=headers).json()
    assert set(setup) == {'type', 'v', 'campus_url', 'code', 'fingerprint'}
    assert setup['type'] == 'beyondnet-campus-setup'
    key = client.get('/api/campus/PSIT-KANPUR').json()['public_key']
    assert setup['fingerprint'] == hashlib.sha256(unb64(key)).hexdigest()
    image = client.get(path + '.png', params=params, headers=headers)
    assert image.status_code == 200 and image.content.startswith(b'\x89PNG\r\n\x1a\n')


def test_generated_roster_is_private_and_repeatable(campus_server):
    client, directory, command = campus_server
    path = directory / 'demo-credentials.json'
    before = path.read_bytes()
    subprocess.run(command, cwd=ROOT, check=True, capture_output=True)
    assert path.read_bytes() == before
    assert path.stat().st_mode & 0o777 == 0o600
    roster = json.loads(before)
    assert {m['role'] for m in roster['members']} == {'student', 'professor', 'hod', 'authority'}
    assert len({m['password'] for m in roster['members']}) == 5
    assert all(len(m['password']) >= 20 for m in roster['members'])
    invalid = client.post('/api/campus/enroll', json={'code': 'PSIT-KANPUR', 'id': 'PSIT-STUDENT-001',
                          'password': 'incorrect-password', 'public_key': public(ed25519.Ed25519PrivateKey.generate())})
    assert invalid.status_code == 401


def test_encrypted_group_delivery_idempotency_and_role_permissions(campus_server):
    client, directory, _ = campus_server
    roster = json.loads((directory / 'demo-credentials.json').read_text())
    trust = client.get('/api/campus/PSIT-KANPUR').json()['public_key']

    def enroll(role):
        member = next(m for m in roster['members'] if m['role'] == role)
        key = ed25519.Ed25519PrivateKey.generate()
        result = client.post('/api/campus/enroll', json={'code': 'PSIT-KANPUR', 'id': member['id'],
                             'password': member['password'], 'public_key': public(key)})
        result.raise_for_status()
        session = result.json()
        assert verify(trust, session['certificate'])['role'] == role
        return key, session

    student_key, student = enroll('student')
    professor_key, professor = enroll('professor')

    def packet(key, session, group, text, kind):
        nonce = os.urandom(12)
        aad = canonical({'campus': 'PSIT-KANPUR', 'group': group, 'type': 'beyondnet/campus-content/v1'})
        cipher = AESGCM(unb64(session['groups'][group]['key'])).encrypt(nonce, canonical({'text': text, 'kind': kind}), aad)
        signed = sign(key, {'type': 'beyondnet/campus-message/v1', 'campus': 'PSIT-KANPUR', 'group': group,
                           'created_at': int(time.time()), 'expires_at': session['certificate']['body']['expires_at'],
                           'nonce_id': uuid.uuid4().hex, 'priority': 0, 'box': {'nonce': b64(nonce), 'ciphertext': b64(cipher)}})
        return {'id': hashlib.sha256(canonical(signed)).hexdigest(), 'signed': signed, 'certificate': session['certificate']}

    def sync(key, session, offered=None, after=0):
        request_id = uuid.uuid4().hex
        result = client.post('/api/campus/sync', json={'code': 'PSIT-KANPUR', 'certificate': session['certificate'],
                             'request': sign(key, {'type': 'beyondnet/campus-sync/v1', 'campus': 'PSIT-KANPUR',
                                                  'at': int(time.time()), 'request_id': request_id, 'after': after, 'packet': offered})})
        if result.status_code != 200:
            return result
        receipt = verify(trust, result.json())
        assert receipt['request_id'] == request_id
        return receipt

    message = packet(professor_key, professor, 'cse-assignments', 'Read chapter 2 before Friday', 'assignment')
    assert 'Read chapter 2' not in json.dumps(message)
    assert sync(professor_key, professor, message)['accepted'] == message['id']
    assert sync(professor_key, professor, message)['accepted'] == message['id']
    received = sync(student_key, student)
    body = verify(public(professor_key), received['packet']['signed'])
    box = body['box']
    aad = canonical({'campus': 'PSIT-KANPUR', 'group': 'cse-assignments', 'type': 'beyondnet/campus-content/v1'})
    plain = AESGCM(unb64(student['groups']['cse-assignments']['key'])).decrypt(unb64(box['nonce']), unb64(box['ciphertext']), aad)
    assert json.loads(plain) == {'text': 'Read chapter 2 before Friday', 'kind': 'assignment'}
    assert sync(student_key, student, after=received['after'])['packet'] is None
    forbidden = packet(student_key, student, 'cse-assignments', 'Forged assignment', 'assignment')
    assert sync(student_key, student, forbidden).status_code == 400
    tampered = dict(message, id='forged')
    assert sync(professor_key, professor, tampered).status_code == 400
