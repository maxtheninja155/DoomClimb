"""
Step 4: Generate sample climbs and inspect them
=================================================
Loads the trained model and generates climbs at various grades/angles.
Prints them in a human-readable format so you can eyeball quality
before converting to CoreML.

Usage:
    cd /Users/maxwellwainwright/Documents/DoomClimb/training
    python 04_generate_samples.py

    # Try tweaking temperature and top_k to see how it affects variety:
    #   temperature=0.8  → more conservative/safe climbs
    #   temperature=1.2  → more creative/weird climbs
    #   top_k=20         → less variety per position
    #   top_k=100        → more variety per position
"""

import json
import os
import sys

import torch

# Add parent so we can import the model
sys.path.insert(0, os.path.dirname(__file__))
from importlib.machinery import SourceFileLoader
_mod = SourceFileLoader("train_model",
    os.path.join(os.path.dirname(__file__), "03_train_model.py")).load_module()
ClimbGPT = _mod.ClimbGPT

# ── Paths ────────────────────────────────────────────────────────────────────
DATA_DIR = os.path.join(os.path.dirname(__file__), "data")
CKPT_DIR = os.path.join(os.path.dirname(__file__), "checkpoints")

# ── Generation settings ──────────────────────────────────────────────────────
TEMPERATURE = 1.0     # Try 0.7–1.3
TOP_K       = 50      # Try 20–100
NUM_SAMPLES = 5       # How many climbs to generate per grade/angle combo


def load_model():
    """Load the trained model and vocab."""
    with open(os.path.join(DATA_DIR, "vocab.json")) as f:
        vocab = json.load(f)
    with open(os.path.join(DATA_DIR, "id_to_token.json")) as f:
        id_to_token = {int(k): v for k, v in json.load(f).items()}
    with open(os.path.join(CKPT_DIR, "config.json")) as f:
        config = json.load(f)

    model = ClimbGPT(
        vocab_size=config['vocab_size'],
        embed_dim=config['embed_dim'],
        num_heads=config['num_heads'],
        num_layers=config['num_layers'],
        max_seq_len=config['max_seq_len'],
        dropout=0.0,  # No dropout at inference
    )

    # Try best checkpoint first, fall back to final
    ckpt_path = os.path.join(CKPT_DIR, "climb_gpt_best.pt")
    if not os.path.exists(ckpt_path):
        ckpt_path = os.path.join(CKPT_DIR, "climb_gpt_final.pt")

    model.load_state_dict(torch.load(ckpt_path, map_location="cpu", weights_only=True))
    model.eval()
    print(f"Loaded model from {ckpt_path}")
    print(f"  {config['num_params']:,} parameters, trained {config['epochs_trained']} epochs")
    print(f"  Best val loss: {config['best_val_loss']:.4f}")

    return model, vocab, id_to_token


def load_socket_positions():
    """Load hold positions for spatial analysis."""
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
                positions[pid] = (float(m.group(2)), float(m.group(3)))
    return positions


def decode_climb(token_ids, id_to_token, socket_pos):
    """
    Decode a generated token sequence back into a human-readable climb.
    Returns a dict with grade, angle, and list of holds with positions.
    """
    tokens = [id_to_token.get(t, f"UNK_{t}") for t in token_ids]

    grade = None
    angle = None
    holds = []

    i = 0
    while i < len(tokens):
        tok = tokens[i]

        if tok.startswith("GRADE_"):
            grade = int(tok.split("_")[1])
        elif tok.startswith("ANGLE_"):
            angle = int(tok.split("_")[1])
        elif tok.startswith("HOLD_"):
            pid = int(tok.split("_")[1])
            # Next token should be a ROLE
            if i + 1 < len(tokens) and tokens[i + 1].startswith("ROLE_"):
                rid = int(tokens[i + 1].split("_")[1])
                pos = socket_pos.get(pid, (0, 0))
                role_name = {12: "start", 13: "middle", 14: "finish", 15: "foot"}[rid]
                holds.append({
                    'placement_id': pid,
                    'role': role_name,
                    'role_id': rid,
                    'x': pos[0],
                    'y': pos[1],
                })
                i += 1  # Skip the role token
        i += 1

    return {
        'grade': grade,
        'angle': angle,
        'holds': holds,
        'num_tokens': len(token_ids),
    }


