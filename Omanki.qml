import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Anki.js" as Anki

// Fullscreen overlay surface, summoned by keybind. The session lives in
// Reviewer; this file is the card around it, styled with the same menu tokens
// and panel primitives the built-in overlays use.
//
// This is the surface for actually sitting down to a deck — the bar panel is
// for clearing a few cards in passing. They share the session implementation
// and the progress file, so a card answered in one is answered in both.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false

  property string fontFamily: Style.font.menuFamily
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  readonly property int contentMargin: Style.spacing.panelPadding

  readonly property string pluginId: (root.manifest && root.manifest.id) || "yamz8.omanki"

  // ------------------------------------------------------------- settings
  // Overlays are not handed a `settings` object the way bar widgets are, so
  // find our own entry in shell.json ourselves.
  //
  // A third-party plugin is given a scoped facade, not the shell: it carries
  // the bar config and not the whole document. Asking it for `shellConfig`
  // yields undefined rather than an error, findEntry then matches nothing,
  // and every setting quietly falls back to its default in this surface while
  // the bar panel -- which is handed its entry directly -- honours them. The
  // deck path going back to the default is the one that shows.
  //
  // It is a live property, so editing the file re-evaluates this without a
  // restart.
  readonly property var pluginSettings: Anki.findEntry(
    root.shell ? { bar: root.shell.barConfig } : null, root.pluginId)

  readonly property string deckPath: Anki.resolveDeck(root.pluginSettings.deck, Quickshell.env("HOME"))
  readonly property int newPerDay: Anki.sanePerDay(root.pluginSettings.newPerDay)
  readonly property var tags: Anki.normalizeTags(root.pluginSettings.tags)
  readonly property int reviewsPerDay: Anki.sanePerDay(root.pluginSettings.reviewsPerDay, 0)
  readonly property int leechThreshold:
      Anki.sanePerDay(root.pluginSettings.leechThreshold, Anki.LEECH_THRESHOLD)
  readonly property bool leechSuspend: root.pluginSettings.leechSuspend !== false
  readonly property int lapsePercent:
      Anki.sanePerDay(root.pluginSettings.lapsePercent, Anki.LAPSE_PERCENT)

  // review | stats | add. The overlay is the surface with room for more than
  // one card, so it is the one that gets the other two.
  property string mode: "review"

  // What `l` last did, shown under the statistics for a few seconds. Restoring
  // nothing is worth saying too: the alternative is a key that appears to do
  // nothing on a deck whose leeches are only flagged and not suspended.
  property string restoreNotice: ""

  Timer {
    id: restoreNoticeTimer
    interval: 6000
    onTriggered: root.restoreNotice = ""
  }

  function restoreLeeches() {
    var n = reviewer.restoreLeeches()
    root.restoreNotice = n > 0
        ? (n === 1 ? "1 card restored" : n + " cards restored")
        : "No suspended cards to restore"
    restoreNoticeTimer.restart()
  }

  // Which statistics tab is showing. Held here rather than in StatsView for
  // the same reason the panel holds its own: the strip that changes it rides
  // on the section header while the body it drives is further down the column,
  // so one property both of them read beats a value bound in two directions
  // between two siblings.
  property int statsTab: 0

  // Wraps, so the arrows walk the strip in a circle rather than stopping at
  // the ends and leaving the reader to work out which end they are on.
  function stepTab(delta) {
    var n = statsView.count
    if (n > 0) root.statsTab = ((root.statsTab + delta) % n + n) % n
  }

  // The leech tab appears and disappears with the leeches, and restoring the
  // last one must not leave the view pointing past the end of the strip.
  Connections {
    target: statsView
    function onCountChanged() {
      if (root.statsTab >= statsView.count) root.statsTab = Math.max(0, statsView.count - 1)
    }
  }

  // Wide enough to read a sentence without becoming a wall of text, and capped
  // so it does not stretch across an ultrawide.
  readonly property int cardWidth: Math.min(Style.space(620), Math.round(panel.width * 0.62))

  // A floor rather than a fixed height: cards vary in length, and a face that
  // resized on every answer would make the grade buttons move under the cursor
  // mid-session.
  readonly property int faceHeight: Math.max(Style.space(180), Math.round(panel.height * 0.22))

  // ------------------------------------------------------- plugin contract
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    root.opened = true
    root.mode = "review"
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function showReview() {
    root.mode = "review"
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function showAdd() {
    root.mode = "add"
    composer.reset()
    Qt.callLater(function() { composer.focusFirst() })
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "yamz8-omanki"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: column.implicitHeight + root.contentMargin * 2
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      // Swallow clicks on the card so they do not reach the dismiss handler.
      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          switch (event.key) {
            case Qt.Key_Escape:
              // Back out one level first: leaving the deck entirely because
              // someone wanted out of the stats would be a rude surprise.
              if (root.mode !== "review") { root.showReview(); event.accepted = true; return }
              root.dismiss(); event.accepted = true; return
            case Qt.Key_Left:
            case Qt.Key_Right:
              // Only in the statistics. The composer is a form, and arrows in
              // a form move the caret — falling through without accepting is
              // what lets them reach it.
              if (root.mode === "stats") {
                root.stepTab(event.key === Qt.Key_Right ? 1 : -1)
                event.accepted = true
              }
              return
            case Qt.Key_Space:
            case Qt.Key_Return:
            case Qt.Key_Enter:
              // The composer owns typing, so these must reach its fields.
              if (root.mode === "add") return
              // Reveal, then grade Good — the same two presses Anki trains
              // into your hands.
              reviewer.activate(); event.accepted = true; return
          }

          // Everything below is a letter or digit, which in the composer is
          // someone typing a card rather than issuing a command.
          if (root.mode === "add") return

          var k = event.text ? event.text.toLowerCase() : ""
          if (k === "s") root.mode = (root.mode === "stats" ? "review" : "stats")
          else if (k === "a") root.showAdd()
          // Restoring is offered wherever the leech count is, which is the
          // statistics — so this one is handled before the bail-out that keeps
          // the grade keys to the review surface.
          else if (k === "l") root.restoreLeeches()
          else if (root.mode !== "review") return
          else if (k === "1") reviewer.answer("again")
          else if (k === "2") reviewer.answer("hard")
          else if (k === "3") reviewer.answer("good")
          else if (k === "4") reviewer.answer("easy")
          else if (k === "u") reviewer.undo()
          else if (k === "r") reviewer.reload()
          else if (k === "p") reviewer.replayAudio()
          else return
          event.accepted = true
        }
      }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Column {
          id: column
          width: parent.width
          spacing: Style.space(14)

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
                font.pixelSize: Style.font.displayLarge
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.lg

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  visible: reviewer.answered > 0
                  text: "Done " + reviewer.answered
                  color: root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(reviewer.stats ? reviewer.stats.pending : 0)
                  color: (reviewer.stats && reviewer.stats.pending > 0) ? Color.accent : root.foreground
                  opacity: (reviewer.stats && reviewer.stats.pending > 0) ? 1.0 : 0.4
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // The section header and, in the statistics, the tab strip on the
          // end of the same line. Stacking the strip underneath put two rows of
          // small-caps text against each other, which crowded both — the same
          // thing that made it ride the header in the bar panel.
          Item {
            width: parent.width
            height: Math.max(sectionHeader.implicitHeight, tabStrip.height)

            PanelSectionHeader {
              id: sectionHeader
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.mode === "stats" ? "STATISTICS"
                  : root.mode === "add" ? "ADD A CARD"
                  : Anki.sectionLabel(reviewer.phase, reviewer.currentState, root.tags)
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            StatsTabs {
              id: tabStrip
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.mode === "stats"
              tabs: statsView.tabs
              current: root.statsTab
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onSelected: function(i) { root.statsTab = i }
            }
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
            urgent: Color.urgent
            fontFamily: root.fontFamily
            // The whole point of the fullscreen surface: a card you can read
            // from across the desk, in a face that holds still between answers.
            minFaceHeight: root.faceHeight
            questionFontSize: Style.font.display
            answerFontSize: Style.font.heading
          }

          GradeButtons {
            width: parent.width
            visible: root.mode === "review" && reviewer.phase === "reviewing" && reviewer.revealed
            reviewer: reviewer
            foreground: root.foreground
            urgent: Color.urgent
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            captionSize: Style.font.bodySmall
          }

          StatsView {
            id: statsView
            width: parent.width
            visible: root.mode === "stats"
            stats: reviewer.deckStats
            heatmap: reviewer.heatmap
            tab: root.statsTab
            foreground: root.foreground
            accent: Color.accent
            urgent: Color.urgent
            fontFamily: root.fontFamily
          }

          CardComposer {
            id: composer
            width: parent.width
            visible: root.mode === "add"
            reviewer: reviewer
            foreground: root.foreground
            accent: Color.accent
            urgent: Color.urgent
            fontFamily: root.fontFamily
            onDismissed: root.showReview()
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: root.mode === "review"
            // The leech notice replaces the hints rather than crowding in
            // beside them: a card has just been taken out of the rotation, and
            // for those few seconds that is the more useful thing to read.
            text: reviewer.leechNotice
                ? reviewer.leechNotice + "  ·  s stats to restore"
                : (reviewer.revealed ? "1-4 grade  ·  space good" : "space reveal")
                  + (reviewer.canUndo ? "  ·  u undo" : "")
                  + "  ·  s stats  ·  a add  ·  esc close"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            visible: root.mode === "stats"
            text: (root.restoreNotice ? root.restoreNotice + "  ·  " : "")
                + "← → tabs  ·  s back to review"
                + (reviewer.deckStats && reviewer.deckStats.suspended > 0 ? "  ·  l restore leeches" : "")
                + "  ·  a add a card  ·  esc close"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
