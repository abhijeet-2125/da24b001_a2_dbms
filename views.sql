PRAGMA foreign_keys=ON;

-- G.1(a) Public profile for the mobile client.
-- Exposes only public profile information and excludes inactive/deletion-window accounts.
CREATE VIEW v_public_profile AS
SELECT
    u.user_id,
    h.handle,
    u.display_name,
    COUNT(DISTINCT f.follower_id) AS follower_count
FROM User u
JOIN UserHandlePeriod h
    ON h.user_id = u.user_id
    AND h.valid_to IS NULL
LEFT JOIN FollowPeriod f
    ON f.followee_id = u.user_id
    AND f.ended_at IS NULL
JOIN UserStatusPeriod s
    ON s.user_id = u.user_id
    AND s.valid_to IS NULL
    AND s.status = 'active'
GROUP BY u.user_id,h.handle,u.display_name;


-- G.1(b) Current moderation state derived from append-only moderation history.
CREATE VIEW v_video_current_state AS
SELECT
    video_id,
    state,
    decided_by_type,
    reviewer_user_id,
    classifier_version,
    decided_at
FROM (
    SELECT
        video_id,
        state,
        decided_by_type,
        reviewer_user_id,
        classifier_version,
        decided_at,
        ROW_NUMBER() OVER (
            PARTITION BY video_id
            ORDER BY decided_at DESC,decision_id DESC
        ) AS rn
    FROM ModerationDecision
)
WHERE rn = 1;


-- G.1(c) Current creator tier from the temporal tier relation.
CREATE VIEW v_creator_tier_current AS
SELECT
    c.creator_id,
    c.user_id,
    ctp.tier
FROM Creator c
JOIN CreatorTierPeriod ctp
    ON ctp.creator_id = c.creator_id
    AND ctp.valid_from <= datetime('now')
    AND (ctp.valid_to IS NULL OR ctp.valid_to > datetime('now'));


-- G.1(d) Daily engagement per video.
-- Impression-days form the base so days with zero engagement are retained.
CREATE VIEW v_video_daily_engagement AS
WITH impression_days AS (
    SELECT
        video_id,
        date(shown_at) AS engagement_date,
        COUNT(*) AS impressions
    FROM Impression
    GROUP BY video_id,date(shown_at)
),
view_days AS (
    SELECT
        i.video_id,
        date(i.shown_at) AS engagement_date,
        COUNT(DISTINCT i.impression_id) AS views,
        SUM(vs.segment_end_ms - vs.segment_start_ms) AS watch_ms
    FROM Impression i
    JOIN ViewSegment vs
        ON vs.impression_id = i.impression_id
    GROUP BY i.video_id,date(i.shown_at)
),
like_days AS (
    SELECT
        video_id,
        date(created_at) AS engagement_date,
        SUM(
            CASE
                WHEN signal_type = 'like' THEN 1
                WHEN signal_type = 'like_retraction' THEN -1
                ELSE 0
            END
        ) AS net_likes
    FROM Signal
    WHERE signal_type IN ('like','like_retraction')
    GROUP BY video_id,date(created_at)
)
SELECT
    i.video_id,
    i.engagement_date,
    i.impressions,
    COALESCE(v.views,0) AS views,
    ROUND(COALESCE(v.watch_ms,0) / 1000.0,2) AS watch_seconds,
    COALESCE(l.net_likes,0) AS net_likes
FROM impression_days i
LEFT JOIN view_days v
    ON v.video_id = i.video_id
    AND v.engagement_date = i.engagement_date
LEFT JOIN like_days l
    ON l.video_id = i.video_id
    AND l.engagement_date = i.engagement_date;


-- G.1(e) Finance view using the historical pricing period valid at each turn timestamp.
CREATE VIEW v_turn_cost AS
SELECT
    t.turn_id,
    t.session_id,
    t.model_id,
    t.created_at,
    t.input_tokens,
    t.output_tokens,
    t.cached_input_tokens,
    p.input_rate,
    p.output_rate,
    p.cached_input_rate,
    ROUND(
        (t.input_tokens - t.cached_input_tokens) * p.input_rate
        + t.cached_input_tokens * p.cached_input_rate
        + t.output_tokens * p.output_rate,
        6
    ) AS turn_cost
FROM Turn t
JOIN ModelPricingPeriod p
    ON p.model_id = t.model_id
    AND t.created_at >= p.valid_from
    AND (p.valid_to IS NULL OR t.created_at < p.valid_to);