-- ICT371 Question 5: Hostel Room Allocation (PostgreSQL)
DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path TO q5, public;

-- (a) TABLES -------------------------------------------------------------
CREATE TABLE students (
  student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
  room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
  allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE NULL,
  status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
  CONSTRAINT chk_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
  CONSTRAINT chk_alloc_dates CHECK (
    (status = 'ACTIVE' AND released_on IS NULL) OR
    (status = 'ENDED'  AND released_on IS NOT NULL)
  )
);

CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT NOT NULL,
  free_beds     INT NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);

-- (b) FUNCTION -----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT AS $$
DECLARE
  v_capacity INT;
  v_active   INT;
BEGIN
  SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room: %', p_room_id;
  END IF;

  SELECT COUNT(*) INTO v_active
  FROM allocations WHERE room_id = p_room_id AND status = 'ACTIVE';   -- ENDED rows ignored

  RETURN v_capacity - v_active;
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) PROCEDURE ----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
AS $$
BEGIN
  IF p_allocated_on IS NULL THEN
    RAISE EXCEPTION 'Allocation date is required';
  END IF;

  PERFORM 1 FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;

  -- lock the room row so two allocations cannot take the last bed together
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room: %', p_room_id;
  END IF;

  IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;

  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % is full', p_room_id;
  END IF;

  INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$ LANGUAGE plpgsql;

-- (d) TRIGGER (protects direct INSERT/UPDATE statements too) -------------
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules() RETURNS TRIGGER AS $$
DECLARE
  v_capacity INT;
  v_active   INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    -- serialise changes to the same room
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;

    -- one ACTIVE allocation per student (exclude the row being updated)
    IF EXISTS (
      SELECT 1 FROM allocations a
      WHERE a.student_id = NEW.student_id AND a.status = 'ACTIVE'
        AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)
    ) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;

    -- capacity (exclude the row being updated)
    SELECT COUNT(*) INTO v_active
    FROM allocations a
    WHERE a.room_id = NEW.room_id AND a.status = 'ACTIVE'
      AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

    IF v_active >= v_capacity THEN
      RAISE EXCEPTION 'Room % is at full capacity (%)', NEW.room_id, v_capacity;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- (g) PROCEDURE: occupancy snapshot --------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
AS $$
BEGIN
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, r.room_id, COUNT(a.allocation_id), r.capacity - COUNT(a.allocation_id)
  FROM rooms r
  LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
  GROUP BY r.room_id, r.capacity
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$ LANGUAGE plpgsql;

-- (a) SEED DATA ----------------------------------------------------------
INSERT INTO students (student_number, full_name) VALUES
  ('2024101', 'Natasha Mwila'), ('2024102', 'Joseph Kapata'), ('2024103', 'Lucy Zimba'),
  ('2024104', 'Moses Daka'),    ('2024105', 'Sarah Ngoma');

INSERT INTO rooms (room_number, capacity) VALUES
  ('R101', 2),   -- will be full
  ('R102', 3),   -- partly occupied
  ('R103', 2);   -- empty (only history)

CALL pr_allocate_room(1, 1, DATE '2026-09-01');
CALL pr_allocate_room(2, 1, DATE '2026-09-01');   -- R101 now full
CALL pr_allocate_room(3, 2, DATE '2026-09-02');   -- R102 has 1 of 3

-- ENDED history does not occupy a bed
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, DATE '2026-02-01', DATE '2026-06-30', 'ENDED');

SELECT * FROM allocations ORDER BY allocation_id;

-- tests (each should raise an error)
-- SELECT fn_free_beds(1);                                  -- 0
-- SELECT fn_free_beds(3);                                  -- 2 (ended row ignored)
-- SELECT fn_free_beds(99);                                 -- Unknown room
-- CALL pr_allocate_room(5, 1, CURRENT_DATE);               -- room full
-- CALL pr_allocate_room(1, 3, CURRENT_DATE);               -- student already active
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--   VALUES (5, 1, CURRENT_DATE, 'ACTIVE');                 -- trigger blocks direct SQL

-- (e) VIEW ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)               AS occupied_beds,
       r.capacity - COUNT(a.allocation_id)  AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) INDEX --------------------------------------------------------------
-- Partial index: only ACTIVE rows are indexed, so it stays small and fast.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) TEST AND SCHEDULE --------------------------------------------------
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- rerun: still one row per date and room
SELECT * FROM occupancy_snapshot ORDER BY room_id;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q5_refresh_occupancy', '55 23 * * *',
  $$CALL q5.pr_refresh_occupancy()$$);