def validate_climb(climb):
    """
    Basic quality checks on a generated climb.
    Returns (is_valid, list_of_issues).
    """
    issues = []
    holds = climb['holds']

    if len(holds) < 3:
        issues.append(f"Too few holds ({len(holds)})")

    roles = [h['role'] for h in holds]
    if 'start' not in roles:
        issues.append("No start hold")
    if 'finish' not in roles:
        issues.append("No finish hold")

    # Check for duplicate placements
    pids = [h['placement_id'] for h in holds]
    if len(pids) != len(set(pids)):
        issues.append(f"Duplicate holds ({len(pids)} - {len(set(pids))} dupes)")

    # Check spatial ordering: starts should be near bottom (high y), finish near top (low y)
    starts = [h for h in holds if h['role'] == 'start']
    finishes = [h for h in holds if h['role'] == 'finish']
    if starts and finishes:
        avg_start_y = sum(h['y'] for h in starts) / len(starts)
        avg_finish_y = sum(h['y'] for h in finishes) / len(finishes)
        if avg_finish_y > avg_start_y:
            issues.append(f"Finish below start (finish_y={avg_finish_y:.2f} > start_y={avg_start_y:.2f})")

    is_valid = len(issues) == 0
    return is_valid, issues


def print_climb(climb, idx, issues=None):
    """Pretty-print a generated climb."""
    grade = climb['grade']
    angle = climb['angle']
    holds = climb['holds']

    status = "✅" if not issues else "⚠️"
    print(f"\n  {status} Climb #{idx}: V{grade} at {angle}° — {len(holds)} holds")

    if issues:
        for issue in issues:
            print(f"     ⚠️  {issue}")

    # Group by role
    for role in ['start', 'middle', 'finish', 'foot']:
        role_holds = [h for h in holds if h['role'] == role]
        if role_holds:
            print(f"     {role:>7s}: ", end="")
            parts = [f"#{h['placement_id']} ({h['x']:.2f}, {h['y']:.2f})" for h in role_holds]
            print(", ".join(parts))


def main():
    model, vocab, id_to_token = load_model()
    socket_pos = load_socket_positions()

    # ── Generate climbs at various grades and angles ─────────────────────
    test_combos = [
        (0,  40, "Easy warm-up"),
        (3,  40, "Moderate"),
        (5,  40, "Intermediate"),
        (7,  40, "Advanced"),
        (10, 40, "Expert"),
        (5,  20, "Intermediate at low angle"),
        (5,  60, "Intermediate at steep angle"),
    ]

    total_valid = 0
    total_generated = 0

    for grade, angle, label in test_combos:
        print(f"\n{'='*60}")
        print(f"Generating: {label} (V{grade} at {angle}°)")
        print(f"{'='*60}")

        grade_token = vocab.get(f"GRADE_{grade}")
        angle_token = vocab.get(f"ANGLE_{angle}")

        if grade_token is None or angle_token is None:
            print(f"  ⚠️  Grade or angle token not in vocabulary, skipping")
            continue

        prefix = torch.tensor([[vocab['BOS'], grade_token, angle_token]])

        for i in range(NUM_SAMPLES):
            token_ids = model.generate(
                prefix,
                max_new_tokens=60,
                temperature=TEMPERATURE,
                top_k=TOP_K,
            )

            # Debug: show raw token sequence for first sample of each combo
            if i == 0:
                token_names = [id_to_token.get(t, f"?{t}") for t in token_ids]
                print(f"  [DEBUG] Raw tokens ({len(token_ids)}): {' '.join(token_names[:20])}"
                      + ("..." if len(token_ids) > 20 else ""))

            climb = decode_climb(token_ids, id_to_token, socket_pos)
            is_valid, issues = validate_climb(climb)
            print_climb(climb, i + 1, issues if not is_valid else None)

            total_generated += 1
            if is_valid:
                total_valid += 1

    # ── Summary ──────────────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print(f"SUMMARY")
    print(f"{'='*60}")
    print(f"  Generated: {total_generated} climbs")
    print(f"  Valid:     {total_valid} ({100*total_valid/max(total_generated,1):.0f}%)")
    print(f"  Invalid:   {total_generated - total_valid}")
    print(f"\n  Temperature: {TEMPERATURE}, Top-k: {TOP_K}")
    print(f"\n  Tweak TEMPERATURE and TOP_K at the top of this file to experiment.")
    print(f"  Next step: run 05_export_coreml.py to convert for iOS")


if __name__ == "__main__":
    main()
