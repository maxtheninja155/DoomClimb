"""
Step 5: Export the trained model to CoreML
============================================
Converts the PyTorch ClimbGPT model to CoreML format (.mlpackage)
so it can run on-device in the iOS app.

CoreML doesn't natively support autoregressive generation loops, so we
export the model as a "single forward pass" that takes a partial sequence
and returns logits for the next token. The Swift code will handle the
generation loop (calling the model repeatedly, sampling, appending tokens).

Requirements:
    pip install coremltools

Usage:
    cd /Users/maxwellwainwright/Documents/DoomClimb/training
    python 05_export_coreml.py

Output:
    export/ClimbGPT.mlpackage  — ready to drag into Xcode
    export/vocab.json          — copy of vocab (bundle with the app)
    export/id_to_token.json    — reverse mapping (bundle with the app)
"""

import json
import os
import shutil

import torch
import torch.nn as nn
import coremltools as ct

from importlib.machinery import SourceFileLoader
_mod = SourceFileLoader("train_model",
    os.path.join(os.path.dirname(__file__), "03_train_model.py")).load_module()
ClimbGPT = _mod.ClimbGPT

# ── Paths ────────────────────────────────────────────────────────────────────
DATA_DIR   = os.path.join(os.path.dirname(__file__), "data")
CKPT_DIR   = os.path.join(os.path.dirname(__file__), "checkpoints")
EXPORT_DIR = os.path.join(os.path.dirname(__file__), "export")
os.makedirs(EXPORT_DIR, exist_ok=True)


# ══════════════════════════════════════════════════════════════════════════════
# WRAPPER MODEL
# ══════════════════════════════════════════════════════════════════════════════
# CoreML needs a clean forward() that takes a fixed-shape input and returns
# logits. We wrap ClimbGPT to:
#   1. Accept a padded token sequence of shape (1, MAX_SEQ_LEN)
#   2. Accept a scalar `length` indicating how many tokens are real
#   3. Return logits for the LAST real token position only (shape: (1, vocab_size))

class ClimbGPTForExport(nn.Module):
    """Thin wrapper that makes ClimbGPT CoreML-friendly."""

    def __init__(self, model, max_seq_len):
        super().__init__()
        self.model = model
        self.max_seq_len = max_seq_len

    def forward(self, tokens):
        """
        tokens: (1, MAX_SEQ_LEN) — padded input sequence

        Returns: (1, MAX_SEQ_LEN, vocab_size) — logits for ALL positions.
        The Swift caller picks the logits at position (length - 1).
        This avoids data-dependent indexing which breaks tracing.
        """
        logits, _ = self.model(tokens)
        return logits


def main():
    # ── Load model ───────────────────────────────────────────────────────
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
    print(f"Loaded model: {config['num_params']:,} params")

    max_seq_len = config['max_seq_len']
    wrapper = ClimbGPTForExport(model, max_seq_len)
    wrapper.eval()

    # ── Trace with example inputs ────────────────────────────────────────
    print("Tracing model...")
    example_tokens = torch.zeros(1, max_seq_len, dtype=torch.long)
    example_tokens[0, :3] = torch.tensor([1, 8, 29])  # BOS, GRADE_4, ANGLE_40

    # check_trace=False: TransformerEncoder takes different optimized code
    # paths on repeated calls, which causes the graph diff check to fail.
    # The outputs are numerically identical — just different ops.
    traced = torch.jit.trace(wrapper, (example_tokens,), check_trace=False)

    # Verify manually that outputs match
    with torch.no_grad():
        out_eager = wrapper(example_tokens)
        out_traced = traced(example_tokens)
        max_diff = (out_eager - out_traced).abs().max().item()
        print(f"  Trace vs eager max diff: {max_diff:.8f} (should be ~0)")

    # ── Convert to CoreML ────────────────────────────────────────────────
    print("Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="tokens", shape=(1, max_seq_len), dtype=int),
        ],
        outputs=[
            ct.TensorType(name="logits"),
        ],
        minimum_deployment_target=ct.target.iOS17,
    )

    # Add metadata
    mlmodel.author = "DoomClimb Training Pipeline"
    mlmodel.short_description = (
        "Generates Kilter Board climbing routes. "
        "Feed a partial token sequence and get logits for the next token."
    )
    mlmodel.input_description["tokens"] = (
        f"Padded token sequence (1, {max_seq_len}). "
        "Format: [BOS, GRADE_X, ANGLE_Y, HOLD_1, ROLE_1, ..., 0, 0, ...]"
    )
    mlmodel.output_description["logits"] = (
        f"Logits for all positions (1, {max_seq_len}, {config['vocab_size']}). "
        "Index at position (length - 1) to get next-token prediction."
    )

    # Save
    mlpackage_path = os.path.join(EXPORT_DIR, "ClimbGPT.mlpackage")
    if os.path.exists(mlpackage_path):
        shutil.rmtree(mlpackage_path)
    mlmodel.save(mlpackage_path)
    print(f"Saved CoreML model → {mlpackage_path}")

    # ── Copy vocab files ─────────────────────────────────────────────────
    for fname in ["vocab.json", "id_to_token.json"]:
        src = os.path.join(DATA_DIR, fname)
        dst = os.path.join(EXPORT_DIR, fname)
        shutil.copy2(src, dst)
        print(f"Copied {fname} → {dst}")

    # ── Verify ───────────────────────────────────────────────────────────
    print("\nVerifying CoreML model...")
    import numpy as np
    tokens_np = example_tokens.numpy().astype(np.int32)
    pred = mlmodel.predict({"tokens": tokens_np})
    logits = pred["logits"]
    print(f"  Output shape: {logits.shape}  (expected: (1, {max_seq_len}, {config['vocab_size']}))")
    # Check logits at position 2 (the last real token: ANGLE_40)
    next_token_logits = logits[0, 2, :]
    print(f"  Top-5 predicted tokens at pos 2: {next_token_logits.argsort()[-5:][::-1].tolist()}")

    # ── Print integration instructions ───────────────────────────────────
    print(f"\n{'='*60}")
    print("INTEGRATION INSTRUCTIONS")
    print(f"{'='*60}")
    print(f"""
    1. Drag these into your Xcode project:
       • {mlpackage_path}
       • {os.path.join(EXPORT_DIR, 'vocab.json')}
       • {os.path.join(EXPORT_DIR, 'id_to_token.json')}

    2. The Swift generation loop will:
       a. Start with tokens = [BOS, GRADE_X, ANGLE_Y, 0, 0, ...] (padded to {max_seq_len}), length = 3
       b. Call model.predict(tokens) → logits of shape (1, {max_seq_len}, vocab_size)
       c. Index logits at position (length - 1) to get next-token logits
       d. Sample next token from those logits (with temperature + top-k)
       e. Set tokens[length] = sampled_token, increment length
       f. Repeat until EOS or max length reached

    3. Decode the token sequence back into (placement_id, role) pairs
       using vocab.json to map token IDs → "HOLD_1234" / "ROLE_13" strings

    ✅ Done! The model is ready for iOS integration.
    """)


if __name__ == "__main__":
    main()
