"""Only test helpers: isolated PostgreSQL schemas, never the public ledger."""
import os
from pathlib import Path
import psycopg
from psycopg import sql
from urllib.parse import urlparse
import uuid
ROOT=Path(__file__).resolve().parents[1]

def environment():
    return {**os.environ, 'BEYONDNET_DB_CONFIG':os.environ.get('BEYONDNET_DB_CONFIG', str(ROOT/'data/postgres.properties')), 'BEYONDNET_DB_SCHEMA':'test_'+uuid.uuid4().hex}

def drop_schema(env):
    schema=env['BEYONDNET_DB_SCHEMA']
    if not schema.startswith('test_') or not schema.replace('_','').isalnum():
        raise ValueError('Unsafe test schema')
    props={}
    path=Path(env.get('BEYONDNET_DB_CONFIG', ROOT/'data/postgres.properties'))
    if path.exists():
        props=dict(line.split('=',1) for line in path.read_text().splitlines() if '=' in line and not line.startswith('#'))
    url=urlparse(env.get('BEYONDNET_DB_URL',props.get('url','jdbc:postgresql://127.0.0.1:5433/beyondnet')).removeprefix('jdbc:'))
    # Use the Python driver so test cleanup does not depend on a host-specific psql binary.
    options = dict(host=url.hostname, port=url.port or 5432,
                   user=env.get('BEYONDNET_DB_USER', props.get('user', 'beyondnet')),
                   password=env.get('BEYONDNET_DB_PASSWORD', props.get('password', '')),
                   dbname=url.path.lstrip('/'), autocommit=True)
    if url.hostname not in {'localhost', '127.0.0.1', '::1'}:
        options.update(sslmode='verify-full', sslrootcert='system')
    with psycopg.connect(**options) as connection:
        connection.execute(sql.SQL('DROP SCHEMA IF EXISTS {} CASCADE').format(sql.Identifier(schema)))
