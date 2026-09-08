import QtQuick 2.15
import QtTest 1.3
import qs.Commons
import "../../components" as Mail
import "../../account" as Account

// The move-to picker leads with what the label brain suggests, headed and
// with its reasons, and the tree follows without repeating them; Return
// takes the top suggestion and says it was one. The brain itself learns a
// choice in memory at once and forgets on request.
Item {
  width: 700
  height: 600

  Mail.LabelPicker {
    id: picker
    textColor: Color.foreground
    accentColor: Color.accent
    dimColor: Color.foreground
    popupBackgroundColor: Color.foreground
    popupBorderColor: Color.foreground
    panelFontFamily: "monospace"
    labels: [
      { id: "Receipts", name: "Receipts", rawName: "Receipts", delimiter: "/", system: false },
      { id: "Travel", name: "Travel", rawName: "Travel", delimiter: "/", system: false },
      { id: "Travel/Flights", name: "Travel/Flights", rawName: "Travel/Flights", delimiter: "/", system: false },
      { id: "INBOX", name: "Inbox", system: true }
    ]
  }
  SignalSpy { id: chosen; target: picker; signalName: "labelChosen" }

  Account.LabelBrain {
    id: brain
    dataHomeOverride: "/tmp/omamail-qml-test-labels"
    accountId: "imap:ada@example.com"
  }
  // The visible texts named so under the list, each item once: a
  // ListView's contentItem is among its children already.
  function texts(item, name, out, seen) {
    out = out || []
    seen = seen || []
    if (seen.indexOf(item) >= 0) return out
    seen.push(item)
    if (item.objectName === name && item.visible !== false) out.push(String(item.text))
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) texts(kids[i], name, out, seen)
    if (item.contentItem) texts(item.contentItem, name, out, seen)
    return out
  }

  // The commands the brain has queued or in hand, for a journal path.
  function commandsFor(journalPath, kind) {
    var out = []
    var queue = brain.jobs || []
    for (var i = 0; i < queue.length; i++) if (queue[i].path + ".choices" === journalPath && (!kind || queue[i].kind === kind)) out.push(queue[i])
    if (brain.running && brain.running.path + ".choices" === journalPath && (!kind || brain.running.kind === kind)) out.push(brain.running)
    return out
  }

  TestCase {
    name: "LabelSuggestions"
    when: windowShown

    // Each case starts with nothing on its way to a file: the stubbed
    // directory maker never exits, so a write in hand would otherwise
    // outlive the case that queued it.
    function init() {
      chosen.clear(); picker.close(); picker.suggestions = []
      brain.jobs = []; brain.running = null; brain.runnerProcess.running = false; brain.runnerProcess.signalled = []
      brain.readPending = false; brain.reading = false; brain.readDone = brain.reads; brain.readRetried = false; brain.activeViews = []
      brain.loaded = true; brain.profile = null; brain.revision++
      brain.commandTimeoutMs = 10000
      wait(0)
    }

    function test_suggestions_lead_with_their_reasons_and_return_takes_the_first() {
      picker.suggestions = [
        { id: "Travel", name: "Travel", because: ["noreply@delta.com", "“flight”"] },
        { id: "Receipts", name: "Receipts", because: [] }]
      picker.open()
      tryCompare(picker, "opened", true)
      compare(picker.matchingLabels.map(function(r) { return r.id }), ["Travel", "Receipts", "Travel/Flights"],
        "suggestions first, then the rest of the tree")
      compare(picker.matchingLabels[0].group, "Suggested")
      compare(picker.matchingLabels[2].group, "All labels")
      compare(picker.cursorIndex, 0, "the cursor rests on the first suggestion")
      tryVerify(function() { return texts(picker.menuRows, "picker-reason").indexOf("noreply@delta.com · “flight”") >= 0 }, 1000)
      compare(texts(picker.menuRows, "picker-heading"), ["Suggested", "All labels"], "two groups, headed")
      keyClick(Qt.Key_Return)
      tryCompare(picker, "opened", false)
      compare(chosen.count, 1)
      compare(chosen.signalArguments[0][0], "Travel")
      compare(chosen.signalArguments[0][1], true, "and it says the choice was a suggestion")
    }

    function test_typing_keeps_a_suggestion_only_while_the_letters_name_it() {
      picker.suggestions = [{ id: "Travel", name: "Travel", because: ["noreply@delta.com"] }]
      picker.open()
      tryCompare(picker, "opened", true)
      keyClick(Qt.Key_R); keyClick(Qt.Key_E); keyClick(Qt.Key_C)
      compare(picker.matchingLabels.map(function(r) { return r.id }), ["Receipts"], "letters that do not name the suggestion drop it")
      compare(picker.matchingLabels[0].group, "", "and with no suggestion there is no heading")
      keyClick(Qt.Key_Return)
      compare(chosen.signalArguments[0][0], "Receipts")
      compare(chosen.signalArguments[0][1], false, "a row from the tree was not a suggestion")
    }

    // The list can shorten under the cursor while the picker is up — the
    // labels refreshed — and Return must still take a row.
    function test_the_cursor_follows_a_list_that_shortens_under_it() {
      picker.open()
      tryCompare(picker, "opened", true)
      picker.cursorIndex = 2
      var all = picker.labels
      picker.labels = all.slice(0, 2)
      compare(picker.cursorIndex, 1, "the cursor moves up to the last row left")
      keyClick(Qt.Key_Return)
      compare(chosen.count, 1, "and Return takes it")
      compare(chosen.signalArguments[0][0], "Travel")
      picker.labels = all
    }

    function test_no_suggestions_is_the_plain_tree() {
      picker.open()
      tryCompare(picker, "opened", true)
      compare(picker.matchingLabels.map(function(r) { return r.id }), ["Receipts", "Travel", "Travel/Flights"])
      compare(picker.matchingLabels[0].group, "")
      // Rows of the last open are torn down a frame later.
      tryVerify(function() { return texts(picker.menuRows, "picker-reason").length === 0 }, 1000)
      tryVerify(function() { return texts(picker.menuRows, "picker-heading").length === 0 }, 1000)
    }

    function test_the_brain_learns_a_choice_at_once_and_forgets_on_request() {
      verify(brain.path.indexOf("/tmp/omamail-qml-test-labels/omamail/labels/") === 0, brain.path)
      verify(brain.path.indexOf("ada") > 0, "named for the account: " + brain.path)
      compare(brain.journalFor(brain.path), brain.path + ".choices", "and its journal beside it")
      compare(brain.suggest(picker.labels, "", { from: { email: "bills@acme.com" }, subject: "Invoice" }, ""), [],
        "nothing learnt, nothing suggested")
      brain.learn("Receipts", "Receipts", { from: { email: "bills@acme.com" }, subject: "Invoice 1" }, "invoice attached", false)
      compare(brain.status.docs, 1)
      compare(brain.present, false, "a profile of choices alone was never built")
      var got = brain.suggest(picker.labels, "", { from: { email: "bills@acme.com" }, subject: "Invoice 2" }, "")
      compare(got.length, 1)
      compare(got[0].id, "Receipts")
      brain.noteDeparture()
      compare(brain.status.movedSince, 1)
      brain.forget()
      compare(brain.status.docs, 0)
      compare(brain.suggest(picker.labels, "", { from: { email: "bills@acme.com" }, subject: "Invoice 3" }, ""), [])
    }

    // A choice is one line appended to the journal by one command, with
    // the paths it is for, and the command is over when it exits; a
    // departure is a line of its own.
    function test_a_choice_is_one_line_appended_by_one_command() {
      brain.learn("Receipts", "Receipts", { from: { email: "bills@acme.com" }, subject: "Café invoice" }, "", false)
      verify(brain.running !== null, "the append runs at once")
      compare(brain.running.kind, "append")
      verify(brain.runnerProcess.running)
      compare(brain.runnerProcess.command[4], brain.directory, "given the directory to make")
      compare(brain.runnerProcess.command[5], brain.journalFor(brain.path), "and the journal to append to")
      var line = JSON.parse(brain.runnerProcess.command[6])
      compare(line.k, "learn")
      compare(line.label, "Receipts")
      compare(line.w, 2, "a choice the brain did not make counts double")
      compare(line.feats.from[0], "bills@acme.com")
      compare(line.feats.subject[0], "café", "as it was tokenised")
      verify(line.t > 0)
      brain.noteDeparture()
      compare(brain.jobs.length, 1, "the next waits its turn")
      brain.runnerProcess.running = false
      brain.runnerProcess.exited(0)
      compare(brain.running.kind, "append")
      compare(JSON.parse(brain.runnerProcess.command[6]).k, "departure")
      brain.runnerProcess.running = false
      brain.runnerProcess.exited(0)
      compare(brain.running, null)
    }

    // Forget removes both files after the append in hand, and drops the
    // appends still waiting, which were of counts that are going.
    function test_forget_removes_both_files_after_the_append_in_hand() {
      brain.learn("Receipts", "Receipts", { from: { email: "bills@acme.com" }, subject: "Invoice" }, "", false)
      brain.learn("Receipts", "Receipts", { from: { email: "bills@acme.com" }, subject: "Invoice 2" }, "", false)
      compare(brain.jobs.length, 1)
      brain.forget()
      compare(brain.jobs.length, 1, "the waiting append is dropped")
      compare(brain.jobs[0].kind, "remove")
      compare(brain.running.kind, "append", "the one in hand finishes first")
      brain.runnerProcess.running = false
      brain.runnerProcess.exited(0)
      compare(brain.running.kind, "remove")
      compare(brain.runnerProcess.command[0], "rm")
      compare(brain.runnerProcess.command[2], brain.path)
      compare(brain.runnerProcess.command[3], brain.journalFor(brain.path), "the journal goes with the profile")
    }

    // A command that does not finish in time is told to stop, and the next
    // goes ahead once it has exited; one that never started is let go.
    function test_a_command_that_does_not_finish_is_stopped() {
      brain.commandTimeoutMs = 200
      brain.learn("Receipts", "Receipts", { from: { email: "bills@acme.com" }, subject: "Invoice" }, "", false)
      brain.learn("Receipts", "Receipts", { from: { email: "bills@acme.com" }, subject: "Invoice 2" }, "", false)
      tryVerify(function() { return brain.runnerProcess.signalled.length > 0 }, 3000)
      compare(brain.runnerProcess.signalled[0], 15)
      verify(brain.running !== null, "stopped, not yet over")
      brain.runnerProcess.running = false
      brain.runnerProcess.exited(143)
      verify(brain.running !== null, "the next goes ahead")
      compare(brain.jobs.length, 0)
      // This one never starts: running falls with no exit.
      brain.runnerProcess.running = false
      tryVerify(function() { return brain.running === null }, 3000)
    }

    // A read waits for the commands in hand and waiting, so the journal it
    // reads is whole; nothing runs while it reads; and a choice made while
    // it reads — on its way to the journal, not yet in it — is kept.
    function test_a_read_waits_for_the_queue_and_the_queue_for_the_read() {
      brain.learn("Receipts", "Receipts", { from: { email: "bills@acme.com" }, subject: "Invoice" }, "", false)
      brain.reload()
      compare(brain.loaded, false)
      compare(brain.readPending, true, "the read waits")
      brain.learn("Travel", "Travel", { from: { email: "noreply@delta.com" }, subject: "Flight" }, "", false)
      compare(brain.status.docs, 2, "a choice made meanwhile counts now")
      compare(brain.jobs.length, 1, "and is queued to be written before the read")
      brain.runnerProcess.running = false
      brain.runnerProcess.exited(0)
      compare(brain.running.kind, "append", "the queue drains first")
      brain.runnerProcess.running = false
      brain.runnerProcess.exited(0)
      compare(brain.running, null)
      compare(brain.reading, true, "then the read starts")
      compare(brain.readPending, false)
      brain.learn("Work", "Work", { from: { email: "boss@example.com" }, subject: "Plan" }, "", false)
      compare(brain.running, null, "nothing runs while the files are read")
      compare(brain.jobs.length, 1)
      // Both files answer: the profile the build wrote, then the journal.
      brain.profileText = JSON.stringify({ version: 1, built: 1000, builtMs: 1000500, accountId: brain.accountId, docs: 3, labels: { Receipts: { name: "Receipts", docs: 3, bodies: 0, from: { "old@example.com": 3 }, domain: {}, to: {}, subject: {}, body: {} } } })
      brain.journalText = [
        JSON.stringify({ t: 1000499, k: "learn", label: "Receipts", name: "Receipts", feats: { from: ["stale@example.com"] }, w: 1 }),
        JSON.stringify({ t: 1000500, k: "learn", label: "Receipts", name: "Receipts", feats: { from: ["instant@example.com"] }, w: 1 }),
        JSON.stringify({ t: 2000000, k: "learn", label: "Travel", name: "Travel", feats: { from: ["noreply@delta.com"], subject: ["flight"] }, w: 2 }),
        "not json at all",
        JSON.stringify({ t: 2000001, k: "departure" }),
        ""].join("\n")
      brain.profileAnswered = true
      brain.journalAnswered = true
      brain.answered()
      compare(brain.loaded, true)
      compare(brain.reading, false)
      compare(brain.status.docs, 5, "the file's three, the journal's one newer than the build, and the choice on its way")
      compare(brain.profile.labels.Travel.from["noreply@delta.com"], 2)
      compare(brain.profile.labels.Work.from["boss@example.com"], 2, "the choice made while reading is kept")
      compare(brain.profile.labels.Receipts.from["stale@example.com"], undefined, "a choice from before the build is in the archive it read")
      compare(brain.profile.labels.Receipts.from["instant@example.com"], undefined, "and one from its first instant")
      compare(brain.status.movedSince, 1, "and a departure since counts")
      brain.answered()
      compare(brain.status.docs, 5, "a file that speaks twice is not read twice")
      verify(brain.running !== null, "and the queue goes on once the read is done")
      compare(JSON.parse(brain.runnerProcess.command[6]).label, "Work")
    }

    // Forget while the files are being read lets the read go: what it
    // would bring back is what is being forgotten.
    function test_forget_while_reading_lets_the_read_go() {
      brain.learn("Receipts", "Receipts", { from: { email: "bills@acme.com" }, subject: "Invoice" }, "", false)
      brain.runnerProcess.running = false
      brain.runnerProcess.exited(0)
      brain.reload()
      compare(brain.reading, true)
      brain.forget()
      compare(brain.reading, false)
      compare(brain.running.kind, "remove", "the files go")
      brain.profileText = JSON.stringify({ version: 1, built: 1, docs: 3, labels: { Receipts: { docs: 3, from: { "old@example.com": 3 } } } })
      brain.journalText = ""
      brain.profileAnswered = true
      brain.journalAnswered = true
      brain.answered()
      compare(brain.status.docs, 0, "a late answer brings nothing back")
      compare(brain.loaded, true)
    }

    // Leaving an account while its files are being read: the read is let
    // go, and its late answer is not taken for the next account's.
    function test_a_switch_while_reading_lets_the_read_go() {
      brain.reload()
      compare(brain.reading, true)
      var first = brain.reads
      brain.accountId = "imap:two@example.com"
      verify(brain.reads > first, "the next account's read begins")
      compare(brain.reading, true)
      compare(brain.readDone, first, "the first is let go")
      brain.profileText = JSON.stringify({ version: 1, built: 1, docs: 7, labels: { A: { docs: 7 } } })
      brain.journalText = ""
      brain.profileAnswered = true
      brain.journalAnswered = true
      brain.answered()
      compare(brain.status.docs, 7, "the second read's answer is this account's")
      brain.accountId = "imap:ada@example.com"
    }

    // A read that never answers is given up — the silent side as an empty
    // file — and tried once more; a second silence stands, and nothing
    // waits behind it.
    function test_a_read_that_never_answers_is_given_up() {
      brain.commandTimeoutMs = 200
      brain.readRetried = false
      brain.reload()
      compare(brain.reading, true)
      var first = brain.reads
      // The first silence gives up and tries again at once; the second stands.
      tryVerify(function() { return brain.loaded && !brain.reading }, 3000)
      compare(brain.readRetried, true)
      compare(brain.reads, first + 1, "tried once more, not again")
      compare(brain.status.docs, 0)
      brain.learn("Receipts", "Receipts", { from: { email: "bills@acme.com" }, subject: "Invoice" }, "", false)
      verify(brain.running !== null, "and commands go on")
    }

    // Leaving an account: the appends already queued carry that account's
    // paths, and the next account starts from its own files.
    function test_a_switch_leaves_the_old_accounts_appends_to_its_own_journal() {
      brain.accountId = "imap:one@example.com"
      var onePath = brain.path
      brain.loaded = true
      brain.learn("Receipts", "Receipts", { from: { email: "first@example.com" }, subject: "One" }, "", false)
      brain.accountId = "imap:two@example.com"
      var twoPath = brain.path
      verify(onePath !== twoPath)
      compare(brain.status.docs, 0, "the next account starts from its own files")
      compare(commandsFor(brain.journalFor(onePath), "append").length, 1, "the choice is on its way to the first account's journal")
      compare(commandsFor(brain.journalFor(twoPath)).length, 0, "and nothing is bound for the other")
      brain.accountId = "imap:ada@example.com"
    }
  }
}
