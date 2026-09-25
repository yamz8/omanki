import QtQuick
import qs.Commons
import qs.Ui
import "Anki.js" as Anki

// The statistics, sized for the bar panel.
//
// StatsView is the same numbers laid out for the overlay, which is a whole
// screen: it can afford a composition bar, a week of forecast, six figures in a
// grid and a paragraph of prose all at once. The panel is about 340 wide and
// tall enough for a card, so the same layout there would be a column of
// squeezed rows that says everything badly.
//
// So the panel gets tabs. One thing at a time, each sized to the space actually
// available, and the strip says what else there is — which a scrolling column
// never does. Both views read the same `stats` object, so there is one
// calculation behind two presentations rather than two of either.
//
// The strip itself is StatsTabs, and it lives on the end of the section header
// rather than above this: a row of small-caps tabs directly under the
// small-caps word "STATISTICS" was two lines saying nearly the same thing, and
// they crowded each other. This exposes `tabs` so the strip can render it, and
// takes `tab` from the panel, which owns it.
Item {
  id: root

  property var stats: null
  // The full year, flat and column-major — see Anki.heatmapGrid. This view
  // only has room for a handful of weeks, so it takes the trailing slice it
  // fits rather than asking for a narrower grid to begin with; see cells.
  property var heatmap: []
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  // Which tab is showing. Owned by the panel, because the strip that changes it
  // is up in the header and this is down in the body: one property read by
  // both beats a value bound in two directions between them.
  property int tab: 0

  signal restoreRequested()

  readonly property int total: root.stats ? root.stats.total : 0
  readonly property int seen: root.stats ? root.stats.seen : 0
  readonly property int leeches: root.stats ? (root.stats.leeches || 0) : 0
  readonly property int suspended: root.stats ? (root.stats.suspended || 0) : 0

  // The leech tab appears only once there is a leech, the way the overlay's
  // leech section does. A tab that is empty whenever you look at it is a tab
  // that teaches you not to look.
  readonly property var tabs: root.leeches > 0
      ? ["DECK", "DUE", "TODAY", "ACTIVITY", "LEECHES"]
      : ["DECK", "DUE", "TODAY", "ACTIVITY"]

  readonly property int count: root.tabs.length

  implicitHeight: body.height

  // --------------------------------------------------------------- the body
  //
  // One height for every tab, taken from the tallest, so that moving along the
  // strip does not resize the panel under the pointer. A panel that changes
  // height as you read it is worse than one that carries a little air.
  Item {
    id: body
    width: parent.width
    // Taken from the tallest tab rather than a number picked by eye, so the
    // panel keeps one height across the strip without the figure needing to be
    // rechecked every time a tab gains a line.
    height: Math.max(deckTab.implicitHeight, dueTab.implicitHeight,
                     todayTab.implicitHeight, activityTab.implicitHeight, leechTab.implicitHeight)

    // ------------------------------------------------------------ deck
    Column {
      id: deckTab
      width: parent.width
      spacing: Style.spacing.sm
      visible: root.tab === 0

      Row {
        width: parent.width
        spacing: Style.spacing.sm

        Text {
          textFormat: Text.PlainText
          anchors.baseline: pct.baseline
          text: root.total + (root.total === 1 ? " card" : " cards")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        Text {
          id: pct
          textFormat: Text.PlainText
          text: root.total ? Anki.percent(root.seen / root.total) + " seen" : ""
          color: root.foreground
          opacity: 0.5
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // The shape of the deck reads faster than its arithmetic, which is why
      // this is a bar and the numbers under it are a caption.
      Row {
        width: parent.width
        height: Style.space(8)
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

      // Two rows of two rather than one row of four: four labels and four
      // numbers do not fit across a panel without shrinking past reading size.
      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.spacing.md
        rowSpacing: Style.spacing.xs

        Repeater {
          model: [
            { label: "mature",   key: "mature" },
            { label: "young",    key: "young" },
            { label: "learning", key: "learning" },
            { label: "unseen",   key: "fresh" }
          ]

          Text {
            required property var modelData
            textFormat: Text.PlainText
            width: (parent.width - Style.spacing.md) / 2
            text: (root.stats ? (root.stats[modelData.key] || 0) : 0) + " " + modelData.label
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // ------------------------------------------------------------- due
    Column {
      id: dueTab
      width: parent.width
      spacing: Style.spacing.sm
      visible: root.tab === 1

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
        font.pixelSize: Style.font.caption
      }

      Row {
        width: parent.width
        height: Style.space(62)
        spacing: Style.spacing.xs

        Repeater {
          model: 7

          Column {
            id: day
            required property int index
            readonly property int n:
                (root.stats && root.stats.forecast) ? (root.stats.forecast[day.index] || 0) : 0

            // Scaled against the busiest day rather than an absolute count, so
            // a quiet week still has a shape instead of seven stubs.
            readonly property int peak: {
              if (!root.stats || !root.stats.forecast) return 1
              var max = 1
              for (var i = 0; i < root.stats.forecast.length; i++)
                max = Math.max(max, root.stats.forecast[i])
              return max
            }

            width: (parent.width - Style.spacing.xs * 6) / 7
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: day.n > 0 ? String(day.n) : ""
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item {
              id: plot
              width: parent.width
              height: Style.space(32)

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

    // ----------------------------------------------------------- today
    Column {
      id: todayTab
      width: parent.width
      spacing: Style.spacing.md
      visible: root.tab === 2

      Row {
        width: parent.width

        Repeater {
          model: [
            { label: "ANSWERED", key: "answeredToday" },
            { label: "NEW",      key: "introducedToday" },
            { label: "REVIEWS",  key: "reviewsToday" }
          ]

          Column {
            required property var modelData
            width: parent.width / 3
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.stats ? String(root.stats[modelData.key] || 0) : "0"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Text {
              textFormat: Text.PlainText
              text: modelData.label
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // Ease and retention are deck-wide rather than today's, but they are the
      // two numbers that answer "is this working", which is the question the
      // rest of this tab is about.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.Wrap
        text: root.stats
            ? "ease " + root.stats.ease.toFixed(2)
              + "  ·  " + Anki.percent(root.stats.retention) + " never relearned"
              + "  ·  " + root.stats.lapsed + " lapsed"
            : ""
        color: root.foreground
        opacity: 0.45
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // -------------------------------------------------------- activity
    //
    // A GitHub-style calendar of cards answered per day. The panel is about
    // 340 wide, nowhere near the room a full year wants, so this takes only
    // as many trailing weeks (columns) as actually fit rather than shrinking
    // every cell to force the whole year in — see cells.
    Column {
      id: activityTab
      width: parent.width
      spacing: Style.spacing.sm
      visible: root.tab === 3

      readonly property int cellSize: Style.space(9)
      readonly property int cellGap: Style.space(2)
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
        font.pixelSize: Style.font.caption
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
            radius: Style.cornerRadius > 0 ? Style.space(2) : 0
            // A future day (modelData null) still has to occupy its slot in
            // the grid — Grid, like Column, drops an invisible item from
            // layout entirely, which would shift every day after it and
            // break the calendar alignment this whole thing exists for. So
            // it stays visible and just renders as nothing.
            color: !cell.modelData ? "transparent"
                : cell.modelData.count > 0
                ? Util.alpha(root.accent, 0.25 + 0.75 * Math.min(1, cell.modelData.count / activityTab.peak))
                : Util.alpha(root.foreground, 0.12)
          }
        }
      }
    }

    // --------------------------------------------------------- leeches
    Column {
      id: leechTab
      width: parent.width
      spacing: Style.spacing.sm
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
        font.pixelSize: Style.font.caption
      }

      // The panel had no way back before this view existed - it said "restore
      // in the overlay" and left you to go there. Now that the count is here,
      // the way back belongs here too.
      Button {
        visible: root.suspended > 0
        text: root.suspended === 1 ? "Restore 1 card" : "Restore " + root.suspended + " cards"
        bordered: true
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onClicked: root.restoreRequested()
      }
    }
  }
}
