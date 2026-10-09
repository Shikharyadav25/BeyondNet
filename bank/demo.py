"""Software rehearsal. All cryptography and settlement use the actual bank API.
The three relay hops are an in-memory radio model, never evidence of BLE transfer.
"""
import json
import secrets
import time
import uuid
from pathlib import Path
from fastapi.testclient import TestClient
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from bank.crypto import public, private, sign, verify, seal, open_box, packet, check_packet, unb64

class DemoDevice:
    def __init__(self, client, account, password, state_file=None):
        self.client = client
        self.account = account
        if state_file and Path(state_file).exists():
            keys = json.loads(Path(state_file).read_text())
            self.sign_key = ed25519.Ed25519PrivateKey.from_private_bytes(unb64(keys['sign']))
            self.box_key = x25519.X25519PrivateKey.from_private_bytes(unb64(keys['box']))
            self.id = keys['id']
        else:
            self.sign_key = ed25519.Ed25519PrivateKey.generate()
            self.box_key = x25519.X25519PrivateKey.generate()
            self.id = str(uuid.uuid4())
            if state_file:
                p = Path(state_file)
                p.write_text(json.dumps({'id':self.id,'sign':private(self.sign_key),'box':private(self.box_key)}))
                p.chmod(0o600)
        login = client.post('/api/login',json={'account':account,'password':password})
        login.raise_for_status()
        self.trust = login.json()['trust']
        self.headers = {'Authorization':'Bearer '+login.json()['token']}
        identity = {'device_id':self.id,'account_id':account,'sign_key':public(self.sign_key),'box_key':public(self.box_key)}
        response = client.post('/api/devices',headers=self.headers,json={k:v for k,v in identity.items() if k!='account_id'} | {'proof':sign(self.sign_key,identity)['signature']})
        response.raise_for_status()
        self.certificate = response.json()['certificate']
        verify(self.trust['sign_key'],self.certificate)
        self.queue = {}

    def payment(self, recipient='chai@karo', amount=12500, **changes):
        now = int(time.time())
        body = {'v':1,'payment_id':str(uuid.uuid4()),'sender':self.account,'recipient':recipient,
                'amount':amount,'currency':'INR','created_at':now,'expires_at':now+900,'device_id':self.id,
                'sender_mailbox':secrets.token_hex(24),'recipient_mailbox':secrets.token_hex(24)} | changes
        p = packet('payment',seal(self.trust['box_key'],sign(self.sign_key,body)),body['sender_mailbox'],body['expires_at'])
        self.queue[p['id']] = p
        return p, body

    def receive(self,p):
        check_packet(p)
        if p['id'] in self.queue:
            return False
        self.queue[p['id']] = p
        return True

    def forward_to(self, other):
        count = 0
        for p in list(self.queue.values()):
            if p['id'] in other.queue or p['hops']>=4:
                continue
            path = (p['path']+[self.id]) if p['kind']=='payment' else p['path']
            count += other.receive({**p,'hops':p['hops']+1,'path':path})
        return count

    def upload(self,p):
        return self.client.post('/api/packets',headers=self.headers,json=p)

    def receipt(self,p):
        value = verify(self.trust['sign_key'],open_box(self.box_key,p['box']))
        if value['device_id'] != self.id:
            raise ValueError('Receipt addressed to another device')
        return value

def rehearse(app):
    trace=[]
    with TestClient(app) as c:
        directory = app.state.db.directory
        merchant = DemoDevice(c,'chai@karo','chai-demo-pass',directory/'sim-merchant.json')
        relay = DemoDevice(c,'relay@karo','relay-demo-pass',directory/'sim-relay.json')
        sender = DemoDevice(c,'alice@karo','alice-demo-pass',directory/'sim-sender.json')
        trace.append('Three simulated devices enrolled; bank certificates verified.')
        p,body=sender.payment()
        trace.append('Sender signed and encrypted a ₹125 request; it remains awaiting bank confirmation.')
        sender.forward_to(relay)
        trace.append('Simulated sender → relay: ciphertext stored before acknowledgment.')
        relay.forward_to(merchant)
        trace.append('Simulated relay → gateway: the same packet ID arrived; relays have no decryption key.')
        routed=merchant.queue[p['id']]
        result=merchant.upload(routed)
        if result.status_code==503:
            trace.append('Bank is paused. Request retained. Resume bank submissions and run again.')
            return {'trace':trace}
        result.raise_for_status()
        receipts=result.json()['receipts']
        for r in receipts:
            merchant.receive(r)
        trace.append('Gateway submitted the encrypted request through the bank HTTP API; returned receipts were stored.')
        merchant.forward_to(relay)
        relay.forward_to(sender)
        trace.append('Simulated return: gateway → relay → sender, with separate seven-day receipt retention.')
        customer_receipt=next(r for r in receipts if r['mailbox']==body['sender_mailbox'])
        outcome=sender.receipt(sender.queue[customer_receipt['id']])
        trace.append('Sender decrypted the receipt and verified the bank signature: '+outcome['status'].upper()+'.')
        second=merchant.upload(routed)
        second.raise_for_status()
        assert second.json()['duplicate'] is True
        trace.append('Duplicate submission returned the original decision with no second debit or credit.')
        return {'trace':trace,'receipt':outcome}
