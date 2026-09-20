#!/usr/bin/env python3
"""Convert an Anki .apkg into an omanki deck ({"cards": [{front, back, tags}]}).

Standard library only. Handles the three collection layouts found in packages:
  collection.anki2    legacy schema, notetypes as JSON in col.models
  collection.anki21   same, written by Anki 2.1
  collection.anki21b  zstd-compressed, notetypes in their own tables

What converts: notes whose notetype is not cloze and has at least two fields;
field 1 becomes the front, field 2 the back. Everything else is skipped and
counted, never guessed at. Anki's scheduling is discarded on purpose - omanki
keeps its own.
"""
import argparse
import html
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import zipfile

# Matches READ_LIMIT in Anki.js (262144). A part stays under this with margin,
# because the plugin refuses a deck whose read reaches the limit.
PART_LIMIT = 250_000
# Guards against a hostile package: nothing legitimate needs more than this.
MAX_DB_BYTES = 512 * 1024 * 1024

SEP = "\x1f"
BLOCK = re.compile(r"</?(?:div|p|li|tr|ul|ol|table|h[1-6])\b[^>]*>", re.I)
BR = re.compile(r"<br\s*/?>", re.I)
IMG = re.compile(r"<img\b[^>]*>", re.I)
TAG = re.compile(r"<[^>]*>")
SOUND = re.compile(r"\[sound:[^\]]*\]")
LATEX = re.compile(r"\[/?\$*\]|\[latex\].*?\[/latex\]", re.I | re.S)


class Stats:
    def __init__(self):
        self.notes = 0
        self.cards = 0
        self.cloze = 0
        self.too_few_fields = 0
        self.empty = 0
        self.duplicate = 0
        self.media = 0
        self.extra_fields = 0


def clean(value, stats):
    """Anki fields are HTML; omanki renders plain text, so leave no markup."""
    stats.media += len(IMG.findall(value)) + len(SOUND.findall(value))
    value = IMG.sub("", value)
    value = SOUND.sub("", value)
    value = BR.sub("\n", value)
    value = BLOCK.sub("\n", value)
    value = TAG.sub("", value)
    value = html.unescape(value).replace("\xa0", " ")
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in value.splitlines()]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def decompress(data):
    try:
        from compression import zstd  # Python 3.14+
        return zstd.decompress(data)
    except ImportError:
        pass
    try:
        import zstandard
        return zstandard.ZstdDecompressor().decompressobj().decompress(data)
    except ImportError:
        pass
    if shutil.which("zstd"):
        r = subprocess.run(["zstd", "-dc"], input=data, capture_output=True)
        if r.returncode == 0:
            return r.stdout
    sys.exit("This package uses zstd compression. Use Python 3.14+, "
             "`pip install zstandard`, or install the `zstd` command.")


def open_collection(pkg, workdir):
    names = set(pkg.namelist())
    for name in ("collection.anki21b", "collection.anki21", "collection.anki2"):
        if name in names:
            break
    else:
        sys.exit("Not an Anki package: no collection.anki2/anki21/anki21b inside.")

    if pkg.getinfo(name).file_size > MAX_DB_BYTES:
        sys.exit("Collection is larger than %d MiB; refusing." % (MAX_DB_BYTES >> 20))
    data = pkg.read(name)
    if name.endswith("b"):
        data = decompress(data)
        if len(data) > MAX_DB_BYTES:
            sys.exit("Collection is larger than %d MiB; refusing." % (MAX_DB_BYTES >> 20))

    path = os.path.join(workdir, "collection.db")
    with open(path, "wb") as f:
        f.write(data)
    return sqlite3.connect("file:%s?mode=ro" % path, uri=True)


def notetypes(db):
    """{id: {"name", "cloze", "fields", "templates"}} for either schema."""
    out = {}
    tables = {r[0] for r in db.execute("select name from sqlite_master where type='table'")}
    if "notetypes" in tables:
        for ntid, name, config in db.execute("select id, name, config from notetypes"):
            # config is a protobuf blob; kind 1 in field 1 marks cloze, but
            # the name check below is the fallback that survives format drift.
            out[ntid] = {"name": name, "cloze": False, "fields": [], "templates": 0}
        for ntid, name in db.execute("select ntid, name from fields order by ntid, ord"):
            if ntid in out:
                out[ntid]["fields"].append(name)
        for ntid, in db.execute("select ntid from templates"):
            if ntid in out:
                out[ntid]["templates"] += 1
        for ntid, cfg in db.execute("select id, config from notetypes"):
            # Cloze notetypes store kind=1 as the first varint pair (0x08 0x01).
            if isinstance(cfg, (bytes, bytearray)) and cfg[:2] == b"\x08\x01":
                out[ntid]["cloze"] = True
    else:
        models = json.loads(db.execute("select models from col").fetchone()[0])
        for key, m in models.items():
            out[int(key)] = {
                "name": m.get("name", ""),
                "cloze": m.get("type") == 1,
                "fields": [f["name"] for f in sorted(m["flds"], key=lambda f: f["ord"])],
                "templates": len(m.get("tmpls", [])),
            }
    for nt in out.values():
        if re.search(r"cloze", nt["name"], re.I):
            nt["cloze"] = True
    return out


