"""Run the existing bank on a host with a persistent data volume."""
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
os.chdir(ROOT)


def main():
    directory = os.environ.get("KARO_DATA_DIR")
    if not directory or not Path(directory).is_absolute():
        sys.exit("Set KARO_DATA_DIR to an absolute path on persistent storage.")
    try:
        port = int(os.environ.get("PORT", "10000"))
        if not 1 <= port <= 65535:
            raise ValueError
    except ValueError:
        sys.exit("PORT must be between 1 and 65535.")

    from bank.app import create_app
    import uvicorn

    app = create_app(directory)
    print("BeyondNet cloud bank · persistent data directory configured", flush=True)
    print("Bank fingerprint: " + app.state.trust["fingerprint"], flush=True)
    print("Operator key is stored in the persistent data directory, not in logs.", flush=True)
    # SQLite ledger and in-memory bank controls use one process. The provider
    # supplies HTTPS/WSS; the upstream listener remains HTTP inside its network.
    uvicorn.run(app, host="0.0.0.0", port=port, workers=1, proxy_headers=False)


if __name__ == "__main__":
    main()
