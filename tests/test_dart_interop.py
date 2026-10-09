import json
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric import x25519
import pytest
from bank.crypto import unb64,open_box,verify,check_packet

def test_python_decrypts_actual_dart_envelope():
    output=Path('mobile/build/dart-wire.json')
    if not output.exists():
        pytest.skip('Run flutter test in mobile first to generate the Dart interoperability vector')
    f=json.loads(Path('mobile/test/fixtures/python-wire.json').read_text())
    p=json.loads(output.read_text());check_packet(p)
    signed=open_box(x25519.X25519PrivateKey.from_private_bytes(unb64(f['box_seed'])),p['box'])
    assert verify(f['sign_public'],signed)==f['body']
