import QtQuick
import qs.Commons
import qs.Ui

// A switch with its state said in a word beside it. The slider alone does
// not say which way it stands — a filled track reads as "on" to one person
// and as "the accent colour" to the next — so "On" or "Off" sits at its
// left, in the caption face, and changes with it. The word is as wide as
// the wider of the two whichever is showing, so the text beside it does not
// reflow on every flip; and the word is a target too, because it looks
// like one. Used wherever a setting is a switch, so every one of them says
// the same thing the same way.
Item {
  id: root

  property bool checked: false
  required property color foreground
  required property color accent
  required property string fontFamily
  // The word's colour: dim beside the text it belongs to.
  property color wordColor: foreground
  // The name a test finds the switch by; it stays on the switch itself.
  property string switchName: ""
  // What the switch itself takes: a busy one swallows presses, a list
  // cursor rests on it, and one that is not interactive is a readout.
  property alias busy: toggle.busy
  property alias hasCursor: toggle.hasCursor
  property alias interactive: toggle.interactive

  signal toggled()

  implicitWidth: widest.width + Style.space(8) + toggle.implicitWidth
  implicitHeight: Math.max(toggle.implicitHeight, word.implicitHeight)

  // The room the wider word needs, reserved for either.
  TextMetrics {
    id: widest
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    text: "Off"
  }

  Text {
    id: word
    objectName: "switchWord"
    anchors.right: toggle.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    width: widest.width
    horizontalAlignment: Text.AlignRight
    text: root.checked ? "On" : "Off"
    color: root.wordColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    textFormat: Text.PlainText
    Accessible.ignored: true

    MouseArea {
      anchors.fill: parent
      enabled: toggle.interactive && !toggle.busy
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggled()
    }
  }

  ToggleSwitch {
    id: toggle
    objectName: root.switchName
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    checked: root.checked
    foreground: root.foreground
    accent: root.accent
    onToggled: root.toggled()
  }
}
