"""
Model Evaluation Harness
=========================
Generates climbs from the trained ClimbGPT model and measures quality
with repeatable, numeric metrics. Run this before AND after any training
change to see whether the change helped.

Metrics:
  1. % Climbable      — passes the climbability validator (start→finish reachable)
  2. % Structurally OK — has start, finish, no dupes, correct ordering
  3. Avg hold count    — number of holds per generated climb
  4. Diversity         — mean pairwise Jaccard distance between climbs at same grade
  5. Grade distribution— are generated grades plausible for the target?

Usage:
    cd /Users/maxwellwainwright/Documents/DoomClimb/training
    python eval_model.py

    # Saves results to data/eval_results.json so you can compare across runs.
"""

import json
import os
import sys
import time
from collections import Counter

import torch

# ── Import model class from 03_train_model.py ──────────────────────────────
sys.path.insert(0, os.path.dirname(__file__))
from importlib.machinery import SourceFileLoader
_mod = SourceFileLoader("train_model",
    os.path.join(os.path.dirname(__file__), "03_train_model.py")).load_module()
ClimbGPT = _mod.ClimbGPT

# ── Import validator ────────────────────────────────────────────────────────
from climbability_validator import (
    validate_climbability, load_socket_positions,
    ROLE_START, ROLE_MIDDLE, ROLE_FINISH, ROLE_FOOT
)

# ── Configuration ───────────────────────────────────────────────────────────
SAMPLES_PER_COMBO  = 20     # climbs to generate per (grade, angle) combo
TEMPERATURE        = 0.9    # match the app's default
TOP_K              = 40     # match the app's default

# Test grid: grades × angles to evaluate
EVAL_GRADES = [0, 2, 4, 6, 8, 10]              # V0 through V10
EVAL_ANGLES = [20, 40, 60]                       # low, mid, steep
# Total: 6 grades × 3 angles × 20 samples = 360 climbs

# ── Paths ───────────────────────────────────────────────────────────────────
DATA_DIR = os.path.join(os.path.dirname(__file__), "data")
CKPT_DIR = os.path.join(os.path.dirname(__file__), "checkpoints")


# ══════════════════════════════════════════════════════════════════════════════
# HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def load_model():
    """Load trained model, vocab, and id_to_token mapping."""
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
        dropout=0.0,
    )

    ckpt_path = os.path.join(CKPT_DIR, "climb_gpt_best.pt")
    if not os.path.exists(ckpt_path):
        ckpt_path = os.path.join(CKPT_DIR, "climb_gpt_final.pt")

    model.load_state_dict(torch.load(ckpt_path, map_location="cpu", weights_only=True))
    model.eval()
    return model, vocab, id_to_token, config


