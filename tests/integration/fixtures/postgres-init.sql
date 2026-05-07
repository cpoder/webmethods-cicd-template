-- tests/integration/fixtures/postgres-init.sql
--
-- Schema for the integration-test JDBC round trips.
-- Postgres applies files in /docker-entrypoint-initdb.d/ once on first
-- boot of the container; the volume is torn down after every run, so
-- this SQL is the single source of truth for the test database shape.
--
-- Tables:
--   audit_events   - rows MSR is expected to write (JDBC round-trip)
--   ping           - smoke table populated by REST-assured tests so
--                    Postgres readiness can be verified end-to-end

CREATE TABLE IF NOT EXISTS audit_events (
    id              BIGSERIAL    PRIMARY KEY,
    correlation_id  VARCHAR(64)  NOT NULL,
    event_type      VARCHAR(64)  NOT NULL,
    payload         JSONB,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_events_correlation_id
    ON audit_events (correlation_id);

CREATE TABLE IF NOT EXISTS ping (
    id          BIGSERIAL    PRIMARY KEY,
    note        VARCHAR(128) NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO testuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO testuser;
