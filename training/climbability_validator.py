"""
Climbability Validator for Kilter Board Climbs
================================================
Determines whether a Kilter Board climb is physically possible by checking
that hand holds form a connected path from start to finish within human
reach distance.

Approach (graph reachability):
  1. Collect all "hand holds" (start + middle + finish roles)
  2. Build a graph where two holds are connected if within max_reach distance
  3. BFS from start holds — if any finish hold is reachable, the climb is climbable

The max_reach threshold is calibrated from real Kilter Board climbs:
  - For each real climb, compute the Minimum Spanning Tree of hand holds
  - The longest MST edge = the "critical reach" (minimum reach to connect all holds)
  - We use the 95th percentile of critical reaches across all real climbs

Coordinate system (from HoldSocketMap.swift):
  - x: 0..1, left to right
  - y: 0..1, origin TOP-LEFT (y=0 is top of board, y=1 is bottom)
  - Start holds are at the BOTTOM of the wall (high y)
  - Finish holds are at the TOP of the wall (low y)

Usage:
    # Run calibration + validation test on training data:
    cd /Users/maxwellwainwright/Documents/DoomClimb/training
    python climbability_validator.py

    # Import in other scripts:
    from climbability_validator import validate_climbability, calibrate_reach
"""

import math
import os
import re
import json
from collections import deque, Counter


# ── Role constants (must match training vocab / kilter.db) ──────────────────

ROLE_START  = 12
ROLE_MIDDLE = 13
ROLE_FINISH = 14
ROLE_FOOT   = 15
HAND_ROLES  = {ROLE_START, ROLE_MIDDLE, ROLE_FINISH}


# ── Core functions ──────────────────────────────────────────────────────────

def euclidean_distance(pos1, pos2):
    """Euclidean distance between two (x, y) positions in normalized coords."""
    dx = pos1[0] - pos2[0]
    dy = pos1[1] - pos2[1]
    return math.sqrt(dx * dx + dy * dy)


def validate_climbability(holds, socket_positions, max_reach):
    """
    Check if a climb is physically climbable using graph reachability.

    Parameters:
        holds:            list of (placement_id, role_id) tuples
        socket_positions: dict mapping placement_id -> (x, y)
        max_reach:        max normalized distance between reachable hand holds

    Returns:
        (is_climbable: bool, issues: list[str])
    """
    issues = []

    # ── Separate holds by role ──────────────────────────────────────────
    hand_holds = []       # list of (pid, (x, y)) for start + middle + finish
    start_indices = []    # indices into hand_holds
    finish_indices = []

    for pid, rid in holds:
        pos = socket_positions.get(pid)
        if pos is None:
            continue

        if rid in HAND_ROLES:
            idx = len(hand_holds)
            hand_holds.append((pid, pos))
            if rid == ROLE_START:
                start_indices.append(idx)
            elif rid == ROLE_FINISH:
                finish_indices.append(idx)

    # ── Structural checks ───────────────────────────────────────────────
    if not start_indices:
        issues.append("no_start_hold")
        return False, issues

    if not finish_indices:
        issues.append("no_finish_hold")
        return False, issues

    if len(hand_holds) < 3:
        issues.append("too_few_hand_holds")
        return False, issues

    # Finish should be ABOVE start on the wall (lower y = higher on wall)
    avg_start_y = sum(hand_holds[i][1][1] for i in start_indices) / len(start_indices)
    avg_finish_y = sum(hand_holds[i][1][1] for i in finish_indices) / len(finish_indices)
    if avg_finish_y > avg_start_y + 0.02:
        issues.append("finish_below_start")

    # ── Graph reachability ──────────────────────────────────────────────
    n = len(hand_holds)
    adj = [[] for _ in range(n)]
    for i in range(n):
        for j in range(i + 1, n):
            d = euclidean_distance(hand_holds[i][1], hand_holds[j][1])
            if d <= max_reach:
                adj[i].append(j)
                adj[j].append(i)

    # BFS from all start holds
    visited = set(start_indices)
    queue = deque(start_indices)
    finish_set = set(finish_indices)

    while queue:
        node = queue.popleft()
        if node in finish_set:
            # Reachable — but may still have structural issues
            if issues:
                return False, issues
            return True, []
        for neighbor in adj[node]:
            if neighbor not in visited:
                visited.add(neighbor)
                queue.append(neighbor)

    issues.append("unreachable_finish")
    return False, issues


# ── Calibration helpers ─────────────────────────────────────────────────────

