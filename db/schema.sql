CREATE TABLE currencies (
    code            CHAR(3)      PRIMARY KEY,          -- ISO 4217: NGN, USD, GBP
    name            VARCHAR(64)  NOT NULL,
    decimal_places  SMALLINT     NOT NULL DEFAULT 2,    -- NGN=2 (kobo), JPY=0
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO currencies (code, name, decimal_places) VALUES
    ('NGN', 'Nigerian Naira',   2),
    ('USD', 'US Dollar',        2),
    ('GBP', 'British Pound',    2),
    ('EUR', 'Euro',             2);

CREATE TABLE account_types (
    id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    name            VARCHAR(32)  NOT NULL UNIQUE,
                                 -- ASSET | LIABILITY | EQUITY | REVENUE | EXPENSE
    normal_balance  VARCHAR(6)   NOT NULL CHECK (normal_balance IN ('DEBIT', 'CREDIT')),
    description     TEXT
);
 
INSERT INTO account_types (name, normal_balance, description) VALUES
    ('ASSET',     'DEBIT',  'Things the entity owns — customer deposit accounts'),
    ('LIABILITY', 'CREDIT', 'Money the bank owes — bank-side of customer deposits'),
    ('EQUITY',    'CREDIT', 'Owners'' stake'),
    ('REVENUE',   'CREDIT', 'Income: fees, interest earned'),
    ('EXPENSE',   'DEBIT',  'Costs: interest paid out, operational costs');


CREATE TABLE TENANTS (
    id              UUID         PRIMARY KEY    DEFAULT gen_random_uuid(),
    name            VARCHAR(128) NOT NULL,
    slug            VARCHAR(64)  NOT NULL UNIQUE,       -- e.g. "acme-bank"
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    metadata        JSONB        NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_tenants_slug ON tenants (slug);


CREATE TABLE users (
    id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID            NOT NULL    REFERENCES tenants (id),
    email           VARCHAR(255)    NOT NULL,    
    full_name       VARCHAR(128)    NOT NULL,
    role            VARCHAR(32)     NOT NULL    DEFAULT 'CUSTOMER',
                                 -- CUSTOMER | ADMIN | SYSTEM
    is_active       BOOLEAN         NOT NULL    DEFAULT TRUE,
    created_at      TIMESTAMPTZ     NOT NULL    DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL    DEFAULT NOW(),

    UNIQUE (tenant_id, email) -- unique per tenants, not globally
);
CREATE INDEX idx_users_tenant ON users (tenant_id);


CREATE TABLE accounts (
    id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID         NOT NULL    REFERENCES tenants (id),
    user_id          UUID         REFERENCES users (id),  -- NULL for system accounts
    account_type_id  UUID         NOT NULL    REFERENCES account_types (id),
    account_number   VARCHAR(20)  NOT NULL,               -- human-readable identifier 
    currency         CHAR(3)      NOT NULL    REFERENCES currencies (code),
    balance_kobo     BIGINT       NOT NULL    DEFAULT 0,     -- always in smallest unit
    status           VARCHAR(16)  NOT NULL    DEFAULT 'ACTIVE' CHECK(status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    is_system        BOOLEAN      NOT NULL    DEFAULT FALSE, -- TRUE for liability/revenue pools
    version          BIGINT       NOT NULL    DEFAULT 0,     -- optimistic lock counter
    metadata         JSONB        NOT NULL    DEFAULT '{}',
    created_at       TIMESTAMPTZ  NOT NULL    DEFAULT NOW(),
    updated_at       TIMESTAMPTZ  NOT NULL    DEFAULT NOW(),
 
    UNIQUE (tenant_id, account_number),
    CONSTRAINT balance_non_negative CHECK (balance_kobo >= 0)
);
CREATE INDEX idx_accounts_tenant   ON accounts (tenant_id);
CREATE INDEX idx_accounts_user     ON accounts (user_id);
CREATE INDEX idx_accounts_currency ON accounts (currency);


CREATE TABLE transactions (
    id                      UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id               UUID         NOT NULL    REFERENCES tenants(id),
    idempotency_key         VARCHAR(128) NOT NULL,
    transaction_types       VARCHAR(32)  NOT NULL    UNIQUE CHECK(transaction_types IN('TRANSFER', 'FEE', 'INTEREST', 'REVERSAL', 'ADJUSTMENT')),                                   
    status                  VARCHAR(16)  NOT NULL    DEFAULT 'PENDING' CHECK(status IN ('PENDING', 'COMPLETED', 'FAILED', 'REVERSED'))                             
    initiated_by            UUID         NOT NULL    REFERENCES users(id),
    metadata                JSONB        NOT NULL    DEFAULT '{}',
    created_at              TIMESTAMPTZ  NOT NULL    DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL    DEFAULT NOW(),

    UNIQUE (tenant_id, idempotency_key) -- unique per tenants, not globally
); 
CREATE INDEX idx_transactions_tenant           ON transactions (tenant_id);
CREATE INDEX idx_transactions_idempotency_key  ON transactions (tenant_id, idempotency_key);
CREATE INDEX idx_transactions_status           ON transactions (status);
CREATE INDEX idx_transactions_created_at       ON transactions (created_at DESC);

CREATE TABLE ledger_entries (
    id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID         NOT NULL    REFERENCES tenants(id),
    transaction_id   UUID         NOT NULL    REFERENCES transactions(id),
    account_id       UUID         NOT NULL    REFERENCES accounts (id),
    entry_type       VARCHAR(6)   NOT NULL    CHECK(entry_type IN ('DEBIT', 'CREDIT')),
    amount_kobo      BIGINT       NOT NULL    CHECK (amount_kobo > 0),
    running_balance  BIGINT       NOT NULL,               -- balance after this entry
    currency         CHAR(3)      NOT NULL    REFERENCES currencies(code),
    created_at       TIMESTAMPTZ  NOT NULL    DEFAULT NOW(),
 
    -- No UPDATE or DELETE ever. Corrections happen via new reversal transactions.
);
 
CREATE INDEX idx_ledger_transaction ON ledger_entries (transaction_id);
CREATE INDEX idx_ledger_account     ON ledger_entries (account_id);
CREATE INDEX idx_ledger_created_at  ON ledger_entries (created_at DESC);
 
-- Prevent any updates or deletes on ledger_entries (append-only enforcement)
CREATE RULE no_update_ledger AS ON UPDATE TO ledger_entries DO INSTEAD NOTHING;
CREATE RULE no_delete_ledger AS ON DELETE TO ledger_entries DO INSTEAD NOTHING;

CREATE TABLE transfers (
    id               UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    transaction_id   UUID         NOT NULL UNIQUE REFERENCES transactions (id),
    tenant_id        UUID         NOT NULL REFERENCES tenants (id),
    from_account_id  UUID         NOT NULL REFERENCES accounts (id),
    to_account_id    UUID         NOT NULL REFERENCES accounts (id),
    amount_kobo      BIGINT       NOT NULL CHECK (amount_kobo > 0),
    currency         CHAR(3)      NOT NULL REFERENCES currencies (code),
    status           VARCHAR(16)  NOT NULL DEFAULT 'PENDING' CHECK(status IN ('PENDING', 'COMPLETED', 'FAILED', 'REVERSED')),
    fee_kobo         BIGINT       NOT NULL DEFAULT 0,
    reversed_by      UUID         REFERENCES transfers(id),  -- points to reversal transfer
    reversal_reason  TEXT         NOT NULL
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
 
    CONSTRAINT different_accounts CHECK (from_account_id <> to_account_id)
); 
CREATE INDEX idx_transfers_tenant        ON transfers (tenant_id);
CREATE INDEX idx_transfers_from_account  ON transfers (from_account_id);
CREATE INDEX idx_transfers_to_account    ON transfers (to_account_id);
CREATE INDEX idx_transfers_status        ON transfers (status);


CREATE TABLE idempotency_keys (
    id              UUID         PRIMARY KEY    DEFAULT gen_random_uuid(),
    tenant_id       UUID         NOT NULL       REFERENCES tenants (id),
    key             VARCHAR(128) NOT NULL,
    request_hash    VARCHAR(64)  NOT NULL,   -- SHA-256 of method + path + body
    response_status SMALLINT,                -- HTTP status cached
    response_body   TEXT,                    -- full JSON response cached
    locked_at       TIMESTAMPTZ,             -- set while request is in-flight. 
                                             -- Indicates that the request is currently being processed.
    completed_at    TIMESTAMPTZ,
    expires_at      TIMESTAMPTZ  NOT NULL       DEFAULT (NOW() + INTERVAL '24 hours'),
    created_at      TIMESTAMPTZ  NOT NULL       DEFAULT NOW(),
 
    UNIQUE (tenant_id, key)
);
 
CREATE INDEX idx_idempotency_tenant_key ON idempotency_keys (tenant_id, key);
CREATE INDEX idx_idempotency_expires_at ON idempotency_keys (expires_at);


CREATE TABLE audit_log (
    id              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID         NOT NULL REFERENCES tenants (id),
    entity_type     VARCHAR(64)  NOT NULL,   -- 'accounts', 'transfers', etc.
    entity_id       UUID         NOT NULL,
    action          VARCHAR(32)  NOT NULL,   -- CREATE | UPDATE | DELETE | FREEZE | REVERSE
    actor_id        UUID         REFERENCES users (id),
    old_value       JSONB,
    new_value       JSONB,
    ip_address      INET,
    user_agent      TEXT,        -- Stores information about the client's device or browser.
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
 
CREATE INDEX idx_audit_entity   ON audit_log (entity_type, entity_id);
CREATE INDEX idx_audit_tenant   ON audit_log (tenant_id);
CREATE INDEX idx_audit_actor    ON audit_log (actor_id);
CREATE INDEX idx_audit_created  ON audit_log (created_at DESC);       


CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
 
CREATE TRIGGER trg_tenants_updated_at
    BEFORE UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
 
CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
 
CREATE TRIGGER trg_accounts_updated_at
    BEFORE UPDATE ON accounts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
 
CREATE TRIGGER trg_transactions_updated_at
    BEFORE UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
 
CREATE TRIGGER trg_transfers_updated_at
    BEFORE UPDATE ON transfers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();



