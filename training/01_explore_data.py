"""
Step 1: Explore the Kilter database
====================================
Run this first to understand what we're working with.
It prints stats about climbs, placements, and quality distributions
so you can see the raw data before we tokenize anything.

Usage:
    cd /Users/maxwellwainwright/Documents/DoomClimb/training
    python 01_explore_data.py
"""

import sqlite3
import os
from collections import Counter

# ── Connect to the database ──────────────────────────────────────────────────
DB_PATH = os.path.join(os.path.dirname(__file__), "..", "kilter.db")
assert os.path.exists(DB_PATH), f"kilter.db not found at {DB_PATH}"

conn = sqlite3.connect(DB_PATH)
conn.row_factory = sqlite3.Row
cur = conn.cursor()

# ── 1. How many climbs total? ────────────────────────────────────────────────
print("=" * 60)
print("KILTER DATABASE EXPLORATION")
print("=" * 60)

cur.execute("SELECT COUNT(*) FROM climbs")
total_climbs = cur.fetchone()[0]
print(f"\nTotal climbs in database: {total_climbs:,}")

cur.execute("SELECT COUNT(*) FROM climbs WHERE frames_count = 1 AND is_listed = 1")
single_frame_listed = cur.fetchone()[0]
print(f"Single-frame, listed climbs: {single_frame_listed:,}")

# ── 2. Climb stats overview ─────────────────────────────────────────────────
cur.execute("""
    SELECT COUNT(*) as cnt,
           AVG(ascensionist_count) as avg_ascents,
           AVG(quality_average) as avg_quality,
           AVG(difficulty_average) as avg_diff
    FROM climb_stats
""")
row = cur.fetchone()
print(f"\nClimb stats rows: {row['cnt']:,}")
print(f"  Avg ascensionist count: {row['avg_ascents']:.1f}")
print(f"  Avg quality rating:     {row['avg_quality']:.2f}")
print(f"  Avg difficulty:         {row['avg_diff']:.1f}")

# ── 3. Quality distribution (so you can pick a good cutoff) ──────────────────
print("\n── Quality Distribution ──")
cur.execute("""
    SELECT ROUND(quality_average, 0) as q_bucket, COUNT(*) as cnt
    FROM climb_stats
    WHERE ascensionist_count >= 5
    GROUP BY q_bucket
    ORDER BY q_bucket
""")
for row in cur.fetchall():
    print(f"  Quality ~{int(row['q_bucket'])}: {row['cnt']:,} climbs")

# ── 4. Difficulty distribution (maps to V-grades) ───────────────────────────
print("\n── Difficulty Distribution (climbs with 5+ ascents) ──")
grade_map = {
    10: "V0", 11: "V0", 12: "V0",
    13: "V1", 14: "V1",
    15: "V2",
    16: "V3", 17: "V3",
    18: "V4", 19: "V4",
    20: "V5", 21: "V5",
    22: "V6",
    23: "V7",
    24: "V8", 25: "V8",
    26: "V9",
    27: "V10",
    28: "V11",
    29: "V12",
    30: "V13",
    31: "V14",
    32: "V15",
    33: "V16",
}
cur.execute("""
    SELECT ROUND(difficulty_average) as diff, COUNT(*) as cnt
    FROM climb_stats
    WHERE ascensionist_count >= 5
    GROUP BY diff
    ORDER BY diff
""")
for row in cur.fetchall():
    d = int(row['diff'])
    grade = grade_map.get(d, f"?({d})")
    bar = "█" * (row['cnt'] // 500)
    print(f"  Diff {d:2d} ({grade:>4s}): {row['cnt']:>6,}  {bar}")

# ── 5. Angle distribution ───────────────────────────────────────────────────
print("\n── Angle Distribution (climbs with 5+ ascents) ──")
cur.execute("""
    SELECT angle, COUNT(*) as cnt
    FROM climb_stats
    WHERE ascensionist_count >= 5
    GROUP BY angle
    ORDER BY angle
""")
for row in cur.fetchall():
    bar = "█" * (row['cnt'] // 500)
    print(f"  {row['angle']:2d}°: {row['cnt']:>6,}  {bar}")

# ── 6. Sample frames (so you can see the raw format) ────────────────────────
print("\n── Sample Climb Frames ──")
cur.execute("""
    SELECT c.name, c.frames, cs.difficulty_average, cs.quality_average,
           cs.ascensionist_count, cs.angle
    FROM climbs c
    JOIN climb_stats cs ON cs.climb_uuid = c.uuid
    WHERE cs.ascensionist_count >= 100
      AND cs.quality_average >= 3.0
      AND c.frames_count = 1
      AND c.layout_id = 1
    ORDER BY cs.ascensionist_count DESC
    LIMIT 5
""")
for row in cur.fetchall():
    print(f"\n  \"{row['name']}\"")
    print(f"  Difficulty: {row['difficulty_average']:.1f}  Quality: {row['quality_average']:.1f}  "
          f"Ascents: {row['ascensionist_count']}  Angle: {row['angle']}°")
    print(f"  Frames: {row['frames'][:80]}...")

# ── 7. How many holds per climb? ────────────────────────────────────────────
print("\n── Holds-Per-Climb Distribution (top 1000 popular climbs) ──")
cur.execute("""
    SELECT c.frames
    FROM climbs c
    JOIN climb_stats cs ON cs.climb_uuid = c.uuid
    WHERE cs.ascensionist_count >= 50
      AND c.frames_count = 1
      AND c.layout_id = 1
    ORDER BY cs.ascensionist_count DESC
    LIMIT 1000
""")
hold_counts = Counter()
for row in cur.fetchall():
    frames = row['frames']
    parts = [p for p in frames.split("p") if p]
    hold_counts[len(parts)] += 1

for count in sorted(hold_counts.keys()):
    bar = "█" * (hold_counts[count] // 5)
    print(f"  {count:2d} holds: {hold_counts[count]:>4}  {bar}")

# ── 8. Unique placement IDs actually used ────────────────────────────────────
print("\n── Placement ID Coverage ──")
cur.execute("""
    SELECT c.frames
    FROM climbs c
    JOIN climb_stats cs ON cs.climb_uuid = c.uuid
    WHERE cs.ascensionist_count >= 5
      AND c.frames_count = 1
      AND c.layout_id = 1
    LIMIT 10000
""")
all_pids = set()
for row in cur.fetchall():
    for part in row['frames'].split("p"):
        if not part:
            continue
        tokens = part.split("r")
        if len(tokens) == 2 and tokens[0].isdigit():
            all_pids.add(int(tokens[0]))

print(f"  Unique placement IDs in sampled climbs: {len(all_pids)}")
print(f"  ID range: {min(all_pids)} – {max(all_pids)}")

conn.close()
print("\n✅ Done! Review the output above to understand the data shape.")
print("   Next step: run 02_build_dataset.py to tokenize climbs for training.")