def _mst_max_edge(positions):
    """
    Longest edge in the Minimum Spanning Tree (Prim's algorithm).

    This is the "critical reach" — the minimum max_reach needed to connect
    all points. Conservative: actual climbability only needs start→finish
    connectivity, not all-pairs connectivity, but this works well for
    calibration since real climbs should have ALL holds reachable.

    positions: list of (x, y) tuples
    Returns:   float (longest edge distance), or 0.0 if < 2 points
    """
    n = len(positions)
    if n < 2:
        return 0.0

    in_mst = [False] * n
    min_edge = [float('inf')] * n
    min_edge[0] = 0.0
    max_edge = 0.0

    for _ in range(n):
        # Pick cheapest vertex not yet in MST
        u = -1
        for v in range(n):
            if not in_mst[v] and (u == -1 or min_edge[v] < min_edge[u]):
                u = v

        in_mst[u] = True
        if min_edge[u] > max_edge and min_edge[u] < float('inf'):
            max_edge = min_edge[u]

        # Update costs for remaining vertices
        for v in range(n):
            if not in_mst[v]:
                d = euclidean_distance(positions[u], positions[v])
                if d < min_edge[v]:
                    min_edge[v] = d

    return max_edge


def calibrate_reach(climbs, socket_positions, percentile=95):
    """
    Calibrate max_reach from real climb data.

    For each climb, finds the critical reach (longest MST edge of hand holds).
    Returns the given percentile of critical reaches.

    Parameters:
        climbs:           list of [(placement_id, role_id), ...] per climb
        socket_positions: dict mapping placement_id -> (x, y)
        percentile:       which percentile to use (default 95)

    Returns:
        (reach_value: float, all_reaches_sorted: list[float])
    """
    critical_reaches = []

    for holds in climbs:
        hand_positions = []
        for pid, rid in holds:
            if rid in HAND_ROLES:
                pos = socket_positions.get(pid)
                if pos:
                    hand_positions.append(pos)

        if len(hand_positions) < 2:
            continue

        cr = _mst_max_edge(hand_positions)
        critical_reaches.append(cr)

    if not critical_reaches:
        return 0.20, []  # fallback

    critical_reaches.sort()
    idx = min(int(len(critical_reaches) * percentile / 100),
              len(critical_reaches) - 1)

    return critical_reaches[idx], critical_reaches


# ── Data loading helpers ────────────────────────────────────────────────────

def load_socket_positions():
    """Parse HoldSocketMap.swift to extract placement_id → (x, y)."""
    swift_path = os.path.join(os.path.dirname(__file__), "..",
                              "DoomClimb", "DoomClimb", "HoldSocketMap.swift")

    # Match: 1073: Socket(placementId: 1073, setId: 1, x: 0.941083, y: 0.931238),
    pattern = re.compile(
        r'Socket\(placementId:\s*(\d+),\s*setId:\s*\d+,\s*x:\s*([\d.]+),\s*y:\s*([\d.]+)\s*\)')

    positions = {}
    with open(swift_path) as f:
        for line in f:
            m = pattern.search(line)
            if m:
                pid = int(m.group(1))
                x, y = float(m.group(2)), float(m.group(3))
                positions[pid] = (x, y)
    return positions


def load_training_climbs():
    """
    Load climbs from the pre-built training data (no kilter.db needed).
    Returns list of [(placement_id, role_id), ...] for each climb.
    """
    data_dir = os.path.join(os.path.dirname(__file__), "data")

    with open(os.path.join(data_dir, "id_to_token.json")) as f:
        id_to_token = {int(k): v for k, v in json.load(f).items()}

    with open(os.path.join(data_dir, "train_sequences.json")) as f:
        train_seqs = json.load(f)
    with open(os.path.join(data_dir, "val_sequences.json")) as f:
        val_seqs = json.load(f)

    all_seqs = train_seqs + val_seqs
    climbs = []

    for seq in all_seqs:
        holds = []
        i = 3  # skip BOS, GRADE, ANGLE
        while i < len(seq) - 1:  # stop before EOS
            hold_name = id_to_token.get(seq[i], "")
            role_name = id_to_token.get(seq[i + 1], "") if i + 1 < len(seq) else ""

            if hold_name.startswith("HOLD_") and role_name.startswith("ROLE_"):
                pid = int(hold_name.split("_")[1])
                rid = int(role_name.split("_")[1])
                holds.append((pid, rid))
                i += 2
            else:
                i += 1

        if holds:
            climbs.append(holds)

    return climbs


# ══════════════════════════════════════════════════════════════════════════════
# MAIN — run calibration + validation test
# ══════════════════════════════════════════════════════════════════════════════

