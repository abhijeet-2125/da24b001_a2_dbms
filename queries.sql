--F1: Top 10 audio tracks by distinct videos in the last 7 days.
SELECT a.track_id,a.title,
COUNT(DISTINCT v.video_id) AS video_count
FROM AudioTrack a
JOIN Video v ON v.audio_track_id = a.track_id
WHERE v.uploaded_at >= datetime('now', '-7 days')
GROUP BY a.track_id,a.title
ORDER BY video_count DESC,a.track_id
LIMIT 10;


-- F2
SELECT c.creator_id,c.user_id,
ROUND(COALESCE(SUM(COALESCE(w.watch_ms,0)),0) / 3600000.0,2) AS watch_hours,
ROUND(COALESCE(AVG(COALESCE(w.completed,0)),0),3) AS mean_completion_rate
FROM Creator c
LEFT JOIN ( SELECT v.video_id,v.owner_id FROM Video v JOIN (SELECT video_id,state
FROM (
SELECT video_id,state,decision_id, ROW_NUMBER() OVER (PARTITION BY video_id
ORDER BY decided_at DESC,decision_id DESC) AS rn
            FROM ModerationDecision
        ) WHERE rn = 1 AND state = 'live') s ON s.video_id = v.video_id ) v ON v.owner_id = c.user_id
LEFT JOIN Impression i ON i.video_id = v.video_id
LEFT JOIN ( SELECT impression_id, SUM(segment_end_ms - segment_start_ms) AS watch_ms, MAX(reached_end) AS completed
FROM ViewSegment
GROUP BY impression_id) w ON w.impression_id = i.impression_id
GROUP BY c.creator_id,c.user_id
ORDER BY watch_hours DESC,c.creator_id;

-- F3: videos with no audio
SELECT v.video_id,v.owner_id,v.uploaded_at
FROM Video v WHERE NOT EXISTS (
SELECT 1
FROM AudioTrack a
WHERE a.track_id = v.audio_track_id)
ORDER BY v.video_id;

-- F3 NULL behavior: NOT IN returns no rows because audio_track_id can be NULL
SELECT COUNT(*)
FROM Video
WHERE audio_track_id NOT IN (SELECT track_id FROM AudioTrack);

-- F4: Users who liked and then retracted a like on the same clip within 60 seconds.
SELECT l.user_id,l.video_id,
l.created_at AS liked_at,
r.created_at AS retracted_at,
ROUND((julianday(r.created_at) - julianday(l.created_at)) * 86400,2 ) AS seconds_to_retract
FROM Signal l
JOIN Signal r ON r.retracts_signal_id = l.signal_id
WHERE l.signal_type = 'like'
AND r.signal_type = 'like_retraction'
AND r.created_at > l.created_at
AND (julianday(r.created_at) - julianday(l.created_at)) * 86400 <= 60
ORDER BY l.created_at,l.signal_id;


-- F5: Videos whose caption carries the given hashtag #life.
WITH normalized AS (
    SELECT
        video_id,
        owner_id,
        caption,
        ' ' || trim(
            replace(
                replace(
                    replace(
                        replace(lower(caption), ',', ' '),
                        '.', ' '
                    ),
                    '!', ' '
                ),
                '?', ' '
            )
        ) || ' ' AS caption_norm
    FROM Video
)
SELECT video_id, owner_id, caption
FROM normalized
WHERE caption_norm LIKE '% #life %'
AND instr(caption_norm,' #life ') > 0
ORDER BY video_id;

-- F6a · Users shown creator 2's clips but never engaged with any of them.
SELECT DISTINCT i.user_id
FROM Impression i
JOIN Video v ON v.video_id = i.video_id
WHERE v.owner_id = 2
EXCEPT
SELECT DISTINCT s.user_id
FROM Signal s
JOIN Video v ON v.video_id = s.video_id
WHERE v.owner_id = 2
ORDER BY user_id;

-- F6b · Signal roll-up using UNION.
SELECT video_id,'like' AS signal_group,COUNT(*) AS signal_count
FROM Signal
WHERE signal_type = 'like'
GROUP BY video_id
UNION
SELECT video_id,'save' AS signal_group,COUNT(*) AS signal_count
FROM Signal
WHERE signal_type = 'save'
GROUP BY video_id
ORDER BY video_id,signal_group;

-- F6c · Same signal roll-up using UNION ALL.
SELECT video_id,'like' AS signal_group,COUNT(*) AS signal_count
FROM Signal
WHERE signal_type = 'like'
GROUP BY video_id
UNION ALL
SELECT video_id,'save' AS signal_group,COUNT(*) AS signal_count
FROM Signal
WHERE signal_type = 'save'
GROUP BY video_id
ORDER BY video_id,signal_group;


