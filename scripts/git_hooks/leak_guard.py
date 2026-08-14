#!/usr/bin/env python3
"""Blocks configured terms from reaching published git text.

AgentHub is public, and published git text is not reliably retractable, so
the practical control is to keep a configured term from being committed in
the first place.

Terms are stored as SHA-256 hashes in `blocked-terms.sha256`, never as
plaintext -- a readable denylist in a public repo would defeat its own
purpose. Hashing resists casual grep and search indexing; it is not meant to
withstand a dictionary attack.

Matching is on whole alphanumeric tokens of the lowercased text, so for a
blocked term `airfoo`, the strings `AirFooUI`, `airfoo/apps#123`, and
`airfoo.yaml` all match, while a term buried inside a larger word
(`myairfoothing`) does not. Examples here are deliberately fictitious: this
file is public, so it must not spell out the words it blocks.

Usage:
  leak_guard.py --message <file>   scan a commit message (commit-msg hook)
  leak_guard.py --staged           scan staged content + paths (pre-commit hook)
  leak_guard.py --stdin            scan arbitrary text, e.g. a PR body
  leak_guard.py --add-term         add a term, read from a prompt (not argv,
                                   so the term never lands in shell history)
"""

from __future__ import annotations

import hashlib
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
DENYLIST = HERE / "blocked-terms.sha256"

TOKEN_RE = re.compile(r"[a-z0-9]+")
# Commit-message comment lines are stripped by git and never persist.
COMMENT_PREFIX = "#"


def load_hashes() -> set[str]:
  if not DENYLIST.exists():
    return set()
  hashes = set()
  for line in DENYLIST.read_text(encoding="utf-8").splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
      continue
    hashes.add(line.split()[0].lower())
  return hashes


def digest(token: str) -> str:
  return hashlib.sha256(token.encode("utf-8")).hexdigest()


def normalize(term: str) -> str:
  """Reduce a term to the token form the scanner will see."""
  return "".join(TOKEN_RE.findall(term.lower()))


def scan(text: str, hashes: set[str]) -> set[str]:
  if not hashes:
    return set()
  return {tok for tok in set(TOKEN_RE.findall(text.lower())) if digest(tok) in hashes}


def report(hits: set[str], where: str) -> int:
  bar = "=" * 68
  print(f"\n{bar}", file=sys.stderr)
  print("  BLOCKED: internal reference detected in " + where, file=sys.stderr)
  print(bar, file=sys.stderr)
  print("\n  Matched: " + ", ".join(sorted(hits)), file=sys.stderr)
  print(
    "\n  This repository is public and published git text is not reliably\n"
    "  retractable. Rewrite the text without this term -- refer to the\n"
    "  subject generically instead.\n\n"
    "  Intentional and reviewed? Bypass with:  git commit --no-verify\n",
    file=sys.stderr,
  )
  return 1


def staged_text() -> str:
  """Staged file contents plus the paths themselves."""
  names = subprocess.run(
    ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
    capture_output=True, text=True, check=False,
  ).stdout
  # Added lines only: pre-existing history is out of scope for a commit guard.
  diff = subprocess.run(
    ["git", "diff", "--cached", "--unified=0", "--diff-filter=ACMR"],
    capture_output=True, text=True, check=False,
  ).stdout
  added = "\n".join(
    line[1:] for line in diff.splitlines()
    if line.startswith("+") and not line.startswith("+++")
  )
  return names + "\n" + added


def add_term() -> int:
  try:
    term = input("Term to block (not echoed to shell history): ").strip()
  except (EOFError, KeyboardInterrupt):
    print("\naborted", file=sys.stderr)
    return 1
  token = normalize(term)
  if not token:
    print("error: term has no alphanumeric content", file=sys.stderr)
    return 1
  digested = digest(token)
  if digested in load_hashes():
    print("already blocked -- no change")
    return 0
  with DENYLIST.open("a", encoding="utf-8") as handle:
    handle.write(f"{digested}\n")
  print(f"added ({len(token)}-char token). Commit blocked-terms.sha256 to share it.")
  return 0


def main(argv: list[str]) -> int:
  if len(argv) < 2:
    print(__doc__, file=sys.stderr)
    return 2

  mode = argv[1]
  if mode == "--add-term":
    return add_term()

  hashes = load_hashes()

  if mode == "--message":
    if len(argv) < 3:
      print("error: --message needs a file path", file=sys.stderr)
      return 2
    raw = pathlib.Path(argv[2]).read_text(encoding="utf-8", errors="replace")
    body = "\n".join(
      line for line in raw.splitlines() if not line.startswith(COMMENT_PREFIX)
    )
    hits = scan(body, hashes)
    return report(hits, "the commit message") if hits else 0

  if mode == "--staged":
    hits = scan(staged_text(), hashes)
    return report(hits, "staged changes") if hits else 0

  if mode == "--stdin":
    hits = scan(sys.stdin.read(), hashes)
    return report(hits, "the provided text") if hits else 0

  print(f"error: unknown mode {mode}", file=sys.stderr)
  return 2


if __name__ == "__main__":
  sys.exit(main(sys.argv))
