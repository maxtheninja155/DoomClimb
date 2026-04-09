"""
Step 3: Train the climb generation model
==========================================
A small GPT-style transformer that learns to generate Kilter Board climbs
conditioned on grade and angle.

Architecture:
  - Causal (autoregressive) transformer
  - Input: [BOS, GRADE_X, ANGLE_Y, HOLD_1, ROLE_1, ..., EOS]
  - The model learns to predict the next token given all previous tokens
  - At inference time, we feed [BOS, GRADE, ANGLE] and let it generate holds

Requirements:
    pip install torch numpy

Usage:
    cd /Users/maxwellwainwright/Documents/DoomClimb/training
    python 03_train_model.py

    # You can adjust hyperparameters below. Start with defaults — they're
    # tuned for a MacBook with Apple Silicon (MPS backend).

Output:
    checkpoints/climb_gpt_final.pt  — trained model weights
    checkpoints/config.json         — model config (needed for inference)
"""

import json
import os
import time
import math

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader

# ── Hyperparameters ──────────────────────────────────────────────────────────
# These are intentionally conservative. A 2M-param model trains in ~10-20 min
# on an M1/M2 Mac with MPS. Increase if you want to experiment.

EMBED_DIM    = 256      # Token embedding dimension
NUM_HEADS    = 4        # Attention heads
NUM_LAYERS   = 4        # Transformer blocks
DROPOUT      = 0.1      # Dropout rate
MAX_SEQ_LEN  = 80       # Maximum sequence length (longest climbs ~60 tokens)

BATCH_SIZE   = 64       # Batch size
LEARNING_RATE = 3e-4    # Adam learning rate
NUM_EPOCHS   = 30       # Training epochs (start here, increase if loss is still dropping)
WARMUP_STEPS = 500      # Linear LR warmup steps

# ── Paths ────────────────────────────────────────────────────────────────────
DATA_DIR = os.path.join(os.path.dirname(__file__), "data")
CKPT_DIR = os.path.join(os.path.dirname(__file__), "checkpoints")
os.makedirs(CKPT_DIR, exist_ok=True)

# ── Device ───────────────────────────────────────────────────────────────────
if torch.backends.mps.is_available():
    DEVICE = torch.device("mps")
    print("Using Apple Silicon GPU (MPS)")
elif torch.cuda.is_available():
    DEVICE = torch.device("cuda")
    print("Using CUDA GPU")
else:
    DEVICE = torch.device("cpu")
    print("Using CPU (training will be slower)")


# ══════════════════════════════════════════════════════════════════════════════
# MODEL
# ══════════════════════════════════════════════════════════════════════════════