-- F7 · Cost of each agent session last month,
--      broken out by prompt template version.
SELECT s.session_id,ptv.template_version_id,ptv.version_number,
ROUND(SUM((t.input_tokens - t.cached_input_tokens) * p.input_rate + t.cached_input_tokens * p.cached_input_rate + t.output_tokens * p.output_rate),6) AS session_cost
FROM Session s
JOIN Turn t ON t.session_id = s.session_id
JOIN PromptTemplateVersion ptv ON ptv.template_version_id = t.prompt_template_version_id
JOIN ModelPricingPeriod p ON p.model_id = t.model_id AND t.created_at >= p.valid_from AND (p.valid_to IS NULL OR t.created_at < p.valid_to)
WHERE s.started_at >= '2026-08-01T00:00:00Z'
AND s.started_at < '2026-09-01T00:00:00Z'
GROUP BY s.session_id,ptv.template_version_id,ptv.version_number
HAVING session_cost > 0.05
ORDER BY session_cost DESC,s.session_id,ptv.version_number;

-- F8 · Videos whose moderation state changed more than twice,
--      with the complete moderation sequence in chronological order.
WITH ordered_decisions AS (
SELECT video_id, state, decided_at, decision_id FROM ModerationDecision),
transition_counts AS (SELECT video_id, COUNT(*) - 1 AS transition_count
    FROM ordered_decisions
    GROUP BY video_id
    HAVING COUNT(*) - 1 > 2)
SELECT d.video_id, tc.transition_count, group_concat(d.state,' -> '
ORDER BY d.decided_at,d.decision_id) AS state_sequence
FROM ordered_decisions d
JOIN transition_counts tc ON tc.video_id = d.video_id
GROUP BY d.video_id, tc.transition_count
ORDER BY d.video_id;

-- F9 · Longest consecutive-day activity streak per user.
-- Activity is defined as generating at least one Signal per day.
WITH active_days AS (
    SELECT DISTINCT
        user_id,
        date(created_at) AS activity_date

    FROM Signal
),

numbered_days AS (
    SELECT
        user_id,
        activity_date,

        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY activity_date
        ) AS rn

    FROM active_days
),

streak_groups AS (
    SELECT
        user_id,
        activity_date,

        date(
            activity_date,
            '-' || rn || ' days'
        ) AS streak_group

    FROM numbered_days
),

streaks AS (
    SELECT
        user_id,
        MIN(activity_date) AS streak_start,
        MAX(activity_date) AS streak_end,
        COUNT(*) AS streak_length

    FROM streak_groups

    GROUP BY
        user_id,
        streak_group
)

SELECT
    user_id,
    streak_start,
    streak_end,
    streak_length

FROM streaks

ORDER BY
    streak_length DESC,
    user_id

LIMIT 10;

-- F10 · Rolling 7-day watch time per user.
WITH daily_watch AS (
    SELECT
        i.user_id,
        date(i.shown_at) AS watch_date,

        SUM(
            vs.segment_end_ms - vs.segment_start_ms
        ) AS watch_ms

    FROM Impression i

    JOIN ViewSegment vs
        ON vs.impression_id = i.impression_id

    GROUP BY
        i.user_id,
        date(i.shown_at)
),

rolling_watch AS (SELECT d1.user_id,d1.watch_date, SUM(d2.watch_ms) AS rolling_7day_watch_ms
FROM daily_watch d1
JOIN daily_watch d2 ON d2.user_id = d1.user_id AND d2.watch_date BETWEEN date(d1.watch_date, '-6 days') AND d1.watch_date
GROUP BY d1.user_id,d1.watch_date)
SELECT user_id,watch_date, ROUND(rolling_7day_watch_ms / 3600000.0, 2) AS rolling_7day_watch_hours
FROM rolling_watch
ORDER BY rolling_7day_watch_hours DESC,user_id, watch_date
LIMIT 10;

-- F11 · Tool-call tree.
-- Reconstructs parent -> child tool-call relationships.
WITH RECURSIVE tool_tree AS (
    SELECT
        tc.tool_call_id,
        tc.turn_id,
        tc.parent_tool_call_id,
        tc.tool_name,
        0 AS depth,
        printf('%s', tc.tool_name) AS call_path

    FROM ToolCall tc
    WHERE tc.parent_tool_call_id IS NULL
    UNION ALL
    SELECT
        child.tool_call_id,
        child.turn_id,
        child.parent_tool_call_id,
        child.tool_name,
        parent.depth + 1 AS depth,
        parent.call_path || ' -> ' || child.tool_name AS call_path

    FROM ToolCall child
    JOIN tool_tree parent ON child.parent_tool_call_id = parent.tool_call_id)

SELECT turn_id,tool_call_id, parent_tool_call_id, depth,call_path
FROM tool_tree
ORDER BY turn_id, depth, tool_call_id
LIMIT 20;

-- F12 · Sessions where the agent recommended a clip and the
--      user subsequently watched that clip to completion.
--      Shelf position is reported for the recommendation.
SELECT DISTINCT
    s.session_id,
    t.turn_id,
    ar.video_id,
    ar.shelf_position
FROM Session s
JOIN Turn t ON t.session_id = s.session_id
JOIN AgentRecommendation ar ON ar.turn_id = t.turn_id

JOIN Impression i
    ON i.recommendation_id = ar.recommendation_id
    AND i.video_id = ar.video_id
    AND i.user_id = s.user_id

WHERE EXISTS (
    SELECT 1
    FROM ViewSegment vs
    WHERE vs.impression_id = i.impression_id
    AND vs.reached_end = 1)
ORDER BY s.session_id, t.turn_id, ar.shelf_position, ar.video_id
LIMIT 20;