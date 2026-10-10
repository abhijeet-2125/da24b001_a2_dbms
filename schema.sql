PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

BEGIN TRANSACTION;

CREATE TABLE User (
    user_id INTEGER PRIMARY KEY,
    auth_method TEXT NOT NULL
        CHECK (auth_method IN ('phone', 'google')),
    phone_number TEXT UNIQUE,
    google_account_id TEXT UNIQUE,
    email TEXT,
    display_name TEXT NOT NULL,
    created_at TEXT NOT NULL,

    CHECK (
        (auth_method = 'phone'
         AND phone_number IS NOT NULL
         AND google_account_id IS NULL)
        OR
        (auth_method = 'google'
         AND google_account_id IS NOT NULL
         AND phone_number IS NULL)
    )
);


CREATE TABLE UserHandlePeriod (
    handle_period_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    handle TEXT NOT NULL,
    valid_from TEXT NOT NULL,
    valid_to TEXT,

    FOREIGN KEY (user_id)
        REFERENCES User(user_id)
        ON DELETE CASCADE, -- handle history belongs to the user

    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

-- This keeps currently open handles unique ignoring ASCII case.
-- The active-account part is checked separately because it depends on
-- UserStatusPeriod as well.
CREATE UNIQUE INDEX active_handle_unique
ON UserHandlePeriod(handle COLLATE NOCASE)
WHERE valid_to IS NULL;


CREATE TRIGGER handle_change_limit
BEFORE INSERT ON UserHandlePeriod
WHEN (
    SELECT COUNT(*)
    FROM UserHandlePeriod h
    WHERE h.user_id = NEW.user_id
    AND h.valid_from > (
        SELECT MIN(h0.valid_from)
        FROM UserHandlePeriod h0
        WHERE h0.user_id = NEW.user_id
    )
    AND h.valid_from >= datetime(NEW.valid_from,'-365 days')
    AND h.valid_from < NEW.valid_from
) >= 2
BEGIN
    SELECT RAISE(ABORT,'handle can be changed at most twice in 365 days');
END;

CREATE TABLE UserStatusPeriod (
    status_period_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    status TEXT NOT NULL
        CHECK (status IN (
            'active',
            'deactivated',
            'pending_deletion'
        )),
    valid_from TEXT NOT NULL,
    valid_to TEXT,

    FOREIGN KEY (user_id)
        REFERENCES User(user_id)
        ON DELETE CASCADE, -- status history belongs to the user

    CHECK (valid_to IS NULL OR valid_to > valid_from)
);


CREATE TABLE InterestCategory (
    category_id INTEGER PRIMARY KEY,
    category_name TEXT NOT NULL UNIQUE
);


CREATE TABLE UserDeclaredInterest (
    user_id INTEGER NOT NULL,
    category_id INTEGER NOT NULL,
    declared_at TEXT NOT NULL,

    PRIMARY KEY (user_id, category_id),

    FOREIGN KEY (user_id)
        REFERENCES User(user_id)
        ON DELETE CASCADE, -- declaration belongs to the user

    FOREIGN KEY (category_id)
        REFERENCES InterestCategory(category_id)
        ON DELETE RESTRICT -- keep categories referenced by existing declarations
);


CREATE TABLE UserInferredInterest (
    inferred_interest_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    category_id INTEGER NOT NULL,
    confidence_score REAL NOT NULL
        CHECK (
            confidence_score >= 0.0
            AND confidence_score <= 1.0
        ),
    valid_from TEXT NOT NULL,
    valid_to TEXT,

    FOREIGN KEY (user_id)
        REFERENCES User(user_id)
        ON DELETE CASCADE, -- inferred-interest history belongs to the user

    FOREIGN KEY (category_id)
        REFERENCES InterestCategory(category_id)
        ON DELETE RESTRICT, -- preserve the category referenced by the history

    CHECK (valid_to IS NULL OR valid_to > valid_from)
);


CREATE TABLE InterestSuppression (
    suppression_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    category_id INTEGER NOT NULL,
    suppressed_from TEXT NOT NULL,
    suppressed_to TEXT,

    FOREIGN KEY (user_id)
        REFERENCES User(user_id)
        ON DELETE CASCADE, -- suppression belongs to the user

    FOREIGN KEY (category_id)
        REFERENCES InterestCategory(category_id)
        ON DELETE RESTRICT, -- preserve the category referenced by the suppression

    CHECK (
        suppressed_to IS NULL
        OR suppressed_to > suppressed_from
    )
);


CREATE TABLE Creator (
    creator_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL UNIQUE,
    became_creator_at TEXT NOT NULL,

    FOREIGN KEY (user_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT -- creator identity must not be removed accidentally
);


-- These two tables reference each other, so the foreign key is deferred.

CREATE TABLE AudioTrack (
    track_id INTEGER PRIMARY KEY,
    origin_video_id INTEGER,
    source_type TEXT NOT NULL
        CHECK (source_type IN ('original', 'licensed')),
    title TEXT NOT NULL,

    FOREIGN KEY (origin_video_id)
        REFERENCES Video(video_id)
        ON DELETE RESTRICT -- keep the source video of an original track
        DEFERRABLE INITIALLY DEFERRED,

    CHECK (
        (source_type = 'original'
         AND origin_video_id IS NOT NULL)
        OR
        (source_type = 'licensed'
         AND origin_video_id IS NULL)
    )
);


CREATE TABLE CreatorTierPeriod (
    tier_period_id INTEGER PRIMARY KEY,
    creator_id INTEGER NOT NULL,

    -- Tier names are kept open because the brief does not define a fixed
    -- list and Finance/Product may introduce new monetisation tiers.
    tier TEXT NOT NULL
        CHECK (length(trim(tier)) > 0),

    valid_from TEXT NOT NULL,
    valid_to TEXT,

    FOREIGN KEY (creator_id)
        REFERENCES Creator(creator_id)
        ON DELETE CASCADE, -- tier history belongs to the creator

    CHECK (valid_to IS NULL OR valid_to > valid_from)
);


CREATE TABLE Video (
    video_id INTEGER PRIMARY KEY,
    owner_id INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL
        CHECK (duration_ms BETWEEN 20000 AND 90000),
    caption TEXT NOT NULL,
    audio_track_id INTEGER,
    uploaded_at TEXT NOT NULL,

    FOREIGN KEY (owner_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT, -- keep the owner identity for existing content

    FOREIGN KEY (audio_track_id)
        REFERENCES AudioTrack(track_id)
        ON DELETE SET NULL -- a video can remain without an audio track
        DEFERRABLE INITIALLY DEFERRED
);


CREATE TABLE Hashtag (
    hashtag_id INTEGER PRIMARY KEY,
    tag_text TEXT NOT NULL COLLATE NOCASE UNIQUE
);


CREATE TABLE VideoHashtag (
    video_id INTEGER NOT NULL,
    hashtag_id INTEGER NOT NULL,

    PRIMARY KEY (video_id, hashtag_id),

    FOREIGN KEY (video_id)
        REFERENCES Video(video_id)
        ON DELETE CASCADE, -- pure association has no meaning without the video

    FOREIGN KEY (hashtag_id)
        REFERENCES Hashtag(hashtag_id)
        ON DELETE CASCADE -- pure association has no meaning without the hashtag
);


CREATE TABLE ModerationDecision (
    decision_id INTEGER PRIMARY KEY,
    video_id INTEGER NOT NULL,
    state TEXT NOT NULL
        CHECK (state IN (
            'pending',
            'live',
            'age_restricted',
            'demoted',
            'taken_down'
        )),
    decided_by_type TEXT NOT NULL
        CHECK (decided_by_type IN ('classifier', 'human')),
    reviewer_user_id INTEGER,
    classifier_version TEXT,
    decided_at TEXT NOT NULL,

    FOREIGN KEY (video_id)
        REFERENCES Video(video_id)
        ON DELETE RESTRICT, -- moderation history must be preserved

    FOREIGN KEY (reviewer_user_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT, -- preserve the recorded human reviewer

    CHECK (
        (decided_by_type = 'human'
         AND reviewer_user_id IS NOT NULL
         AND classifier_version IS NULL)
        OR
        (decided_by_type = 'classifier'
         AND reviewer_user_id IS NULL
         AND classifier_version IS NOT NULL)
    )
);


CREATE TABLE FollowPeriod (
    follow_period_id INTEGER PRIMARY KEY,
    follower_id INTEGER NOT NULL,
    followee_id INTEGER NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT,

    FOREIGN KEY (follower_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT, -- preserve social history for the follower

    FOREIGN KEY (followee_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT, -- preserve social history for the followee

    CHECK (follower_id <> followee_id),
    CHECK (ended_at IS NULL OR ended_at > started_at)
);


CREATE TABLE BlockPeriod (
    block_period_id INTEGER PRIMARY KEY,
    blocker_id INTEGER NOT NULL,
    blocked_id INTEGER NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT,

    FOREIGN KEY (blocker_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT, -- preserve who created the block

    FOREIGN KEY (blocked_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT, -- preserve who was blocked

    CHECK (blocker_id <> blocked_id),
    CHECK (ended_at IS NULL OR ended_at > started_at)
);


CREATE TABLE MutePeriod (
    mute_period_id INTEGER PRIMARY KEY,
    muter_id INTEGER NOT NULL,
    muted_id INTEGER NOT NULL,
    started_at TEXT NOT NULL,
    ended_at TEXT,

    FOREIGN KEY (muter_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT, -- preserve mute history for the muter

    FOREIGN KEY (muted_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT, -- preserve mute history for the muted user

    CHECK (muter_id <> muted_id),
    CHECK (ended_at IS NULL OR ended_at > started_at)
);


CREATE TABLE Model (
    model_id INTEGER PRIMARY KEY,
    model_name TEXT NOT NULL UNIQUE
);


CREATE TABLE PromptTemplate (
    template_id INTEGER PRIMARY KEY,
    template_name TEXT NOT NULL UNIQUE
);


CREATE TABLE PromptTemplateVersion (
    template_version_id INTEGER PRIMARY KEY,
    template_id INTEGER NOT NULL,
    version_number INTEGER NOT NULL,
    template_text TEXT NOT NULL,
    created_at TEXT NOT NULL,

    FOREIGN KEY (template_id)
        REFERENCES PromptTemplate(template_id)
        ON DELETE CASCADE, -- versions belong to their template

    UNIQUE (template_id, version_number),

    CHECK (version_number >= 1)
);


CREATE TABLE Session (
    session_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    started_at TEXT NOT NULL,

    FOREIGN KEY (user_id)
        REFERENCES User(user_id)
        ON DELETE CASCADE -- session has no meaning without the user
);


CREATE TABLE Turn (
    turn_id INTEGER PRIMARY KEY,
    session_id INTEGER NOT NULL,
    turn_index INTEGER NOT NULL,
    user_message TEXT NOT NULL,
    assistant_message TEXT NOT NULL,
    prompt_template_version_id INTEGER NOT NULL,
    model_id INTEGER NOT NULL,
    temperature REAL NOT NULL
        CHECK (temperature >= 0.0),
    input_tokens INTEGER NOT NULL
        CHECK (input_tokens >= 0),
    output_tokens INTEGER NOT NULL
        CHECK (output_tokens >= 0),
    cached_input_tokens INTEGER NOT NULL
        CHECK (cached_input_tokens >= 0),
    created_at TEXT NOT NULL,

    FOREIGN KEY (session_id)
        REFERENCES Session(session_id)
        ON DELETE CASCADE, -- turns belong to a session

    FOREIGN KEY (prompt_template_version_id)
        REFERENCES PromptTemplateVersion(template_version_id)
        ON DELETE RESTRICT, -- historical turns must keep their exact prompt version

    FOREIGN KEY (model_id)
        REFERENCES Model(model_id)
        ON DELETE RESTRICT, -- historical turns must keep their model identity

    UNIQUE (session_id, turn_index),

    CHECK (turn_index >= 1)
);


CREATE TABLE ToolCall (
    tool_call_id INTEGER PRIMARY KEY,
    turn_id INTEGER NOT NULL,
    parent_tool_call_id INTEGER,
    tool_name TEXT NOT NULL,
    arguments_json TEXT NOT NULL,
    result TEXT,
    latency_ms INTEGER,
    errored INTEGER NOT NULL
        CHECK (errored IN (0, 1)),
    called_at TEXT NOT NULL,

    FOREIGN KEY (turn_id)
        REFERENCES Turn(turn_id)
        ON DELETE CASCADE, -- tool call belongs to its turn

    FOREIGN KEY (parent_tool_call_id)
        REFERENCES ToolCall(tool_call_id)
        ON DELETE CASCADE, -- nested call depends on its parent

    CHECK (json_valid(arguments_json)),

    CHECK (
        latency_ms IS NULL
        OR latency_ms >= 0
    )
);


CREATE TABLE ModelPricingPeriod (
    pricing_period_id INTEGER PRIMARY KEY,
    model_id INTEGER NOT NULL,
    input_rate REAL NOT NULL
        CHECK (input_rate >= 0.0),
    output_rate REAL NOT NULL
        CHECK (output_rate >= 0.0),
    cached_input_rate REAL NOT NULL
        CHECK (cached_input_rate >= 0.0),
    valid_from TEXT NOT NULL,
    valid_to TEXT,

    FOREIGN KEY (model_id)
        REFERENCES Model(model_id)
        ON DELETE RESTRICT, -- preserve historical model pricing

    UNIQUE (model_id, valid_from),

    CHECK (valid_to IS NULL OR valid_to > valid_from)
);


CREATE TABLE AgentRecommendation (
    recommendation_id INTEGER PRIMARY KEY,
    turn_id INTEGER NOT NULL,
    video_id INTEGER NOT NULL,
    shelf_position INTEGER NOT NULL,
    recommended_at TEXT NOT NULL,

    FOREIGN KEY (turn_id)
        REFERENCES Turn(turn_id)
        ON DELETE CASCADE, -- recommendation belongs to the turn

    FOREIGN KEY (video_id)
        REFERENCES Video(video_id)
        ON DELETE RESTRICT, -- preserve recommendation history

    UNIQUE (turn_id, shelf_position),

    CHECK (shelf_position >= 1)
);


CREATE TABLE Impression (
    impression_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    video_id INTEGER NOT NULL,
    recommendation_id INTEGER,
    shown_at TEXT NOT NULL,
    feed_position INTEGER NOT NULL,
    model_version TEXT NOT NULL,

    FOREIGN KEY (user_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT, -- preserve historical impression ownership

    FOREIGN KEY (video_id)
        REFERENCES Video(video_id)
        ON DELETE RESTRICT, -- preserve historical watch telemetry

    FOREIGN KEY (recommendation_id)
        REFERENCES AgentRecommendation(recommendation_id)
        ON DELETE SET NULL, -- impression remains valid if recommendation is removed

    CHECK (feed_position >= 1)
);


CREATE TABLE ViewSegment (
    view_segment_id INTEGER PRIMARY KEY,
    impression_id INTEGER NOT NULL,
    segment_start_ms INTEGER NOT NULL,
    segment_end_ms INTEGER NOT NULL,
    reached_end INTEGER NOT NULL
        CHECK (reached_end IN (0, 1)),

    FOREIGN KEY (impression_id)
        REFERENCES Impression(impression_id)
        ON DELETE CASCADE, -- segment cannot exist without its impression

    CHECK (segment_end_ms >= segment_start_ms)
);


CREATE TABLE Signal (
    signal_id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    video_id INTEGER NOT NULL,
    signal_type TEXT NOT NULL
        CHECK (signal_type IN (
            'like',
            'save',
            'share',
            'comment',
            'follow_from_feed',
            'not_interested',
            'report',
            'like_retraction'
        )),
    share_destination TEXT,
    comment_text TEXT,
    retracts_signal_id INTEGER,
    created_at TEXT NOT NULL,

    FOREIGN KEY (user_id)
        REFERENCES User(user_id)
        ON DELETE RESTRICT, -- preserve the actor in interaction history

    FOREIGN KEY (video_id)
        REFERENCES Video(video_id)
        ON DELETE RESTRICT, -- preserve the interaction history

    FOREIGN KEY (retracts_signal_id)
        REFERENCES Signal(signal_id)
        ON DELETE RESTRICT, -- a retraction must retain its referenced signal

    CHECK (
        (signal_type = 'share'
         AND share_destination IN (
             'whatsapp',
             'instagram',
             'copied_link'
         ))
        OR
        (signal_type <> 'share'
         AND share_destination IS NULL)
    ),

    CHECK (
        (signal_type = 'comment'
         AND comment_text IS NOT NULL)
        OR
        (signal_type <> 'comment'
         AND comment_text IS NULL)
    ),

    CHECK (
        (signal_type = 'like_retraction'
         AND retracts_signal_id IS NOT NULL)
        OR
        (signal_type <> 'like_retraction'
         AND retracts_signal_id IS NULL)
    )
);


CREATE TABLE LLMJudgeScore (
    score_id INTEGER PRIMARY KEY,
    turn_id INTEGER NOT NULL UNIQUE,
    helpfulness REAL NOT NULL,
    groundedness REAL NOT NULL,
    safety REAL NOT NULL,
    judged_at TEXT NOT NULL,

    FOREIGN KEY (turn_id)
        REFERENCES Turn(turn_id)
        ON DELETE CASCADE, -- score belongs to its turn

    CHECK (helpfulness BETWEEN 0 AND 5),
    CHECK (groundedness BETWEEN 0 AND 5),
    CHECK (safety BETWEEN 0 AND 5)
);


CREATE TABLE UserRating (
    rating_id INTEGER PRIMARY KEY,
    turn_id INTEGER NOT NULL UNIQUE,
    rating TEXT NOT NULL
        CHECK (rating IN ('up', 'down')),
    rated_at TEXT NOT NULL,

    FOREIGN KEY (turn_id)
        REFERENCES Turn(turn_id)
        ON DELETE CASCADE -- rating belongs to its turn
);

COMMIT;