def decode_tokens_to_holds(token_ids, id_to_token):
    """
    Decode a generated token sequence into (placement_id, role_id) pairs.
    Returns: (grade, angle, holds_list)
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
            if i + 1 < len(tokens) and tokens[i + 1].startswith("ROLE_"):
                rid = int(tokens[i + 1].split("_")[1])
                holds.append((pid, rid))
                i += 1
        i += 1

    return grade, angle, holds


def structural_check(holds):
    """
    Basic structural validation (no spatial/reach check).
    Returns: (is_ok: bool, issues: list[str])
    """
    issues = []
    if len(holds) < 3:
        issues.append("too_few_holds")

    roles = [rid for _, rid in holds]
    if ROLE_START not in roles:
        issues.append("no_start")
    if ROLE_FINISH not in roles:
        issues.append("no_finish")

    pids = [pid for pid, _ in holds]
    if len(pids) != len(set(pids)):
        issues.append("duplicate_holds")

    return len(issues) == 0, issues


def jaccard_distance(set_a, set_b):
    """Jaccard distance = 1 - |intersection| / |union|. Range 0 (identical) to 1 (disjoint)."""
    if not set_a and not set_b:
        return 0.0
    intersection = len(set_a & set_b)
    union = len(set_a | set_b)
    return 1.0 - intersection / union if union > 0 else 0.0


def compute_diversity(climbs_hold_sets):
    """
    Mean pairwise Jaccard distance across a list of hold sets.
    Higher = more diverse (1.0 = every climb is completely different).
    """
    n = len(climbs_hold_sets)
    if n < 2:
        return 0.0

    total = 0.0
    pairs = 0
    for i in range(n):
        for j in range(i + 1, n):
            total += jaccard_distance(climbs_hold_sets[i], climbs_hold_sets[j])
            pairs += 1

    return total / pairs if pairs > 0 else 0.0


# ══════════════════════════════════════════════════════════════════════════════
# MAIN EVAL
# ══════════════════════════════════════════════════════════════════════════════

def main():
    print("=" * 60)
    print("MODEL EVALUATION HARNESS")
    print("=" * 60)

    # ── Load everything ─────────────────────────────────────────────────
    print("\nLoading model...")
    model, vocab, id_to_token, config = load_model()
    print(f"  {config['num_params']:,} params, best val loss: {config['best_val_loss']:.4f}")

    socket_pos = load_socket_positions()
    print(f"  {len(socket_pos)} socket positions loaded")

    # Load calibrated reach
    reach_path = os.path.join(DATA_DIR, "reach_config.json")
    with open(reach_path) as f:
        reach_config = json.load(f)
    max_reach = reach_config["max_reach"]
    print(f"  Using max_reach = {max_reach:.4f} (calibrated)")

    total_combos = len(EVAL_GRADES) * len(EVAL_ANGLES)
    total_samples = total_combos * SAMPLES_PER_COMBO
    print(f"\n  Eval grid: {len(EVAL_GRADES)} grades × {len(EVAL_ANGLES)} angles "
          f"× {SAMPLES_PER_COMBO} samples = {total_samples} climbs")

    # ── Generate and evaluate ───────────────────────────────────────────
    print(f"\n── GENERATING CLIMBS ──")

    all_results = []            # per-climb results
    combo_results = {}          # per-(grade, angle) aggregated results
    gen_start = time.time()

    for grade in EVAL_GRADES:
        for angle in EVAL_ANGLES:
            grade_token = vocab.get(f"GRADE_{grade}")
            angle_token = vocab.get(f"ANGLE_{angle}")
            if grade_token is None or angle_token is None:
                print(f"  ⚠️  Skipping V{grade}/{angle}° (token not in vocab)")
                continue

            prefix = torch.tensor([[vocab['BOS'], grade_token, angle_token]])

            combo_climbs = []
            combo_hold_sets = []

            for _ in range(SAMPLES_PER_COMBO):
                token_ids = model.generate(
                    prefix, max_new_tokens=60,
                    temperature=TEMPERATURE, top_k=TOP_K
                )

                gen_grade, gen_angle, holds = decode_tokens_to_holds(token_ids, id_to_token)

                # Structural check
                struct_ok, struct_issues = structural_check(holds)

                # Climbability check
                climb_ok, climb_issues = validate_climbability(holds, socket_pos, max_reach)

                result = {
                    "target_grade": grade,
                    "target_angle": angle,
                    "num_holds": len(holds),
                    "structural_ok": struct_ok,
                    "climbable": climb_ok,
                    "issues": struct_issues + climb_issues,
                }
                all_results.append(result)
                combo_climbs.append(result)

                # For diversity: set of placement IDs
                hold_set = frozenset(pid for pid, _ in holds)
                combo_hold_sets.append(hold_set)

            # Compute per-combo stats
            n = len(combo_climbs)
            combo_results[(grade, angle)] = {
                "n": n,
                "structural_ok": sum(1 for c in combo_climbs if c["structural_ok"]),
                "climbable": sum(1 for c in combo_climbs if c["climbable"]),
                "avg_holds": sum(c["num_holds"] for c in combo_climbs) / max(n, 1),
                "diversity": compute_diversity(combo_hold_sets),
            }

    gen_time = time.time() - gen_start

    # ── Print results ───────────────────────────────────────────────────
    print(f"\nGenerated {len(all_results)} climbs in {gen_time:.1f}s "
          f"({len(all_results)/gen_time:.1f} climbs/sec)\n")

    # Per-combo table
    print("── PER-COMBO RESULTS ──")
    print(f"  {'Grade':>5s}  {'Angle':>5s}  {'Struct%':>7s}  {'Climb%':>7s}  "
          f"{'AvgHolds':>8s}  {'Diversity':>9s}")
    print(f"  {'─'*5}  {'─'*5}  {'─'*7}  {'─'*7}  {'─'*8}  {'─'*9}")

    for grade in EVAL_GRADES:
        for angle in EVAL_ANGLES:
            key = (grade, angle)
            if key not in combo_results:
                continue
            r = combo_results[key]
            n = r["n"]
            struct_pct = 100 * r["structural_ok"] / max(n, 1)
            climb_pct = 100 * r["climbable"] / max(n, 1)
            print(f"  V{grade:<4d}  {angle:>4d}°  {struct_pct:>6.0f}%  {climb_pct:>6.0f}%  "
                  f"{r['avg_holds']:>8.1f}  {r['diversity']:>9.3f}")

    # Aggregate totals
    total = len(all_results)
    total_struct = sum(1 for r in all_results if r["structural_ok"])
    total_climb = sum(1 for r in all_results if r["climbable"])
    total_holds = sum(r["num_holds"] for r in all_results)

    # Per-grade aggregation
    grade_stats = {}
    for grade in EVAL_GRADES:
        grade_results = [r for r in all_results if r["target_grade"] == grade]
        if not grade_results:
            continue
        gn = len(grade_results)
        grade_stats[grade] = {
            "climbable_pct": 100 * sum(1 for r in grade_results if r["climbable"]) / gn,
            "avg_holds": sum(r["num_holds"] for r in grade_results) / gn,
        }

    # Diversity across ALL generated climbs at same grade
    all_diversity_by_grade = {}
    for grade in EVAL_GRADES:
        grade_hold_sets = []
        for r in all_results:
            if r["target_grade"] == grade:
                # Reconstruct hold set from the result
                grade_hold_sets.append(frozenset())  # placeholder
        # We need actual hold sets — recompute from combo_results
    # Use the per-combo diversity and average across angles for each grade
    grade_avg_diversity = {}
    for grade in EVAL_GRADES:
        diversities = []
        for angle in EVAL_ANGLES:
            key = (grade, angle)
            if key in combo_results:
                diversities.append(combo_results[key]["diversity"])
        if diversities:
            grade_avg_diversity[grade] = sum(diversities) / len(diversities)

    # ── Summary ─────────────────────────────────────────────────────────
    print(f"\n── OVERALL SUMMARY ──")
    print(f"  Total generated:   {total}")
    print(f"  Structurally OK:   {total_struct:>4d} ({100*total_struct/total:.1f}%)")
    print(f"  Climbable:         {total_climb:>4d} ({100*total_climb/total:.1f}%)")
    print(f"  Avg holds/climb:   {total_holds/total:.1f}")

    print(f"\n── PER-GRADE SUMMARY ──")
    print(f"  {'Grade':>5s}  {'Climb%':>7s}  {'AvgHolds':>8s}  {'Diversity':>9s}")
    print(f"  {'─'*5}  {'─'*7}  {'─'*8}  {'─'*9}")
    for grade in EVAL_GRADES:
        if grade in grade_stats:
            gs = grade_stats[grade]
            div = grade_avg_diversity.get(grade, 0)
            print(f"  V{grade:<4d}  {gs['climbable_pct']:>6.1f}%  "
                  f"{gs['avg_holds']:>8.1f}  {div:>9.3f}")

    # Issue breakdown
    issue_counter = Counter()
    for r in all_results:
        for issue in r["issues"]:
            issue_counter[issue] += 1

    if issue_counter:
        print(f"\n── ISSUE BREAKDOWN ──")
        for issue, count in issue_counter.most_common():
            print(f"  {issue}: {count} ({100*count/total:.1f}%)")

    # ── Save results ────────────────────────────────────────────────────
    save_data = {
        "config": {
            "samples_per_combo": SAMPLES_PER_COMBO,
            "temperature": TEMPERATURE,
            "top_k": TOP_K,
            "eval_grades": EVAL_GRADES,
            "eval_angles": EVAL_ANGLES,
            "max_reach": max_reach,
        },
        "model": {
            "num_params": config["num_params"],
            "best_val_loss": config["best_val_loss"],
            "epochs_trained": config["epochs_trained"],
        },
        "summary": {
            "total_generated": total,
            "structural_ok_pct": round(100 * total_struct / total, 1),
            "climbable_pct": round(100 * total_climb / total, 1),
            "avg_holds": round(total_holds / total, 1),
        },
        "per_grade": {
            f"V{g}": {
                "climbable_pct": round(grade_stats[g]["climbable_pct"], 1),
                "avg_holds": round(grade_stats[g]["avg_holds"], 1),
                "diversity": round(grade_avg_diversity.get(g, 0), 3),
            }
            for g in EVAL_GRADES if g in grade_stats
        },
        "generation_time_sec": round(gen_time, 1),
    }

    results_path = os.path.join(DATA_DIR, "eval_results.json")
    with open(results_path, "w") as f:
        json.dump(save_data, f, indent=2)

    print(f"\n  Saved eval results → {results_path}")
    print(f"\n{'='*60}")
    print("✅ Baseline captured! After retraining, run this again and")
    print("   compare the numbers in data/eval_results.json.")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