def main():
    print("=" * 60)
    print("CLIMBABILITY VALIDATOR — CALIBRATION & TEST")
    print("=" * 60)

    # ── 1. Load data ────────────────────────────────────────────────────
    print("\nLoading data...")
    socket_pos = load_socket_positions()
    print(f"  Socket positions: {len(socket_pos)}")

    climbs = load_training_climbs()
    print(f"  Training climbs:  {len(climbs):,}")

    # ── 2. Calibrate reach ──────────────────────────────────────────────
    print("\n── REACH CALIBRATION ──")
    print("Computing critical reach for each climb (MST longest edge)...")

    reach_95, all_reaches = calibrate_reach(climbs, socket_pos, percentile=95)

    if all_reaches:
        # Print percentile distribution
        print(f"\n  Percentile distribution ({len(all_reaches):,} climbs):")
        for pct in [25, 50, 75, 90, 95, 99]:
            idx = min(int(len(all_reaches) * pct / 100), len(all_reaches) - 1)
            print(f"    {pct:3d}th: {all_reaches[idx]:.4f}")
        print(f"     max: {all_reaches[-1]:.4f}")
        print(f"     min: {all_reaches[0]:.4f}")

        # Simple histogram
        print(f"\n  Histogram of critical reaches:")
        buckets = [0] * 10
        bucket_size = 0.03
        for r in all_reaches:
            b = min(int(r / bucket_size), 9)
            buckets[b] += 1
        for i, count in enumerate(buckets):
            lo = i * bucket_size
            hi = (i + 1) * bucket_size
            bar = "█" * (count // max(len(all_reaches) // 200, 1))
            print(f"    {lo:.2f}–{hi:.2f}: {count:>6,}  {bar}")

    max_reach = reach_95
    print(f"\n  ➜ Using 95th percentile: max_reach = {max_reach:.4f}")

    # ── 3. Validate all training climbs ─────────────────────────────────
    print(f"\n── VALIDATION ON TRAINING DATA ──")
    print(f"Running validator on all {len(climbs):,} training climbs...")

    pass_count = 0
    fail_count = 0
    issue_counter = Counter()

    for holds in climbs:
        ok, issues = validate_climbability(holds, socket_pos, max_reach)
        if ok:
            pass_count += 1
        else:
            fail_count += 1
            for issue in issues:
                issue_counter[issue] += 1

    total = pass_count + fail_count
    print(f"\n  ✅ Climbable:     {pass_count:>6,} ({100*pass_count/total:.1f}%)")
    print(f"  ❌ Not climbable: {fail_count:>6,} ({100*fail_count/total:.1f}%)")

    if issue_counter:
        print(f"\n  Failure reasons:")
        for issue, count in issue_counter.most_common():
            print(f"    {issue}: {count:,}")

    # ── 4. Sanity checks ───────────────────────────────────────────────
    print(f"\n── SANITY CHECKS ──")

    # Test 1: A real popular climb should pass
    if climbs:
        ok, issues = validate_climbability(climbs[0], socket_pos, max_reach)
        status = "✅ climbable" if ok else f"❌ {issues}"
        print(f"  Test 1 — Real climb (first in dataset):    {status}")

    # Test 2: Artificially remove holds to create a gap
    if len(climbs) > 10:
        test_climb = list(climbs[10])  # copy
        # Remove all middle holds to create a gap between start and finish
        broken_climb = [(pid, rid) for pid, rid in test_climb if rid != ROLE_MIDDLE]
        ok, issues = validate_climbability(broken_climb, socket_pos, max_reach)
        status = "✅ climbable" if ok else f"❌ {issues}"
        print(f"  Test 2 — Middle holds removed (gap):       {status}")

    # Test 3: Only start holds, no finish
    if climbs:
        no_finish = [(pid, rid) for pid, rid in climbs[0] if rid != ROLE_FINISH]
        ok, issues = validate_climbability(no_finish, socket_pos, max_reach)
        status = "✅ climbable" if ok else f"❌ {issues}"
        print(f"  Test 3 — No finish hold:                   {status}")

    # Test 4: Two holds that are impossibly far apart
    far_apart = [(1089, ROLE_START), (1538, ROLE_FINISH)]  # bottom-left and top-right-ish
    ok, issues = validate_climbability(far_apart, socket_pos, max_reach)
    status = "✅ climbable" if ok else f"❌ {issues}"
    print(f"  Test 4 — Two holds, huge gap:              {status}")

    # ── 5. Save calibrated config ──────────────────────────────────────
    config = {
        "max_reach": round(max_reach, 6),
        "percentile_used": 95,
        "calibrated_from_n_climbs": len(all_reaches),
        "reach_percentiles": {
            str(p): round(all_reaches[min(int(len(all_reaches) * p / 100),
                                          len(all_reaches) - 1)], 6)
            for p in [25, 50, 75, 90, 95, 99]
        } if all_reaches else {}
    }
    config_path = os.path.join(os.path.dirname(__file__), "data", "reach_config.json")
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    print(f"\n  Saved calibrated config → {config_path}")

    print(f"\n{'='*60}")
    print("✅ Done! Review the numbers above.")
    print("   Key question: does the pass rate on training data look right?")
    print("   (95%+ is expected — lower means threshold is too tight)")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
