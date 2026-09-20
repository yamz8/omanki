#!/usr/bin/env python3
"""Tests for skills/apkg-to-omanki/convert.py. Packages are built in memory, so
no binary fixtures live in the repo."""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
CONVERT = os.path.join(HERE, "..", "skills", "apkg-to-omanki", "convert.py")
SEP = "\x1f"

passed = failed = 0


def t(name, ok):
    global passed, failed
    if ok:
        passed += 1
        print("  ok   " + name)
    else:
        failed += 1
        print("  FAIL " + name)


def sqlite_bytes(build):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "c.db")
        db = sqlite3.connect(p)
        build(db)
        db.commit()
        db.close()
        return open(p, "rb").read()


def legacy(notes, models):
    def build(db):
        db.execute("create table col (models text)")
        db.execute("insert into col values (?)", (json.dumps(models),))
        db.execute("create table notes (id integer, mid integer, flds text, tags text)")
        for i, (mid, flds, tags) in enumerate(notes):
            db.execute("insert into notes values (?,?,?,?)", (i, mid, SEP.join(flds), tags))
    return sqlite_bytes(build)


def modern(notes, types):
    """types: {id: (name, [fields], template_count, is_cloze)}"""
    def build(db):
        db.execute("create table notetypes (id integer, name text, config blob)")
        db.execute("create table fields (ntid integer, ord integer, name text)")
        db.execute("create table templates (ntid integer, ord integer)")
        for ntid, (name, flds, tmpls, cloze) in types.items():
            db.execute("insert into notetypes values (?,?,?)", (ntid, name, b"\x08\x01" if cloze else b"\x10\x02"))
            for o, f in enumerate(flds):
                db.execute("insert into fields values (?,?,?)", (ntid, o, f))
            for o in range(tmpls):
                db.execute("insert into templates values (?,?)", (ntid, o))
        db.execute("create table notes (id integer, mid integer, flds text, tags text)")
        for i, (mid, flds, tags) in enumerate(notes):
            db.execute("insert into notes values (?,?,?,?)", (i, mid, SEP.join(flds), tags))
    return sqlite_bytes(build)


def package(d, members):
    p = os.path.join(d, "x.apkg")
    with zipfile.ZipFile(p, "w") as z:
        for name, data in members.items():
            z.writestr(name, data)
    return p


def run(pkg, out, *extra):
    r = subprocess.run([sys.executable, CONVERT, pkg, "-o", out, *extra], capture_output=True, text=True)
    return r


def load(path):
    return json.load(open(path, encoding="utf-8"))["cards"]


BASIC = {"1": {"name": "Basic", "type": 0, "tmpls": [{}], "flds": [{"name": "Front", "ord": 0}, {"name": "Back", "ord": 1}]},
         "2": {"name": "Basic (and reversed card)", "type": 0, "tmpls": [{}, {}], "flds": [{"name": "Front", "ord": 0}, {"name": "Back", "ord": 1}]},
         "3": {"name": "Cloze", "type": 1, "tmpls": [{}], "flds": [{"name": "Text", "ord": 0}, {"name": "Extra", "ord": 1}]},
         "4": {"name": "One", "type": 0, "tmpls": [{}], "flds": [{"name": "Only", "ord": 0}]}}

