CREATE TABLE IF NOT EXISTS campus_records (
 id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL,
 source TEXT NOT NULL, updated_at BIGINT NOT NULL, expires_at BIGINT NOT NULL,
 search_vector TSVECTOR GENERATED ALWAYS AS (to_tsvector('simple', title || ' ' || body)) STORED
);
CREATE INDEX IF NOT EXISTS campus_search_idx ON campus_records USING GIN(search_vector);
CREATE TABLE IF NOT EXISTS campus_principals (
 id TEXT PRIMARY KEY, token_hash TEXT UNIQUE NOT NULL, expires_at BIGINT NOT NULL, revoked BOOLEAN NOT NULL DEFAULT FALSE
);
