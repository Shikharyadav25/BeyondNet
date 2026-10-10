"""Java HTTP/WSS + independent Python crypto oracle; only temporary demo ledgers."""
import copy
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
import pytest
import httpx
from websockets.sync.client import connect
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from scripts.test_postgres import environment, drop_schema
from tests.support.wire_oracle import public, sign, seal, open_box, verify, packet, canonical

ROOT = Path(__file__).resolve().parents[1]
JAR = ROOT / 'backend/target/bank-1.2.0.jar'


@pytest.fixture
def java_bank(tmp_path):
    if not JAR.exists():
        pytest.fail('Build backend with mvn package before Java integration tests')
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    env = {**environment(), 'KARO_DATA_DIR':str(tmp_path)}
    log = tmp_path / 'test-startup.log'
    with log.open('w') as f:
        process = subprocess.Popen(['java', '-jar', str(JAR), f'--server.port={port}'], cwd=ROOT, env=env, stdout=f, stderr=f)
    client = httpx.Client(base_url=f'http://127.0.0.1:{port}', timeout=20)
    try:
        for _ in range(300):
            try:
                response = client.get('/api/health')
                response.raise_for_status()
                break
            except httpx.HTTPError:
                if process.poll() is not None:
                    pytest.fail('Java startup failed: ' + log.read_text()[-3000:])
                time.sleep(.1)
        else:
            pytest.fail('Java readiness timed out')
        yield client, tmp_path, port
    finally:
        client.close()
        process.terminate()
        process.wait(timeout=15)
        drop_schema(env)


class Device:
    def __init__(self, client, account, role='customer', signup=True):
        self.client, self.account = client, account
        self.password = 'integration-password'
        if signup:
            response = client.post('/api/signup', json={'account': account, 'name': account, 'password': self.password, 'role': role})
        else:
            response = client.post('/api/login', json={'account': account, 'password': self.password})
        response.raise_for_status()
        self.trust = response.json()['trust']
        self.token = response.json()['token']
        self.headers = {'Authorization': 'Bearer ' + self.token}
        self.signing, self.box = ed25519.Ed25519PrivateKey.generate(), x25519.X25519PrivateKey.generate()
        self.id = str(uuid.uuid4())
        identity = {'device_id': self.id, 'account_id': account, 'sign_key': public(self.signing), 'box_key': public(self.box)}
        response = client.post('/api/devices', headers=self.headers, json={k: v for k, v in identity.items() if k != 'account_id'} | {'proof': sign(self.signing, identity)['signature']})
        response.raise_for_status()
        self.certificate = response.json()['certificate']
        verify(self.trust['sign_key'], self.certificate)

    def pin(self, value='123456'):
        r = self.client.post('/api/pin', headers=self.headers, json={'pin': value, 'password': self.password})
        r.raise_for_status()
        return r.json()

    def fund(self, amount=100000):
        r = self.client.post('/api/topups', headers=self.headers, json={'amount': amount, 'request_id': str(uuid.uuid4())})
        r.raise_for_status()

    def payment(self, recipient='shop@beyondnet', amount=1000, **changes):
        now = int(time.time())
        b = {'v': 2, 'payment_id': str(uuid.uuid4()), 'sender': self.account, 'recipient': recipient, 'amount': amount, 'currency': 'INR', 'created_at': now, 'expires_at': now + 600, 'device_id': self.id, 'sender_mailbox': uuid.uuid4().hex + uuid.uuid4().hex[:16], 'recipient_mailbox': uuid.uuid4().hex + uuid.uuid4().hex[:16], 'pin': '123456'} | changes
        p = packet('payment', seal(self.trust['box_key'], sign(self.signing, b)), b['sender_mailbox'], b['expires_at'])
        return p, b

    def receipt(self, p):
        result = verify(self.trust['sign_key'], open_box(self.box, p['box']))
        assert result['device_id'] == self.id
        return result


def test_java_http_and_websocket_payment_recovery(java_bank):
    c, data, port = java_bank
    assert c.get('/').status_code == 200
    assert c.get('/static/app.js').status_code == 200
    assert c.get('/static/style.css').status_code == 200
    assert c.get('/api/admin/state').status_code == 401
    sender, merchant = Device(c, 'sam@beyondnet'), Device(c, 'shop@beyondnet', 'merchant')
    sender.pin(); sender.fund()
    p, body = sender.payment()
    with connect(f'ws://127.0.0.1:{port}/api/live') as sw, connect(f'ws://127.0.0.1:{port}/api/live') as mw:
        for ws, d in [(sw, sender), (mw, merchant)]:
            ws.send(json.dumps({'token': d.token, 'device_id': d.id}))
            assert json.loads(ws.recv(timeout=5))['type'] == 'ready'
            assert json.loads(ws.recv(timeout=5))['type'] == 'account'
        sw.send(json.dumps({'type': 'submit', 'id': 'live-payment', 'packet': p}))
        result = json.loads(sw.recv(timeout=10))
        assert result['type'] == 'result'
        assert sender.receipt(result['receipts'][0])['status'] == 'paid'
        batch = json.loads(mw.recv(timeout=10))
        while batch['type'] != 'receipts':
            batch = json.loads(mw.recv(timeout=10))
        assert merchant.receipt(batch['receipts'][0])['amount'] == 1000
    again = c.post('/api/packets', json=p, headers=merchant.headers)
    assert again.json()['duplicate']
    assert again.json()['receipts'] == result['receipts']
    inbox = c.get('/api/receipts/' + sender.id, headers=sender.headers).json()
    assert sender.receipt(inbox['receipts'][0])['payment_id'] == body['payment_id']
    assert c.get('/api/receipts/' + merchant.id, headers=sender.headers).status_code == 403
    assert c.get('/api/me', headers=sender.headers).json()['account']['balance'] == 99000
    admin = {'Authorization': 'Bearer ' + (data / 'admin-token.txt').read_text().strip()}
    state = c.get('/api/admin/state', headers=admin).json()
    assert len(state['payments']) == 1 and sum(x['delta'] for x in state['ledger']) == 0


