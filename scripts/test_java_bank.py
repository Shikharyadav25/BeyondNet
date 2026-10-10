"""Test-only Spring Boot subprocess and temporary ledger; never user data."""
import json
import signal
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
from test_postgres import environment, drop_schema

def stop(signum, frame):
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)

root = Path(__file__).resolve().parents[1]
jar = root / 'backend/target/bank-1.2.0.jar'
if not jar.is_file():
    raise SystemExit('Build backend with mvn package before the live Flutter test.')
with tempfile.TemporaryDirectory(prefix='beyondnet-java-test-') as directory:
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    env = {**environment(), 'KARO_DATA_DIR': directory, 'PORT': str(port)}
    process = subprocess.Popen(['java', '-jar', str(jar), '--server.port=' + str(port)], cwd=root, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(300):
            if process.poll() is not None:
                raise RuntimeError('Java test bank exited before readiness')
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/health', timeout=1) as response:
                    health = json.load(response)
                print(json.dumps({'port': port, 'fingerprint': health['fingerprint']}), flush=True)
                break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError('Java test bank readiness timed out')
        # Parent holds stdin open; closing it guarantees cleanup of child/data.
        import sys
        sys.stdin.read()
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        drop_schema(env)
