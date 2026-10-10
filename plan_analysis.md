# ScrollSense Assignment 2 — Query Plan Analysis

## Environment and cost assumptions

- Database: `scrollsense_a2.db`
- SQLite version: 3.54.0
- Dataset scale: 50×
- Approximate database size: 1.5 GB
- Assumed block size: 4096 bytes
- Assumed average row footprint: 64 bytes
- Estimated rows per block: `floor(4096 / 64) = 64`

These are simplified cost-model assumptions. Actual SQLite page usage varies because records have different sizes and pages include B-tree and record overhead.

## 1. Access paths and scan-cost estimate

### F4 — Like retractions within 60 seconds

The query joins `Signal` to itself to match a like with a retraction and checks the time difference.

**Before the composite index**

```text
|--SCAN r
|--SEARCH l USING INTEGER PRIMARY KEY (rowid=?)
`--USE TEMP B-TREE FOR ORDER BY
```

SQLite scans the retraction-side input, looks up the corresponding like by primary key, and uses a temporary B-tree for ordering.

**After `idx_signal_type_retracts_created`**

```text
|--SEARCH r USING COVERING INDEX idx_signal_type_retracts_created (signal_type=?)
|--SEARCH l USING INTEGER PRIMARY KEY (rowid=?)
`--USE TEMP B-TREE FOR ORDER BY
```

The composite index enables a search using the leading `signal_type` column instead of scanning the entire `r` input. The primary-key lookup and temporary sort remain.

**Additional timing check — Signal retractions**

A count-only query joining `Signal` to itself to identify like retractions within 60 seconds returned 29,379 rows. SQLite reported an elapsed time of 0.047581 seconds (user CPU: 0.009800 seconds; system CPU: 0.006061 seconds). This is a lightweight baseline and should not be compared directly with the full F4 query runtime because it omits the original output columns, calculated duration, and ordering.

**F4 timing check:** The count-wrapped retraction query returned 29,379 matching rows in 0.017600 seconds (user CPU: 0.014305 seconds; system CPU: 0.003235 seconds). This measurement performs the filtering and join but returns only a count; it is not the runtime of the full F4 query, which also returns individual rows and sorts the output. The earlier standalone count-only check took 0.047581 seconds, illustrating that timings can vary between runs and query forms.

### F7 — Session cost by prompt-template version

The query joins `Session`, `Turn`, `PromptTemplateVersion`, and `ModelPricingPeriod`, filters sessions by start time, aggregates cost, and orders the results.

**Before `idx_session_started_session`**

```text
|--SCAN t
|--SEARCH s USING INTEGER PRIMARY KEY (rowid=?)
|--SEARCH ptv USING INTEGER PRIMARY KEY (rowid=?)
|--SEARCH p USING INDEX sqlite_autoindex_ModelPricingPeriod_1 (model_id=? AND valid_from<?)
|--USE TEMP B-TREE FOR GROUP BY
`--USE TEMP B-TREE FOR ORDER BY
```

**After `idx_session_started_session`**

```text
|--SEARCH s USING COVERING INDEX idx_session_started_session (started_at>? AND started_at<?)
|--SEARCH t USING INDEX sqlite_autoindex_Turn_1 (session_id=?)
|--SEARCH ptv USING INTEGER PRIMARY KEY (rowid=?)
|--SEARCH p USING INDEX sqlite_autoindex_ModelPricingPeriod_1 (model_id=? AND valid_from<?)
|--USE TEMP B-TREE FOR GROUP BY
`--USE TEMP B-TREE FOR ORDER BY
```

The access path changes from scanning `Turn` first to searching sessions within the requested date range and then finding their turns. The index begins with `started_at`, which supports the range predicate. Temporary B-trees are still needed for grouping and ordering.

**F7 measured runtime (after index creation):** 0.548 seconds real time, 0.084 seconds user CPU time, and 0.076 seconds system CPU time. This is one observed run on the scaled database. A before-index timing has not yet been recorded, so no speedup is claimed.

### F10 — Seven-day rolling watch time

This query joins the high-volume `ViewSegment` and `Impression` tables to compute rolling watch-time aggregates.