def convert(db, reverse, stats):
    types = notetypes(db)
    cards, seen = [], set()

    def add(front, back, tags):
        if not front or not back:
            stats.empty += 1
        elif front in seen:
            stats.duplicate += 1
        else:
            seen.add(front)
            card = {"front": front, "back": back}
            if tags:
                card["tags"] = tags
            cards.append(card)

    for ntid, flds, tags in db.execute("select mid, flds, tags from notes order by id"):
        stats.notes += 1
        nt = types.get(ntid)
        if nt is None or nt["cloze"]:
            stats.cloze += 1
            continue
        fields = flds.split(SEP)
        if len(fields) < 2:
            stats.too_few_fields += 1
            continue
        if len(fields) > 2:
            stats.extra_fields += 1

        front, back = clean(fields[0], stats), clean(fields[1], stats)
        tag_list = [t for t in tags.split() if t.lower() != "leech"]
        add(front, back, tag_list)
        # "Basic (and reversed card)" has two templates over the same two fields.
        if reverse and nt["templates"] == 2:
            add(back, front, tag_list)

    stats.cards = len(cards)
    return cards


def write_parts(cards, base):
    """One file if it fits, else base-1.json, base-2.json, ... each under the cap."""
    parts, cur, size = [], [], 0
    for card in cards:
        line = json.dumps(card, ensure_ascii=False)
        n = len(line.encode("utf-8")) + 6
        if cur and size + n > PART_LIMIT:
            parts.append(cur)
            cur, size = [], 0
        cur.append(line)
        size += n
    parts.append(cur)

    root, ext = os.path.splitext(base)
    paths = [base] if len(parts) == 1 else ["%s-%d%s" % (root, i + 1, ext) for i in range(len(parts))]
    return parts, paths


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("apkg")
    ap.add_argument("-o", "--output", required=True,
                    help="deck to write, e.g. ~/.local/share/omanki/cards.json")
    ap.add_argument("--reverse", action="store_true",
                    help="also emit the reverse card of 'Basic (and reversed card)' notes")
    ap.add_argument("--force", action="store_true", help="overwrite existing output")
    args = ap.parse_args()

    stats = Stats()
    with tempfile.TemporaryDirectory() as tmp, zipfile.ZipFile(args.apkg) as pkg:
        db = open_collection(pkg, tmp)
        cards = convert(db, args.reverse, stats)
        db.close()

    if not cards:
        sys.exit("No convertible cards found (%d notes; %d cloze/unknown, %d with under two fields)."
                 % (stats.notes, stats.cloze, stats.too_few_fields))

    out = os.path.expanduser(args.output)
    parts, paths = write_parts(cards, out)
    if not args.force:
        for p in paths:
            if os.path.exists(p):
                sys.exit("%s exists; pass --force to overwrite (it may be your deck)." % p)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    for lines, p in zip(parts, paths):
        with open(p, "w", encoding="utf-8") as f:
            f.write('{\n"cards": [\n' + ",\n".join(lines) + "\n]\n}\n")

    print("%d notes -> %d cards in %d file%s:" % (stats.notes, stats.cards, len(paths), "s" if len(paths) > 1 else ""))
    for p in paths:
        print("  " + p)
    for n, what in [
        (stats.cloze, "skipped: cloze or unknown notetype"),
        (stats.too_few_fields, "skipped: fewer than two fields"),
        (stats.empty, "skipped: empty front or back after stripping"),
        (stats.duplicate, "skipped: duplicate front"),
        (stats.extra_fields, "with extra fields beyond front/back (dropped)"),
        (stats.media, "images or sounds removed"),
    ]:
        if n:
            print("  %d %s" % (n, what))
    if len(paths) > 1:
        print("Each file is one deck under omanki's 256 KiB cap; point the `deck` setting at one.")


if __name__ == "__main__":
    main()
