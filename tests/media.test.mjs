// Media-card tests for the omanki plugin.
//
//   node tests/media.test.mjs
//
// Two things are checked separately, the way Anki.js separates them: parsing
// (pure JS, run under plain node) decides which filenames a card may even
// name, and MEDIA_VALIDATE_SH (plain sh, run against real directories)
// decides whether one of those filenames is safe to hand to an Image or a
// MediaPlayer as an absolute path.

import { spawnSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Anki.js"), "utf8")

const EXPORTS = [
  "parseDeck", "collectMediaFilenames", "attachMediaPaths", "mediaDirFor",
  "MEDIA_VALIDATE_SH", "dirOf",
]
const G = {}
new Function("exports", `${source}\nfor (const k of ${JSON.stringify(EXPORTS)}) exports[k] = eval(k)`)(G)

let pass = 0, fail = 0
const t = (name, cond) => {
  if (cond) { pass++; console.log("  ok   " + name) }
  else { fail++; console.log("  FAIL " + name) }
}
const group = (name) => console.log("\n" + name)

// ------------------------------------------------------------------ parsing

group("parseDeck accepts media fields on a card")
{
  const deck = G.parseDeck(JSON.stringify({
    cards: [{ front: "Number 12", back: "tin, ton, den", frontAudio: "12.ogg", tags: ["major-system"] }]
  }))
  t("the card survives", deck.cards.length === 1)
  t("the audio filename is kept", deck.cards[0].frontAudio === "12.ogg")
  t("an absent field defaults to empty", deck.cards[0].backAudio === "")
  t("an absent image field defaults to empty", deck.cards[0].frontImage === "")
}

group("parseDeck refuses a media field that is a path, not a filename")
{
  const hostile = [
    "../../etc/passwd", "/etc/passwd", "sub/dir/file.png", "a\\b.png", "..", ".",
  ]
  for (const name of hostile) {
    const deck = G.parseDeck(JSON.stringify({
      cards: [{ front: "f " + name, back: "b", frontImage: name }]
    }))
    t(`"${name}" is dropped rather than kept`, deck.cards[0].frontImage === "")
    t(`"${name}" does not cost the card its front/back`, deck.cards[0].front && deck.cards[0].back)
  }
}

group("parseDeck leaves ordinary text-only cards exactly as before")
{
  const deck = G.parseDeck(JSON.stringify({ cards: [{ front: "Q", back: "A", tags: ["x"] }] }))
  const card = deck.cards[0]
  t("front and back are unaffected", card.front === "Q" && card.back === "A")
  t("every media field defaults empty",
    card.frontImage === "" && card.backImage === "" && card.frontAudio === "" && card.backAudio === "")
}

group("collectMediaFilenames")
{
  const cards = G.parseDeck(JSON.stringify({
    cards: [
      { front: "a", back: "b", frontImage: "x.png", frontAudio: "x.png" },
      { front: "c", back: "d", backImage: "y.jpg" },
      { front: "e", back: "f" },
    ]
  })).cards

  const names = G.collectMediaFilenames(cards)
  t("distinct filenames only, in first-seen order", names.join(",") === "x.png,y.jpg")
}

group("attachMediaPaths")
{
  const cards = G.parseDeck(JSON.stringify({
    cards: [{ front: "a", back: "b", frontImage: "x.png", backAudio: "missing.ogg" }]
  })).cards

  const out = G.attachMediaPaths(cards, { "x.png": "/home/u/.local/share/omanki/media/x.png" })
  t("a validated filename becomes its resolved path",
    out[0].frontImagePath === "/home/u/.local/share/omanki/media/x.png")
  t("a filename missing from the map resolves to empty",
    out[0].backAudioPath === "")
  t("the original card is not mutated", cards[0].frontImagePath === undefined)
  t("fields the card never set also resolve to empty",
    out[0].backImagePath === "" && out[0].frontAudioPath === "")
}

group("mediaDirFor")
{
  t("sits beside the deck file", G.mediaDirFor("/home/u/.local/share/omanki/cards.json")
    === "/home/u/.local/share/omanki/media")
}

// -------------------------------------------------------- MEDIA_VALIDATE_SH
//
// Run as plain sh against real directories, the same way READ_SH/WRITE_SH
// are — what matters is that a filename cannot walk out of the media
// directory, by traversal or by a symlink at any point along the way.

const sh = (script, home, rel, input) =>
  spawnSync("sh", ["-c", script, "omanki-media", home, rel],
            { input: input ?? "", encoding: "utf8" })

const REL = ".local/share/omanki/media"

function makeMediaHome() {
  const home = mkdtempSync(join(tmpdir(), "omanki-media-home-"))
  const mediaDir = join(home, REL)
  mkdirSync(mediaDir, { recursive: true })
  writeFileSync(join(mediaDir, "face.jpg"), "jpg-bytes")
  return { home, mediaDir }
}

group("a real file inside the media directory validates")
{
  const { home, mediaDir } = makeMediaHome()
  const r = sh(G.MEDIA_VALIDATE_SH, home, REL, "face.jpg\n")
  t("exits cleanly", r.status === 0)
  t("prints the file's real path", r.stdout.trim() === join(mediaDir, "face.jpg"))
}

group("filenames are matched back up by position, one line per name")
{
  const { home } = makeMediaHome()
  const r = sh(G.MEDIA_VALIDATE_SH, home, REL, "face.jpg\nmissing.png\nface.jpg\n")
  const lines = r.stdout.split("\n")
  t("three names in, three lines out (plus the trailing newline)",
    lines.length === 4 && lines[3] === "")
  t("the real file resolves on both mentions", lines[0] !== "" && lines[2] !== "")
  t("the missing one resolves to a blank line", lines[1] === "")
}

group("traversal and absolute paths never reach the filesystem check")
{
  const { home } = makeMediaHome()
  for (const name of ["../face.jpg", "/etc/passwd", "sub/face.jpg", ".", ".."]) {
    const r = sh(G.MEDIA_VALIDATE_SH, home, REL, name + "\n")
    t(`"${name}" resolves to a blank line`, r.stdout === "\n")
  }
}

group("a symlinked file inside the media directory is refused")
{
  const { home, mediaDir } = makeMediaHome()
  const decoy = mkdtempSync(join(tmpdir(), "omanki-media-decoy-"))
  writeFileSync(join(decoy, "secret.txt"), "not yours")
  symlinkSync(join(decoy, "secret.txt"), join(mediaDir, "link.jpg"))

  const r = sh(G.MEDIA_VALIDATE_SH, home, REL, "link.jpg\n")
  t("the symlinked entry resolves to a blank line, not the decoy's path", r.stdout === "\n")
}

group("a symlink planted at the media directory itself is refused")
{
  const home = mkdtempSync(join(tmpdir(), "omanki-media-home-"))
  mkdirSync(join(home, ".local/share/omanki"), { recursive: true })
  const decoy = mkdtempSync(join(tmpdir(), "omanki-media-decoy-"))
  writeFileSync(join(decoy, "face.jpg"), "not yours")
  symlinkSync(decoy, join(home, REL))

  const r = sh(G.MEDIA_VALIDATE_SH, home, REL, "face.jpg\n")
  t("the whole call is refused rather than reading through the link", r.status === 65)
  t("nothing is printed", r.stdout === "")
}

group("a missing media directory validates nothing, rather than erroring")
{
  const home = mkdtempSync(join(tmpdir(), "omanki-media-home-"))
  const r = sh(G.MEDIA_VALIDATE_SH, home, REL, "face.jpg\n")
  t("exits cleanly", r.status === 0)
  t("nothing is printed — the caller reads this as every name being invalid", r.stdout === "")
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
