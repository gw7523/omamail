import QtQuick 2.15
import QtTest 1.3
import qs.Commons
import "../../components" as Mail

// Typing into the mailbox switcher narrows it to the rows the letters name,
// Enter opens the row the cursor is on by its place in the full list, and
// with nothing typed a bare digit still opens the row that carries it.
Item {
  width: 600
  height: 500

  Mail.MailboxSwitcher {
    id: switcher
    textColor: Color.foreground
    accentColor: Color.accent
    dimColor: Color.foreground
    popupBackgroundColor: Color.foreground
    popupBorderColor: Color.foreground
    panelFontFamily: "monospace"
    rows: [
      { kind: "mailbox", key: "inbox", name: "Inbox", number: 1, count: 0, icon: "inbox", selected: true },
      { kind: "label", id: "Work", name: "Work", number: 2, count: 3, icon: "label", selected: false },
      { kind: "label", id: "Work/Invoices", name: "Work/Invoices", number: 3, count: 0, icon: "label", selected: false },
      { kind: "label", id: "Receipts", name: "Receipts", number: 4, count: 1, icon: "label", selected: false },
      { kind: "label", id: "77", name: "77", number: 0, count: 0, icon: "label", selected: false }
    ]
  }
  SignalSpy { id: chosen; target: switcher; signalName: "rowChosen" }
  // The rows as given, taken once and put back before every case: one case
  // marks a row as the one in use.
  property var rowsAsGiven: []
  Component.onCompleted: rowsAsGiven = switcher.rows.slice()

  TestCase {
    name: "MailboxSwitcher"
    when: windowShown

    function init() { chosen.clear(); switcher.close(); switcher.rows = rowsAsGiven; wait(0) }

    function test_typing_narrows_and_enter_opens_the_match() {
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      compare(switcher.shown.length, 5, "nothing typed shows every row")
      compare(switcher.cursorIndex, 0, "the cursor rests on the row in use")
      keyClick(Qt.Key_I); keyClick(Qt.Key_N); keyClick(Qt.Key_V)
      compare(switcher.query, "inv")
      compare(switcher.shown.length, 1)
      compare(switcher.shown[0].name, "Work/Invoices")
      compare(switcher.cursorIndex, 0)
      keyClick(Qt.Key_Return)
      compare(chosen.count, 1)
      compare(chosen.signalArguments[0][0], 2, "chosen by its place in the full list")
      tryCompare(switcher, "opened", false)
    }

    function test_the_arrows_walk_what_is_left() {
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      keyClick(Qt.Key_W); keyClick(Qt.Key_O)
      compare(switcher.shown.length, 2, "Work and Work/Invoices")
      keyClick(Qt.Key_Down)
      compare(switcher.cursorIndex, 1)
      keyClick(Qt.Key_Down)
      compare(switcher.cursorIndex, 0, "and wrap")
      keyClick(Qt.Key_Up)
      compare(switcher.cursorIndex, 1)
      keyClick(Qt.Key_Return)
      compare(chosen.signalArguments[0][0], 2)
    }

    function test_a_bare_digit_still_opens_its_row() {
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      keyClick(Qt.Key_4)
      compare(chosen.count, 1)
      compare(chosen.signalArguments[0][0], 3, "the fourth row")
      tryCompare(switcher, "opened", false)
    }

    function test_a_digit_after_letters_is_a_letter() {
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      keyClick(Qt.Key_W); keyClick(Qt.Key_4)
      compare(chosen.count, 0)
      compare(switcher.query, "w4")
      compare(switcher.shown.length, 0, "and nothing is called that")
      keyClick(Qt.Key_Return)
      compare(chosen.count, 0, "Enter over nothing opens nothing")
    }

    // A digit is a key only where a row on show carries it; a folder called
    // by numbers no row carries is typed like any other name.
    function test_a_digit_no_row_carries_is_a_letter() {
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      keyClick(Qt.Key_7)
      compare(chosen.count, 0)
      compare(switcher.query, "7")
      keyClick(Qt.Key_7)
      compare(switcher.query, "77")
      compare(switcher.shown.length, 1)
      keyClick(Qt.Key_Return)
      compare(chosen.signalArguments[0][0], 4)
    }

    // A click on a narrowed row opens that row, not the row that sat in its
    // place before typing.
    function test_a_click_on_a_narrowed_row_opens_it() {
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      keyClick(Qt.Key_R); keyClick(Qt.Key_E); keyClick(Qt.Key_C)
      compare(switcher.shown.length, 1)
      var rows = []
      var kids = switcher.menuRows.children
      for (var i = 0; i < kids.length; i++) if (kids[i].objectName === "mailbox-row" && kids[i].visible) rows.push(kids[i])
      compare(rows.length, 1)
      mouseClick(rows[0], 20, rows[0].height / 2)
      wait(20)
      compare(chosen.count, 1)
      compare(chosen.signalArguments[0][0], 3, "Receipts, by its place in the full list")
    }

    // Typing it all away puts the cursor back on the row in use, and Escape
    // closes with nothing chosen.
    function test_clearing_rests_the_cursor_and_escape_closes() {
      switcher.rows = switcher.rows.map(function(r, i) { var c = {}; for (var k in r) c[k] = r[k]; c.selected = i === 3; return c })
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      compare(switcher.cursorIndex, 3)
      keyClick(Qt.Key_W)
      compare(switcher.cursorIndex, 0)
      keyClick(Qt.Key_Backspace)
      compare(switcher.query, "")
      compare(switcher.cursorIndex, 3, "back on the row in use")
      keyClick(Qt.Key_Escape)
      tryCompare(switcher, "opened", false)
      compare(chosen.count, 0)
    }

    function test_opening_again_starts_clean() {
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      keyClick(Qt.Key_R); keyClick(Qt.Key_E); keyClick(Qt.Key_C)
      compare(switcher.shown.length, 1)
      switcher.close()
      tryCompare(switcher, "opened", false)
      switcher.openCentered()
      tryCompare(switcher, "opened", true)
      compare(switcher.query, "")
      compare(switcher.shown.length, 5)
    }
  }
}
