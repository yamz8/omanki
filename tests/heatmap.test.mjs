// Daily-activity heatmap tests for the omanki plugin.
//
//   node tests/heatmap.test.mjs
//
// There is no review log (see Anki.js's note above answeredOn), so a day's
// count can only be read off cards' current `updated` fields, and only until
// one of those cards is answered again later — after that, the old day's
// share of it is gone for good. These tests are about that constraint:
// freezeActivity has to capture a day before it can be lost, never touch
// today or an already-frozen day, and heatmapGrid has to place today
// correctly and never invent activity for a day that has not happened yet.

import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const source = readFileSync(join(here, "..", "Anki.js"), "utf8")

const EXPORTS = [
  "DAY", "dayKey", "dayOfWeek", "newState", "normalizeState", "emptyProgress",
  "parseProgress", "serializeProgress", "mergeProgress", "answeredOn",
  "freezeActivity", "heatmapGrid", "HEATMAP_WEEKS", "ACTIVITY_MAX_DAYS",
]
const G = {}
new Function("exports", `${source}\nfor (const k of ${JSON.stringify(EXPORTS)}) exports[k] = eval(k)`)(G)

let pass = 0, fail = 0
const t = (name, cond) => {
  if (cond) { pass++; console.log("  ok   " + name) }
  else { fail++; console.log("  FAIL " + name) }
}
const group = (name) => console.log("\n" + name)

const { DAY } = G
const NOW = 1_700_000_000
const TODAY = G.dayKey(NOW)

// A minimal reviews document: one entry per {id, updated}, phase "review" so
// normalizeState keeps it as given.
function reviewsAt(entries) {
  const reviews = {}
  for (const [id, updated] of entries) {
    reviews[id] = { phase: "review", due: updated, interval: DAY, ease: 2500, reps: 1, lapses: 0, step: 0, updated, firstDay: "" }
  }
  return { reviews, activity: {} }
}

group("dayOfWeek")
{
  const week = new Set()
  for (let i = 0; i < 7; i++) week.add(G.dayOfWeek(NOW - i * DAY))
  t("a run of seven consecutive days covers all seven weekdays", week.size === 7)
  t("stepping back exactly a week returns the same weekday",
    G.dayOfWeek(NOW) === G.dayOfWeek(NOW - 7 * DAY))
  const w = G.dayOfWeek(NOW)
  t("in range 0-6", w >= 0 && w <= 6)
}

group("answeredOn")
{
  const yesterday = NOW - DAY
  const progress = reviewsAt([
    ["a", NOW], ["b", NOW],           // today
    ["c", yesterday], ["d", yesterday], ["e", yesterday], // yesterday
    ["f", NOW - 2 * DAY],             // two days ago
  ])

  t("counts only cards updated on the given day", G.answeredOn(progress, TODAY) === 2)
  t("a different day is counted separately", G.answeredOn(progress, G.dayKey(yesterday)) === 3)
  t("a day with nothing is zero", G.answeredOn(progress, G.dayKey(NOW - 30 * DAY)) === 0)
  t("an empty progress document is zero", G.answeredOn(G.emptyProgress(), TODAY) === 0)
}

group("freezeActivity")
{
  const yesterday = G.dayKey(NOW - DAY)
  const twoAgo = G.dayKey(NOW - 2 * DAY)

  const progress = reviewsAt([["a", NOW - DAY], ["b", NOW - DAY], ["c", NOW - 2 * DAY]])
  const frozen = G.freezeActivity(progress, NOW)

  t("yesterday is frozen at its true count", frozen.activity[yesterday] === 2)
  t("two days ago is frozen too", frozen.activity[twoAgo] === 1)
  t("today is never frozen", !Object.prototype.hasOwnProperty.call(frozen.activity, TODAY))
  t("a day with nothing is frozen at zero, not left absent",
    Object.prototype.hasOwnProperty.call(frozen.activity, G.dayKey(NOW - 3 * DAY))
    && frozen.activity[G.dayKey(NOW - 3 * DAY)] === 0)

  // The whole point: once a card is answered again, its old day's
  // contribution is gone from a fresh derivation — so an already-frozen day
  // must never be recomputed, or it would quietly lose what it recorded.
  const movedOn = reviewsAt([["a", NOW], ["b", NOW]]) // both cards now updated today
  movedOn.activity = { [yesterday]: 2 } // yesterday's true count, already frozen
  const refrozen = G.freezeActivity(movedOn, NOW)
  t("an already-frozen day is left exactly as it was, not rederived",
    refrozen.activity[yesterday] === 2)

  t("reviews pass through unchanged", refrozen.reviews === movedOn.reviews || Object.keys(refrozen.reviews).length === Object.keys(movedOn.reviews).length)
}

