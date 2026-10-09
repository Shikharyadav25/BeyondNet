"""Launch the persistent laptop bank. Keep this process running during a demo."""
import argparse
import os
from pathlib import Path
import sys
import webbrowser
import threading

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
os.chdir(ROOT)
from bank.app import create_app
import uvicorn

parser=argparse.ArgumentParser(description='BeyondNet laptop bank')
parser.add_argument('--port',type=int,default=8080)
parser.add_argument('--host',default='127.0.0.1')
parser.add_argument('--no-browser',action='store_true')
args=parser.parse_args()
app=create_app()
print('\nBeyondNet · demo bank',flush=True)
print(f'Console: http://localhost:{args.port}',flush=True)
print(f'Operator key file: {app.state.db.directory.resolve() / "admin-token.txt"}',flush=True)
print(f'Bank fingerprint: {app.state.trust["fingerprint"]}',flush=True)
print('For phones, expose this endpoint with a trusted HTTPS tunnel. See docs/FIRST_PAYMENT.md.\n',flush=True)
if not args.no_browser:threading.Timer(1.5,lambda:webbrowser.open(f'http://localhost:{args.port}')).start()
uvicorn.run(app,host=args.host,port=args.port,proxy_headers=False)