class ClimbGPT(nn.Module):
    """
    A small GPT-style model for generating Kilter Board climbs.

    Uses TransformerEncoder (self-attention only) with a causal mask —
    this is the correct architecture for a decoder-only autoregressive model.
    (TransformerDecoder has cross-attention which leaks future information.)

    Given a prefix [BOS, GRADE, ANGLE], it autoregressively generates
    (HOLD, ROLE) pairs until it produces an EOS token.
    """

    def __init__(self, vocab_size, embed_dim, num_heads, num_layers,
                 max_seq_len, dropout=0.1, pad_token_id=0):
        super().__init__()
        self.vocab_size = vocab_size
        self.embed_dim = embed_dim
        self.max_seq_len = max_seq_len
        self.pad_token_id = pad_token_id

        # Token + positional embeddings
        self.token_emb = nn.Embedding(vocab_size, embed_dim, padding_idx=pad_token_id)
        self.pos_emb   = nn.Embedding(max_seq_len, embed_dim)
        self.drop       = nn.Dropout(dropout)

        # Transformer encoder blocks (self-attention only — no cross-attention leak)
        encoder_layer = nn.TransformerEncoderLayer(
            d_model=embed_dim,
            nhead=num_heads,
            dim_feedforward=embed_dim * 4,
            dropout=dropout,
            activation='gelu',
            batch_first=True,
            norm_first=True,         # Pre-norm (more stable training)
        )
        self.transformer = nn.TransformerEncoder(encoder_layer, num_layers=num_layers)
        self.ln_f = nn.LayerNorm(embed_dim)

        # Output projection (tied with token embeddings for efficiency)
        self.head = nn.Linear(embed_dim, vocab_size, bias=False)
        self.head.weight = self.token_emb.weight  # Weight tying

        self._init_weights()

    def _init_weights(self):
        for p in self.parameters():
            if p.dim() > 1:
                nn.init.xavier_uniform_(p)

    def forward(self, x, targets=None):
        """
        x:       (batch, seq_len) — input token IDs
        targets: (batch, seq_len) — target token IDs (shifted by 1)

        Returns:
            logits: (batch, seq_len, vocab_size)
            loss:   scalar (if targets provided)
        """
        B, T = x.shape
        assert T <= self.max_seq_len, f"Sequence length {T} exceeds max {self.max_seq_len}"

        # Embeddings
        positions = torch.arange(T, device=x.device).unsqueeze(0)  # (1, T)
        h = self.token_emb(x) + self.pos_emb(positions)
        h = self.drop(h)

        # Causal mask: each token can only attend to itself and earlier tokens
        causal_mask = nn.Transformer.generate_square_subsequent_mask(
            T, device=x.device, dtype=h.dtype
        )

        # Padding mask: ignore PAD tokens
        pad_mask = (x == self.pad_token_id)  # True where padded

        # Self-attention only, with causal mask to prevent future peeking
        h = self.transformer(
            h,
            mask=causal_mask,
            src_key_padding_mask=pad_mask,
        )
        h = self.ln_f(h)
        logits = self.head(h)

        loss = None
        if targets is not None:
            # Flatten for cross-entropy, ignoring PAD positions
            loss = F.cross_entropy(
                logits.view(-1, self.vocab_size),
                targets.view(-1),
                ignore_index=self.pad_token_id,
            )

        return logits, loss

    @torch.no_grad()
    def generate(self, prefix, max_new_tokens=60, temperature=1.0, top_k=50):
        """
        Autoregressive generation starting from a prefix.

        prefix: (1, prefix_len) tensor of token IDs, e.g. [BOS, GRADE_5, ANGLE_40]
        Returns: list of generated token IDs (excluding the prefix)
        """
        self.eval()
        x = prefix.clone()

        for _ in range(max_new_tokens):
            # Crop to max_seq_len if needed
            x_cond = x[:, -self.max_seq_len:]

            logits, _ = self.forward(x_cond)
            logits = logits[:, -1, :] / temperature  # Last position only

            # Top-k filtering
            if top_k > 0:
                v, _ = torch.topk(logits, min(top_k, logits.size(-1)))
                logits[logits < v[:, [-1]]] = -float('inf')

            probs = F.softmax(logits, dim=-1)
            next_token = torch.multinomial(probs, num_samples=1)
            x = torch.cat([x, next_token], dim=1)

            # Stop at EOS
            if next_token.item() == 2:  # EOS token
                break

        return x[0].tolist()  # Full sequence including prefix


# ══════════════════════════════════════════════════════════════════════════════
# DATASET
# ══════════════════════════════════════════════════════════════════════════════

class ClimbDataset(Dataset):
    """
    Loads tokenized climb sequences and prepares them for causal LM training.
    Each item returns (input, target) where target is input shifted right by 1.
    """

    def __init__(self, sequences, max_seq_len, pad_token_id=0):
        self.sequences = sequences
        self.max_seq_len = max_seq_len
        self.pad_token_id = pad_token_id

    def __len__(self):
        return len(self.sequences)

    def __getitem__(self, idx):
        seq = self.sequences[idx]

        # Truncate if needed
        if len(seq) > self.max_seq_len:
            seq = seq[:self.max_seq_len]

        # Input = all tokens except last, Target = all tokens except first
        # (standard causal LM setup)
        inp = seq[:-1]
        tgt = seq[1:]

        # Pad to fixed length
        pad_len = self.max_seq_len - 1 - len(inp)
        inp = inp + [self.pad_token_id] * pad_len
        tgt = tgt + [self.pad_token_id] * pad_len

        return torch.tensor(inp, dtype=torch.long), torch.tensor(tgt, dtype=torch.long)


# ══════════════════════════════════════════════════════════════════════════════
# TRAINING LOOP
# ══════════════════════════════════════════════════════════════════════════════

