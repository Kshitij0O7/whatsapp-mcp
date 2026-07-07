-- SolarTechy WhatsApp assistant — Postgres schema
-- Apply with:  psql -d solartechy -f assistant/db/schema.sql
-- Safe to re-run (idempotent).

-- One record per WhatsApp conversation (keyed by chat_jid, since modern WhatsApp
-- identifiers use the @lid form and are not always phone numbers).
CREATE TABLE IF NOT EXISTS customers (
    chat_jid            TEXT PRIMARY KEY,
    phone_number        TEXT,
    name                TEXT,
    company_name        TEXT,
    designation         TEXT,
    email               TEXT,
    city                TEXT,
    state               TEXT,
    business_type       TEXT,
    current_software    TEXT,
    monthly_projects    TEXT,
    interested_services TEXT,
    lead_status         TEXT DEFAULT 'NEW',      -- NEW / INTERESTED / QUALIFIED / DEMO / CUSTOMER / COLD
    lead_score          INTEGER DEFAULT 0,
    conversation_state  TEXT,                    -- GREETING / PRODUCT_INQUIRY / ... / ESCALATED / CLOSED
    rolling_summary     TEXT,                    -- long-term memory, updated by the assistant
    assigned_to         TEXT,
    notes               TEXT,
    last_contact_time   TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Full message log as the assistant sees it (both sides).
CREATE TABLE IF NOT EXISTS conversations (
    id            BIGSERIAL PRIMARY KEY,
    chat_jid      TEXT NOT NULL,
    role          TEXT NOT NULL,                 -- 'customer' or 'assistant'
    content       TEXT NOT NULL,
    wa_message_id TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_conversations_chat_time
    ON conversations (chat_jid, created_at);

-- Human hand-off records.
CREATE TABLE IF NOT EXISTS escalations (
    id                    BIGSERIAL PRIMARY KEY,
    chat_jid              TEXT NOT NULL,
    phone_number          TEXT,
    customer_name         TEXT,
    company_name          TEXT,
    category              TEXT,                  -- DEMO / ENTERPRISE / PAYMENT / BUG / KB_GAP / ...
    priority              TEXT,                  -- LOW / MEDIUM / HIGH
    summary               TEXT,
    conversation_snapshot TEXT,
    status                TEXT NOT NULL DEFAULT 'PENDING',  -- PENDING / IN_PROGRESS / RESOLVED
    assigned_to           TEXT,
    internal_notes        TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_escalations_status ON escalations (status);
CREATE INDEX IF NOT EXISTS idx_escalations_chat   ON escalations (chat_jid);
