import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "../account/Model.js" as Model
import "Menu.js" as Menu

// The rail as a menu: every mailbox and label the sidebar draws, opened from
// the header's scope line or from `Alt+M`, for a window whose rail is
// collapsed to icons, folded into tabs, or simply further from the pointer
// than the header is.
//
// The rows are `Model.switcherRows` over the same slots the rail numbers, so
// the digit a row shows here is the Ctrl key that opens it from the list, and
// a bare digit while this is up opens it too.
Item {
  id: root

  required property color textColor
  required property color accentColor
  required property color dimColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily

  // [{ kind, key|id, name, icon, count, selected, number }]
  property var rows: []
  // What has been typed, and the rows it leaves: every row in its own order
  // with nothing typed, the best matches first otherwise. Each kept row
  // remembers its place in the full list, which is what choosing it names.
  property string query: ""
  readonly property var shown: Model.filterRows(rows, query)
  // Typing puts the cursor on the best match; typing it all away puts it
  // back where it rests, on the row in use.
  onQueryChanged: if (query.trim() === "") restCursorOnActive(); else cursorIndex = 0

  readonly property bool opened: menu.opened
  readonly property alias menuRows: list

  // Where the keyboard is standing, and never where the mouse is: a row draws
  // its own hover, for the reason the account switcher gives.
  property int cursorIndex: 0

  signal rowChosen(int index)

  anchors.fill: parent
  z: 45

  property real anchorX: 0
  property real anchorY: 0

  function openAt(sceneX, sceneY) {
    var local = root.mapFromGlobal(sceneX, sceneY)
    anchorX = local.x
    anchorY = local.y
    menu.open()
    place()
  }

  // Placed after it opens and again whenever its height changes: a Popup has
  // no height until its first open, and this list changes length with the
  // account's labels.
  function place() {
    if (!menu.visible) return
    var tall = menu.height > 0 ? menu.height : menu.implicitHeight
    var placed = Menu.position(anchorX, anchorY, menu.width, tall, root.width, root.height)
    menu.x = placed.x
    menu.y = placed.y
  }

  function openCentered() {
    anchorX = Math.max(0, (root.width - menu.width) / 2)
    anchorY = Math.max(0, (root.height - menu.implicitHeight) / 2)
    menu.open()
    place()
  }

  function close() { menu.close() }

  function moveCursor(delta) {
    var count = root.shown.length
    if (count === 0) return
    cursorIndex = Model.wrappedIndex(cursorIndex, delta, count)
  }

  function choose(index) {
    var count = root.shown.length
    if (index < 0 || index >= count) return
    // `index` is a place among the rows shown; what is reported is the row's
    // place in the full list, so a narrowed list still opens the right thing.
    var original = root.shown[index].sourceIndex
    menu.close()
    root.rowChosen(original)
  }

  function chooseCursor() { choose(cursorIndex) }
  // A bare digit names a row by the number it carries, among the rows shown.
  function chooseNumber(number) {
    var all = root.shown
    for (var i = 0; i < all.length; i++) if (Number(all[i].number) === Number(number)) { choose(i); return }
  }

  // Opening puts the keyboard on the scope already open, so the first `j` is
  // one step from it rather than back at the top.
  // Read afresh rather than through `shown`: called as the query changes,
  // when that binding may not have caught up yet.
  function restCursorOnActive() {
    var all = Model.filterRows(root.rows, root.query)
    for (var i = 0; i < all.length; i++) {
      if (all[i].selected) { cursorIndex = i; return }
    }
    cursorIndex = 0
  }

  QQC.Popup {
    id: menu
    width: Style.space(230)
    implicitHeight: list.implicitHeight + Style.space(8)
    padding: Style.space(4)
    modal: false
    focus: true
    closePolicy: QQC.Popup.CloseOnEscape | QQC.Popup.CloseOnPressOutside
    onHeightChanged: root.place()
    onOpened: {
      search.reset()
      root.restCursorOnActive()
      root.place()
      search.takeFocus()
    }
    background: Rectangle {
      radius: Style.cornerRadius
      color: root.popupBackgroundColor
      border.width: 1
      border.color: root.popupBorderColor
    }

    // Keys answered here rather than in `KeyRouter`, because an open popup
    // takes every key before the shortcut map sees it. AGENTS.md, "Keys and
    // focus", and `tests/qml/tst_popup_keys.qml` hold the reason.
    contentItem: Column {
      id: list
      spacing: Style.space(2)
      // A key that reaches the column — the field lost focus to a click on
      // the padding, say — still goes to the search line.
      Keys.forwardTo: [search]

      SwitcherSearch {
        id: search
        width: menu.width - menu.leftPadding - menu.rightPadding
        foreground: root.textColor
        accent: root.accentColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.bodySmall
        onTextChanged: root.query = text
        onMoved: function(delta) { root.moveCursor(delta) }
        onChosen: root.chooseCursor()
        numbers: root.shown.map(function(r) { return Number(r.number) || 0 })
        onNumbered: function(number) { root.chooseNumber(number) }
      }

      Repeater {
        model: root.shown

        Rectangle {
          id: row
          objectName: "mailbox-row"
          required property var modelData
          required property int index

          readonly property bool hasCursor: root.cursorIndex === row.index

          width: menu.width - menu.leftPadding - menu.rightPadding
          implicitHeight: Style.spacing.popupRowHeight
          radius: Style.cornerRadius
          color: modelData.selected
            ? Style.selectedFillFor(root.textColor, root.accentColor)
            : (rowHover.hovered || hasCursor
              ? Style.hoverFillFor(root.textColor, root.accentColor) : "transparent")
          border.width: hasCursor ? Style.normalBorderWidth : 0
          border.color: Style.hoverBorderFor(root.textColor, root.accentColor)

          ActionIcon {
            id: rowIcon
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            name: row.modelData.icon
            iconSize: Style.font.iconSmall
            color: root.textColor
          }

          Text {
            anchors.left: rowIcon.right
            anchors.leftMargin: Style.space(8)
            anchors.right: suffix.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            // A label's name was typed by the account's owner.
            textFormat: Text.PlainText
            text: row.modelData.name
            color: root.textColor
            font.family: root.panelFontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: row.modelData.selected
            elide: Text.ElideRight
          }

          // The count where a label has one, then the key that opens the row.
          Row {
            id: suffix
            anchors.right: parent.right
            anchors.rightMargin: Style.space(9)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: row.modelData.count > 0
              text: row.modelData.count > 999 ? "999+" : String(row.modelData.count)
              color: root.textColor
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: row.modelData.number >= 1 && row.modelData.number <= 10
              text: row.modelData.number === 10 ? "0" : String(row.modelData.number)
              color: root.dimColor
              font.family: root.panelFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          HoverHandler { id: rowHover }
          TapHandler { gesturePolicy: TapHandler.ReleaseWithinBounds; onTapped: root.choose(row.index) }
        }
      }
    }
  }
}
