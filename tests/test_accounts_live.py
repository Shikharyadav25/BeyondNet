"""Real bank signup, funding, live delivery and recovery (no physical BLE)."""
import uuid
from concurrent.futures import ThreadPoolExecutor
import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect
from bank.app import create_app
from bank.demo import DemoDevice

@pytest.fixture
def bank(tmp_path):
    app = create_app(tmp_path)
    with TestClient(app) as client:
        yield app, client

def signup(c, id='sam@beyondnet', role='customer'):
    return c.post('/api/signup', json={'account': id, 'name': 'Sam', 'password': 'demo-password', 'role': role})

def fund(c, d, amount=100000, request_id=None):
    return c.post('/api/topups', headers=d.headers, json={'amount': amount, 'request_id': request_id or str(uuid.uuid4())})

def live(ws, d):
    ws.send_json({'token': d.headers['Authorization'][7:], 'device_id': d.id})
    assert ws.receive_json()['type'] == 'ready'
    assert ws.receive_json()['type'] == 'account'

def until(ws, kind):
    for _ in range(15):
        result = ws.receive_json()
        if result['type'] == kind:
            return result
    raise AssertionError('Missing expected live message')

def test_signup_only_personal_or_merchant_and_zero_balance(bank):
    app, c = bank
    assert signup(c).json()['account'] == {'id': 'sam@beyondnet', 'name': 'Sam', 'role': 'customer', 'balance': 0, 'revision': 0}
    assert signup(c).status_code == 409
    assert signup(c, 'store@beyondnet', 'merchant').status_code == 200
    assert signup(c, 'other@beyondnet', 'relay').status_code == 422
    assert signup(c, 'bad id').status_code == 400
    assert not any(a['role'] == 'relay' for a in c.get('/api/admin/state', headers={'Authorization': 'Bearer '+app.state.db.admin_token}).json()['accounts'])

def test_topup_retry_conflict_bounds_and_double_entry(bank):
    app, c = bank
    signup(c)
    d = DemoDevice(c, 'sam@beyondnet', 'demo-password')
    rid = str(uuid.uuid4())
    assert fund(c, d, request_id=rid).json()['account']['balance'] == 100000
    assert fund(c, d, request_id=rid).json()['duplicate']
    assert fund(c, d, amount=200000, request_id=rid).status_code == 409
    for amount in [0, -100, 1000001, True, 1.5]:
        assert fund(c, d, amount).status_code == 422
    assert c.post('/api/topups', json={'amount': 100, 'request_id': str(uuid.uuid4())}).status_code == 401
    with app.state.db.connect() as db:
        rows = list(db.execute('SELECT * FROM ledger'))
        assert len(rows) == 2 and sum(r['delta'] for r in rows) == 0
        assert db.execute('SELECT balance FROM accounts WHERE id=?', (d.account,)).fetchone()[0] == 100000

def test_concurrent_topup_once_and_restart_recovery(bank, tmp_path):
    app, c = bank
    signup(c)
    d = DemoDevice(c, 'sam@beyondnet', 'demo-password')
    rid = str(uuid.uuid4())
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: fund(c, d, request_id=rid).json(), range(4)))
    assert sum(not r['duplicate'] for r in results) == 1
    with TestClient(create_app(tmp_path)) as restarted:
        assert fund(restarted, d, request_id=rid).json()['account']['balance'] == 100000

def test_new_users_pay_over_websocket_and_merchant_receives_live(bank):
    app, c = bank
    signup(c)
    signup(c, 'shop@beyondnet', 'merchant')
    sender = DemoDevice(c, 'sam@beyondnet', 'demo-password')
    merchant = DemoDevice(c, 'shop@beyondnet', 'demo-password')
    fund(c, sender)
    p, body = sender.payment(recipient=merchant.account, amount=1000)
    with c.websocket_connect('/api/live') as sw, c.websocket_connect('/api/live') as mw:
        live(sw, sender)
        live(mw, merchant)
        sw.send_json({'type': 'submit', 'id': 'first', 'packet': p})
        result = until(sw, 'result')
        assert result['id'] == 'first'
        assert sender.receipt(result['receipts'][0])['status'] == 'paid'
        merchant_batch = until(mw, 'receipts')
        assert merchant.receipt(merchant_batch['receipts'][0])['amount'] == 1000
        sw.send_json({'type': 'submit', 'id': 'retry', 'packet': p})
        assert until(sw, 'result')['duplicate']
    with app.state.db.connect() as db:
        assert db.execute('SELECT balance FROM accounts WHERE id=?', (sender.account,)).fetchone()[0] == 99000
        assert db.execute('SELECT COUNT(*) FROM payments').fetchone()[0] == 1
    # Lost websocket response: reconnect replays the durable inbox without another debit.
    with c.websocket_connect('/api/live') as sw:
        live(sw, sender)
        batch = until(sw, 'receipts')
        assert sender.receipt(batch['receipts'][0])['payment_id'] == body['payment_id']
    assert c.get('/api/receipts/'+merchant.id, headers=sender.headers).status_code == 403
    assert len(c.get('/api/receipts/'+sender.id, headers=sender.headers).json()['receipts']) == 1

def test_any_customer_can_gateway_and_bank_pause_retries_same_packet(bank):
    app, c = bank
    for id, role in [('sam@beyondnet','customer'), ('friend@beyondnet','customer'), ('shop@beyondnet','merchant')]:
        signup(c, id, role)
    sender = DemoDevice(c, 'sam@beyondnet', 'demo-password')
    gateway = DemoDevice(c, 'friend@beyondnet', 'demo-password')
    DemoDevice(c, 'shop@beyondnet', 'demo-password')
    fund(c, sender)
    p, _ = sender.payment(recipient='shop@beyondnet')
    with c.websocket_connect('/api/live') as ws:
        live(ws, gateway)
        app.state.bank_online = False
        ws.send_json({'type': 'submit', 'id': 'paused', 'packet': p})
        assert until(ws, 'error')['status'] == 503
        app.state.bank_online = True
        ws.send_json({'type': 'submit', 'id': 'resumed', 'packet': p})
        assert sender.receipt(until(ws, 'result')['receipts'][0])['status'] == 'paid'

def test_live_rejects_bad_token_other_device_and_revocation(bank):
    app, c = bank
    a = DemoDevice(c, 'alice@karo', 'alice-demo-pass')
    b = DemoDevice(c, 'chai@karo', 'chai-demo-pass')
    for token, device in [('wrong', a.id), (a.headers['Authorization'][7:], b.id)]:
        with c.websocket_connect('/api/live') as ws:
            ws.send_json({'token': token, 'device_id': device})
            with pytest.raises(WebSocketDisconnect):
                ws.receive_json()
    with c.websocket_connect('/api/live') as ws:
        live(ws, a)
        with app.state.db.connect() as db:
            db.execute('UPDATE devices SET revoked=1 WHERE id=?', (a.id,))
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()

def test_recipient_id_lookup_requires_enrolled_device(bank):
    app, c = bank
    signup(c, 'shop@beyondnet', 'merchant')
    a = DemoDevice(c, 'alice@karo', 'alice-demo-pass')
    assert c.get('/api/recipients/shop@beyondnet', headers=a.headers).status_code == 404
    shop = DemoDevice(c, 'shop@beyondnet', 'demo-password')
    cert = c.get('/api/recipients/shop@beyondnet', headers=a.headers).json()['certificate']
    assert cert['body']['device_id'] == shop.id
    assert c.get('/api/recipients/shop@beyondnet').status_code == 401
