PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=0;

-- G.3 T1 — Retraction atomicity
-- The schema models a retraction as a separate negative Signal
-- referencing the original like. The transaction is rolled back
-- to demonstrate that the retraction is not partially persisted.

BEGIN;

INSERT INTO Signal(
    user_id,
    video_id,
    signal_type,
    retracts_signal_id,
    created_at
)
VALUES(
    183,
    5,
    'like_retraction',
    1,
    '2026-04-22T21:51:30Z'
);

-- Proof inside the transaction: the retraction exists.
SELECT
    signal_id,
    user_id,
    video_id,
    signal_type,
    retracts_signal_id
FROM Signal
WHERE retracts_signal_id = 1;

ROLLBACK;

-- Proof after rollback: the retraction is gone.
SELECT COUNT(*)
FROM Signal
WHERE retracts_signal_id = 1;


-- G.3 T2 — Moderation decision isolation
-- Run the following BEGIN/INSERT block in Connection 1.
-- Keep the transaction uncommitted while Connection 2 executes
-- the SELECT shown below.
--
-- Connection 1:
--
-- BEGIN;
-- INSERT INTO ModerationDecision(
--     video_id,
--     state,
--     decided_by_type,
--     reviewer_user_id,
--     classifier_version,
--     decided_at
-- )
-- VALUES(
--     1,
--     'live',
--     'classifier',
--     NULL,
--     'clf-demo',
--     '2026-09-13T18:00:00Z'
-- );
--
-- SELECT video_id,state,decided_at
-- FROM v_video_current_state
-- WHERE video_id = 1;
--
-- Connection 2, while Connection 1 is uncommitted:
--
-- SELECT video_id,state,decided_at
-- FROM v_video_current_state
-- WHERE video_id = 1;
--
-- Connection 1 observes the new uncommitted state ('live'),
-- while Connection 2 continues to observe the committed state
-- ('pending'). This demonstrates isolation with WAL.
--
-- Roll back in Connection 1 after the demonstration:
--
-- ROLLBACK;

-- G.3 T3 — Handle-change enforcement
-- The trigger allows two handle changes in a rolling 365-day
-- period and rejects the third.

BEGIN;

UPDATE UserHandlePeriod
SET valid_to = '2026-05-01T00:00:00Z'
WHERE user_id = 1
AND valid_to IS NULL;

INSERT INTO UserHandlePeriod(
    user_id,
    handle,
    valid_from,
    valid_to
)
VALUES(
    1,
    'user_1_change1',
    '2026-05-01T00:00:00Z',
    NULL
);

UPDATE UserHandlePeriod
SET valid_to = '2026-07-01T00:00:00Z'
WHERE user_id = 1
AND valid_to IS NULL;

INSERT INTO UserHandlePeriod(
    user_id,
    handle,
    valid_from,
    valid_to
)
VALUES(
    1,
    'user_1_change2',
    '2026-07-01T00:00:00Z',
    NULL
);

-- Third change deliberately fails:
INSERT INTO UserHandlePeriod(
    user_id,
    handle,
    valid_from,
    valid_to
)
VALUES(
    1,
    'user_1_change3',
    '2026-08-01T00:00:00Z',
    NULL
);

-- Expected error:
-- handle can be changed at most twice in 365 days

ROLLBACK;
-- G.3 T3 — SQLite single-writer contention
-- Connection 1:
--
-- BEGIN IMMEDIATE;
--
-- UPDATE UserHandlePeriod
-- SET handle = 'user_1_locked_test'
-- WHERE user_id = 1
-- AND valid_to IS NULL;
--
-- Keep this transaction open.
--
-- Connection 2:
--
-- PRAGMA busy_timeout=0;
--
-- UPDATE UserHandlePeriod
-- SET handle = 'user_1_busy_test'
-- WHERE user_id = 1
-- AND valid_to IS NULL;
--
-- Expected error:
-- database is locked (5)
--
-- This demonstrates SQLITE_BUSY because SQLite permits only one
-- writer at a time. Roll back Connection 1 after the experiment.