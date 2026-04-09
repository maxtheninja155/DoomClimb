"""
Step 2: Build the training dataset
====================================
Extracts climbs from kilter.db, filters for quality, tokenizes them
into sequences, and saves everything as .pt files for PyTorch training.

What this script does:
  1. Pulls climbs that are single-frame, listed, layout_id=1, with decent stats
  2. Parses the frames string into (placement_id, role_id) pairs
  3. Filters out edge holds (the bogus x=0/x=1 set-20 positions)
  4. Sorts holds bottom-to-top (by y-position descending → ascending on the wall)
  5. Builds a vocabulary:  [PAD, BOS, EOS, SEP] + grade tokens + angle tokens + hold tokens
  6. Encodes each climb as: [BOS, GRADE, ANGLE, hold1, role1, hold2, role2, ..., EOS]
  7. Saves train/val splits as .pt files

Usage:
    cd /Users/maxwellwainwright/Documents/DoomClimb/training
    python 02_build_dataset.py

Output:
    data/vocab.json          — token ↔ ID mapping
    data/train_sequences.pt  — tokenized training sequences
    data/val_sequences.pt    — tokenized validation sequences
    data/dataset_stats.json  — stats about the dataset
"""

import sqlite3
import json
import os
import random
from collections import Counter

# ── Configuration ────────────────────────────────────────────────────────────
# Tweak these to control data quality vs quantity tradeoff

MIN_ASCENTS    = 5      # Minimum ascensionist count (filters out untested climbs)
MIN_QUALITY    = 1.5    # Minimum quality rating (filters out bad climbs)
MIN_HOLDS      = 4      # Minimum holds in a climb (too few = boring)
MAX_HOLDS      = 30     # Maximum holds in a climb (too many = probably data errors)
VAL_FRACTION   = 0.1    # 10% of data for validation
RANDOM_SEED    = 42

# These are the "set 20" edge holds with bogus x=0 or x=1 positions.
# We skip any placement ID whose blob-detected position is at the image border.
# (Same logic as the app's KilterDatabaseService filter)
EDGE_THRESHOLD = 0.01

# ── Paths ────────────────────────────────────────────────────────────────────
DB_PATH   = os.path.join(os.path.dirname(__file__), "..", "kilter.db")
DATA_DIR  = os.path.join(os.path.dirname(__file__), "data")
os.makedirs(DATA_DIR, exist_ok=True)

# ── Load HoldSocketMap positions from the Swift source ───────────────────────
# We need these to (a) filter edge holds and (b) sort holds spatially

def load_socket_positions():
    """Parse HoldSocketMap.swift to extract placement_id → (x, y) mapping."""
    swift_path = os.path.join(os.path.dirname(__file__), "..",
                              "DoomClimb", "DoomClimb", "HoldSocketMap.swift")
    import re
    pattern = re.compile(r'^\s*(\d+)\s*:\s*SIMD2<Float>\(\s*([\d.]+)\s*,\s*([\d.]+)\s*\)')
    positions = {}
    with open(swift_path) as f:
        for line in f:
            m = pattern.match(line)
            if m:
                pid = int(m.group(1))
                x, y = float(m.group(2)), float(m.group(3))
                positions[pid] = (x, y)
    return positions

SOCKET_POS = load_socket_positions()
print(f"Loaded {len(SOCKET_POS)} socket positions from HoldSocketMap.swift")

# Which placement IDs are valid (not on the edge)?
VALID_PLACEMENTS = {
    pid for pid, (x, y) in SOCKET_POS.items()
    if x > EDGE_THRESHOLD and x < (1 - EDGE_THRESHOLD)
    and y > EDGE_THRESHOLD and y < (1 - EDGE_THRESHOLD)
}
print(f"Valid (non-edge) placements: {len(VALID_PLACEMENTS)}")

# ── Extract climbs from the database ─────────────────────────────────────────

