import QtQuick
import qs.Commons
import qs.Ui
import "Anki.js" as Anki

// What the deck looks like from above: how far through it you are, what is
// coming, and whether the scheduling is working. Almost everything shown is
// derived from the cards themselves rather than any history the plugin keeps
// — the one exception is ACTIVITY's calendar, which does need a day's count
// saved before it stops being derivable; see activityTab and Anki.js's note
// above answeredOn for why.
//
// In tabs, the same five the bar panel uses, for a reason the panel did not
// have: the page fitted here, but fitting is not the same as reading. Six
// figures at one weight, a composition bar, a week of forecast and a paragraph
// of prose all arriving together gave the eye nowhere to land — everything on
// it was equally loud, so it read as a table rather than an answer.
//
// So the split is by question. What is the deck (DECK), what is coming (DUE),
// how did today go (TODAY), how has activity looked over time (ACTIVITY),
// what has gone wrong (LEECHES). Each tab then gets the room this surface
// always had, spent on one thing instead of five.
//
// Same tab names and same order as PanelStats, because the two surfaces should
// not be two things to learn. What differs is what a tab may hold: at this
// width each one can carry a legend, a taller plot and a sentence, where the
// panel's has to make do with a caption.
Item {
  id: root

  property var stats: null
  // The full year, flat and column-major — see Anki.heatmapGrid. This
  // surface has real width to spend, so it typically shows far more of it
  // than the panel can; see activityTab.cells.
  property var heatmap: []
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  // Which tab is showing. Owned by Omanki.qml, which also owns the strip that
  // changes it — the strip rides on the section header, well above this, so one
  // property read by both beats a value bound in two directions between them.
  property int tab: 0

  readonly property int seen: root.stats ? root.stats.seen : 0
  readonly property int total: root.stats ? root.stats.total : 0
  readonly property int leeches: root.stats ? (root.stats.leeches || 0) : 0
  readonly property int suspended: root.stats ? (root.stats.suspended || 0) : 0

  // The leech tab appears only once there is a leech. A deck with none is the
  // ordinary case and should not carry a tab explaining a thing that has not
  // happened.
  readonly property var tabs: root.leeches > 0
      ? ["DECK", "DUE", "TODAY", "ACTIVITY", "LEECHES"]
      : ["DECK", "DUE", "TODAY", "ACTIVITY"]

  readonly property int count: root.tabs.length

  implicitHeight: body.height

  // One height for every tab, taken from the tallest. The card is centred on
  // the screen and sized to its content, so a tab that is shorter than its
  // neighbour would move the whole surface — and the grade buttons with it —
  // every time an arrow key is pressed.
  Item {
    id: body
    width: parent.width
    height: Math.max(deckTab.implicitHeight, dueTab.implicitHeight,
                     todayTab.implicitHeight, activityTab.implicitHeight, leechTab.implicitHeight)

    // ------------------------------------------------------------- deck
    //
    // The shape of the deck reads faster than its arithmetic, which is why this
    // is a bar and the numbers under it are a legend.
    Column {
      id: deckTab
      width: parent.width
      spacing: Style.spacing.md
      visible: root.tab === 0

      Row {
        width: parent.width
        spacing: Style.spacing.md

        Text {
          id: deckCount
          textFormat: Text.PlainText
          text: root.total + (root.total === 1 ? " card" : " cards")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        Text {
          textFormat: Text.PlainText
          anchors.baseline: deckCount.baseline
          text: root.total ? Anki.percent(root.seen / root.total) + " seen" : ""
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Row {
        width: parent.width
        height: Style.space(10)
        spacing: Math.max(1, Style.space(1))

        Repeater {
          model: [
            { key: "mature",   tone: root.accent,     alpha: 1.00 },
            { key: "young",    tone: root.accent,     alpha: 0.55 },
            { key: "learning", tone: root.urgent,     alpha: 0.85 },
            { key: "fresh",    tone: root.foreground, alpha: 0.18 }
          ]

          Rectangle {
            id: seg
            required property var modelData
            readonly property int n: root.stats ? (root.stats[seg.modelData.key] || 0) : 0
            height: parent.height
            // Widths are shares of the whole deck, less the hairline gaps.
            width: root.total > 0
                ? Math.max(seg.n > 0 ? Style.space(2) : 0,
                           (parent.width - Style.space(3)) * seg.n / root.total)
                : 0
            visible: seg.n > 0
            radius: Style.cornerRadius > 0 ? height / 2 : 0
            color: Util.alpha(seg.modelData.tone, seg.modelData.alpha)
          }
        }
      }

      // One row rather than the panel's two-by-two: there is width here for
      // four, and four across keeps the legend in the same reading order as the
      // bar it describes.
      Row {
        width: parent.width
        spacing: Style.spacing.lg

        Repeater {
          model: [
            { label: "mature",   key: "mature",   tone: root.accent,     alpha: 1.00 },
            { label: "young",    key: "young",    tone: root.accent,     alpha: 0.55 },
            { label: "learning", key: "learning", tone: root.urgent,     alpha: 0.85 },
            { label: "unseen",   key: "fresh",    tone: root.foreground, alpha: 0.18 }
          ]

          Row {
            required property var modelData
            spacing: Style.spacing.xs

            // A swatch, so the legend names the bar rather than merely sitting
            // under it. The panel has no room for these; this does.
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(8)
              height: Style.space(8)
              radius: Style.cornerRadius > 0 ? width / 2 : 0
              color: Util.alpha(modelData.tone, modelData.alpha)
            }

            Text {
              textFormat: Text.PlainText
              text: (root.stats ? (root.stats[modelData.key] || 0) : 0) + " " + modelData.label
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }

    // -------------------------------------------------------------- due
    Column {
      id: dueTab
      width: parent.width
      spacing: Style.spacing.md
      visible: root.tab === 1

      // The tab is already called DUE, so this says how many rather than
      // repeating the word as a heading.
      Text {
        textFormat: Text.PlainText
        text: {
          if (!root.stats || !root.stats.forecast) return ""
          var n = 0
          for (var i = 0; i < root.stats.forecast.length; i++) n += root.stats.forecast[i]
          return n + (n === 1 ? " card" : " cards") + " over the next week"
        }
        color: root.foreground
        opacity: 0.55
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Row {
        width: parent.width
        height: Style.space(76)
        spacing: Style.spacing.sm

        Repeater {
          model: 7

          Column {
            id: day
            required property int index

            readonly property int n:
                (root.stats && root.stats.forecast) ? (root.stats.forecast[day.index] || 0) : 0

            // Bars are scaled against the busiest day rather than an absolute
            // count, so a quiet week still has shape instead of seven stubs.
            readonly property int peak: {
              if (!root.stats || !root.stats.forecast) return 1
              var max = 1
              for (var i = 0; i < root.stats.forecast.length; i++)
                max = Math.max(max, root.stats.forecast[i])
              return max
            }

            width: (parent.width - Style.spacing.sm * 6) / 7
            spacing: Style.spacing.xxs

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: day.n > 0 ? String(day.n) : ""
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Item {
              id: plot
              width: parent.width
              height: Style.space(44)

              Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: day.n > 0
                    ? Math.max(Style.space(3), plot.height * day.n / day.peak)
                    : Math.max(1, Style.space(1))
                radius: Style.cornerRadius > 0 ? Style.space(2) : 0
                color: day.n > 0
                    ? Util.alpha(root.accent, day.index === 0 ? 1.0 : 0.45)
                    : Util.alpha(root.foreground, 0.12)
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: day.index === 0 ? "now" : "+" + day.index
              color: root.foreground
              opacity: 0.35
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    // ------------------------------------------------------------ today
    //
    // One figure with its breakdown, rather than six figures at one weight.
    // `answeredToday` is `reviewsToday + introducedToday` by construction — a
    // card whose firstDay is today was answered today — so showing all three as
    // peers was three numbers carrying two facts, and the grid of them was the
    // densest thing on the old page.
    Column {
      id: todayTab
      width: parent.width
      spacing: Style.spacing.md
      visible: root.tab === 2

      Row {
        width: parent.width
        spacing: Style.spacing.md

        Text {
          id: answered
          textFormat: Text.PlainText
          text: root.stats ? String(root.stats.answeredToday) : "0"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }

        Text {
          textFormat: Text.PlainText
          anchors.baseline: answered.baseline
          text: (root.stats && root.stats.answeredToday === 1) ? "card answered today" : "cards answered today"
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.Wrap
        text: root.stats
            ? root.stats.reviewsToday + (root.stats.reviewsToday === 1 ? " review" : " reviews")
              + "  ·  " + root.stats.introducedToday + " new"
            : ""
        color: root.foreground
        opacity: 0.55
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      PanelSeparator {
        width: parent.width
        foreground: root.foreground
      }

      // Deck-wide rather than today's, but they are the numbers that answer
      // "is this working", which is the question the rest of this tab asks.
      // One line, the way the panel says it: at headline size they competed
      // with the figure above for attention and won it on nothing but size.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.Wrap
        text: root.stats
            ? "ease " + root.stats.ease.toFixed(2)
              + "  ·  " + Anki.percent(root.stats.retention) + " never relearned"
              + "  ·  " + root.stats.lapsed + (root.stats.lapsed === 1 ? " lapsed card" : " lapsed cards")
            : ""
        color: root.foreground
        opacity: 0.5
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      // Retention has no review log behind it, and saying so is cheaper than
      // letting someone read it as Anki's number.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.Wrap
        text: "A lifetime figure per card, not a rolling window."
        color: root.foreground
        opacity: 0.3
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // ------------------------------------------------------------ activity
    //
    // A GitHub-style calendar of cards answered per day, over as many
    // trailing weeks as this width actually fits — see cells. There is no
    // review log (this file's own top note), so history only exists from
    // whenever this feature first started freezing a day's count; a deck
    // that predates it just shows a shorter calendar, not a wrong one.
    Column {
      id: activityTab
      width: parent.width
      spacing: Style.spacing.md
      visible: root.tab === 3

      readonly property int cellSize: Style.space(13)
      readonly property int cellGap: Style.space(3)
      readonly property int weeksAvailable: root.heatmap ? Math.floor(root.heatmap.length / 7) : 0
      readonly property int weeksVisible: Math.max(1, Math.min(activityTab.weeksAvailable,
          Math.floor((width + activityTab.cellGap) / (activityTab.cellSize + activityTab.cellGap))))
      readonly property var cells: (root.heatmap || []).slice(
          (activityTab.weeksAvailable - activityTab.weeksVisible) * 7)
      readonly property int peak: {
        var max = 1
        for (var i = 0; i < activityTab.cells.length; i++) {
          var c = activityTab.cells[i]
          if (c && c.count > max) max = c.count
        }
        return max
      }
      readonly property int total: {
        var n = 0
        for (var i = 0; i < activityTab.cells.length; i++) {
          var c = activityTab.cells[i]
          if (c) n += c.count
        }
        return n
      }

      Text {
        textFormat: Text.PlainText
        text: activityTab.total + (activityTab.total === 1 ? " card" : " cards")
            + " in the last " + activityTab.weeksVisible + (activityTab.weeksVisible === 1 ? " week" : " weeks")
        color: root.foreground
        opacity: 0.55
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Grid {
        rows: 7
        flow: Grid.TopToBottom
        spacing: activityTab.cellGap

        Repeater {
          model: activityTab.cells

          Rectangle {
            id: cell
            required property var modelData
            width: activityTab.cellSize
            height: activityTab.cellSize
            radius: Style.cornerRadius > 0 ? Style.space(3) : 0
            // A future day (modelData null) still has to occupy its slot —
            // Grid drops an invisible item from layout entirely, which would
            // shift every day after it and break the calendar alignment this
            // exists for. So it stays visible and just renders as nothing.
            color: !cell.modelData ? "transparent"
                : cell.modelData.count > 0
                ? Util.alpha(root.accent, 0.25 + 0.75 * Math.min(1, cell.modelData.count / activityTab.peak))
                : Util.alpha(root.foreground, 0.12)
          }
        }
      }
    }

    // ---------------------------------------------------------- leeches
    //
    // This is also the only place a suspended card can be found again: there is
    // no card browser to go looking in, so the count and the way back have to
    // be in the same view, or suspending would be a one-way door.
    Column {
      id: leechTab
      width: parent.width
      spacing: Style.spacing.md
      visible: root.tab === 4 && root.leeches > 0

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.Wrap
        text: {
          var n = root.leeches
          var s = root.suspended
          var head = n === 1
              ? "1 card has lapsed enough to count as a leech"
              : n + " cards have lapsed enough to count as a leech"
          if (s === 0) return head + ". None are suspended."
          if (s === n) return head + (n === 1 ? ", and it is suspended." : ", and all of them are suspended.")
          return head + ", and " + s + " of them " + (s === 1 ? "is" : "are") + " suspended."
        }
        color: root.foreground
        opacity: 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
