"""Create public sample UI state with an isolated bank; never starts a server."""
import argparse
import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fastapi.testclient import TestClient
from bank.app import create_app
from bank.demo import rehearse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
args = parser.parse_args()
with TemporaryDirectory(prefix="beyondnet-preview-") as directory:
    app = create_app(directory)
    with TestClient(app) as client:
        rehearse(app)
        token = (Path(directory) / "admin-token.txt").read_text().strip()
        response = client.get("/api/admin/state", headers={"Authorization": "Bearer " + token})
        response.raise_for_status()
        args.output.write_text(json.dumps(response.json()))
print("Generated isolated sample bank state; existing bank data was not changed.")