def extract_climbs():
    """Pull quality climbs from kilter.db and parse their frames."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    # Each climb can appear multiple times in climb_stats (once per angle).
    # We want each (climb, angle) pair as a separate training example since
    # the same climb at different angles is effectively a different problem.
    cur.execute("""
        SELECT c.uuid, c.name, c.frames,
               cs.angle, cs.difficulty_average, cs.quality_average,
               cs.ascensionist_count
        FROM   climbs c
        JOIN   climb_stats cs ON cs.climb_uuid = c.uuid
        WHERE  c.frames_count  = 1
          AND  c.is_listed     = 1
          AND  c.layout_id     = 1
          AND  cs.ascensionist_count >= ?
          AND  cs.quality_average    >= ?
        ORDER BY cs.ascensionist_count DESC
    """, (MIN_ASCENTS, MIN_QUALITY))

    climbs = []
    skipped_edge = 0
    skipped_size = 0

    for row in cur.fetchall():
        # Parse frames: "p1145r12p1146r12p1149r13..." → [(1145, 12), (1146, 12), ...]
        holds = []
        for part in row['frames'].split("p"):
            if not part:
                continue
            tokens = part.split("r")
            if len(tokens) != 2:
                continue
            try:
                pid, rid = int(tokens[0]), int(tokens[1])
            except ValueError:
                continue

            # Skip edge holds
            if pid not in VALID_PLACEMENTS:
                skipped_edge += 1
                continue

            holds.append((pid, rid))

        # Filter by hold count
        if len(holds) < MIN_HOLDS or len(holds) > MAX_HOLDS:
            skipped_size += 1
            continue

        # Sort holds by y-position descending (bottom of wall = high y → top)
        # This gives us a natural bottom-to-top ordering for the sequence
        holds.sort(key=lambda h: -SOCKET_POS[h[0]][1])

        # Map difficulty_average to V-grade
        diff = row['difficulty_average']
        v_grade = difficulty_to_vgrade(diff)

        climbs.append({
            'uuid':    row['uuid'],
            'name':    row['name'],
            'holds':   holds,          # [(placement_id, role_id), ...]
            'grade':   v_grade,        # 0–16
            'angle':   row['angle'],   # 0, 5, 10, ..., 70
            'quality': row['quality_average'],
            'ascents': row['ascensionist_count'],
        })

    conn.close()

    print(f"\nExtracted {len(climbs):,} climb examples")
    print(f"  Skipped {skipped_edge:,} individual edge holds")
    print(f"  Skipped {skipped_size:,} climbs (too few / too many holds)")
    return climbs


def difficulty_to_vgrade(diff):
    """Convert Kilter difficulty_average to V-grade (0–16)."""
    if diff < 13:  return 0
    if diff < 15:  return 1
    if diff < 16:  return 2
    if diff < 18:  return 3
    if diff < 20:  return 4
    if diff < 22:  return 5
    if diff < 23:  return 6
    if diff < 24:  return 7
    if diff < 26:  return 8
    if diff < 27:  return 9
    if diff < 28:  return 10
    if diff < 29:  return 11
    if diff < 30:  return 12
    if diff < 31:  return 13
    if diff < 32:  return 14
    if diff < 33:  return 15
    return 16


# ── Build vocabulary ─────────────────────────────────────────────────────────

def build_vocab(climbs):
    """
    Build the token vocabulary.

    Token layout:
      0: PAD     — padding for batching
      1: BOS     — beginning of sequence
      2: EOS     — end of sequence
      3: SEP     — separator between (hold, role) pairs (optional, for clarity)
      4–20:      — GRADE_V0 through GRADE_V16 (17 tokens)
      21–35:     — ANGLE_0 through ANGLE_70 (15 tokens, step 5)
      36–39:     — ROLE_12 (start), ROLE_13 (middle), ROLE_14 (finish), ROLE_15 (foot)
      40+:       — One token per unique placement ID
    """
    # Collect all placement IDs actually used in our filtered dataset
    all_pids = set()
    for climb in climbs:
        for pid, rid in climb['holds']:
            all_pids.add(pid)

    all_pids = sorted(all_pids)
    print(f"\nUnique placement IDs in dataset: {len(all_pids)}")

    vocab = {
        'PAD': 0,
        'BOS': 1,
        'EOS': 2,
        'SEP': 3,
    }

    # Grade tokens (V0–V16)
    for g in range(17):
        vocab[f'GRADE_{g}'] = 4 + g

    # Angle tokens (0°–70° in steps of 5)
    valid_angles = list(range(0, 75, 5))  # [0, 5, 10, ..., 70]
    for i, angle in enumerate(valid_angles):
        vocab[f'ANGLE_{angle}'] = 21 + i

    # Role tokens
    role_ids = [12, 13, 14, 15]
    for i, rid in enumerate(role_ids):
        vocab[f'ROLE_{rid}'] = 36 + i

    # Hold (placement) tokens
    hold_offset = 40
    pid_to_token = {}
    for i, pid in enumerate(all_pids):
        token_name = f'HOLD_{pid}'
        token_id = hold_offset + i
        vocab[token_name] = token_id
        pid_to_token[pid] = token_id

    print(f"Vocabulary size: {len(vocab)}")
    print(f"  Special tokens: 4")
    print(f"  Grade tokens:   17  (V0–V16)")
    print(f"  Angle tokens:   {len(valid_angles)}  (0°–70°)")
    print(f"  Role tokens:    4   (start, middle, finish, foot)")
    print(f"  Hold tokens:    {len(all_pids)}")

    return vocab, pid_to_token


# ── Tokenize climbs ──────────────────────────────────────────────────────────

def tokenize_climb(climb, vocab, pid_to_token):
    """
    Convert a single climb into a token sequence.

    Format: [BOS, GRADE_X, ANGLE_Y, HOLD_1, ROLE_1, HOLD_2, ROLE_2, ..., EOS]

    The model learns: given a grade + angle, generate holds in order from
    bottom of the wall to top (start holds → middle holds → finish hold).
    """
    tokens = [vocab['BOS']]

    # Condition tokens
    grade_token = vocab.get(f"GRADE_{climb['grade']}")
    angle_token = vocab.get(f"ANGLE_{climb['angle']}")

    if grade_token is None or angle_token is None:
        return None  # Skip climbs with unexpected grade/angle

    tokens.append(grade_token)
    tokens.append(angle_token)

    # Hold + role pairs (already sorted bottom-to-top)
    for pid, rid in climb['holds']:
        hold_token = pid_to_token.get(pid)
        role_token = vocab.get(f"ROLE_{rid}")
        if hold_token is None or role_token is None:
            continue
        tokens.append(hold_token)
        tokens.append(role_token)

    tokens.append(vocab['EOS'])
    return tokens


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    random.seed(RANDOM_SEED)

    # Step 1: Extract
    climbs = extract_climbs()

    # Step 2: Build vocab
    vocab, pid_to_token = build_vocab(climbs)

    # Step 3: Tokenize
    print("\nTokenizing climbs...")
    sequences = []
    for climb in climbs:
        seq = tokenize_climb(climb, vocab, pid_to_token)
        if seq is not None and len(seq) >= 8:  # At minimum: BOS + grade + angle + 1 hold/role + EOS
            sequences.append(seq)

    print(f"Tokenized {len(sequences):,} sequences")

    # Show sequence length distribution
    lengths = [len(s) for s in sequences]
    print(f"  Sequence lengths: min={min(lengths)}, max={max(lengths)}, "
          f"avg={sum(lengths)/len(lengths):.1f}")

    # Step 4: Train/val split
    random.shuffle(sequences)
    val_size = int(len(sequences) * VAL_FRACTION)
    val_seqs = sequences[:val_size]
    train_seqs = sequences[val_size:]
    print(f"\nSplit: {len(train_seqs):,} train, {len(val_seqs):,} val")

    # Step 5: Save
    # Save vocab as JSON (human-readable, needed for inference later)
    vocab_path = os.path.join(DATA_DIR, "vocab.json")
    with open(vocab_path, "w") as f:
        json.dump(vocab, f, indent=2)
    print(f"Saved vocab → {vocab_path}")

    # Save the reverse mapping (token_id → placement_id) for decoding
    id_to_token_name = {v: k for k, v in vocab.items()}
    reverse_path = os.path.join(DATA_DIR, "id_to_token.json")
    with open(reverse_path, "w") as f:
        json.dump({str(k): v for k, v in id_to_token_name.items()}, f, indent=2)
    print(f"Saved reverse vocab → {reverse_path}")

    # Save sequences as JSON (can also save as .pt if you have torch installed)
    train_path = os.path.join(DATA_DIR, "train_sequences.json")
    val_path = os.path.join(DATA_DIR, "val_sequences.json")

    with open(train_path, "w") as f:
        json.dump(train_seqs, f)
    with open(val_path, "w") as f:
        json.dump(val_seqs, f)
    print(f"Saved train sequences → {train_path}")
    print(f"Saved val sequences   → {val_path}")

    # Save some stats
    stats = {
        "total_climbs_extracted": len(climbs),
        "total_sequences": len(sequences),
        "train_size": len(train_seqs),
        "val_size": len(val_seqs),
        "vocab_size": len(vocab),
        "unique_holds": len([k for k in vocab if k.startswith("HOLD_")]),
        "min_seq_length": min(lengths),
        "max_seq_length": max(lengths),
        "avg_seq_length": round(sum(lengths) / len(lengths), 1),
        "config": {
            "min_ascents": MIN_ASCENTS,
            "min_quality": MIN_QUALITY,
            "min_holds": MIN_HOLDS,
            "max_holds": MAX_HOLDS,
        },
    }
    stats_path = os.path.join(DATA_DIR, "dataset_stats.json")
    with open(stats_path, "w") as f:
        json.dump(stats, f, indent=2)
    print(f"Saved stats → {stats_path}")

    # Step 6: Print a few sample sequences (decoded) for sanity checking
    print("\n── Sample Tokenized Sequences (decoded) ──")
    for i in range(min(3, len(train_seqs))):
        seq = train_seqs[i]
        decoded = [id_to_token_name[t] for t in seq]
        print(f"\n  Example {i+1} ({len(seq)} tokens):")
        print(f"  {' → '.join(decoded[:8])}...")
        # Show what the climb looks like
        grade_tok = decoded[1]  # GRADE_X
        angle_tok = decoded[2]  # ANGLE_Y
        holds = [(decoded[j], decoded[j+1]) for j in range(3, len(decoded)-1, 2)]
        print(f"  Grade: {grade_tok}, Angle: {angle_tok}")
        print(f"  Holds: {len(holds)} placements")
        for h, r in holds[:5]:
            pid = h.replace("HOLD_", "")
            pos = SOCKET_POS.get(int(pid), (0, 0))
            print(f"    {h} ({r}) at position ({pos[0]:.3f}, {pos[1]:.3f})")
        if len(holds) > 5:
            print(f"    ... and {len(holds) - 5} more")

    print("\n✅ Dataset built! Next step: run 03_train_model.py")


if __name__ == "__main__":
    main()
