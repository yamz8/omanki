---
name: apkg-to-omanki
description: Convert an Anki .apkg deck into an omanki deck (cards.json). Use when the user has a shared or exported Anki package and wants to study it in omanki, or asks to "import", "convert" or "use" an .apkg / Anki deck with omanki.
---

# Convert an Anki `.apkg` for omanki

omanki's deck is `{ "cards": [{ "front", "back", "tags" }] }`, plain text, capped
at 256 KiB per file. An `.apkg` is a zip of SQLite plus media. `convert.py`
(next to this file, standard library only) does the one-shot conversion.

## Run it

```bash
python3 convert.py path/to/deck.apkg -o ~/.local/share/omanki/cards.json
```

- **It will not overwrite a file.** `~/.local/share/omanki/cards.json` may be
  the user's real deck, so an existing output needs `--force`, which you should
  only pass after the user has said to replace it. To keep both, write to a
  second file and point omanki's `deck` setting at it.
- `--reverse` also emits the reverse card for "Basic (and reversed card)" notes.
  Ask before using it; it doubles those cards.
- Newer packages (`collection.anki21b`) are zstd-compressed. That needs Python
  3.14+, the `zstandard` module, or the `zstd` command. The script says so if
  none is present.

## What to expect, and what to tell the user

The script prints what it did. Relay the counts, especially anything skipped:

- **Converted:** non-cloze notes with two or more fields. Field 1 is the front,
  field 2 the back. Tags carry through (Anki's `leech` tag is dropped; omanki
  tracks leeches itself).
- **Skipped, and counted:** cloze notes, notes with fewer than two fields,
  notes whose front or back is empty once markup is stripped, and duplicate
  fronts (omanki keeps one schedule per front).
- **Dropped silently by design:** fields beyond the second (reported as a
  count), Anki scheduling (omanki keeps its own), and all images and audio.
  HTML is reduced to plain text because omanki renders plain text only. A deck
  that depends on pictures or audio will lose the part that mattered; say so.
- **Split:** past 256 KiB the output becomes `name-1.json`, `name-2.json`, ...
  Each is a complete deck. omanki reads one file at a time via the `deck`
  setting, so the user picks which to study. Do not concatenate them back.

After writing, the plugin picks the deck up on its next reload (`r` in the
panel). Do not touch `~/.local/state/omarchy/omanki.json`; that is progress.