```text
|--CO-ROUTINE rolling_watch
|  |--MATERIALIZE daily_watch
|  |  |--SCAN vs
|  |  |--SEARCH i USING INTEGER PRIMARY KEY (rowid=?)
|  |  `--USE TEMP B-TREE FOR GROUP BY
|  |--SCAN d1
|  |--BLOOM FILTER ON d2 (user_id=?)
|  |--SEARCH d2 USING AUTOMATIC COVERING INDEX (user_id=?)
|  `--USE TEMP B-TREE FOR GROUP BY
|--SCAN rolling_watch
`--USE TEMP B-TREE FOR ORDER BY
```

SQLite scans `ViewSegment`, looks up the associated `Impression` using its integer primary key, materializes the daily aggregate, and uses a Bloom filter and an automatic covering index for the self-join on `user_id`. Temporary B-trees support grouping and ordering.

### Simplified full-scan calculation

`ViewSegment` contains 8,892,547 rows.

- Rows per block: `floor(4096 / 64) = 64`
- Estimated blocks: `ceil(8,892,547 / 64) = 138,946`
- Estimated block volume: approximately 569 MB in decimal units.


## 2. Composite-index experiments

### Index 1: Signal retraction lookup

```sql
CREATE INDEX idx_signal_type_retracts_created
ON Signal(signal_type, retracts_signal_id, created_at);
```

The leading `signal_type` column supports the equality predicate in F4. The remaining columns are relevant to matching the referenced signal and its timestamp. The captured plan confirms a covering-index search using `signal_type=?`. The temporary sort remains.

### Index 2: Session date-range lookup

```sql
CREATE INDEX idx_session_started_session
ON Session(started_at, session_id);
```

The leading `started_at` column supports the date-range predicate in F7. The captured plan changes from scanning `Turn` first to searching sessions in the date range and then finding matching turns through the existing index on `Turn(session_id)`. Grouping and ordering still use temporary B-trees.

### Index 3: Completed-view existence check

```sql
CREATE INDEX idx_viewsegment_impression_reached
ON ViewSegment(impression_id, reached_end);
```

The index supports F12's correlated existence check using both `impression_id` and `reached_end`. Before this index, SQLite used an automatic partial covering index. Afterward, the plan uses the persistent covering index. The plan still scans `Impression` and creates temporary B-trees for `DISTINCT` and ordering.

### Index considered but not built

```sql
-- Considered, not built:
-- CREATE INDEX idx_impression_recommendation_video_user
-- ON Impression(recommendation_id, video_id, user_id);
```

This index could support the recommendation, video, and user matching conditions in F12. It was not built in this experiment, so no performance gain is claimed. Building an index on the 15-million-row `Impression` table would require additional build time and storage. This is a trade-off rather than a measured result.

### Runtime comparison

The following wall-clock times were measured by running each complete query
with its target index absent and then present. The SQL and parameters were
kept the same within each pair.

| Query | Before index (s) | After index (s) | Observed reduction |
|---|---:|---:|---:|
| F4 — Signal retractions | 0.09 | 0.03 | 66.7% |
| F7 — Session cost | 0.13 | 0.08 | 38.5% |
| F12 — Completed recommendations | 6.94 | 3.46 | 50.1% |

The observed reduction is calculated as
((before time - after time) / before time) * 100.
These are single-run measurements, not controlled benchmarks. Cache state,
system load, and query-planning effects may influence the results. They
should therefore be treated as preliminary observations rather than
definitive performance guarantees. The execution plans provide complementary
evidence of the access-path changes.

All three target indexes were recreated after their respective baseline
measurements. The rejected Impression index was not built, so its storage and
performance trade-off remains a qualitative assessment.
## 3. Join strategy and cost model

F10 joins `ViewSegment` and `Impression`, both high-volume tables. F12 also matches these tables and connects them to recommendation, turn, and session records.

SQLite implements joins using nested-loop strategies. The captured plans show scans or searches of an outer input followed by primary-key or index lookups. The plans do not show a native hash join or sort-merge join.

For a simplified comparison, let:

- \(B(R)=138,946\) pages for `ViewSegment`.
- \(B(S)=234,375\) pages for `Impression`, assuming 64 rows per page.
- \(M=100\) buffer pages for a textbook block nested-loop model.

A naive tuple nested-loop join can be expensive if every outer row scans the entire inner relation. Under the simplified block nested-loop formula,

\[
B(R)+\left\lceil\frac{B(R)}{M-2}\right\rceil B(S)
\]

\[
=138,946+\left\lceil\frac{138,946}{98}\right\rceil(234,375)
\]

\[
=138,946+1,418(234,375)
=332,482,696
\]

estimated page transfers.

A two-pass sort-merge or Grace hash join is often estimated at approximately

\[
3(B(R)+B(S))=1,119,963
\]

page transfers under textbook assumptions.

These are theoretical comparisons, not measured SQLite costs. They assume simplified page sizes, buffer availability, and algorithm conditions. The actual SQLite plan uses indexed primary-key lookups and must not be equated with a naive nested-loop scan of the entire inner relation for each outer row. SQLite's algorithm choices are constrained by the join strategies available to the engine and the indexes present.

### Three-table join ordering

A reasonable strategy is to apply selective predicates early, then join the reduced result to the next relation through an available index. For a session-related query, filtering `Session` by its date range before joining to `Turn` can reduce the rows carried into later joins. The best order depends on actual selectivity, cardinalities, and available indexes; identifying a definitively cheapest order requires comparing candidate plans and measurements on the scaled database.

## Task 4: Predicate Pushdown

### 4.1 Relational Algebra: Naive Plan and Pushed-Down Rewrite

Predicate pushdown is a query optimisation technique in which a selection condition is applied as early as possible, reducing the number of tuples processed by subsequent joins. For this experiment, I use query F7, which calculates session-level model inference costs for sessions that started during August 2026.

The selective predicate is:

\[
\text{started\_at} \geq \text{'2026-08-01T00:00:00Z'}
\]

and

\[
\text{started\_at} < \text{'2026-09-01T00:00:00Z'}
\]

**Naive relational algebra plan**

Let \(S\) denote `Session`, \(T\) denote `Turn`, \(P\) denote `ModelPricingPeriod`, and \(V\) denote `PromptTemplateVersion`. The naive plan joins the relations before applying the date selection.

\[
\sigma_{\text{date range}}
\left(
S \bowtie T \bowtie V \bowtie P
\right)
\]

Here, \(\sigma\) denotes the selection operator, and \(\bowtie\) denotes a join. The selection retains only sessions whose start time falls within August 2026. Applying it after the joins can logically require intermediate join results containing sessions that will eventually be discarded.

**Pushed-down relational algebra plan**

The selection can instead be applied to `Session` before joining it with the other relations:

\[
\left(\sigma_{\text{date range}}(S)\right)
\bowtie T \bowtie V \bowtie P
\]

This rewrite reduces the number of session tuples entering the join operations. The join conditions, aggregation, `HAVING` condition, and final ordering remain unchanged.

**Equivalence rule and limitation**

For an inner join, a selection predicate that refers only to attributes of one input relation can be pushed below that join without changing the result, provided the predicate and join semantics remain unchanged. However, moving a predicate across an outer join can change the result because the selection may remove rows containing NULL values that the outer join was intended to preserve. Therefore, predicate pushdown must respect the semantics of the original query.

### 4.2 SQL Implementation and Execution-Plan Evidence

**Original query (F7)**

```sql
SELECT
    s.session_id,
    ptv.template_version_id,
    ptv.version_number,
    ROUND(
        SUM(
            (t.input_tokens - t.cached_input_tokens) * p.input_rate
            + t.cached_input_tokens * p.cached_input_rate
            + t.output_tokens * p.output_rate
        ),
        6
    ) AS session_cost