def test_multiple_gateways_tampering_expiry_and_pin(java_bank):
    c, _, _ = java_bank
    sender, merchant, relay = Device(c, 'sam@beyondnet'), Device(c, 'shop@beyondnet', 'merchant'), Device(c, 'friend@beyondnet')
    sender.pin(); sender.fund()
    p, b = sender.payment()
    def upload(i):
        return c.post('/api/packets', headers=(relay if i % 2 else merchant).headers, json=p).json()
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(upload, range(12)))
    assert sum(not r['duplicate'] for r in results) == 1
    assert all(r['receipts'] == results[0]['receipts'] for r in results)
    changed = {**b, 'amount': 1001}
    conflict = packet('payment', seal(sender.trust['box_key'], sign(sender.signing, changed)), b['sender_mailbox'], b['expires_at'])
    assert c.post('/api/packets', headers=relay.headers, json=conflict).status_code == 409
    bad = copy.deepcopy(p); bad['box']['ciphertext'] = 'AAAA'
    assert c.post('/api/packets', headers=relay.headers, json=bad).status_code == 400
    expired, _ = sender.payment(created_at=int(time.time())-700, expires_at=int(time.time())-100)
    assert sender.receipt(c.post('/api/packets', headers=relay.headers, json=expired).json()['receipts'][0])['status'] == 'rejected'
    wrong, _ = sender.payment(pin='000000')
    receipt = sender.receipt(c.post('/api/packets', headers=relay.headers, json=wrong).json()['receipts'][0])
    assert receipt['status'] == 'rejected' and 'PIN' in receipt['reason']
    assert c.get('/api/me', headers=sender.headers).json()['account']['balance'] == 99000
    assert c.post('/api/packets', json=p).status_code == 401
    assert c.post('/api/packets', content=b'x' * 17000, headers=relay.headers).status_code == 413
    assert c.post('/api/topups', headers=sender.headers, json={'request_id': str(uuid.uuid4()), 'amount': True}).status_code == 422


def test_java_imports_old_python_identity_passwords_and_completed_receipts(tmp_path):
    # Frozen synthetic old-bank ledger: no Python web backend is shipped or started.
    import sqlite3
    f=json.loads((ROOT/'tests/fixtures/legacy-migration.json').read_text())
    (tmp_path/'bank-keys.json').write_text(json.dumps(f['keys']))
    (tmp_path/'admin-token.txt').write_text(f['operator_token'])
    with sqlite3.connect(tmp_path/'bank.sqlite3') as legacy:
        legacy.executescript(f['sqlite_sql'])
        legacy.execute('UPDATE sessions SET expiry=?',(int(time.time())+3600,))
    p, original, fingerprint, token = f['packet'], f['response'], f['fingerprint'], f['operator_token']
    headers={'Authorization':f['session_token']}
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
    env={**environment(),'KARO_DATA_DIR':str(tmp_path)}
    process = subprocess.Popen(['java','-jar',str(JAR),f'--server.port={port}'],cwd=ROOT,env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        with httpx.Client(base_url=f'http://127.0.0.1:{port}',timeout=15) as c:
            for _ in range(300):
                try:
                    health=c.get('/api/health');health.raise_for_status();break
                except httpx.HTTPError:time.sleep(.1)
            assert health.json()['fingerprint']==fingerprint
            assert (tmp_path/'admin-token.txt').read_text().strip()==token
            c.post('/api/login',json={'account':'sam@beyondnet','password':'integration-password'}).raise_for_status()
            recovered=c.post('/api/packets',headers=headers,json=p)
            assert recovered.json()['duplicate'] and recovered.json()['receipts']==original['receipts']
            assert c.get('/api/me',headers=headers).json()['account']['balance']==99000
    finally:
        process.terminate();process.wait(timeout=15)
        drop_schema(env)


def test_bank_setup_qr_endpoint_is_operator_scoped_and_public_only(java_bank):
    c, data, _ = java_bank
    body={'bank_url':'https://bank.example'}
    assert c.post('/api/admin/setup-qr',json=body).status_code==401
    headers={'Authorization':'Bearer '+(data/'admin-token.txt').read_text().strip()}
    qr=c.post('/api/admin/setup-qr',headers=headers,json=body)
    assert qr.status_code==200 and qr.headers['content-type'].startswith('image/png')
    assert qr.content.startswith(b'\x89PNG\r\n\x1a\n')
    assert c.post('/api/admin/setup-qr',headers=headers,json={'bank_url':'http://bank.example'}).status_code==422
