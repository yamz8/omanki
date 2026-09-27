import QtQuick
import qs.Commons
import qs.Ui
import "Anki.js" as Anki

// Look a card up instead of waiting to be asked it. A deck built from your own
// notes is also a reference, and the answer you need now is usually on a card
// that is not due for weeks. The whole deck is listed, face up, and typing
// narrows it — the same shape as the shell's keybinding list, so it needs no
// learning.
//
// Read-only on purpose: looking a card up is not reviewing it, so nothing here
// touches the schedule.
Column {
  id: root

  // Every card, not the tag-filtered session: a lookup is about the deck, and a
  // card hidden by today's filter is still something you may want to find.
  property var cards: []
  property int listHeight: Style.space(360)

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  signal dismissed()

  readonly property var results: Anki.searchCards(root.cards, queryField.text)

  spacing: Style.spacing.md

  // Caught here for the same reason the composer catches it: the field holds
  // focus, so the overlay's key catcher never sees the key.
  Keys.onEscapePressed: function(event) {
    root.dismissed()
    event.accepted = true
  }

  function reset() {
    queryField.text = ""
    list.currentIndex = 0
    list.positionViewAtBeginning()
  }

  function focusFirst() {
    queryField.forceActiveFocus()
  }

  // A new query starts from its best match rather than wherever the cursor was
  // in a list that no longer exists.
  onResultsChanged: {
    list.currentIndex = 0
    list.positionViewAtBeginning()
  }

  function step(delta) {
    var n = root.results.length
    if (!n) return
    list.currentIndex = Math.max(0, Math.min(n - 1, list.currentIndex + delta))
  }

  TextField {
    id: queryField
    width: parent.width
    placeholderText: "Search the deck"
    foreground: root.foreground
    accent: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.body

    // The field keeps focus while the arrows walk the list, so typing and
    // moving never need a mode switch between them.
    Keys.onUpPressed: function(event) { root.step(-1); event.accepted = true }
    Keys.onDownPressed: function(event) { root.step(1); event.accepted = true }
    Keys.onPressed: function(event) {
      var page = Math.max(1, Math.floor(list.height / Style.space(56)))
      if (event.key === Qt.Key_PageUp) { root.step(-page); event.accepted = true }
      else if (event.key === Qt.Key_PageDown) { root.step(page); event.accepted = true }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    text: queryField.text.trim()
        ? root.results.length + " of " + root.cards.length + " card" + (root.cards.length === 1 ? "" : "s")
        : root.cards.length + " card" + (root.cards.length === 1 ? "" : "s")
    color: root.foreground
    opacity: 0.5
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  ListView {
    id: list
    width: parent.width
    height: root.listHeight
    clip: true
    spacing: Style.space(2)
    model: root.results
    boundsBehavior: Flickable.StopAtBounds
    highlightMoveDuration: 0

    delegate: Rectangle {
      id: row
      required property var modelData
      required property int index

      width: ListView.view.width
      height: rowColumn.implicitHeight + Style.spacing.sm * 2
      radius: Style.cornerRadius
      color: ListView.isCurrentItem ? Util.alpha(root.accent, 0.14) : "transparent"

      MouseArea {
        anchors.fill: parent
        onClicked: list.currentIndex = row.index
      }

      Column {
        id: rowColumn
        anchors.verticalCenter: parent.verticalCenter
        x: Style.spacing.md
        width: parent.width - Style.spacing.md * 2
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.Wrap
          text: row.modelData.front
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.Wrap
          text: row.modelData.back
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: row.modelData.tags.length > 0
          text: "#" + row.modelData.tags.join("  #")
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: root.results.length === 0
    horizontalAlignment: Text.AlignHCenter
    text: root.cards.length ? "No card matches." : "The deck is empty."
    color: root.foreground
    opacity: 0.55
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    text: "type to filter  ·  ↑ ↓ move  ·  esc back to review"
    color: root.foreground
    opacity: 0.4
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}