FROM Session s
JOIN Turn t
    ON t.session_id = s.session_id
JOIN PromptTemplateVersion ptv
    ON ptv.template_version_id = t.prompt_template_version_id
JOIN ModelPricingPeriod p
    ON p.model_id = t.model_id
   AND t.created_at >= p.valid_from
   AND (p.valid_to IS NULL OR t.created_at < p.valid_to)
WHERE s.started_at >= '2026-08-01T00:00:00Z'
  AND s.started_at < '2026-09-01T00:00:00Z'
GROUP BY
    s.session_id,
    ptv.template_version_id,
    ptv.version_number
HAVING session_cost > 0.05
ORDER BY
    session_cost DESC,
    s.session_id,
    ptv.version_number;
```

**Rewritten query with explicit predicate pushdown**

```sql
WITH filtered_sessions AS (
    SELECT
        session_id,
        user_id
    FROM Session
    WHERE started_at >= '2026-08-01T00:00:00Z'
      AND started_at < '2026-09-01T00:00:00Z'
)
SELECT
    s.session_id,
    ptv.template_version_id,
    ptv.version_number,
    ROUND(
        SUM(
            (t.input_tokens - t.cached_input_tokens) * p.input_rate
            + t.cached_input_tokens * p.cached_input_rate
            + t.output_tokens * p.output_rate
        ),
        6
    ) AS session_cost
