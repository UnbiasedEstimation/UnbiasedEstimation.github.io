#!/usr/bin/env bash
# Sync articles from UnbiasedEstimation/content into the local _content/
# directory, filtered by the `publish-to-website: true` frontmatter flag.
#
# Behavior:
#  1. Clones (or pulls latest) UnbiasedEstimation/content into _content_src/.
#  2. Walks every .qmd and .md file under _content_src/content/.
#  3. Reads each file's YAML frontmatter; checks `publish-to-website`.
#  4. If true, copies the file + sibling assets (figures/, images/) into
#     _content/ preserving the relative directory structure.
#  5. Writes a manifest of synced files to .last-sync.txt.
#
# Idempotent — running again wipes _content/ and re-copies.

set -euo pipefail

SITE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_REPO="git@github.com:UnbiasedEstimation/content.git"
SRC_DIR="${SITE_ROOT}/_content_src"
DEST_DIR="${SITE_ROOT}/_content"
MANIFEST="${SITE_ROOT}/.last-sync.txt"
SRC_BRANCH="${SRC_BRANCH:-main}"

# Source articles live under content/ in the upstream repo (post-restructure).
CONTENT_SUBPATH="content"

echo "[sync] site root:       $SITE_ROOT"
echo "[sync] source repo:     $SRC_REPO (branch: $SRC_BRANCH)"
echo "[sync] content subpath: $CONTENT_SUBPATH"
echo

# Step 1: clone or refresh _content_src/
if [[ -d "$SRC_DIR/.git" ]]; then
  echo "[sync] refreshing $SRC_DIR ..."
  git -C "$SRC_DIR" fetch origin "$SRC_BRANCH" --quiet
  git -C "$SRC_DIR" reset --hard "origin/$SRC_BRANCH" --quiet
else
  echo "[sync] cloning $SRC_REPO into $SRC_DIR ..."
  rm -rf "$SRC_DIR"
  git clone --depth=1 --branch "$SRC_BRANCH" --quiet "$SRC_REPO" "$SRC_DIR"
fi

# Step 2: clean _content/ and recreate
echo "[sync] wiping $DEST_DIR ..."
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

# Step 3-4: filter and copy. Use Python for robust YAML parsing.
echo "[sync] filtering by publish-to-website: true ..."
python3 - <<PYEOF
import os
import re
import shutil
import sys
from pathlib import Path

src_root = Path("${SRC_DIR}") / "${CONTENT_SUBPATH}"
dest_root = Path("${DEST_DIR}")
manifest = Path("${MANIFEST}")

def parse_frontmatter(path):
    """Return the YAML frontmatter as a dict, or {} if none."""
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return {}
    if not text.startswith("---"):
        return {}
    # Find the closing '---' delimiter
    end = text.find("\n---", 4)
    if end == -1:
        return {}
    raw = text[4:end]
    # Tiny YAML parser: key: value pairs, no nested structures needed.
    fm = {}
    for line in raw.splitlines():
        m = re.match(r"^([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(.*)$", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        # Strip quotes
        if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
            val = val[1:-1]
        fm[key] = val
    return fm

count_total = 0
count_kept = 0
synced = []

for path in src_root.rglob("*"):
    if not path.is_file():
        continue
    if path.suffix not in (".qmd", ".md"):
        continue
    # Skip non-publishable files
    name = path.name
    if name.startswith("_") or name in ("README.md",):
        continue
    count_total += 1
    fm = parse_frontmatter(path)
    flag = fm.get("publish-to-website", "").lower()
    if flag != "true":
        continue
    # Copy file
    rel = path.relative_to(src_root)
    dest = dest_root / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)
    # Copy sibling asset folders (figures/, images/, assets/)
    for asset_dir in ("figures", "images", "assets"):
        src_asset = path.parent / asset_dir
        if src_asset.is_dir():
            dest_asset = dest.parent / asset_dir
            if dest_asset.exists():
                shutil.rmtree(dest_asset)
            shutil.copytree(src_asset, dest_asset)
    synced.append(str(rel))
    count_kept += 1

manifest.write_text(
    f"# Last sync: {count_kept} of {count_total} articles flagged publish-to-website: true\n\n"
    + "\n".join(sorted(synced))
    + "\n"
)
print(f"[sync] kept {count_kept} of {count_total} articles")
print(f"[sync] manifest: {manifest}")
PYEOF

echo
echo "[sync] done. Next: run 'quarto render' to build the site."
