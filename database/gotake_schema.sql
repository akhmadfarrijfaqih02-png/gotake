-- =====================================================================
-- GoTake - Campus Loan System
-- PostgreSQL 14+ schema: tables, constraints, functions, views, seed
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. ENUM TYPES
-- ---------------------------------------------------------------------
CREATE TYPE user_role       AS ENUM ('student', 'admin');
CREATE TYPE loan_status     AS ENUM ('requested', 'approved', 'rejected', 'borrowed', 'returned');
CREATE TYPE collateral_type AS ENUM ('KTM', 'KTP');
CREATE TYPE item_condition  AS ENUM ('good', 'minor_damage', 'damaged');
-- "overdue" is NOT stored: it is derived (borrowed AND return_date < today), see v_loan_overview.

-- ---------------------------------------------------------------------
-- 2. TABLES
-- ---------------------------------------------------------------------

-- Students and admins share one table; login screen routes by role.
CREATE TABLE users (
    id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role               user_role     NOT NULL DEFAULT 'student',
    nim                VARCHAR(20)   UNIQUE,           -- students log in with NIM
    username           VARCHAR(50)   UNIQUE,           -- admins log in with username
    full_name          VARCHAR(100)  NOT NULL,
    email              VARCHAR(100)  NOT NULL,
    password_hash      VARCHAR(255)  NOT NULL,         -- bcrypt/argon2 hash, never plain text
    phone              VARCHAR(20),
    program            VARCHAR(100),                   -- student: study program
    class_name         VARCHAR(30),                    -- student: class
    staff_id           VARCHAR(30)   UNIQUE,           -- admin: staff id (ADM-001)
    department         VARCHAR(100),                   -- admin: department
    photo_url          TEXT,
    notify_on_approved BOOLEAN       NOT NULL DEFAULT TRUE,
    notify_before_due  BOOLEAN       NOT NULL DEFAULT TRUE,
    is_active          BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    CONSTRAINT chk_user_identity CHECK (
        (role = 'student' AND nim IS NOT NULL) OR
        (role = 'admin'   AND username IS NOT NULL)
    )
);
CREATE UNIQUE INDEX uq_users_email ON users (lower(email));

CREATE TABLE categories (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        VARCHAR(100) NOT NULL UNIQUE,
    description VARCHAR(255)
);

CREATE TABLE items (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_id   BIGINT         NOT NULL REFERENCES categories(id),
    code          VARCHAR(30)    NOT NULL UNIQUE,
    name          VARCHAR(100)   NOT NULL,
    description   VARCHAR(255),
    location      VARCHAR(100)   NOT NULL,
    total_qty     INT            NOT NULL,
    available_qty INT            NOT NULL,             -- physically in storage right now
    condition     item_condition NOT NULL DEFAULT 'good',
    image_url     TEXT,
    is_active     BOOLEAN        NOT NULL DEFAULT TRUE, -- "Delete" = deactivate, keeps loan history
    created_at    TIMESTAMPTZ    NOT NULL DEFAULT now(),
    CONSTRAINT chk_item_qty CHECK (total_qty >= 0 AND available_qty BETWEEN 0 AND total_qty)
);

-- One row per borrow request (header).
CREATE TABLE loans (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id          BIGINT          NOT NULL REFERENCES users(id),
    borrow_date      DATE            NOT NULL,
    return_date      DATE            NOT NULL,           -- planned return date
    purpose          VARCHAR(255)    NOT NULL,
    collateral       collateral_type NOT NULL,
    collateral_agreed BOOLEAN        NOT NULL DEFAULT FALSE,
    letter_received  BOOLEAN         NOT NULL DEFAULT FALSE, -- Wadir 2 approval letter (offline)
    letter_number    VARCHAR(50),
    status           loan_status     NOT NULL DEFAULT 'requested',
    reviewed_by      BIGINT          REFERENCES users(id),
    reviewed_at      TIMESTAMPTZ,
    rejection_reason VARCHAR(255),
    handed_over_at   TIMESTAMPTZ,
    created_at       TIMESTAMPTZ     NOT NULL DEFAULT now(),
    CONSTRAINT chk_loan_dates    CHECK (return_date >= borrow_date),
    CONSTRAINT chk_collateral    CHECK (collateral_agreed),
    CONSTRAINT chk_reject_reason CHECK (status <> 'rejected' OR rejection_reason IS NOT NULL),
    CONSTRAINT chk_reviewer      CHECK (status = 'requested' OR reviewed_by IS NOT NULL)
);