def train():
    # ── Load data ────────────────────────────────────────────────────────
    print("Loading dataset...")
    with open(os.path.join(DATA_DIR, "train_sequences.json")) as f:
        train_seqs = json.load(f)
    with open(os.path.join(DATA_DIR, "val_sequences.json")) as f:
        val_seqs = json.load(f)
    with open(os.path.join(DATA_DIR, "vocab.json")) as f:
        vocab = json.load(f)

    vocab_size = len(vocab)
    print(f"Vocab size: {vocab_size}")
    print(f"Train: {len(train_seqs):,} sequences")
    print(f"Val:   {len(val_seqs):,} sequences")

    train_ds = ClimbDataset(train_seqs, MAX_SEQ_LEN)
    val_ds   = ClimbDataset(val_seqs, MAX_SEQ_LEN)

    train_loader = DataLoader(train_ds, batch_size=BATCH_SIZE, shuffle=True,
                              num_workers=0, pin_memory=True)
    val_loader   = DataLoader(val_ds, batch_size=BATCH_SIZE, shuffle=False,
                              num_workers=0, pin_memory=True)

    # ── Build model ──────────────────────────────────────────────────────
    model = ClimbGPT(
        vocab_size=vocab_size,
        embed_dim=EMBED_DIM,
        num_heads=NUM_HEADS,
        num_layers=NUM_LAYERS,
        max_seq_len=MAX_SEQ_LEN,
        dropout=DROPOUT,
    ).to(DEVICE)

    num_params = sum(p.numel() for p in model.parameters())
    print(f"\nModel parameters: {num_params:,}")
    print(f"Model size: ~{num_params * 4 / 1024 / 1024:.1f} MB (float32)")

    # ── Optimizer + scheduler ────────────────────────────────────────────
    optimizer = torch.optim.AdamW(model.parameters(), lr=LEARNING_RATE,
                                   weight_decay=0.01)

    # Cosine annealing with warmup
    total_steps = len(train_loader) * NUM_EPOCHS

    def lr_lambda(step):
        if step < WARMUP_STEPS:
            return step / max(WARMUP_STEPS, 1)
        progress = (step - WARMUP_STEPS) / max(total_steps - WARMUP_STEPS, 1)
        return 0.5 * (1 + math.cos(math.pi * progress))

    scheduler = torch.optim.lr_scheduler.LambdaLR(optimizer, lr_lambda)

    # ── Training ─────────────────────────────────────────────────────────
    print(f"\n{'='*60}")
    print(f"Training for {NUM_EPOCHS} epochs ({total_steps:,} steps)")
    print(f"{'='*60}\n")

    best_val_loss = float('inf')
    global_step = 0

    for epoch in range(1, NUM_EPOCHS + 1):
        model.train()
        epoch_loss = 0
        epoch_tokens = 0
        t0 = time.time()

        for batch_idx, (inp, tgt) in enumerate(train_loader):
            inp, tgt = inp.to(DEVICE), tgt.to(DEVICE)

            _, loss = model(inp, tgt)
            optimizer.zero_grad()
            loss.backward()

            # Gradient clipping (prevents exploding gradients)
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)

            optimizer.step()
            scheduler.step()
            global_step += 1

            # Track loss (weighted by number of non-pad tokens)
            num_tokens = (tgt != 0).sum().item()
            epoch_loss += loss.item() * num_tokens
            epoch_tokens += num_tokens

        avg_train_loss = epoch_loss / max(epoch_tokens, 1)
        dt = time.time() - t0

        # ── Validation ───────────────────────────────────────────────────
        model.eval()
        val_loss = 0
        val_tokens = 0

        with torch.no_grad():
            for inp, tgt in val_loader:
                inp, tgt = inp.to(DEVICE), tgt.to(DEVICE)
                _, loss = model(inp, tgt)
                num_tokens = (tgt != 0).sum().item()
                val_loss += loss.item() * num_tokens
                val_tokens += num_tokens

        avg_val_loss = val_loss / max(val_tokens, 1)
        lr = optimizer.param_groups[0]['lr']

        improved = ""
        if avg_val_loss < best_val_loss:
            best_val_loss = avg_val_loss
            # Save best model
            torch.save(model.state_dict(), os.path.join(CKPT_DIR, "climb_gpt_best.pt"))
            improved = " ★ best"

        print(f"Epoch {epoch:3d}/{NUM_EPOCHS} | "
              f"train_loss: {avg_train_loss:.4f} | "
              f"val_loss: {avg_val_loss:.4f} | "
              f"lr: {lr:.6f} | "
              f"time: {dt:.1f}s{improved}")

    # ── Save final model + config ────────────────────────────────────────
    torch.save(model.state_dict(), os.path.join(CKPT_DIR, "climb_gpt_final.pt"))

    config = {
        "vocab_size": vocab_size,
        "embed_dim": EMBED_DIM,
        "num_heads": NUM_HEADS,
        "num_layers": NUM_LAYERS,
        "max_seq_len": MAX_SEQ_LEN,
        "dropout": DROPOUT,
        "num_params": num_params,
        "best_val_loss": best_val_loss,
        "epochs_trained": NUM_EPOCHS,
    }
    with open(os.path.join(CKPT_DIR, "config.json"), "w") as f:
        json.dump(config, f, indent=2)

    print(f"\n{'='*60}")
    print(f"Training complete!")
    print(f"Best validation loss: {best_val_loss:.4f}")
    print(f"Model saved to: {CKPT_DIR}/")
    print(f"Next step: run 04_generate_samples.py to test generation")
    print(f"{'='*60}")


if __name__ == "__main__":
    train()
