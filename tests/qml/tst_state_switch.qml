import QtQuick 2.15
import QtTest 1.3
import qs.Commons
import "../../components" as Mail

// A switch says which way it stands, in a word that follows it.
Item {
  width: 400
  height: 200

  Mail.StateSwitch {
    id: toggle
    switchName: "probe"
    foreground: Color.foreground
    accent: Color.accent
    fontFamily: "monospace"
  }
  SignalSpy { id: flips; target: toggle; signalName: "toggled" }

  TestCase {
    name: "StateSwitch"
    when: windowShown

    function word() {
      var kids = toggle.children
      for (var i = 0; i < kids.length; i++) if (kids[i].objectName === "switchWord") return kids[i]
      return null
    }
    function inner() {
      var kids = toggle.children
      for (var i = 0; i < kids.length; i++) if (kids[i].objectName === "probe") return kids[i]
      return null
    }

    function test_the_word_follows_the_switch() {
      toggle.checked = false
      compare(word().text, "Off")
      var offWidth = toggle.implicitWidth
      toggle.checked = true
      compare(word().text, "On")
      compare(toggle.implicitWidth, offWidth, "the room is the wider word's, whichever shows")
      verify(inner() !== null, "the switch keeps the name a test finds it by")
      compare(inner().checked, true)
      compare(word().textFormat, Text.PlainText)
      inner().toggled()
      compare(flips.count, 1, "the switch's own toggle reaches the owner")
      mouseClick(word())
      compare(flips.count, 2, "the word is a target too")
      toggle.busy = true
      compare(inner().busy, true, "what the switch takes reaches it")
      mouseClick(word())
      compare(flips.count, 2, "and a busy one takes no press on the word")
      toggle.busy = false
      toggle.hasCursor = true
      compare(inner().hasCursor, true)
    }
  }
}
