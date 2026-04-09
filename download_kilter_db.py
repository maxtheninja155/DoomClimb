"""
DoomClimb — Kilter Board Database Downloader
=============================================
Run this once in PyCharm to download the official Kilter Board SQLite database.
The output file (kilter.db) is what you drag into your Xcode project.

Steps after running:
  1. This script saves kilter.db next to itself.
  2. In Xcode: right-click your DoomClimb group → Add Files → select kilter.db.
     Make sure "Copy items if needed" and your app target are both checked.
"""

import subprocess
import sys
import os

# ── 1. Install boardlib if it isn't already installed ──────────────────────────
print("Installing boardlib...")
subprocess.check_call(
    [sys.executable, "-m", "pip", "install", "--quiet", "boardlib"],
    stdout=sys.stdout,
    stderr=sys.stderr,
)
print("boardlib ready.\n")

# ── 2. Download the Kilter Board database ──────────────────────────────────────
output_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kilter.db")
print(f"Downloading Kilter Board database → {output_path}")
print("(This fetches the official APK and syncs live route data — may take a minute.)\n")

result = subprocess.run(
    [sys.executable, "-m", "boardlib", "database", "kilter", output_path],
    stdout=sys.stdout,
    stderr=sys.stderr,
)

# ── 3. Verify ──────────────────────────────────────────────────────────────────
if result.returncode == 0 and os.path.exists(output_path):
    size_mb = os.path.getsize(output_path) / (1024 * 1024)
    print(f"\n✅  Success! kilter.db saved ({size_mb:.1f} MB)")
    print(f"   Location: {output_path}")
    print("\nNext step: drag kilter.db into your Xcode project.")
    print("  • Right-click the DoomClimb folder in Xcode's navigator")
    print("  • Add Files to 'DoomClimb'")
    print("  • Select kilter.db")
    print("  • Check 'Copy items if needed' and your app target, then click Add.")
else:
    print("\n❌  Something went wrong. Check the error output above.")
    print("    Common fix: make sure you're using Python 3.8+ in PyCharm.")
    sys.exit(1)

# ── 4. Print a quick schema preview so you can see what's inside ───────────────
try:
    import sqlite3
    con = sqlite3.connect(output_path)
    cur = con.cursor()

    print("\n── Database tables ───────────────────────────────────────────")
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    for (name,) in cur.fetchall():
        cur.execute(f"SELECT COUNT(*) FROM [{name}]")
        count = cur.fetchone()[0]
        print(f"  {name:<40} {count:>8} rows")

    print("\n── Sample holds (holes table, first 5 rows) ──────────────────")
    cur.execute("SELECT id, x, y FROM holes LIMIT 5")
    print(f"  {'id':<8} {'x':<8} {'y':<8}")
    for row in cur.fetchall():
        print(f"  {row[0]:<8} {row[1]:<8} {row[2]:<8}")

    print("\n── Sample LED positions (leds table, first 5 rows) ───────────")
    cur.execute("SELECT hole_id, product_size_id, position FROM leds LIMIT 5")
    print(f"  {'hole_id':<12} {'product_size_id':<18} {'position':<10}")
    for row in cur.fetchall():
        print(f"  {row[0]:<12} {row[1]:<18} {row[2]:<10}")

    con.close()
except Exception as e:
    print(f"\n(Schema preview skipped: {e})")
