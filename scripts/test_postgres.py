"""Only test helpers: isolated PostgreSQL schemas, never the public ledger."""
import os
from pathlib import Path
import shutil
import subprocess
from urllib.parse import urlparse
import uuid
ROOT=Path(__file__).resolve().parents[1]

def environment():
    return {**os.environ, 'BEYONDNET_DB_CONFIG':str(ROOT/'data/postgres.properties'), 'BEYONDNET_DB_SCHEMA':'test_'+uuid.uuid4().hex}

def drop_schema(env):
    schema=env['BEYONDNET_DB_SCHEMA']
    if not schema.startswith('test_') or not schema.replace('_','').isalnum():
        raise ValueError('Unsafe test schema')
    props={}
    path=Path(env.get('BEYONDNET_DB_CONFIG', ROOT/'data/postgres.properties'))
    if path.exists():
        props=dict(line.split('=',1) for line in path.read_text().splitlines() if '=' in line and not line.startswith('#'))
    url=urlparse(env.get('BEYONDNET_DB_URL',props.get('url','jdbc:postgresql://127.0.0.1:5433/beyondnet')).removeprefix('jdbc:'))
    # Prefer the modern client: system CA trust needs libpq 16+, and this Mac's PATH also has psql 14.
    command=None
    for directory in ['/opt/homebrew/opt/postgresql@18/bin','/usr/local/opt/postgresql@18/bin','/opt/homebrew/opt/postgresql@17/bin','/usr/local/opt/postgresql@17/bin']:
        if Path(directory,'psql').exists():command=str(Path(directory,'psql'));break
    if not command:command=shutil.which('psql')
    subprocess.run([command,'-h',url.hostname,'-p',str(url.port or 5432),'-U',env.get('BEYONDNET_DB_USER',props.get('user','beyondnet')),'-d',url.path.lstrip('/'),'-v','ON_ERROR_STOP=1','-c',f'DROP SCHEMA IF EXISTS {schema} CASCADE'],env={**os.environ,'PGPASSWORD':env.get('BEYONDNET_DB_PASSWORD',props.get('password','')), **({'PGSSLMODE':'verify-full','PGSSLROOTCERT':'system'} if url.hostname not in {'localhost','127.0.0.1','::1'} else {})},check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