group("heatmapGrid")
{
  const weeks = 4
  const progress = reviewsAt([["a", NOW], ["a2", NOW]]) // 2 answered today
  const grid = G.heatmapGrid(progress, NOW, weeks)

  t("the grid is weeks*7 cells", grid.length === weeks * 7)

  const todayDow = G.dayOfWeek(NOW)
  const todayIndex = (weeks - 1) * 7 + todayDow
  t("today lands in the last column at its real weekday row",
    grid[todayIndex] && grid[todayIndex].day === TODAY)
  t("today's count is derived live", grid[todayIndex].count === 2)

  t("every cell after today in the final column is null",
    grid.slice(todayIndex + 1, weeks * 7).every((c) => c === null))

  if (todayDow > 0) {
    t("yesterday sits one row above today in the same column",
      grid[todayIndex - 1] && grid[todayIndex - 1].day === G.dayKey(NOW - DAY))
  }

  t("a full week back lands on the same weekday, one column earlier",
    grid[todayIndex - 7] && grid[todayIndex - 7].day === G.dayKey(NOW - 7 * DAY))
}

group("heatmapGrid prefers a frozen day over live derivation")
{
  // A card answered on some past day and then answered again since — a live
  // derivation of that old day would now read zero, but the frozen entry
  // remembers what actually happened.
  const oldDay = G.dayKey(NOW - 10 * DAY)
  const progress = reviewsAt([["a", NOW]]) // the only card now points at today
  progress.activity = { [oldDay]: 5 }

  const grid = G.heatmapGrid(progress, NOW, G.HEATMAP_WEEKS)
  const cell = grid.find((c) => c && c.day === oldDay)
  t("the frozen count wins over what a live derivation would say now",
    cell && cell.count === 5)
}

group("mergeProgress merges activity by the larger side, per day")
{
  const a = { reviews: {}, activity: { "2026-01-01": 3, "2026-01-02": 1 } }
  const b = { reviews: {}, activity: { "2026-01-02": 4, "2026-01-03": 2 } }
  const merged = G.mergeProgress(a, b)

  t("a day only one side has is kept", merged.activity["2026-01-01"] === 3)
  t("a day the other side only has is kept too", merged.activity["2026-01-03"] === 2)
  t("a day both have takes the larger", merged.activity["2026-01-02"] === 4)
  t("merging is symmetric", G.mergeProgress(b, a).activity["2026-01-02"] === 4)
}

group("parseProgress and serializeProgress round-trip activity")
{
  const doc = { reviews: {}, activity: { "2026-01-01": 3 } }
  const raw = G.serializeProgress(doc)
  const parsed = G.parseProgress(raw)
  t("the count survives a round trip", parsed.activity["2026-01-01"] === 3)

  t("a missing activity object parses to empty, not a crash",
    JSON.stringify(G.parseProgress('{"reviews":{}}').activity) === "{}")
  t("a negative or non-numeric count is clamped to zero",
    G.parseProgress('{"reviews":{},"activity":{"2026-01-01":-5,"2026-01-02":"nonsense"}}').activity["2026-01-01"] === 0)
  t("garbage input still parses to an empty activity map",
    JSON.stringify(G.parseProgress("not json").activity) === "{}")
}

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail ? 1 : 0)