FROM filtered_sessions s
JOIN Turn t
    ON t.session_id = s.session_id
JOIN PromptTemplateVersion ptv
    ON ptv.template_version_id = t.prompt_template_version_id
JOIN ModelPricingPeriod p
    ON p.model_id = t.model_id
   AND t.created_at >= p.valid_from
   AND (p.valid_to IS NULL OR t.created_at < p.valid_to)
GROUP BY
    s.session_id,
    ptv.template_version_id,
    ptv.version_number
HAVING session_cost > 0.05
ORDER BY
    session_cost DESC,
    s.session_id,
    ptv.version_number;
```

The two SQL statements preserve the same date range, join conditions, cost calculation, grouping, `HAVING` condition, and ordering. The rewritten version makes the early filtering of sessions explicit through a common table expression named `filtered_sessions`.

**Execution-plan evidence and interpretation**

The captured SQLite execution plan for F7 after index creation includes the following operations:

```text
SEARCH s USING COVERING INDEX idx_session_started_session
    (started_at>? AND started_at<?)
SEARCH t USING INDEX sqlite_autoindex_Turn_1 (session_id=?)
SEARCH ptv USING INTEGER PRIMARY KEY (rowid=?)
SEARCH p USING INDEX sqlite_autoindex_ModelPricingPeriod_1
    (model_id=? AND valid_from<?)
