import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "../account/Model.js" as Model

// Where a message goes when it leaves the inbox with somewhere to be.
//
// The rail already names the mailboxes a key can reach; this is the rest of
// them, and on an account with thirty labels a list is only usable if it is
// narrowed by typing. So the field owns the focus from the moment it opens and
// the keyboard walks the list underneath it -- the destination is picked by
// typing three letters and pressing Return, never by arrowing through thirty.
Item {
  id: root

  required property color textColor
  required property color accentColor
  required property color dimColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  // [{ id, name, system, unread, total }], as the provider reported them.
  property var labels: []
  // The raw label or folder view already on screen, which cannot be its own
  // move destination.
  property string currentLabelId: ""

  property string searchQuery: ""

  // What the label brain suggests for the message, at most three, each
  // with the tokens that told: [{ id, name, because }]. They lead the list
  // under their own heading while the typed letters still name them.
  property var suggestions: []

  readonly property bool opened: menu.opened
  // The list, for a test to read the rows drawn: a Popup's contents are
  // not children of the item that owns it.
  readonly property alias menuRows: labelList
  readonly property var matchingLabels: Model.pickerRows(
    root.suggestions, root.labels, root.searchQuery, root.currentLabelId)

  // Where the keyboard is standing. Reset to the top on every keystroke
  // because the list underneath it has changed: holding an index still would
  // leave the cursor on whatever row happened to inherit that position.
  property int cursorIndex: 0
  // The list can shorten under the cursor for other reasons — the labels
  // refreshed while the picker is up — and Return on a row that is gone
  // must still take one.
  onMatchingLabelsChanged: if (cursorIndex >= matchingLabels.length) cursorIndex = Math.max(0, matchingLabels.length - 1)

  // Whether the row taken was one the brain suggested rides along: a
  // choice it did not make is the one it learns most from.
  signal labelChosen(string labelId, bool suggested)

  anchors.fill: parent
  z: 50

  function open() {
    searchField.text = ""
    root.searchQuery = ""
    root.cursorIndex = 0
    menu.open()
    place()
    searchField.forceActiveFocus()
  }

  function close() { menu.close() }

  // A Popup does not build its contents until it is first opened, so on the
  // first open its height is still zero and centring it lands it high. Placing
  // again on every height change is what makes the first open sit where all
  // the later ones do, and it re-centres the card as typing shortens the list.
  function place() {
    if (!menu.visible) return
    var menuHeight = menu.height > 0 ? menu.height : menu.implicitHeight
    menu.x = Math.max(Style.space(8), (root.width - menu.width) / 2)
    menu.y = Math.max(Style.space(8), (root.height - menuHeight) / 3)
  }

  function moveCursor(delta) {
    var matchCount = root.matchingLabels.length
    if (matchCount === 0) return
    cursorIndex = Model.wrappedIndex(cursorIndex, delta, matchCount)
  }

  function chooseCursor() {
    var matchCount = root.matchingLabels.length
    if (root.cursorIndex < 0 || root.cursorIndex >= matchCount) return
    var chosenLabel = root.matchingLabels[root.cursorIndex]
    menu.close()
    root.labelChosen(String(chosenLabel.id || ""), chosenLabel.suggested === true)
  }

  QQC.Popup {
    id: menu
    width: Math.min(Style.space(340), root.width - Style.space(24))
    implicitHeight: card.implicitHeight + Style.space(16)
    padding: Style.space(8)
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onHeightChanged: root.place()
    onOpened: root.place()

    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }

    contentItem: Column {
      id: card
      spacing: Style.space(8)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: "Move to"
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: "(" + root.matchingLabels.length + ")"
          color: root.dimColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // The field answers the keys itself. Inside an open `QQC.Popup` a
      // `KeyRouter` binding is the thing that would look live and never run --
      // the popup takes every key before the shortcut map sees it -- and this
      // one has to intercept the arrows and Return before the text cursor
      // does, while leaving every printable key to the filter.
      TextField {
        id: searchField
        width: parent.width
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
        placeholderText: "Type to find a label..."
        onTextChanged: {
          root.searchQuery = text
          root.cursorIndex = 0
        }
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Down) {
            root.moveCursor(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveCursor(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.chooseCursor()
            event.accepted = true
          }
          // Escape is not here: the popup's own CloseOnEscape is already the
          // one mechanism that closes it, and a second would be one too many.
        }
      }

      ListView {
        id: labelList

        WheelScroller { view: labelList }
        width: parent.width
        implicitHeight: Math.min(contentHeight, Style.space(280))
        clip: true
        model: root.matchingLabels
        currentIndex: root.cursorIndex
        highlightMoveDuration: 0
        // Keeps the keyboard's row on screen once the list is longer than the
        // card, which is the case this whole component exists for.
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        delegate: Rectangle {
          id: labelRow
          required property var modelData
          required property int index

          readonly property bool hasCursor: root.cursorIndex === labelRow.index
          readonly property bool suggested: labelRow.modelData.suggested === true
          // Why it was suggested, as the model wrote it; and the heading of
          // the group this row is the first of, drawn above it.
          readonly property string because: String(labelRow.modelData.reason || "")
          readonly property string heading: String(labelRow.modelData.heading || "")

          width: labelList.width
          implicitHeight: Style.space(34) + (because !== "" ? Style.space(12) : 0) + (heading !== "" ? Style.space(18) : 0)
          radius: Style.cornerRadius
          color: labelRow.hasCursor || rowHover.hovered
            ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent"
          border.width: labelRow.hasCursor ? Style.normalBorderWidth : 0
          border.color: Style.hoverBorderFor(root.textColor, root.accentColor)

          // A child steps in under its parent, and is named by its own
          // leaf; a match to typed letters shows its whole path, flat. A
          // suggestion is named in full, with why underneath, and the first
          // row of a group carries the group's heading.
          Column {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10) + Math.min(8, Number(labelRow.modelData.depth) || 0) * Style.space(12)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Text {
              objectName: "picker-heading"
              width: parent.width
              visible: labelRow.heading !== ""
              bottomPadding: Style.space(3)
              textFormat: Text.PlainText
              text: labelRow.heading
              color: root.dimColor
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: String(labelRow.modelData.leaf || labelRow.modelData.name || "")
              color: root.textColor
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Text {
              objectName: "picker-reason"
              width: parent.width
              visible: labelRow.because !== ""
              textFormat: Text.PlainText
              text: labelRow.because
              color: root.dimColor
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          HoverHandler { id: rowHover }

          TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: {
              root.cursorIndex = labelRow.index
              root.chooseCursor()
            }
          }
        }
      }

      // An account with no labels yet -- and a provider that has none at all --
      // would otherwise open an empty card that looks broken rather than
      // empty, and typing past every match is the same picture arrived at a
      // different way.
      Text {
        width: parent.width
        visible: root.matchingLabels.length === 0
        textFormat: Text.PlainText
        text: root.searchQuery === ""
          ? "No labels to move into" : "No label matches that"
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
