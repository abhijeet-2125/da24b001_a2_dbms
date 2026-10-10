-- F4: Find retractions by type and their referenced signal.
CREATE INDEX IF NOT EXISTS idx_signal_type_retracts_created
ON Signal(signal_type, retracts_signal_id, created_at);

-- F7: Filter sessions by start time and retain the session ID
-- for joining to Turn.
CREATE INDEX IF NOT EXISTS idx_session_started_session
ON Session(started_at, session_id);

-- Rejected candidate: this index would support recommendation-to-impression
-- matching, but its storage and build costs are not justified for this
-- experiment. It is intentionally not created.
-- CREATE INDEX IF NOT EXISTS idx_impression_recommendation_video_user
-- ON Impression(recommendation_id, video_id, user_id);

-- F12: Support the completion check by impression and completion flag.
CREATE INDEX IF NOT EXISTS idx_viewsegment_impression_reached
ON ViewSegment(impression_id, reached_end);
