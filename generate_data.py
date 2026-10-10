import hashlib
import json
import random
import sqlite3
from datetime import datetime, timedelta, timezone


ROLL_NUMBER = "DA24B001"

N_USERS = 5000
N_VIDEOS = 20000
N_IMPRESSIONS = 300000
N_AGENT_SESSIONS = 2000
SCALE = 50

DB_FILE = "scrollsense_a2.db"

START = datetime(2026, 3, 1, tzinfo=timezone.utc)
END = datetime(2026, 9, 13, tzinfo=timezone.utc)

seed = int(hashlib.sha256(ROLL_NUMBER.encode()).hexdigest()[:16], 16)
random.seed(seed)


def ts(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def random_time(start=START, end=END):
    seconds = int((end - start).total_seconds())
    return start + timedelta(seconds=random.randint(0, seconds))


def choice(values, weights):
    return random.choices(values, weights=weights, k=1)[0]


def activity_time():
    day = random_time().date()

    hour = choice(
        range(24),
        [
            1, 1, 1, 1, 1, 2,
            3, 4, 6, 7, 8, 8,
            9, 10, 12, 14, 16, 18,
            19, 18, 14, 9, 5, 3
        ]
    )

    return datetime(
        day.year,
        day.month,
        day.day,
        hour,
        random.randint(0, 59),
        random.randint(0, 59),
        tzinfo=timezone.utc
    )


def watch_time(duration):
    if random.random() < 0.07:
        return duration * random.randint(2, 3)

    x = random.random()

    if x < 0.65:
        p = random.uniform(0.02, 0.30)
    elif x < 0.90:
        p = random.uniform(0.30, 0.70)
    else:
        p = random.uniform(0.70, 1.0)

    return max(250, int(duration * p))


def main():
    users_n = int(N_USERS * SCALE)
    videos_n = int(N_VIDEOS * SCALE)
    impressions_n = int(N_IMPRESSIONS * SCALE)
    sessions_n = int(N_AGENT_SESSIONS * SCALE)

    conn = sqlite3.connect(DB_FILE)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")

    cur = conn.cursor()

    try:
        conn.execute("BEGIN")

        users = []

        for i in range(1, users_n + 1):
            method = choice(["phone", "google"],[0.62, 0.38])

            phone = None
            google = None

            if method == "phone":
                phone = f"9{i:09d}"
            else:
                google = f"google_{i}_{random.randint(1000,9999)}"

            created = random_time(START,START + timedelta(days=150))

            users.append((
                i,
                method,
                phone,
                google,
                f"user{i}@example.com",
                f"User {i}",
                ts(created)
            ))

        cur.executemany(
            """
            INSERT INTO User
            (
                user_id,
                auth_method,
                phone_number,
                google_account_id,
                email,
                display_name,
                created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            users
        )

        handles = []

        for i in range(1, users_n + 1):
            start = random_time(
                START,
                END - timedelta(days=120)
            )

            if random.random() < 0.12:
                change = start + timedelta(
                    days=random.randint(30, 120)
                )

                handles.append((
                    len(handles) + 1,
                    i,
                    f"user_{i}",
                    ts(start),
                    ts(change)
                ))

                handles.append((
                    len(handles) + 1,
                    i,
                    f"user_{i}_new",
                    ts(change),
                    None
                ))
            else:
                handles.append((
                    len(handles) + 1,
                    i,
                    f"user_{i}",
                    ts(start),
                    None
                ))

        cur.executemany(
            """
            INSERT INTO UserHandlePeriod
            (
                handle_period_id,
                user_id,
                handle,
                valid_from,
                valid_to
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            handles
        )

        statuses = []

        for i in range(1, users_n + 1):
            created = datetime.strptime(
                users[i - 1][6],
                "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=timezone.utc)

            if random.random() < 0.08:
                start = created + timedelta(
                    days=random.randint(10, 100)
                )

                if start >= END - timedelta(days=1):
                    statuses.append((
                        len(statuses) + 1,
                        i,
                        "active",
                        ts(created),
                        None
                    ))
                    continue

                status = choice(
                    ["deactivated", "pending_deletion"],
                    [0.65, 0.35]
                )

                if status == "pending_deletion":
                    end = start + timedelta(days=30)
                else:
                    end = start + timedelta(
                        days=random.randint(5, 60)
                    )

                end = min(
                    end,
                    END - timedelta(seconds=1)
                )

                statuses.append((
                    len(statuses) + 1,
                    i,
                    "active",
                    ts(created),
                    ts(start)
                ))

                statuses.append((
                    len(statuses) + 1,
                    i,
                    status,
                    ts(start),
                    ts(end)
                ))

                statuses.append((
                    len(statuses) + 1,
                    i,
                    "active",
                    ts(end),
                    None
                ))
            else:
                statuses.append((
                    len(statuses) + 1,
                    i,
                    "active",
                    ts(created),
                    None
                ))

        cur.executemany(
            """
            INSERT INTO UserStatusPeriod
            (
                status_period_id,
                user_id,
                status,
                valid_from,
                valid_to
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            statuses
        )

        category_names = [
            "technology",
            "sports",
            "music",
            "travel",
            "food",
            "fitness",
            "gaming",
            "education",
            "fashion",
            "comedy",
            "movies",
            "photography",
            "science",
            "business",
            "art",
            "books",
            "coding",
            "cars",
            "nature",
            "news"
        ]

        categories = [
            (i + 1, name)
            for i, name in enumerate(category_names)
        ]

        cur.executemany(
            """
            INSERT INTO InterestCategory
            (category_id, category_name)
            VALUES (?, ?)
            """,
            categories
        )

        declared = []

        for user_id in range(1, users_n + 1):
            selected = random.sample(
                range(1, len(categories) + 1),
                random.randint(1, 4)
            )

            for category_id in selected:
                declared.append((
                    user_id,
                    category_id,
                    ts(activity_time())
                ))

        cur.executemany(
            """
            INSERT INTO UserDeclaredInterest
            (user_id, category_id, declared_at)
            VALUES (?, ?, ?)
            """,
            declared
        )

        inferred = []

        for user_id in range(1, users_n + 1):
            for _ in range(random.randint(1, 3)):
                category_id = random.randint(
                    1,
                    len(categories)
                )

                score = round(
                    random.betavariate(3.5, 2.0),
                    3
                )

                start = random_time(
                    START,
                    END - timedelta(days=14)
                )

                inferred.append((
                    len(inferred) + 1,
                    user_id,
                    category_id,
                    score,
                    ts(start),
                    ts(start + timedelta(days=7))
                ))

        cur.executemany(
            """
            INSERT INTO UserInferredInterest
            (
                inferred_interest_id,
                user_id,
                category_id,
                confidence_score,
                valid_from,
                valid_to
            )
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            inferred
        )

        suppressions = []

        for user_id in range(1, users_n + 1):
            if random.random() < 0.18:
                start = random_time(
                    START,
                    END - timedelta(days=20)
                )

                suppressions.append((
                    len(suppressions) + 1,
                    user_id,
                    random.randint(1, len(categories)),
                    ts(start),
                    None
                ))

        cur.executemany(
            """
            INSERT INTO InterestSuppression
            (
                suppression_id,
                user_id,
                category_id,
                suppressed_from,
                suppressed_to
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            suppressions
        )

        creator_n = max(
            1,
            int(users_n * 0.18)
        )

        creator_users = random.sample(
            range(1, users_n + 1),
            creator_n
        )

        creators = []

        for creator_id, user_id in enumerate(
            creator_users,
            start=1
        ):
            creators.append((
                creator_id,
                user_id,
                ts(
                    random_time(
                        START,
                        END - timedelta(days=30)
                    )
                )
            ))

        cur.executemany(
            """
            INSERT INTO Creator
            (creator_id, user_id, became_creator_at)
            VALUES (?, ?, ?)
            """,
            creators
        )

        tier_names = [
            "starter",
            "growing",
            "pro",
            "elite"
        ]

        tiers = []

        for creator_id in range(
            1,
            creator_n + 1
        ):
            start = random_time(
                START,
                END - timedelta(days=90)
            )

            tier = choice(
                tier_names,
                [0.45, 0.30, 0.18, 0.07]
            )

            tiers.append((
                len(tiers) + 1,
                creator_id,
                tier,
                ts(start),
                None
            ))

            if random.random() < 0.30:
                change = start + timedelta(
                    days=random.randint(30, 90)
                )

                if change < END:
                    tiers[-1] = (
                        tiers[-1][0],
                        tiers[-1][1],
                        tiers[-1][2],
                        tiers[-1][3],
                        ts(change)
                    )

                    tiers.append((
                        len(tiers) + 1,
                        creator_id,
                        choice(
                            tier_names,
                            [0.15, 0.30, 0.35, 0.20]
                        ),
                        ts(change),
                        None
                    ))

        cur.executemany(
            """
            INSERT INTO CreatorTierPeriod
            (
                tier_period_id,
                creator_id,
                tier,
                valid_from,
                valid_to
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            tiers
        )

        models = [
            (1, "gpt-small"),
            (2, "gpt-medium"),
            (3, "gpt-large"),
            (4, "reasoning-v1"),
            (5, "reasoning-v2")
        ]

        cur.executemany(
            """
            INSERT INTO Model
            (model_id, model_name)
            VALUES (?, ?)
            """,
            models
        )

        pricing = []

        for model_id in range(1, 6):
            pricing.append((
                len(pricing) + 1,
                model_id,
                round(0.40 * model_id, 4),
                round(0.80 * model_id, 4),
                round(0.10 * model_id, 4),
                "2026-03-01T00:00:00Z",
                "2026-07-01T00:00:00Z"
            ))

            pricing.append((
                len(pricing) + 1,
                model_id,
                round(0.46 * model_id, 4),
                round(0.92 * model_id, 4),
                round(0.115 * model_id, 4),
                "2026-07-01T00:00:00Z",
                None
            ))

        cur.executemany(
            """
            INSERT INTO ModelPricingPeriod
            (
                pricing_period_id,
                model_id,
                input_rate,
                output_rate,
                cached_input_rate,
                valid_from,
                valid_to
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            pricing
        )

        templates = [
            (1, "why_this"),
            (2, "search_shelf"),
            (3, "general_chat"),
            (4, "creator_help")
        ]

        cur.executemany(
            """
            INSERT INTO PromptTemplate
            (template_id, template_name)
            VALUES (?, ?)
            """,
            templates
        )

        texts = {
            1: [
                "Explain why this video was recommended.",
                "Give a concise reason for surfacing this clip."
            ],
            2: [
                "Find relevant clips matching the user's request.",
                "Search for candidate videos and return a useful shelf."
            ],
            3: [
                "Answer the user's question using available context.",
                "Respond clearly using available evidence."
            ],
            4: [
                "Help the creator understand audience engagement.",
                "Explain the creator analytics clearly."
            ]
        }

        versions = []

        for template_id in range(1, 5):
            for version, text in enumerate(
                texts[template_id],
                start=1
            ):
                created = datetime(
                    2026,
                    3 + version,
                    1,
                    tzinfo=timezone.utc
                )

                versions.append((
                    len(versions) + 1,
                    template_id,
                    version,
                    text,
                    ts(created)
                ))

        cur.executemany(
            """
            INSERT INTO PromptTemplateVersion
            (
                template_version_id,
                template_id,
                version_number,
                template_text,
                created_at
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            versions
        )

        videos = []

        for video_id in range(
            1,
            videos_n + 1
        ):
            uploaded = random_time(
                START,
                END - timedelta(days=2)
            )

            videos.append((
                video_id,
                random.randint(1, users_n),
                random.randint(20000, 90000),
                f"video {video_id} #daily #life",
                None,
                ts(uploaded)
            ))

        cur.executemany(
            """
            INSERT INTO Video
            (
                video_id,
                owner_id,
                duration_ms,
                caption,
                audio_track_id,
                uploaded_at
            )
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            videos
        )

        original_videos = random.sample(
            range(1, videos_n + 1),
            max(1, int(videos_n * 0.35))
        )

        audio = []

        for video_id in original_videos:
            audio.append((
                len(audio) + 1,
                video_id,
                "original",
                f"original_audio_{video_id}"
            ))

        for i in range(int(videos_n * 0.20)):
            audio.append((
                len(audio) + 1,
                None,
                "licensed",
                f"licensed_audio_{i + 1}"
            ))

        cur.executemany(
            """
            INSERT INTO AudioTrack
            (
                track_id,
                origin_video_id,
                source_type,
                title
            )
            VALUES (?, ?, ?, ?)
            """,
            audio
        )

        tracks = [row[0] for row in audio]

        audio_updates = []

        for video_id in range(1, videos_n + 1):
            if random.random() < 0.72:
                audio_updates.append((
                    random.choice(tracks),
                    video_id
                ))

        cur.executemany(
            """
            UPDATE Video
            SET audio_track_id = ?
            WHERE video_id = ?
            """,
            audio_updates
        )

        hashtag_names = [
            "life",
            "fun",
            "daily",
            "student",
            "travel",
            "food",
            "coding",
            "tech",
            "fitness",
            "music",
            "gaming",
            "fashion",
            "art",
            "learning",
            "comedy",
            "nature",
            "books",
            "cars",
            "science",
            "friends"
        ]

        hashtags = [
            (i + 1, name)
            for i, name in enumerate(hashtag_names)
        ]

        cur.executemany(
            """
            INSERT INTO Hashtag
            (hashtag_id, tag_text)
            VALUES (?, ?)
            """,
            hashtags
        )

        video_tags = []

        for video_id in range(1, videos_n + 1):
            selected = random.sample(
                range(1, len(hashtags) + 1),
                random.randint(1, 3)
            )

            for hashtag_id in selected:
                video_tags.append((
                    video_id,
                    hashtag_id
                ))

        cur.executemany(
            """
            INSERT INTO VideoHashtag
            (video_id, hashtag_id)
            VALUES (?, ?)
            """,
            video_tags
        )

        moderation = []

        for video_id in range(1, videos_n + 1):
            uploaded = datetime.strptime(
                videos[video_id - 1][5],
                "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=timezone.utc)

            first = uploaded + timedelta(
                minutes=random.randint(1, 30)
            )

            moderation.append((
                len(moderation) + 1,
                video_id,
                "pending",
                "classifier",
                None,
                "clf-v1",
                ts(first)
            ))

            if random.random() < 0.80:
                live = first + timedelta(
                    minutes=random.randint(1, 180)
                )

                moderation.append((
                    len(moderation) + 1,
                    video_id,
                    "live",
                    "classifier",
                    None,
                    "clf-v1",
                    ts(live)
                ))

            if random.random() < 0.07:
                change = first + timedelta(
                    days=random.randint(10, 120)
                )

                moderation.append((
                    len(moderation) + 1,
                    video_id,
                    choice(
                        [
                            "age_restricted",
                            "demoted",
                            "taken_down"
                        ],
                        [0.45, 0.35, 0.20]
                    ),
                    "human",
                    random.randint(1, users_n),
                    None,
                    ts(change)
                ))

            if random.random() < 0.015:
                change = first + timedelta(
                    days=random.randint(30, 150)
                )

                moderation.append((
                    len(moderation) + 1,
                    video_id,
                    choice(
                        [
                            "live",
                            "demoted",
                            "taken_down"
                        ],
                        [0.55, 0.25, 0.20]
                    ),
                    "human",
                    random.randint(1, users_n),
                    None,
                    ts(change)
                ))

        cur.executemany(
            """
            INSERT INTO ModerationDecision
            (
                decision_id,
                video_id,
                state,
                decided_by_type,
                reviewer_user_id,
                classifier_version,
                decided_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            moderation
        )

        popular_users = random.sample(
            range(1, users_n + 1),
            max(1, int(users_n * 0.05))
        )

        follows = []

        for _ in range(int(users_n * 3)):
            follower = random.randint(
                1,
                users_n
            )

            if random.random() < 0.70:
                followee = random.choice(popular_users)
            else:
                followee = random.randint(
                    1,
                    users_n
                )

            if follower == followee:
                continue

            started = activity_time()
            ended = None

            if random.random() < 0.18:
                end = started + timedelta(
                    days=random.randint(1, 120)
                )

                if end <= END:
                    ended = ts(end)

            follows.append((
                len(follows) + 1,
                follower,
                followee,
                ts(started),
                ended
            ))

        cur.executemany(
            """
            INSERT INTO FollowPeriod
            (
                follow_period_id,
                follower_id,
                followee_id,
                started_at,
                ended_at
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            follows
        )

        blocks = []

        for _ in range(int(users_n * 0.18)):
            blocker = random.randint(
                1,
                users_n
            )

            blocked = random.randint(
                1,
                users_n
            )

            if blocker == blocked:
                continue

            started = activity_time()

            cur.execute(
                """
                UPDATE FollowPeriod
                SET ended_at = ?
                WHERE ended_at IS NULL
                  AND started_at < ?
                  AND (
                      (follower_id = ? AND followee_id = ?)
                      OR
                      (follower_id = ? AND followee_id = ?)
                  )
                """,
                (
                    ts(started),
                    ts(started),
                    blocker,
                    blocked,
                    blocked,
                    blocker
                )
            )

            blocks.append((
                len(blocks) + 1,
                blocker,
                blocked,
                ts(started),
                None
            ))

        cur.executemany(
            """
            INSERT INTO BlockPeriod
            (
                block_period_id,
                blocker_id,
                blocked_id,
                started_at,
                ended_at
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            blocks
        )

        mutes = []

        for _ in range(int(users_n * 0.30)):
            muter = random.randint(
                1,
                users_n
            )

            muted = random.randint(
                1,
                users_n
            )

            if muter == muted:
                continue

            mutes.append((
                len(mutes) + 1,
                muter,
                muted,
                ts(activity_time()),
                None
            ))

        cur.executemany(
            """
            INSERT INTO MutePeriod
            (
                mute_period_id,
                muter_id,
                muted_id,
                started_at,
                ended_at
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            mutes
        )

        sessions = []

        for session_id in range(
            1,
            sessions_n + 1
        ):
            sessions.append((
                session_id,
                random.randint(1, users_n),
                ts(activity_time())
            ))

        cur.executemany(
            """
            INSERT INTO Session
            (
                session_id,
                user_id,
                started_at
            )
            VALUES (?, ?, ?)
            """,
            sessions
        )

        turns = []
        turn_user = {}

        for session_id, user_id, started_at in sessions:
            n = choice(
                [1, 2, 3, 4, 5],
                [0.15, 0.30, 0.28, 0.18, 0.09]
            )

            start = datetime.strptime(
                started_at,
                "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=timezone.utc)

            elapsed = 0

            for index in range(1, n + 1):
                elapsed += random.randint(1, 7)

                created = start + timedelta(
                    minutes=elapsed
                )

                turn_id = len(turns) + 1
                input_tokens = random.randint(100, 1800)
                output_tokens = random.randint(80, 1200)

                turns.append((
                    turn_id,
                    session_id,
                    index,
                    choice(
                        [
                            "Why was this video recommended?",
                            "Find me a clip about this topic.",
                            "Show me something similar.",
                            "Can you explain this result?",
                            "What should I watch next?"
                        ],
                        [0.24, 0.22, 0.20, 0.18, 0.16]
                    ),
                    "Here is the explanation based on the available context.",
                    random.randint(1, len(versions)),
                    choice(
                        [1, 2, 3, 4, 5],
                        [0.20, 0.25, 0.25, 0.18, 0.12]
                    ),
                    round(
                        random.uniform(0.1, 1.0),
                        2
                    ),
                    input_tokens,
                    output_tokens,
                    random.randint(
                        0,
                        min(input_tokens, 800)
                    ),
                    ts(created)
                ))

                turn_user[turn_id] = user_id

        cur.executemany(
            """
            INSERT INTO Turn
            (
                turn_id,
                session_id,
                turn_index,
                user_message,
                assistant_message,
                prompt_template_version_id,
                model_id,
                temperature,
                input_tokens,
                output_tokens,
                cached_input_tokens,
                created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            turns
        )

        tools = []

        for turn in turns:
            if random.random() >= 0.55:
                continue

            root = len(tools) + 1

            tools.append((
                root,
                turn[0],
                None,
                choice(
                    [
                        "search_videos",
                        "search_hashtags",
                        "lookup_creator",
                        "rank_candidates"
                    ],
                    [0.40, 0.20, 0.20, 0.20]
                ),
                json.dumps({
                    "query": "interesting clip",
                    "limit": random.randint(5, 20)
                }),
                json.dumps({
                    "status": "ok"
                }),
                random.randint(30, 800),
                0,
                turn[11]
            ))

            if random.random() < 0.35:
                child = len(tools) + 1

                tools.append((
                    child,
                    turn[0],
                    root,
                    "fetch_video_metadata",
                    json.dumps({
                        "video_id": random.randint(
                            1,
                            videos_n
                        )
                    }),
                    json.dumps({
                        "status": "ok"
                    }),
                    random.randint(20, 500),
                    0,
                    turn[11]
                ))

                if random.random() < 0.25:
                    grandchild = len(tools) + 1

                    tools.append((
                        grandchild,
                        turn[0],
                        child,
                        "fetch_creator_context",
                        json.dumps({
                            "creator_id": random.randint(
                                1,
                                creator_n
                            )
                        }),
                        json.dumps({
                            "status": "ok"
                        }),
                        random.randint(20, 400),
                        0,
                        turn[11]
                    ))

        cur.executemany(
            """
            INSERT INTO ToolCall
            (
                tool_call_id,
                turn_id,
                parent_tool_call_id,
                tool_name,
                arguments_json,
                result,
                latency_ms,
                errored,
                called_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            tools
        )

        recommendations = []

        for turn in turns:
            if random.random() >= 0.60:
                continue

            selected = random.sample(
                range(1, videos_n + 1),
                random.randint(3, 8)
            )

            created = datetime.strptime(
                turn[11],
                "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=timezone.utc)

            for position, video_id in enumerate(
                selected,
                start=1
            ):
                recommendations.append((
                    len(recommendations) + 1,
                    turn[0],
                    video_id,
                    position,
                    ts(
                        created + timedelta(
                            seconds=position
                        )
                    )
                ))

        cur.executemany(
            """
            INSERT INTO AgentRecommendation
            (
                recommendation_id,
                turn_id,
                video_id,
                shelf_position,
                recommended_at
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            recommendations
        )

        rec_map = {
            row[0]: row
            for row in recommendations
        }

        impressions = []

        for impression_id in range(
            1,
            impressions_n + 1
        ):
            user_id = random.randint(
                1,
                users_n
            )

            video_id = random.randint(
                1,
                videos_n
            )

            shown = activity_time()
            recommendation_id = None

            if rec_map and random.random() < 0.12:
                recommendation_id = random.choice(
                    list(rec_map.keys())
                )

                rec = rec_map[recommendation_id]

                turn_id = rec[1]
                user_id = turn_user[turn_id]
                video_id = rec[2]

                rec_time = datetime.strptime(
                    rec[4],
                    "%Y-%m-%dT%H:%M:%SZ"
                ).replace(tzinfo=timezone.utc)

                shown = rec_time + timedelta(
                    seconds=random.randint(1, 30)
                )

            impressions.append((
                impression_id,
                user_id,
                video_id,
                recommendation_id,
                ts(shown),
                random.randint(1, 20),
                choice(
                    [
                        "feed-v13",
                        "feed-v14",
                        "feed-v15",
                        "feed-v16"
                    ],
                    [0.20, 0.30, 0.30, 0.20]
                )
            ))

        cur.executemany(
            """
            INSERT INTO Impression
            (
                impression_id,
                user_id,
                video_id,
                recommendation_id,
                shown_at,
                feed_position,
                model_version
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            impressions
        )

        durations = {
            row[0]: row[2]
            for row in videos
        }

        views = []

        for impression in impressions:
            if random.random() >= 0.42:
                continue

            duration = durations[impression[2]]
            total = watch_time(duration)

            if total > duration:
                full_plays = total // duration
                remainder = total % duration

                for _ in range(full_plays):
                    views.append((
                        len(views) + 1,
                        impression[0],
                        0,
                        duration,
                        1
                    ))

                if remainder > 0:
                    views.append((
                        len(views) + 1,
                        impression[0],
                        0,
                        remainder,
                        0
                    ))

                continue

            start = 0
            remaining = total

            n = (
                1
                if random.random() < 0.78
                else random.randint(2, 3)
            )

            for i in range(n):
                if i == n - 1:
                    length = remaining
                else:
                    length = max(
                        250,
                        int(
                            remaining
                            * random.uniform(0.25, 0.60)
                        )
                    )

                length = min(
                    length,
                    duration - start
                )

                if length <= 0:
                    break

                end = start + length

                views.append((
                    len(views) + 1,
                    impression[0],
                    start,
                    end,
                    int(end >= duration)
                ))

                start = end
                remaining -= length

                if start >= duration:
                    break

        cur.executemany(
            """
            INSERT INTO ViewSegment
            (
                view_segment_id,
                impression_id,
                segment_start_ms,
                segment_end_ms,
                reached_end
            )
            VALUES (?, ?, ?, ?, ?)
            """,
            views
        )

        signals = []
        likes = []

        signal_types = [
            "like",
            "save",
            "share",
            "comment",
            "follow_from_feed",
            "not_interested",
            "report"
        ]

        viewed_impressions = {
            row[1]
            for row in views
        }

        selected_impressions = random.sample(
            range(1, impressions_n + 1),
            max(
                1,
                int(impressions_n * 0.07)
            )
        )

        impression_map = {
            row[0]: row
            for row in impressions
        }

        for impression_id in selected_impressions:
            if impression_id not in viewed_impressions:
                if random.random() > 0.15:
                    continue

            impression = impression_map[impression_id]

            kind = choice(
                signal_types,
                [0.46, 0.18, 0.10, 0.10, 0.07, 0.06, 0.03]
            )

            shown = datetime.strptime(
                impression[4],
                "%Y-%m-%dT%H:%M:%SZ"
            ).replace(tzinfo=timezone.utc)

            created = shown + timedelta(
                seconds=random.randint(1, 30)
            )

            share = None
            comment = None

            if kind == "share":
                share = choice(
                    [
                        "whatsapp",
                        "instagram",
                        "copied_link"
                    ],
                    [0.50, 0.25, 0.25]
                )

            if kind == "comment":
                comment = choice(
                    [
                        "great clip",
                        "this was useful",
                        "lol",
                        "saving this",
                        "interesting"
                    ],
                    [0.28, 0.22, 0.20, 0.15, 0.15]
                )

            signal_id = len(signals) + 1

            signals.append((
                signal_id,
                impression[1],
                impression[2],
                kind,
                share,
                comment,
                None,
                ts(created)
            ))

            if kind == "like":
                likes.append((
                    signal_id,
                    impression[1],
                    impression[2],
                    created
                ))

        cur.executemany(
            """
            INSERT INTO Signal
            (
                signal_id,
                user_id,
                video_id,
                signal_type,
                share_destination,
                comment_text,
                retracts_signal_id,
                created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            signals
        )

        retractions = []

        if likes:
            selected_likes = random.sample(
                likes,
                max(
                    1,
                    int(len(likes) * 0.12)
                )
            )

            for original_id, user_id, video_id, created in selected_likes:
                retractions.append((
                    len(signals) + len(retractions) + 1,
                    user_id,
                    video_id,
                    "like_retraction",
                    None,
                    None,
                    original_id,
                    ts(
                        created + timedelta(
                            seconds=random.randint(5, 55)
                        )
                    )
                ))

        cur.executemany(
            """
            INSERT INTO Signal
            (
                signal_id,
                user_id,
                video_id,
                signal_type,
                share_destination,
                comment_text,
                retracts_signal_id,
                created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            retractions
        )

        judge_rows = []

        for turn in turns:
            if random.random() < 0.18:
                judge_rows.append((
                    len(judge_rows) + 1,
                    turn[0],
                    round(random.uniform(2.5, 5.0), 2),
                    round(random.uniform(2.5, 5.0), 2),
                    round(random.uniform(3.0, 5.0), 2),
                    ts(
                        datetime.strptime(
                            turn[11],
                            "%Y-%m-%dT%H:%M:%SZ"
                        ).replace(tzinfo=timezone.utc)
                        + timedelta(
                            minutes=random.randint(1, 30)
                        )
                    )
                ))

        cur.executemany(
            """
            INSERT INTO LLMJudgeScore
            (
                score_id,
                turn_id,
                helpfulness,
                groundedness,
                safety,
                judged_at
            )
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            judge_rows
        )

        ratings = []

        for turn in turns:
            if random.random() < 0.06:
                ratings.append((
                    len(ratings) + 1,
                    turn[0],
                    choice(
                        ["up", "down"],
                        [0.72, 0.28]
                    ),
                    ts(
                        datetime.strptime(
                            turn[11],
                            "%Y-%m-%dT%H:%M:%SZ"
                        ).replace(tzinfo=timezone.utc)
                        + timedelta(
                            minutes=random.randint(1, 60)
                        )
                    )
                ))

        cur.executemany(
            """
            INSERT INTO UserRating
            (
                rating_id,
                turn_id,
                rating,
                rated_at
            )
            VALUES (?, ?, ?, ?)
            """,
            ratings
        )

        conn.commit()

        print("Data generation complete")
        print("Users:", users_n)
        print("Videos:", videos_n)
        print("Impressions:", impressions_n)
        print("Agent sessions:", sessions_n)
        print("Seed:", ROLL_NUMBER)

    except Exception:
        conn.rollback()
        raise

    finally:
        conn.close()


if __name__ == "__main__":
    main()