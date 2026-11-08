#!/usr/bin/env bash
# Sync articles from UnbiasedEstimation/content into the local content/
# directory, filtered by the `publish-to-website: true` frontmatter flag.
#
# content/ must not start with "_": Quarto skips such directories when
# rendering. _content_src/ keeps its underscore so the full clone, drafts
# included, is never rendered.
#
# Behavior:
#  1. Clones (or pulls latest) UnbiasedEstimation/content into _content_src/.
#  2. Walks every .qmd and .md file under _content_src/content/.
#  3. Reads each file's YAML frontmatter; checks `publish-to-website`.
#  4. If true, copies the file + sibling assets (figures/, images/) into
#     content/ preserving the relative directory structure.
#  5. Writes a manifest of synced files to .last-sync.txt.
#
# Idempotent — running again wipes content/ and re-copies.

set -euo pipefail

SITE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_REPO="git@github.com:UnbiasedEstimation/content.git"
SRC_DIR="${SITE_ROOT}/_content_src"
DEST_DIR="${SITE_ROOT}/content"
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

# Step 2: clean content/ and recreate
echo "[sync] wiping $DEST_DIR ..."
rm -rf "$DEST_DIR"
mkdir -p "$DEST_DIR"

# Step 3-4: filter and copy. Use Python for robust YAML parsing.
echo "[sync] filtering by publish-to-website: true ..."
python3 - <<PYEOF
import json
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

# Our own frontmatter keys whose names Quarto or Pandoc already use, so they
# are dropped from the copy. (No backticks in this heredoc: bash would run
# their contents as a command.)
STRIP_KEYS = (
    "progress",  # reveal.js option, must be boolean; ours is a percentage
    "math",      # Pandoc template variable holding the MathJax script tag
)

def strip_keys(text):
    """Remove STRIP_KEYS (with any indented continuation lines) from the frontmatter."""
    if not text.startswith("---"):
        return text
    end = text.find("\n---", 4)
    if end == -1:
        return text
    kept, skipping = [], False
    for line in text[4:end].splitlines(keepends=True):
        m = re.match(r"^([A-Za-z][A-Za-z0-9_-]*)\s*:", line)
        if m:
            skipping = m.group(1) in STRIP_KEYS
        if not skipping:
            kept.append(line)
    return text[:4] + "".join(kept) + text[end:]

def strip_pdf_format(text):
    """Remove the pdf entry under format: in the frontmatter."""
    if not text.startswith("---"):
        return text
    end = text.find("\n---", 4)
    if end == -1:
        return text
    kept, in_format, pdf_indent = [], False, None
    for line in text[4:end].splitlines(keepends=True):
        indent = len(line) - len(line.lstrip())
        if pdf_indent is not None:
            if line.strip() and indent <= pdf_indent:
                pdf_indent = None
            else:
                continue
        if indent == 0 and line.strip():
            in_format = line.startswith("format:")
        elif in_format and re.match(r"^\s+pdf\s*:", line):
            pdf_indent = indent
            continue
        kept.append(line)
    return text[:4] + "".join(kept) + text[end:]

def linkedin_meta(text, fm):
    """For posts first published on LinkedIn, date them by the LinkedIn post
    and add linkedin-url, which _partials/title-metadata.html renders as
    "<date> on LinkedIn" with the link."""
    url = fm.get("published-url", "")
    if "linkedin.com/" not in url or not text.startswith("---"):
        return text
    end = text.find("\n---", 4)
    if end == -1:
        return text
    lines = text[4:end].splitlines(keepends=True)
    pub = fm.get("published-date", "")
    if pub:
        lines = [("date: " + pub + "\n") if re.match(r"^date\s*:", l) else l for l in lines]
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    # Metadata strings are parsed as Markdown, which turns "--" in a URL into
    # an en dash. Pass the URL as a raw HTML inline so it reaches the page
    # verbatim. chr(96) is a backtick; a literal one would be run by bash here.
    bt = chr(96)
    lines.append('linkedin-url: "' + bt + url + bt + '{=html}"')
    return text[:4] + "".join(lines) + text[end:]

