// Rendering-safety tests.
//
//   node tests/rendering.test.mjs
//
// Card text is imported content: a deck can be shared, downloaded, or written
// by someone else. Qt's `Text` defaults to `Text.AutoText`, which sniffs its
// input and switches to rich text when it looks like markup — at which point
// `<img src="http://…">` in a card makes the shell fetch that URL, reaching
// local, loopback, or remote resources chosen by whoever wrote the deck.
//
// The fix is at the renderer, not the parser: cards are *supposed* to contain
// arbitrary characters, so sanitising them would corrupt legitimate cards
// (a card teaching HTML, say). Forcing `Text.PlainText` means markup is shown
// as the literal text it is.
//
// These tests read the QML as source. They cannot prove Qt honours the
// property — only that every sink declares it, which is the part that rots
// when someone adds a Text six months from now.

import { readFileSync, readdirSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const qmlFiles = readdirSync(root).filter((f) => f.endsWith(".qml")).sort()

let pass = 0, fail = 0
const t = (name, cond) => {
  if (cond) { pass++; console.log("  ok   " + name) }
  else { fail++; console.log("  FAIL " + name) }
}
const group = (name) => console.log("\n" + name)

// `Text` is the renderer. `PanelSectionHeader` is a bare Text subclass from
// qs.Ui — none of the shared Ui components set textFormat, so anything built
// on them inherits AutoText and has to be corrected where it is instantiated.
const OPEN = /(?<![A-Za-z_.])(Text|PanelSectionHeader)\s*\{/g

function declarations(src) {
  const out = []
  for (const m of src.matchAll(OPEN)) {
    const open = src.indexOf("{", m.index)
    let depth = 0, i = open
    for (; i < src.length; i++) {
      if (src[i] === "{") depth++
      else if (src[i] === "}" && --depth === 0) break
    }
    out.push({ kind: m[1], line: src.slice(0, open).split("\n").length, body: src.slice(open, i) })
  }
  return out
}

group("every text sink forces plain text")
{
  t("the plugin has QML to check at all", qmlFiles.length > 0)

  let checked = 0
  const unhardened = []
  for (const file of qmlFiles) {
    const src = readFileSync(join(root, file), "utf8")
    for (const d of declarations(src)) {
      checked++
      if (!/textFormat:\s*Text\.PlainText/.test(d.body))
        unhardened.push(`${file}:${d.line} ${d.kind}`)
    }
  }

  t(`all ${checked} declarations are plain text`, unhardened.length === 0)
  if (unhardened.length) unhardened.forEach((u) => console.log("         " + u))
  t("there are sinks to harden, so the check is not vacuous", checked > 20)
}

group("no sink opts back into interpreting markup")
{
  const offenders = []
  for (const file of qmlFiles) {
    const src = readFileSync(join(root, file), "utf8")
    if (/textFormat:\s*Text\.(RichText|AutoText|StyledText|MarkdownText)/.test(src)) offenders.push(file)
  }
  t("no RichText, AutoText, StyledText or MarkdownText anywhere", offenders.length === 0)
}

group("the card face specifically")
{
  const reviewer = readFileSync(join(root, "Reviewer.qml"), "utf8")
  const declared = declarations(reviewer)
  // The question/answer text itself.
  const wording = declared.filter((d) =>
    /text:\s*root\.current\s*\?\s*root\.current\.(front|back)\s*:/.test(d.body))
  // The audio-replay glyphs, identified by the literal speaker character.
  const glyphs = declared.filter((d) => d.body.includes("\u{f057e}"))

  t("both card sinks are found", wording.length === 2)
  t("the question is plain text",
    wording.some((d) => /front/.test(d.body) && /textFormat:\s*Text\.PlainText/.test(d.body)))
  t("the answer is plain text",
    wording.some((d) => /back/.test(d.body) && /textFormat:\s*Text\.PlainText/.test(d.body)))
  t("both speaker glyphs are found",
    glyphs.length === 2 && glyphs.some((d) => /right/.test(d.body)) && glyphs.some((d) => /left/.test(d.body)))
  t("the speaker glyphs are plain text too",
    glyphs.every((d) => /textFormat:\s*Text\.PlainText/.test(d.body)))
}

group("the parser deliberately does not sanitise")
{
  // Safety belongs to the renderer. A card about HTML must survive intact, so
  // the parser is expected to hand markup through untouched — these tests
  // exist so nobody "fixes" this by stripping tags and quietly corrupting
  // legitimate cards.
  const src = readFileSync(join(root, "Anki.js"), "utf8")
  const G = {}
  new Function("exports", `${src}\nexports.parseDeck = parseDeck`)(G)

  const hostile = '<img src="http://example.invalid/pixel.png">'
  const deck = G.parseDeck(JSON.stringify({ cards: [{ front: hostile, back: "<b>x</b>" }] }))

  t("markup in a front survives verbatim", deck.cards[0].front === hostile)
  t("markup in a back survives verbatim", deck.cards[0].back === "<b>x</b>")
  t("no card is dropped for containing markup", deck.cards.length === 1)
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
