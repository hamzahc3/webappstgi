CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ───────── Identity & tenancy ─────────
CREATE TABLE users (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email         CITEXT UNIQUE NOT NULL,
  display_name  TEXT NOT NULL,
  avatar_url    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE workspaces (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE workspace_members (
  workspace_id UUID REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id      UUID REFERENCES users(id) ON DELETE CASCADE,
  role         TEXT NOT NULL DEFAULT 'member',  -- owner|admin|member|guest
  PRIMARY KEY (workspace_id, user_id)
);

-- ───────── Channels ─────────
CREATE TYPE channel_type AS ENUM ('public','private','dm');

CREATE TABLE channels (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  type         channel_type NOT NULL,
  name         TEXT,                         -- NULL for DMs
  topic        TEXT,
  created_by   UUID REFERENCES users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE channel_members (
  channel_id   UUID REFERENCES channels(id) ON DELETE CASCADE,
  user_id      UUID REFERENCES users(id) ON DELETE CASCADE,
  last_read_message_id BIGINT,               -- powers "Catch me up" default range
  last_read_at TIMESTAMPTZ,
  joined_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (channel_id, user_id)
);

-- ───────── Messages ─────────
CREATE TABLE messages (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- monotonic, good for ranges
  channel_id     UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  author_id      UUID NOT NULL REFERENCES users(id),
  parent_id      BIGINT REFERENCES messages(id),     -- threads
  content_json   JSONB NOT NULL,                     -- Tiptap doc
  content_text   TEXT  NOT NULL,                     -- plain-text projection for search/LLM
  search_tsv     TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', content_text)) STORED,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at      TIMESTAMPTZ,
  deleted_at     TIMESTAMPTZ
);
CREATE INDEX idx_msg_channel_time ON messages (channel_id, id DESC);
CREATE INDEX idx_msg_author ON messages (channel_id, author_id, created_at);
CREATE INDEX idx_msg_tsv ON messages USING GIN (search_tsv);

-- ───────── Tags (topics) ─────────
CREATE TABLE tags (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id UUID NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name         TEXT NOT NULL,
  UNIQUE (workspace_id, name)
);
CREATE TABLE message_tags (
  message_id BIGINT REFERENCES messages(id) ON DELETE CASCADE,
  tag_id     UUID   REFERENCES tags(id) ON DELETE CASCADE,
  source     TEXT NOT NULL DEFAULT 'user',   -- user|ai
  PRIMARY KEY (message_id, tag_id)
);
CREATE TABLE document_tags (
  document_id UUID, tag_id UUID REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (document_id, tag_id)
);

-- ───────── Attachments & documents ─────────
CREATE TABLE attachments (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id   BIGINT REFERENCES messages(id) ON DELETE CASCADE,
  uploader_id  UUID NOT NULL REFERENCES users(id),
  storage_key  TEXT NOT NULL,                -- s3 key
  filename     TEXT NOT NULL,
  mime_type    TEXT NOT NULL,
  size_bytes   BIGINT NOT NULL,
  sha256       TEXT NOT NULL,                -- dedupe + idempotency
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TYPE ingest_status AS ENUM ('pending','processing','ready','failed','needs_ocr');

CREATE TABLE documents (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  attachment_id UUID UNIQUE NOT NULL REFERENCES attachments(id) ON DELETE CASCADE,
  workspace_id  UUID NOT NULL,
  channel_id    UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  uploader_id   UUID NOT NULL,
  doc_type      TEXT NOT NULL DEFAULT 'pdf',  -- pdf|news|report|contract...
  title         TEXT,
  page_count    INT,
  language      TEXT,
  status        ingest_status NOT NULL DEFAULT 'pending',
  error         TEXT,
  summary       TEXT,                         -- cached doc-level summary
  published_at  TIMESTAMPTZ,                  -- for news docs, if extractable
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at  TIMESTAMPTZ
);
CREATE INDEX idx_docs_channel ON documents (channel_id, created_at DESC);

-- ───────── Chunks + embeddings ─────────
CREATE TABLE document_chunks (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id   UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  chunk_index   INT  NOT NULL,
  page_start    INT  NOT NULL,
  page_end      INT  NOT NULL,
  text          TEXT NOT NULL,
  token_count   INT  NOT NULL,
  bboxes        JSONB,                        -- optional [{page,x0,y0,x1,y1}] for highlight
  -- denormalized filter columns
  workspace_id  UUID NOT NULL,
  channel_id    UUID NOT NULL,
  uploader_id   UUID NOT NULL,
  doc_type      TEXT NOT NULL,
  doc_created_at TIMESTAMPTZ NOT NULL,
  -- retrieval
  embedding     vector(1536) NOT NULL,
  embedding_model TEXT NOT NULL,
  text_tsv      TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
  UNIQUE (document_id, chunk_index)
);
CREATE INDEX idx_chunks_hnsw ON document_chunks
  USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 64);
CREATE INDEX idx_chunks_tsv  ON document_chunks USING GIN (text_tsv);
CREATE INDEX idx_chunks_filter ON document_chunks (channel_id, doc_type, doc_created_at);

-- Optional: embed messages so chat can be retrieved semantically too
CREATE TABLE message_embeddings (
  message_id BIGINT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
  channel_id UUID NOT NULL,
  embedding  vector(1536) NOT NULL,
  embedding_model TEXT NOT NULL
);
CREATE INDEX idx_msg_hnsw ON message_embeddings USING hnsw (embedding vector_cosine_ops);

-- ───────── AI artifacts (cache + audit) ─────────
CREATE TABLE ai_summaries (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id  UUID NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  requested_by UUID NOT NULL REFERENCES users(id),
  range_start BIGINT, range_end BIGINT,            -- message id range
  filters     JSONB NOT NULL DEFAULT '{}',
  body        TEXT NOT NULL,
  citations   JSONB NOT NULL DEFAULT '[]',
  model       TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);