USE TEMP B-TREE FOR GROUP BY
USE TEMP B-TREE FOR ORDER BY
```

The `SEARCH s` operation shows that SQLite uses the composite index `idx_session_started_session` to restrict sessions to the requested date range rather than scanning the entire `Session` table. The subsequent operations access matching turns, prompt-template versions, and pricing periods. SQLite also uses temporary B-trees for grouping and ordering.

This plan provides evidence that the optimizer uses an indexed date-range search on `Session`, consistent with applying the selective condition early. However, this plan alone does not prove that the explicit CTE rewrite improves runtime over the original query, because SQLite may already perform the equivalent optimisation for the original SQL.

The measured runtime of the original F7 query after index creation was approximately **0.548 seconds** in the recorded run. A directly comparable runtime measurement for both SQL versions has not been established, so no numerical speedup is claimed. A fair comparison would execute both statements on the same database under the same conditions and compare their `EXPLAIN QUERY PLAN` outputs and wall-clock runtimes.

**Conclusion:** Predicate pushdown can reduce intermediate results by filtering rows before joins. For F7, the captured execution plan confirms an indexed date-range search on `Session`; a separate, controlled comparison is still required to establish whether writing the filter explicitly as a CTE yields any additional performance benefit.

## Task 5: Concurrency, Schedules, and Isolation

### 5.1 Precedence-Graph Analysis of A1 Deliverable G.3 (T2)

In A1 Deliverable G.3, T2, Connection 1 begins a transaction and inserts a new moderation decision for video 1 with state `live`. It then queries the current state of the video. Before Connection 1 commits, Connection 2 queries the same video and sees the previously committed `pending` state. Connection 1 subsequently rolls back, so the inserted decision does not become part of the committed history.

The relevant operations are:

| Order | Connection | Operation |
|---|---|---|
| 1 | C1 | Begin transaction |
| 2 | C1 | Insert an uncommitted `live` moderation decision for video 1 |
| 3 | C1 | Read the current state of video 1 and observe `live` |
| 4 | C2 | Read the current state of video 1 and observe the committed `pending` state |
| 5 | C1 | Roll back the transaction |

The insert by C1 and the read by C2 concern the same logical video state, but the read in C2 does not observe the uncommitted insert. Under the demonstrated interleaving, there is no conflicting read or write pair between two committed transactions that establishes a precedence edge: C1 rolls back, and C2 only reads the previously committed state.

Therefore, this experiment demonstrates **read isolation for an uncommitted change**, not a non-conflict-serializable committed schedule. A precedence graph for this particular experiment has no edge between committed transactions, and it is trivially acyclic. It is not meaningful to claim a non-serializable anomaly from this T2 result.

### 5.2 Proposed Non-Conflict-Serializable Schedule

I use the `ModerationDecision` history table and videos 1 and 2 to illustrate a write-skew scenario. For this demonstration, assume the application invariant is that at least one of these two videos must remain in the `live` state.

Let \(T_1\) and \(T_2\) each read the latest moderation state of both videos. Transaction \(T_1\) then decides to update video 1, while \(T_2\) decides to update video 2.

The abstract schedule is:

| Order | Transaction | Operation |
|---|---|---|
| 1 | \(T_1\) | Read state of video 1 |
| 2 | \(T_2\) | Read state of video 1 |
| 3 | \(T_1\) | Read state of video 2 |
| 4 | \(T_2\) | Read state of video 2 |
| 5 | \(T_1\) | Write a new moderation decision for video 1 |
| 6 | \(T_2\) | Write a new moderation decision for video 2 |

The conflicting reads and writes produce two edges:

- \(T_2 \rightarrow T_1\): \(T_2\)'s read of video 1 precedes \(T_1\)'s write to video 1.
- \(T_1 \rightarrow T_2\): \(T_1\)'s read of video 2 precedes \(T_2\)'s write to video 2.

The precedence graph therefore contains the cycle

\[
T_1 \rightarrow T_2 \rightarrow T_1
\]

The abstract schedule is not conflict-serializable. If both transactions independently conclude that the other video will remain live and then demote their respective videos, the invariant could be violated. This is a write-skew scenario.

However, this is an abstract schedule, not an observed successful execution. SQLite permits only one writer at a time, and in WAL mode a transaction attempting to write from an outdated read snapshot may fail with `SQLITE_BUSY_SNAPSHOT`. The anomaly must not be reported as a committed SQLite outcome unless the experiment actually demonstrates it.

### 5.3 Prevention Using `BEGIN IMMEDIATE`

SQLite's `BEGIN IMMEDIATE` obtains a writer reservation before the transaction reads and validates the invariant. The transaction can then inspect both videos and make its decision while preventing another writer from independently completing the same read-then-write sequence.

A controlled demonstration should use two separate database connections:

1. Connection 1 executes `BEGIN IMMEDIATE` and reads the latest states of videos 1 and 2.
2. Connection 2 attempts `BEGIN IMMEDIATE` while Connection 1 holds the writer reservation.
3. Record whether Connection 2 waits or returns `SQLITE_BUSY`, according to the configured busy timeout.
4. Connection 1 validates the invariant and commits or rolls back.
5. Retry Connection 2 if necessary and verify the resulting states.

The two-connection locking test was executed against a disposable database copy. Connection 1 acquired the writer reservation using `BEGIN IMMEDIATE`; Connection 2 then attempted the same operation and received `OperationalError: database is locked` with a one-second timeout. Connection 1 rolled back successfully. This demonstrates writer serialization in the tested scenario, although it does not demonstrate a committed write-skew anomaly or verify every possible interleaving.

**Cost of the fix:** `BEGIN IMMEDIATE` serializes competing writers, so a transaction may have to wait for another writer to finish. Under contention, a connection may also receive `SQLITE_BUSY` and need to retry its transaction.

### 5.4 Observed `BEGIN IMMEDIATE` Locking Result

The concurrency test was executed against a disposable copy of the scaled database, `concurrency_test.db`, using two independent Python SQLite connections with a one-second timeout.

Connection 1 executed `BEGIN IMMEDIATE` and successfully acquired the writer reservation. While Connection 1 held that reservation, Connection 2 attempted `BEGIN IMMEDIATE` and returned `OperationalError: database is locked`. Connection 1 then rolled back successfully.

This observed result confirms that SQLite prevented the second connection from acquiring the writer reservation during the test. It demonstrates writer serialization, rather than a committed write-skew anomaly. The experiment therefore supports the locking-prevention discussion, but it does not establish that both transactions committed an inconsistent state under the proposed schedule.