print("legacy schema")
with tempfile.TemporaryDirectory() as d:
    notes = [
        (1, ["hello", "world"], " a b::c leech "),
        (1, ["<div>two</div>lines &amp; more&nbsp;text<br>", "<b>bold</b>"], ""),
        (1, ['pic <img src="x.png">', "[sound:a.mp3]answer"], ""),
        (1, ["hello", "dup"], ""),
        (1, ["", "empty front"], ""),
        (1, ["<img src='only.png'>", "media only front"], ""),
        (2, ["fwd", "back"], "rev"),
        (3, ["{{c1::cloze}} text", ""], ""),
        (4, ["lonely"], ""),
        (1, ["extra", "field", "third"], ""),
    ]
    pkg = package(d, {"collection.anki2": legacy(notes, BASIC)})
    out = os.path.join(d, "deck.json")
    r = run(pkg, out)
    t("exits cleanly", r.returncode == 0)
    cards = load(out)
    by = {c["front"]: c for c in cards}
    t("basic note converts", by["hello"]["back"] == "world")
    t("tags carry through and leech is dropped", by["hello"]["tags"] == ["a", "b::c"])
    t("html becomes plain text", "two\nlines & more text" in by and by["two\nlines & more text"]["back"] == "bold")
    t("images and sounds are removed", by["pic"]["back"] == "answer")
    t("duplicate front keeps the first", by["hello"]["back"] == "world")
    t("empty front is dropped", "" not in by and "media only front" not in [c["back"] for c in cards])
    t("cloze and one-field notes are skipped", "lonely" not in by and not any("cloze" in f for f in by))
    t("extra fields are dropped, not merged", by["extra"]["back"] == "field")
    t("no reverse card by default", "back" not in by)
    t("report counts skipped notes", "1 skipped: cloze or unknown notetype" in r.stdout and "2 skipped: empty" in r.stdout)

    out2 = os.path.join(d, "rev.json")
    run(pkg, out2, "--reverse")
    t("--reverse emits the reversed card", "back" in {c["front"] for c in load(out2)})

    r = run(pkg, out)
    t("refuses to overwrite without --force", r.returncode != 0 and "exists" in r.stderr)
    t("--force overwrites", run(pkg, out, "--force").returncode == 0)

print("modern schema")
with tempfile.TemporaryDirectory() as d:
    types = {10: ("Basic", ["Front", "Back"], 1, False), 11: ("Cloze", ["Text", "Extra"], 1, True)}
    notes = [(10, ["q", "a"], "t"), (11, ["{{c1::x}}", ""], "")]
    db = modern(notes, types)
    dummy = legacy([(1, ["Update Anki", "to see this"], "")], BASIC)
    try:
        from compression import zstd
        z = zstd.compress(db)
    except ImportError:
        z = None
    if z is not None:
        pkg = package(d, {"collection.anki2": dummy, "collection.anki21b": z})
        out = os.path.join(d, "deck.json")
        r = run(pkg, out)
        cards = load(out)
        t("prefers the real collection over the dummy", [c["front"] for c in cards] == ["q"])
        t("cloze is detected from the modern notetype", "cloze" in r.stdout)
    else:
        print("  skip zstd (needs Python 3.14+)")
    pkg = package(d, {"collection.anki21": db})
    out = os.path.join(d, "u.json")
    t("uncompressed modern tables also work", run(pkg, out).returncode == 0 and load(out)[0]["back"] == "a")

print("limits and errors")
with tempfile.TemporaryDirectory() as d:
    notes = [(1, ["question %d " % i + "x" * 200, "answer " + "y" * 200], "") for i in range(2000)]
    pkg = package(d, {"collection.anki2": legacy(notes, BASIC)})
    out = os.path.join(d, "big.json")
    r = run(pkg, out)
    files = sorted(f for f in os.listdir(d) if f.startswith("big-"))
    t("an oversized deck is split", r.returncode == 0 and len(files) > 1)
    t("every part is under omanki's read cap",
      all(os.path.getsize(os.path.join(d, f)) < 262144 - 3 for f in files))
    t("no cards are lost in the split", sum(len(load(os.path.join(d, f))) for f in files) == 2000)
    t("the split is announced", "256 KiB" in r.stdout)

    bad = os.path.join(d, "bad.apkg")
    open(bad, "wb").write(b"not a zip")
    t("a file that is not a zip is refused", run(bad, os.path.join(d, "o.json")).returncode != 0)
    empty = package(d, {"readme.txt": "hi"})
    r = run(empty, os.path.join(d, "o2.json"))
    t("a zip without a collection is refused", r.returncode != 0 and "Not an Anki package" in r.stderr)

print("\n%d passed, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
