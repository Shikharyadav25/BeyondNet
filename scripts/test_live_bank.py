"""Ephemeral loopback bank for Flutter integration tests; no tunnel or user data."""
import json
from pathlib import Path
import socket
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import uvicorn
from bank.app import create_app

with tempfile.TemporaryDirectory(prefix='beyondnet-integration-') as directory:
    app = create_app(directory)
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    print(json.dumps({'port': listener.getsockname()[1], 'fingerprint': app.state.trust['fingerprint']}), flush=True)
    server = uvicorn.Server(uvicorn.Config(app, log_level='error', ws_max_size=16384))
    server.run(sockets=[listener])
