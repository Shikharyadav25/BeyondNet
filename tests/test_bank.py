import copy
import time
from concurrent.futures import ThreadPoolExecutor
import pytest
from fastapi.testclient import TestClient
from bank.app import create_app
from bank.crypto import seal, sign, packet, public
from bank.demo import DemoDevice, rehearse

@pytest.fixture
def bank(tmp_path):
    app=create_app(tmp_path)
    with TestClient(app) as client:
        merchant=DemoDevice(client,'chai@karo','chai-demo-pass')
        sender=DemoDevice(client,'alice@karo','alice-demo-pass')
        gateway=DemoDevice(client,'gateway@karo','gateway-demo-pass')
        yield app,client,sender,merchant,gateway

def state(app,c):
    return c.get('/api/admin/state',headers={'Authorization':'Bearer '+app.state.db.admin_token}).json()

def test_offline_multi_hop_receipt_and_duplicate(bank):
    app,c,a,m,g=bank
    relay=DemoDevice(c,'relay@karo','relay-demo-pass')
    p,b=a.payment()
    assert a.forward_to(relay)==1
    assert relay.forward_to(g)==1
    response=g.upload(g.queue[p['id']]);assert response.status_code==200
    for r in response.json()['receipts']:g.receive(r)
    g.forward_to(relay);relay.forward_to(a)
    receipt=a.receipt(a.queue[next(r['id'] for r in response.json()['receipts'] if r['mailbox']==b['sender_mailbox'])])
    assert receipt['status']=='paid' and receipt['amount']==12500
    assert len(state(app,c)['ledger'])==2
    assert g.upload(p).json()['duplicate']
    assert len(state(app,c)['ledger'])==2
    assert sum(x['delta'] for x in state(app,c)['ledger'])==0

def test_bank_unreachable_then_retry(bank):
    app,c,a,m,g=bank;p,b=a.payment()
    app.state.bank_online=False
    assert g.upload(p).status_code==503
    assert not state(app,c)['ledger']
    app.state.bank_online=True
    assert g.upload(p).status_code==200
    assert len(state(app,c)['ledger'])==2

def test_insufficient_funds_rejection_never_executes_later(bank):
    app,c,a,m,g=bank;p,b=a.payment(amount=200000)
    res=g.upload(p);assert res.status_code==200
    assert a.receipt(res.json()['receipts'][0])['status']=='rejected'
    with app.state.db.connect() as db:db.execute('UPDATE accounts SET balance=500000 WHERE id=?',(a.account,))
    retry=g.upload(p).json()
    assert retry['duplicate'] and a.receipt(retry['receipts'][0])['status']=='rejected'
    assert not state(app,c)['ledger']

def test_duplicate_id_changed_instruction_conflicts(bank):
    app,c,a,m,g=bank;p,b=a.payment()
    assert g.upload(p).status_code==200
    changed={**b,'amount':b['amount']+1}
    forged=packet('payment',seal(a.trust['box_key'],sign(a.sign_key,changed)),b['sender_mailbox'],b['expires_at'])
    assert g.upload(forged).status_code==409
    assert len(state(app,c)['ledger'])==2

def test_reencrypted_same_instruction_is_idempotent(bank):
    app,c,a,m,g=bank;p,b=a.payment()
    assert g.upload(p).status_code==200
    new=packet('payment',seal(a.trust['box_key'],sign(a.sign_key,b)),b['sender_mailbox'],b['expires_at'])
    assert new['id']!=p['id']
    assert g.upload(new).json()['duplicate']
    assert len(state(app,c)['ledger'])==2

def test_tampered_ciphertext_and_forged_signature(bank):
    app,c,a,m,g=bank;p,b=a.payment()
    tampered=copy.deepcopy(p);tampered['box']['ciphertext']='AAAA'
    assert g.upload(tampered).status_code==400
    bad=sign(m.sign_key,b)
    forged=packet('payment',seal(a.trust['box_key'],bad),b['sender_mailbox'],b['expires_at'])
    assert g.upload(forged).status_code==400
    assert not state(app,c)['ledger']

def test_expiry_and_unknown_outcome_recovery(bank):
    app,c,a,m,g=bank;now=int(time.time());p,b=a.payment(created_at=now-1000,expires_at=now-100)
    res=g.upload(p);assert res.status_code==200
    assert a.receipt(res.json()['receipts'][0])['status']=='rejected'
    p2,b2=a.payment();first=g.upload(p2).json()
    # Receipt loss is recovered by a scoped capability, with no further debit.
    mailbox=c.get('/api/mailbox/'+b2['sender_mailbox'],headers=g.headers).json()['receipts']
    assert mailbox and a.receipt(mailbox[0])['status']=='paid'
    assert c.get('/api/mailbox/'+'0'*48,headers=g.headers).json()['receipts']==[]
    assert len(state(app,c)['ledger'])==2

def test_concurrent_payments_cannot_overspend(bank):
    app,c,a,m,g=bank
    requests=[a.payment(amount=70000)[0] for _ in range(2)]
    with ThreadPoolExecutor(max_workers=2) as pool:results=list(pool.map(g.upload,requests))
    assert all(r.status_code==200 for r in results)
    outcomes=[a.receipt(r.json()['receipts'][0])['status'] for r in results]
    assert sorted(outcomes)==['paid','rejected']
    assert len(state(app,c)['ledger'])==2
    assert next(x['balance'] for x in state(app,c)['accounts'] if x['id']==a.account)==30000

def test_bank_trust_and_results_persist_after_restart(bank):
    app,c,a,m,g=bank;p,b=a.payment();first=g.upload(p).json()
    restarted=create_app(app.state.db.directory)
    with TestClient(restarted) as other:
        assert other.get('/api/health').json()['fingerprint']==a.trust['fingerprint']
        r=other.post('/api/packets',headers=g.headers,json=p)
        assert r.json()['duplicate'] and r.json()['receipts']==first['receipts']

def test_revoked_key_denied(bank):
    app,c,a,m,g=bank;p,b=a.payment()
    c.post('/api/admin/revoke/'+a.id,headers={'Authorization':'Bearer '+app.state.db.admin_token})
    assert g.upload(p).status_code==400

def test_auth_and_size_limits(bank):
    app,c,a,m,g=bank;p,b=a.payment()
    assert c.post('/api/packets',json=p).status_code==401
    assert c.get('/api/admin/state',headers=a.headers).status_code==401
    assert c.post('/api/login',json={'account':'alice@karo','password':'wrong'}).status_code==401
    assert c.post('/api/packets',content=b'x'*17000,headers=g.headers).status_code==413

def test_fake_success_rejected_by_recipient(bank):
    app,c,a,m,g=bank;p,b=a.payment();r=g.upload(p).json()['receipts'][0]
    fake=seal(public(a.box_key),sign(m.sign_key,{'status':'paid','device_id':a.id}))
    with pytest.raises(Exception):a.receipt({**r,'box':fake})

def test_software_rehearsal(bank):
    app,c,a,m,g=bank
    result=rehearse(app)
    assert result['receipt']['status']=='paid' and len(result['trace'])==8