# Website categories, built from the content repo's topics (and a few tags
# where the topic alone misses a post). A post gets every category it matches.
CATEGORY_TOPICS = {
    "A/B testing": ["experimentation", "ab-testing", "randomized-experiments"],
    "Experimental design": ["design-of-experiments"],
    "Power & sample size": ["power-analysis", "covariate-adjustment"],
    "Personalization & causal ML": ["personalization", "causal-ml"],
    "Causal inference": ["causal-inference", "identification", "treatment-effects", "econometrics", "synthetic-control"],
    "Geo-testing": ["geotesting"],
    "Marketing measurement": ["marketing-measurement", "incrementality", "ROI", "ROAS", "lagged-effects",
                              "marketing-science", "influencer-marketing", "direct-mail"],
    "Marketing mix modeling": ["mmm"],
    "Bayesian vs. frequentist": ["bayesian", "frequentist", "estimation", "confidence-intervals"],
    "Statistical thinking": ["statistics", "philosophy", "statistical-philosophy", "fraud", "model-selection"],
}
CATEGORY_TAGS = {
    "variance-reduction": "Power & sample size",
    "geotest": "Geo-testing",
    "mmm": "Marketing mix modeling",
}
TOPIC_CATEGORY = {t: c for c, ts in CATEGORY_TOPICS.items() for t in ts}
unmapped_topics = {}

def flow_list(raw, key):
    """Items of a YAML flow list like  key: [a, b]  (may wrap over lines)."""
    m = re.search(r"^" + key + r":\s*\[(.*?)\]", raw, re.M | re.S)
    return [x.strip().strip("\"'") for x in m.group(1).split(",") if x.strip()] if m else []

def add_categories(text, rel):
    """Add a categories list derived from topics/tags, unless the post has one."""
    if not text.startswith("---"):
        return text
    end = text.find("\n---", 4)
    if end == -1:
        return text
    raw = text[4:end]
    if re.search(r"^categories\s*:", raw, re.M):
        return text
    cats = []
    for t in flow_list(raw, "topics"):
        if t in TOPIC_CATEGORY:
            cats.append(TOPIC_CATEGORY[t])
        else:
            unmapped_topics.setdefault(t, []).append(str(rel))
    cats += [CATEGORY_TAGS[t] for t in flow_list(raw, "tags") if t in CATEGORY_TAGS]
    cats = [c for c in CATEGORY_TOPICS if c in cats]   # dedupe, fixed order
    if not cats:
        return text
    sep = "" if raw.endswith("\n") else "\n"
    return text[:end] + sep + "categories: " + json.dumps(cats, ensure_ascii=False) + text[end:]

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
    # Copy file, minus frontmatter keys that clash with Quarto options
    rel = path.relative_to(src_root)
    dest = dest_root / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    text = linkedin_meta(strip_keys(path.read_text(encoding="utf-8")), fm)
    text = add_categories(text, rel)
    # The site renders HTML only, but Quarto still links a PDF for a declared
    # pdf format. Ship the content repo's rendered PDF if there is one;
    # otherwise drop the pdf format so no dead link appears.
    pdf = path.with_suffix(".pdf")
    if pdf.is_file():
        shutil.copy2(pdf, dest.with_suffix(".pdf"))
    else:
        text = strip_pdf_format(text)
    dest.write_text(text, encoding="utf-8")
    shutil.copystat(path, dest)
    # Copy sibling bibliography files (papers declare a references.bib)
    for bib in path.parent.glob("*.bib"):
        shutil.copy2(bib, dest.parent / bib.name)
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
for topic, files in sorted(unmapped_topics.items()):
    print(f"[sync] topic without a website category: {topic} ({', '.join(files)})")
print(f"[sync] manifest: {manifest}")
PYEOF

echo
echo "[sync] done. Next: run 'quarto render' to build the site."
