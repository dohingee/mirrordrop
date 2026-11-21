"""
Builds the App Store listing text for fastlane deliver (ios/fastlane/metadata) from the one source,
docs/store/ko.md and docs/store/en.md, and checks it against App Store Connect's limits.

  python .github/scripts/store-metadata.py          # rewrite ios/fastlane/metadata (run after editing docs/store)
  python .github/scripts/store-metadata.py --check  # fail if a limit or rule is broken, or the files are stale

The iOS App Store listing workflow (ios-store.yml) runs --check first, on Ubuntu, before any macOS time.
What each docs/store section holds: the numbered headings there ("## 4. 설명", "## 4. Description",
"### 9-1."), each with one ```text block. The review contact (name, phone, email) is never written
here: the workflow adds it at run time from GitHub repository variables (docs/SETUP.md 5).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "ios" / "fastlane" / "metadata"

# Demo video for App Review (docs/RELEASE.md 5). Replaces <VIDEO_URL> in the review notes.
DEMO_VIDEO_URL = "https://mirrordrop-app.web.app/review/demo.mp4"

# App Store Connect locale folder -> source document, section numbers, URL labels in its bullet list.
SECTIONS = {"name": "1", "subtitle": "2", "promotional_text": "3", "description": "4",
            "keywords": "5", "release_notes": "6"}
LOCALES = {
    "ko": ("docs/store/ko.md", {"privacy_url": "개인정보 처리방침 URL", "support_url": "지원 URL",
                                "marketing_url": "마케팅 URL"}),
    "en-US": ("docs/store/en.md", {"privacy_url": "Privacy Policy URL", "support_url": "Support URL",
                                   "marketing_url": "Marketing URL"}),
}
# App Store Connect help "Platform version information" / "App information" (checked 2026-11-22).
# Characters, except keywords: bytes in UTF-8 (a Hangul syllable is 3 bytes).
CHAR_LIMITS = {"name": 30, "subtitle": 30, "promotional_text": 170, "description": 4000,
               "release_notes": 4000, "notes": 4000}
KEYWORD_BYTES = 100
# docs/store/ko.md rules: no trademarks in the name, subtitle or keywords.
FORBIDDEN = re.compile(r"chromecast|google", re.I)
# English category names as written in docs/store/ko.md 7 -> App Store Connect IDs.
CATEGORIES = {"Photo & Video": "PHOTO_AND_VIDEO", "Utilities": "UTILITIES", "Entertainment": "ENTERTAINMENT",
              "Lifestyle": "LIFESTYLE", "Productivity": "PRODUCTIVITY"}


def sections(md: str) -> dict[str, str]:
    """Section number ("4", "9-1") -> its first ```text block."""
    out = {}
    # Split at every heading, so a block is only taken from its own section.
    parts = re.split(r"^(#{1,6} .*)$", md, flags=re.M)
    for heading, body in zip(parts[1::2], parts[2::2]):
        num = re.match(r"#{2,3} (\d+(?:-\d+)?)\. ", heading)
        block = re.search(r"^```text\n(.*?)\n```", body, re.S | re.M)
        if num and block:
            out.setdefault(num.group(1), block.group(1).strip())
    return out


def build() -> tuple[dict[str, str], list[str]]:
    """Relative path under metadata/ -> content, and the list of problems."""
    files, problems = {}, []

    def need(cond: bool, msg: str):
        if not cond:
            problems.append(msg)

    for locale, (doc, url_labels) in LOCALES.items():
        md = (ROOT / doc).read_text(encoding="utf-8")
        sec = sections(md)
        for key, num in SECTIONS.items():
            text = sec.get(num)
            need(text is not None, f"{doc}: no ```text block under section {num} ({key})")
            if text is None:
                continue
            files[f"{locale}/{key}.txt"] = text
            if key == "keywords":
                size = len(text.encode("utf-8"))
                need(size <= KEYWORD_BYTES, f"{locale} keywords: {size} bytes, limit {KEYWORD_BYTES}")
                need(", " not in text, f"{locale} keywords: no space after commas (it counts as a byte)")
            else:
                need(len(text) <= CHAR_LIMITS[key], f"{locale} {key}: {len(text)} characters, limit {CHAR_LIMITS[key]}")
            if key in ("name", "subtitle", "keywords"):
                need(not FORBIDDEN.search(text), f"{locale} {key}: contains a trademark (Chromecast/Google): {text!r}")
        for key, label in url_labels.items():
            m = re.search(re.escape(label) + r":\s*`(https://[^`\s]+)`", md)
            need(m is not None, f"{doc}: no https URL after '{label}:'")
            if m:
                files[f"{locale}/{key}.txt"] = m.group(1)

    ko = (ROOT / "docs/store/ko.md").read_text(encoding="utf-8")
    sec = sections(ko)
    for slot, label in (("primary_category", "기본"), ("secondary_category", "보조")):
        m = re.search(r"^- " + label + r": \*\*[^*]+\*\*\(([^)]+)\)", ko, re.M)
        cat = CATEGORIES.get(m.group(1)) if m else None
        need(cat is not None, f"docs/store/ko.md 7: '{label}' category not found or unknown "
                              f"({m.group(1) if m else 'missing'}; known: {', '.join(CATEGORIES)})")
        if cat:
            files[f"{slot}.txt"] = cat
    copyright_ = sec.get("8")
    need(bool(copyright_), "docs/store/ko.md: no copyright text in section 8")
    if copyright_:
        need("@" not in copyright_, "copyright: no email address")
        files["copyright.txt"] = copyright_
    notes = sec.get("9-1")
    need(bool(notes), "docs/store/ko.md: no review notes in section 9-1")
    if notes:
        notes = notes.replace("<VIDEO_URL>", DEMO_VIDEO_URL)
        need("<" not in notes, "review notes: a <PLACEHOLDER> is left")
        need(len(notes) <= CHAR_LIMITS["notes"], f"review notes: {len(notes)} characters, limit {CHAR_LIMITS['notes']}")
        files["review_information/notes.txt"] = notes
    return files, problems


def main() -> int:
    check = "--check" in sys.argv[1:]
    files, problems = build()
    for rel, text in sorted(files.items()):
        unit = "bytes" if rel.endswith("keywords.txt") else "chars"
        n = len(text.encode("utf-8")) if unit == "bytes" else len(text)
        print(f"{rel:40} {n:5} {unit}")
    if check:
        # The workflow adds the review contact files at run time; anything else must match the docs.
        existing = {p.relative_to(OUT).as_posix() for p in OUT.rglob("*.txt")} if OUT.exists() else set()
        for rel in sorted(existing | set(files)):
            path = OUT / rel
            if rel not in files:
                problems.append(f"ios/fastlane/metadata/{rel} has no source in docs/store (delete it)")
            elif not path.exists() or path.read_text(encoding="utf-8").strip() != files[rel]:
                problems.append(f"ios/fastlane/metadata/{rel} differs from docs/store: run python .github/scripts/store-metadata.py")
    else:
        for rel, text in files.items():
            path = OUT / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text + "\n", encoding="utf-8", newline="\n")
    for p in problems:
        print(f"::error::{p}" if check else f"PROBLEM: {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
