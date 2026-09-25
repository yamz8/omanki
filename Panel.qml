import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Anki.js" as Anki

// Bar widget: a card glyph with the number of cards waiting, opening the
// review session in a standard popup panel. Built on the same Ui.Panel base as
// Network and Tailscale so it inherits their open/close lifecycle, popout
// coordination, and IPC.
Panel {
  id: root
  moduleName: "yamz8.omanki"
  ipcTarget: "yamz8.omanki"

  // Bar widgets are handed their inline shell.json entry, so `setting()` from
  // the Panel base is all the config plumbing this surface needs.
  readonly property string deckPath: Anki.resolveDeck(root.setting("deck", ""), Quickshell.env("HOME"))
  readonly property int newPerDay: Anki.sanePerDay(root.setting("newPerDay", 20))
  readonly property var tags: Anki.normalizeTags(root.setting("tags", []))
  readonly property int reviewsPerDay: Anki.sanePerDay(root.setting("reviewsPerDay", 0), 0)
  readonly property int leechThreshold: Anki.sanePerDay(root.setting("leechThreshold", Anki.LEECH_THRESHOLD), Anki.LEECH_THRESHOLD)
  readonly property bool leechSuspend: root.setting("leechSuspend", true) !== false
  readonly property int lapsePercent: Anki.sanePerDay(root.setting("lapsePercent", Anki.LAPSE_PERCENT), Anki.LAPSE_PERCENT)
  // The count is the point of the widget, but a bar that has to stay narrow
  // can turn it off and keep the glyph.
  readonly property bool showCount: root.setting("showCount", true) !== false

  // The bar sizes a widget from its implicit size, and Ui.Panel is a bare Item
  // with none — without this the widget occupies 0x0 and draws nothing.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // review | stats. The overlay has room for a third (the composer); the panel
  // does not, and a form typed into a popup that closes on focus loss is not a
  // trade worth making.
  property string mode: "review"

  // Restoring is offered wherever the leech count is. Until the panel had a
  // statistics view it had neither, and said so by pointing at the overlay.
  function restoreLeeches() {
    var n = reviewer.restoreLeeches()
    root.restoreNotice = n > 0
        ? (n === 1 ? "1 card restored" : n + " cards restored")
        : "No suspended cards to restore"
    restoreNoticeTimer.restart()
  }

  property string restoreNotice: ""

  Timer {
    id: restoreNoticeTimer
    interval: 6000
    onTriggered: root.restoreNotice = ""
  }

  // Which statistics tab is showing. Held here because the strip that changes
  // it rides on the section header while the body it drives is further down the
  // column: one property both of them read, rather than a value bound in two
  // directions between two siblings.
  property int statsTab: 0

  // Wraps, so the arrows walk the strip in a circle rather than stopping at the
  // ends and leaving the reader to work out which end they are on.
  function stepTab(delta) {
    var n = stats.count
    if (n > 0) root.statsTab = ((root.statsTab + delta) % n + n) % n
  }

  // The leech tab appears and disappears with the leeches, and the last one
  // being restored must not leave the view pointing past the end of the strip.
  Connections {
    target: stats
    function onCountChanged() {
      if (root.statsTab >= stats.count) root.statsTab = Math.max(0, stats.count - 1)
    }
  }

  function showStats() { root.mode = "stats" }
  function showReview() { root.mode = "review" }
  function toggleStats() { root.mode = root.mode === "stats" ? "review" : "stats" }

  // A surface that closes and reopens is a new sitting, so it starts on the
  // cards rather than on whatever was last being read about them.
  onOpenedChanged: if (!root.opened) root.mode = "review"

  readonly property int panelContentWidth: Style.space(340)
  readonly property int pending: reviewer.stats ? reviewer.stats.pending : 0

  // WidgetButton rather than BarIconButton: the count makes this a
  // variable-width label, and BarIconButton is a fixed single-glyph slot that
  // would squeeze the number into the icon's box.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showCount && root.pending > 0 ? "󰘸 " + root.pending : "󰘸"
    fontSize: Style.bar.iconFont
    // Cards waiting is the whole signal; with none, the widget should recede
    // rather than sit at full strength all day.
    dimmed: root.pending === 0
    tooltipText: root.pending > 0
        ? root.pending + " card" + (root.pending === 1 ? "" : "s") + " to review"
        : "omanki — nothing due"
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelContentWidth)
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // Space and Enter both arrive as activate, which is exactly the
      // reveal-then-grade rhythm Anki uses.
      // Space and Enter reveal and grade, but only on the cards: in the
      // statistics they would grade a card that is not on screen.
      onActivateRequested: if (root.mode === "review") reviewer.activate()

      // Escape backs out one level before it closes, the way the overlay's
      // does. Leaving the panel entirely because someone wanted out of the
      // statistics would be a rude surprise.
      onCloseRequested: {
        if (root.mode !== "review") { root.showReview(); return }
        root.close()
      }

      // Tab belongs to the shell: it moves between bar panels, and every other
      // panel answers it that way. The statistics tabs are walked with the
      // arrows instead, which is what a row of tabs suggests anyway.
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // Arrows walk the tabs, and so do h and l: PanelKeyCatcher turns those
      // into movement before any panel sees them, which is the shell's vim
      // convention and the reason `l` cannot also mean "restore" here. The
      // overlay has no such catcher, so there it still can.
      onMoveRequested: function(dx, dy) {
        if (root.mode === "stats" && dx !== 0) root.stepTab(dx > 0 ? 1 : -1)
      }

      onTextKey: function(t) {
        var k = t.toLowerCase()
        // Same key as the overlay, so the two surfaces stay one set of keys.
        if (k === "s") root.toggleStats()
        else if (k === "r") reviewer.reload()
        else if (root.mode !== "review") return
        else if (k === "1") reviewer.answer("again")
        else if (k === "2") reviewer.answer("hard")
        else if (k === "3") reviewer.answer("good")
        else if (k === "4") reviewer.answer("easy")
        else if (k === "u") reviewer.undo()
        else if (k === "p") reviewer.replayAudio()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "omanki"
          meta: {
            if (reviewer.phase === "loading") return "Loading"
            if (reviewer.phase === "error") return "Deck error"
            if (reviewer.phase === "empty") return "Empty deck"
            var s = reviewer.stats
            if (!s.pending) return s.total + " card" + (s.total === 1 ? "" : "s") + "  ·  all caught up"
            return s.due + " due  ·  " + s.fresh + " new"
          }
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: "󰘸"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          // How many are left, on the trailing edge — the slot the native
          // panels use for at-a-glance state.
          trailingControl: Component {
            Row {
              spacing: Style.spacing.md

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                visible: reviewer.answered > 0
                text: "Done " + reviewer.answered
                color: root.foreground
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: String(root.pending)
                color: root.pending > 0 ? Color.accent : root.foreground
                opacity: root.pending > 0 ? 1.0 : 0.4
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
        }

        // The section header and, in the statistics, the tab strip on the end
        // of the same line. Stacking the strip under the header put two rows of
        // small-caps text against each other, which crowded both and spent a
        // row of a panel that has few to spare.
        Item {
          width: parent.width
          height: Math.max(sectionHeader.implicitHeight, tabStrip.height)

          PanelSectionHeader {
            id: sectionHeader
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.mode === "stats"
                ? "STATISTICS"
                : Anki.sectionLabel(reviewer.phase, reviewer.currentState, root.tags)
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          StatsTabs {
            id: tabStrip
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.mode === "stats"
            tabs: stats.tabs
            current: root.statsTab
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onSelected: function(i) { root.statsTab = i }
          }
        }

        PanelStats {
          id: stats
          width: parent.width
          visible: root.mode === "stats"
          stats: reviewer.deckStats
          heatmap: reviewer.heatmap
          tab: root.statsTab
          foreground: root.foreground
          accent: Color.accent
          urgent: root.urgent
          fontFamily: root.fontFamily
          onRestoreRequested: root.restoreLeeches()
        }

        Reviewer {
          id: reviewer
          width: parent.width
          visible: root.mode === "review"
          deckPath: root.deckPath
          stateDir: Quickshell.env("HOME") + "/.local/state/omarchy"
          newPerDay: root.newPerDay
          reviewsPerDay: root.reviewsPerDay
          leechThreshold: root.leechThreshold
          leechSuspend: root.leechSuspend
          lapsePercent: root.lapsePercent
          tags: root.tags
          active: root.opened
          foreground: root.foreground
          accent: Color.accent
          urgent: root.urgent
          fontFamily: root.fontFamily
        }

        // Shown only with the answer: grading a card you have not turned over
        // is guessing, not recall.
        GradeButtons {
          width: parent.width
          visible: root.mode === "review" && reviewer.phase === "reviewing" && reviewer.revealed
          reviewer: reviewer
          foreground: root.foreground
          urgent: root.urgent
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          // The hints are longer than the panel is wide once undo is offered.
          // A width alone does not contain a Text - without this it is drawn
          // centred at its natural width and spills past both edges - and
          // wrapping is right where eliding is not, since the part that would
          // be dropped is a key the reader is being told about.
          wrapMode: Text.Wrap
          // The bar panel has no statistics view to restore from, so it says
          // where the restoring lives rather than offering a key it does not
          // have. Saying nothing would leave a card gone with no account of it.
          text: {
            if (root.mode === "stats")
              return (root.restoreNotice ? root.restoreNotice + "  ·  " : "")
                  + "← → tabs  ·  s back to cards"
                  + "  ·  esc close"
            // A card taken out mid-session says so here; the statistics are
            // now where it can be put back, rather than the overlay.
            if (reviewer.leechNotice)
              return reviewer.leechNotice + "  ·  s statistics to restore"
            return (reviewer.revealed ? "1-4 grade  ·  space good" : "space reveal")
                + (reviewer.canUndo ? "  ·  u undo" : "")
                + "  ·  s stats  ·  esc close"
          }
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
