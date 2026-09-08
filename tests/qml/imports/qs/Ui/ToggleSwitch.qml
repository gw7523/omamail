import QtQuick

Item {
  property bool checked: false
  property bool busy: false
  property bool interactive: true
  property bool hasCursor: false
  property color foreground: "transparent"
  property color accent: "transparent"
  signal toggled()
}