-- One row per item inside a request (a request can hold many items).
CREATE TABLE loan_items (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id          BIGINT         NOT NULL REFERENCES loans(id) ON DELETE CASCADE,
    item_id          BIGINT         NOT NULL REFERENCES items(id),
    qty              INT            NOT NULL CHECK (qty > 0),
    condition_before item_condition NOT NULL DEFAULT 'good',
    condition_after  item_condition,                       -- filled by admin on return
    notes            VARCHAR(255),
    UNIQUE (loan_id, item_id)
);

-- Return record (one per loan) with manual compensation.
CREATE TABLE returns (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id             BIGINT        NOT NULL UNIQUE REFERENCES loans(id),
    received_by         BIGINT        NOT NULL REFERENCES users(id),
    returned_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    was_late            BOOLEAN       NOT NULL DEFAULT FALSE,
    compensation_amount NUMERIC(12,0) NOT NULL DEFAULT 0 CHECK (compensation_amount >= 0),
    notes               VARCHAR(255)
);

-- Key/value system settings (Settings screen).
CREATE TABLE settings (
    key        VARCHAR(50) PRIMARY KEY,
    value      TEXT        NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- In-app notifications (approved, rejected, due reminder, new request, overdue).
CREATE TABLE notifications (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id    BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    loan_id    BIGINT       REFERENCES loans(id) ON DELETE CASCADE,
    type       VARCHAR(30)  NOT NULL,
    message    TEXT         NOT NULL,
    is_read    BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 3. INDEXES
-- ---------------------------------------------------------------------
CREATE INDEX idx_items_category   ON items (category_id);
CREATE INDEX idx_loans_user       ON loans (user_id);
CREATE INDEX idx_loans_status     ON loans (status);
CREATE INDEX idx_loans_dates      ON loans USING gist (daterange(borrow_date, return_date, '[]'));
CREATE INDEX idx_loan_items_item  ON loan_items (item_id);
CREATE INDEX idx_notif_user_unread ON notifications (user_id, is_read);

-- ---------------------------------------------------------------------
-- 4. FUNCTIONS (business rules live in the database)
-- ---------------------------------------------------------------------

-- Stock of an item that is free for a date range
-- (total minus quantities of approved/borrowed loans overlapping the range).
CREATE FUNCTION item_available_on(p_item_id BIGINT, p_from DATE, p_to DATE)
RETURNS INT LANGUAGE sql STABLE AS $$
    SELECT i.total_qty - COALESCE((
        SELECT SUM(li.qty)
        FROM loan_items li
        JOIN loans l ON l.id = li.loan_id
        WHERE li.item_id = i.id
          AND l.status IN ('approved', 'borrowed')
          AND daterange(l.borrow_date, l.return_date, '[]') && daterange(p_from, p_to, '[]')
    ), 0)::INT
    FROM items i
    WHERE i.id = p_item_id;
$$;

-- Enforce max loan duration from settings (default 3 days).
CREATE FUNCTION trg_check_loan_duration() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE max_days INT;
BEGIN
    SELECT value::INT INTO max_days FROM settings WHERE key = 'max_loan_days';
    IF max_days IS NOT NULL AND (NEW.return_date - NEW.borrow_date) > max_days THEN
        RAISE EXCEPTION 'Loan duration exceeds maximum of % days', max_days;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER loans_check_duration
    BEFORE INSERT OR UPDATE OF borrow_date, return_date ON loans
    FOR EACH ROW EXECUTE FUNCTION trg_check_loan_duration();

-- Admin: approve a pending request (re-checks stock for the requested dates).
CREATE FUNCTION approve_loan(p_loan_id BIGINT, p_admin_id BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE l loans%ROWTYPE; r RECORD;
BEGIN
    SELECT * INTO l FROM loans WHERE id = p_loan_id FOR UPDATE;
    IF NOT FOUND OR l.status <> 'requested' THEN
        RAISE EXCEPTION 'Loan % is not in requested status', p_loan_id;
    END IF;
    FOR r IN SELECT item_id, qty FROM loan_items WHERE loan_id = p_loan_id LOOP
        PERFORM 1 FROM items WHERE id = r.item_id FOR UPDATE;   -- serialize concurrent approvals
        IF item_available_on(r.item_id, l.borrow_date, l.return_date) < r.qty THEN
            RAISE EXCEPTION 'Insufficient stock for item % on requested dates', r.item_id;
        END IF;
    END LOOP;
    UPDATE loans SET status = 'approved', reviewed_by = p_admin_id, reviewed_at = now()
    WHERE id = p_loan_id;
    INSERT INTO notifications (user_id, loan_id, type, message)
    VALUES (l.user_id, p_loan_id, 'approved', 'Your borrow request has been approved.');
END $$;

-- Admin: reject a pending request with a reason.
CREATE FUNCTION reject_loan(p_loan_id BIGINT, p_admin_id BIGINT, p_reason TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE l loans%ROWTYPE;
BEGIN
    SELECT * INTO l FROM loans WHERE id = p_loan_id FOR UPDATE;
    IF NOT FOUND OR l.status <> 'requested' THEN
        RAISE EXCEPTION 'Loan % is not in requested status', p_loan_id;
    END IF;
    UPDATE loans SET status = 'rejected', reviewed_by = p_admin_id,
                     reviewed_at = now(), rejection_reason = p_reason
    WHERE id = p_loan_id;
    INSERT INTO notifications (user_id, loan_id, type, message)
    VALUES (l.user_id, p_loan_id, 'rejected', 'Your borrow request was rejected: ' || p_reason);
END $$;

-- Admin: hand items over (approved -> borrowed). Stock decreases here.
CREATE FUNCTION hand_over_loan(p_loan_id BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE l loans%ROWTYPE;
BEGIN
    SELECT * INTO l FROM loans WHERE id = p_loan_id FOR UPDATE;
    IF NOT FOUND OR l.status <> 'approved' THEN
        RAISE EXCEPTION 'Loan % is not in approved status', p_loan_id;
    END IF;
    UPDATE items i SET available_qty = i.available_qty - li.qty      -- CHECK blocks negative stock
    FROM loan_items li
    WHERE li.loan_id = p_loan_id AND li.item_id = i.id;
    UPDATE loans SET status = 'borrowed', handed_over_at = now() WHERE id = p_loan_id;
END $$;

-- Admin: record return (borrowed/overdue -> returned). Stock increases here.
CREATE FUNCTION return_loan(p_loan_id BIGINT, p_admin_id BIGINT,
                            p_compensation NUMERIC DEFAULT 0, p_notes TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE l loans%ROWTYPE;
BEGIN
    SELECT * INTO l FROM loans WHERE id = p_loan_id FOR UPDATE;
    IF NOT FOUND OR l.status <> 'borrowed' THEN
        RAISE EXCEPTION 'Loan % is not in borrowed status', p_loan_id;
    END IF;
    UPDATE items i SET available_qty = i.available_qty + li.qty
    FROM loan_items li
    WHERE li.loan_id = p_loan_id AND li.item_id = i.id;
    INSERT INTO returns (loan_id, received_by, was_late, compensation_amount, notes)
    VALUES (p_loan_id, p_admin_id, CURRENT_DATE > l.return_date, p_compensation, p_notes);
    UPDATE loans SET status = 'returned' WHERE id = p_loan_id;
END $$;

-- ---------------------------------------------------------------------
-- 5. VIEWS (feed the dashboards and reports)
-- ---------------------------------------------------------------------

-- Loan list with derived "overdue" status (Manage Request, My Borrowings, Dashboard tables).
CREATE VIEW v_loan_overview AS
SELECT l.id, l.user_id, u.full_name, u.nim,
       l.borrow_date, l.return_date, l.collateral, l.status,
       CASE WHEN l.status = 'borrowed' AND l.return_date < CURRENT_DATE
            THEN 'overdue' ELSE l.status::TEXT END AS display_status,
       (SELECT string_agg(i.name || ' x' || li.qty, ', ' ORDER BY i.name)
          FROM loan_items li JOIN items i ON i.id = li.item_id
         WHERE li.loan_id = l.id) AS items
FROM loans l
JOIN users u ON u.id = l.user_id;

-- Admin dashboard cards.
CREATE VIEW v_admin_dashboard AS
SELECT (SELECT COALESCE(SUM(total_qty), 0) FROM items WHERE is_active)                  AS total_items,
       (SELECT COUNT(*) FROM loans WHERE status = 'borrowed')                           AS currently_borrowed,
       (SELECT COUNT(*) FROM loans WHERE status = 'requested')                          AS pending_approval,
       (SELECT COUNT(*) FROM loans WHERE status = 'borrowed'
                                     AND return_date < CURRENT_DATE)                    AS overdue_return;

-- Reports: cards.
CREATE VIEW v_report_summary AS
SELECT (SELECT COUNT(*) FROM loans
         WHERE handed_over_at >= date_trunc('month', now()))                            AS transactions_this_month,
       (SELECT ROUND(AVG(r.returned_at::DATE - l.handed_over_at::DATE), 1)
          FROM returns r JOIN loans l ON l.id = r.loan_id)                              AS avg_return_days,
       (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE was_late) / NULLIF(COUNT(*), 0), 1)
          FROM returns)                                                                 AS overdue_rate_pct;

-- Reports: borrow trend per month.
CREATE VIEW v_report_monthly AS
SELECT date_trunc('month', handed_over_at)::DATE AS month, COUNT(*) AS transactions
FROM loans
WHERE handed_over_at IS NOT NULL
GROUP BY 1;

-- Reports: top borrowed items.
CREATE VIEW v_report_top_items AS
SELECT i.id AS item_id, i.name, c.name AS category, COUNT(*) AS times_borrowed,
       RANK() OVER (ORDER BY COUNT(*) DESC) AS rank
FROM loan_items li
JOIN loans l      ON l.id = li.loan_id AND l.handed_over_at IS NOT NULL
JOIN items i      ON i.id = li.item_id
JOIN categories c ON c.id = i.category_id
GROUP BY i.id, i.name, c.name;

-- Outstanding loans + total compensation (proposal requires these reports).
CREATE VIEW v_report_outstanding AS
SELECT * FROM v_loan_overview WHERE display_status IN ('borrowed', 'overdue');

CREATE VIEW v_report_compensation AS
SELECT date_trunc('month', returned_at)::DATE AS month, SUM(compensation_amount) AS total_compensation
FROM returns
GROUP BY 1;

-- ---------------------------------------------------------------------
-- 6. SEED DATA
-- ---------------------------------------------------------------------
INSERT INTO settings (key, value) VALUES
    ('site_name',            'GoTake - Campus Loan System'),
    ('max_loan_days',        '3'),
    ('require_collateral',   'true'),
    ('notify_admin_new_req', 'true'),
    ('notify_admin_overdue', 'false');

INSERT INTO categories (name, description) VALUES
    ('Inventory furniture',  'Chairs, carpets, tables'),
    ('Electronic equipment', 'Projectors, cables, audio');

INSERT INTO items (category_id, code, name, location, total_qty, available_qty) VALUES
    (2, 'ELC-001', 'Epson Projector',         'Server room',                8,  5),
    (1, 'FRN-001', 'Chair',                   'General warehouse',        250,  0),
    (1, 'FRN-002', 'Carpet',                  'General warehouse',         10,  5),
    (2, 'ELC-002', 'HDMI/VGA Cable',          'Technician''s room',        50,  5),
    (2, 'ELC-003', 'Headset/Mic Recording',   'Multimedia equipment room',  7,  5),
    (2, 'ELC-004', 'LAN Cable',               'General warehouse',         30,  5);

-- First admin: replace the hash with one generated by your app (bcrypt/argon2).
-- INSERT INTO users (role, username, staff_id, full_name, email, password_hash, department)
-- VALUES ('admin', 'admin', 'ADM-001', 'Admin Facilities', 'admin.sarpras@campus.ac.id',
--         '<PASTE_HASH_HERE>', 'General Affairs & Facilities');

COMMIT;


