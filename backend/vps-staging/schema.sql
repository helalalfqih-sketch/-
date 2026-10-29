-- Smart Content Creator: isolated EMPTY SQLite prototype, not PocketBase internal schema.
-- No Firebase data import. No authenticated endpoints. All app writes must be via an API with server authorization.
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS users (
 id TEXT PRIMARY KEY,
 email_normalized TEXT NOT NULL UNIQUE,
 display_name TEXT NOT NULL DEFAULT '',
 is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0,1)),
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS user_roles (
 user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
 role TEXT NOT NULL CHECK(role IN ('owner','admin','editor','member')),
 granted_by TEXT REFERENCES users(id),
 granted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS products (
 id TEXT PRIMARY KEY,
 owner_id TEXT NOT NULL REFERENCES users(id),
 sku TEXT,
 title TEXT NOT NULL,
 description TEXT NOT NULL DEFAULT '',
 price_decimal TEXT NOT NULL DEFAULT '0',
 sale_price_decimal TEXT,
 currency TEXT NOT NULL DEFAULT 'YER',
 quantity INTEGER NOT NULL DEFAULT 0 CHECK(quantity >= 0),
 category TEXT,
 status TEXT NOT NULL DEFAULT 'draft' CHECK(status IN ('draft','review','published','archived')),
 source_ref TEXT,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 UNIQUE(owner_id,sku)
);
CREATE INDEX IF NOT EXISTS idx_products_owner_status ON products(owner_id,status);
CREATE TABLE IF NOT EXISTS media_assets (
 id TEXT PRIMARY KEY,
 owner_id TEXT NOT NULL REFERENCES users(id),
 object_key TEXT NOT NULL UNIQUE,
 kind TEXT NOT NULL,
 mime_type TEXT NOT NULL,
 size_bytes INTEGER NOT NULL DEFAULT 0 CHECK(size_bytes >= 0),
 visibility TEXT NOT NULL DEFAULT 'private' CHECK(visibility IN ('private','public')),
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS content_items (
 id TEXT PRIMARY KEY,
 owner_id TEXT NOT NULL REFERENCES users(id),
 prompt TEXT,
 result_text TEXT,
 model TEXT,
 status TEXT NOT NULL DEFAULT 'draft',
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS ai_jobs (
 id TEXT PRIMARY KEY,
 owner_id TEXT NOT NULL REFERENCES users(id),
 job_type TEXT NOT NULL,
 state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','completed','failed','cancelled')),
 request_id TEXT UNIQUE,
 result_ref TEXT,
 error_code TEXT,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_ai_jobs_owner_state ON ai_jobs(owner_id,state);
CREATE TABLE IF NOT EXISTS subscriptions (
 id TEXT PRIMARY KEY,
 user_id TEXT NOT NULL REFERENCES users(id),
 plan TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'inactive',
 starts_at TEXT,
 expires_at TEXT,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS audit_events (
 id TEXT PRIMARY KEY,
 actor_id TEXT REFERENCES users(id),
 action TEXT NOT NULL,
 entity_type TEXT NOT NULL,
 entity_id TEXT,
 created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
PRAGMA user_version = 1;