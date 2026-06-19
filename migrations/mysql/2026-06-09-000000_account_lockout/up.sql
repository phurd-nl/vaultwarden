-- NIST AC-7 account lockout (additive, see docs/adr/0003).
ALTER TABLE users ADD COLUMN failed_login_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN locked_until DATETIME;
