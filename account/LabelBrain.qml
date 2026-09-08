import QtQuick
import Quickshell
import Quickshell.Io

import "../cache/Cache.js" as Cache
import "LabelBrain.js" as Brain

// One account's label profile: the file `scripts/label-brain.py` wrote,
// read once, scored against a message when the move-to picker opens, and
// added to as choices are made there. The rules are LabelBrain.js's; this
// holds the files.
//
// Two files, and neither is rewritten here. The profile is the build's,
// written whole by the script and only by it. Beside it, a journal: one
// line appended per choice made in the picker, and one per message that
// left its label — so what the window writes is only ever an append, one
// small command at a time, and nothing here reads a file to write it back.
// Reading is the profile plus the journal's lines newer than the build;
// the build reads the archive those choices moved messages into, and
// removes the journal it has folded in.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // Where the profiles live. A test points `dataHomeOverride` somewhere that
  // is not the owner's home.
  property string dataHomeOverride: ""
  readonly property string dataHome: dataHomeOverride !== "" ? dataHomeOverride
    : (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share"))
  readonly property string directory: dataHome + "/omamail/labels"

  // One profile per account, named as the cache names its own, so the name
  // can never leave the directory — see Cache.fileName — and its journal
  // beside it.
  property string accountId: ""
  readonly property string path: pathFor(accountId)
  function pathFor(id) { return directory + "/" + Cache.fileName(id) }
  function journalFor(profilePath) { return String(profilePath || "") + ".choices" }

  // The profile in memory: the file's counts with the journal's choices
  // added, then every choice made since. `loaded` says both files have
  // been read for this account (or found missing).
  property var profile: null
  property bool loaded: false
  // Bumped on every change to the profile in place, so what is bound to
  // `status` sees a change the object's identity does not show.
  property int revision: 0
  readonly property var status: { void revision; return Brain.status(profile) }
  readonly property bool present: !!profile && Number(profile.built) > 0

  signal restored()

  // The files the profile in memory belongs to, kept by hand: `path`, a
  // binding, is not to be read inside the change handler, where it may
  // still say the old name or already the new.
  property string ownPath: ""
  Component.onCompleted: {
    ownPath = pathFor(accountId)
    read()
  }

  // Moved elsewhere — a test or a capture pointing the files away from the
  // home — the files are the same account's, read again from there.
  onDataHomeOverrideChanged: {
    ownPath = pathFor(accountId)
    profile = null
    revision++
    cancelRead()
    read()
  }

  // Leaving an account: a read of its files still under way is let go —
  // its answers would come under the next account's name.
  onAccountIdChanged: {
    ownPath = pathFor(accountId)
    profile = null
    revision++
    cancelRead()
    read()
  }

  // Read both files again — after a build wrote the profile — once every
  // command still waiting has run, so the journal read is whole.
  function reload() { read() }

  property bool readPending: false
  property bool reading: false
  property int reads: 0
  property int readDone: 0
  function read() {
    loaded = false
    readPending = true
    pump()
  }
  function cancelRead() {
    readPending = false
    reading = false
    readDone = reads
    readRetried = false
    readWatchdog.stop()
    dropViews()
  }
  // The views of the read under way, so a read let go of does not leave
  // them waiting on a file.
  property var activeViews: []
  function dropViews() {
    var views = activeViews
    activeViews = []
    for (var i = 0; i < views.length; i++) if (views[i] && typeof views[i].destroy === "function") views[i].destroy()
  }
  // Each read is a fresh pair of file views made for it, so an answer can
  // belong to no read but its own: one from a read since let go is dropped.
  function startRead() {
    if (!readPending || reading || running || runner.running || jobs.length > 0) return
    readPending = false
    reading = true
    reads++
    profileAnswered = false
    journalAnswered = false
    readWatchdog.restart()
    var profileView = readerFactory.createObject(root, { path: ownPath })
    var journalView = readerFactory.createObject(root, { path: journalFor(ownPath) })
    activeViews = [profileView, journalView]
    if (!profileView || !journalView) {
      console.warn("omamail: could not open the label profile for reading")
      giveUpRead()
      return
    }
    // Each answers through a closure that names the view, so an answer
    // can belong to no read but its own.
    var views = [profileView, journalView]
    for (var i = 0; i < views.length; i++) {
      var view = views[i]
      view.generation = reads
      view.isProfile = view === profileView
      answerThrough(view)
      view.reload()
    }
  }
  // Through the view's own signal: on the real file view `loaded` names a
  // property as well as a signal, so it cannot be connected to by name.
  function answerThrough(view) {
    view.done.connect(function(ok) { root.fileAnswered(view, ok) })
  }
  function fileAnswered(view, ok) {
    // A file that answered is a read that can be tried again if a later
    // one hangs: the retry is one per hung read, not one per lifetime.
    if (ok && !!view && view.generation === reads && reading) readRetried = false
    var current = !!view && view.generation === reads && reading
    var content = ok ? String(view.text()) : ""
    var isProfile = !!view && view.isProfile === true
    if (view && typeof view.destroy === "function") view.destroy()
    var kept = []
    for (var i = 0; i < activeViews.length; i++) if (activeViews[i] !== view) kept.push(activeViews[i])
    activeViews = kept
    if (!current) return
    if (isProfile) { profileText = content; profileAnswered = true }
    else { journalText = content; journalAnswered = true }
    answered()
  }
  // A read that never answers does not hold everything behind it: the side
  // that did not answer is taken as an empty file, once, and the read is
  // tried again after; a second silence stands.
  property bool readRetried: false
  function giveUpRead() {
    if (!reading) return
    console.warn("omamail: the label profile did not read in time")
    dropViews()
    if (!profileAnswered) profileText = ""
    if (!journalAnswered) journalText = ""
    profileAnswered = true
    journalAnswered = true
    var retry = !readRetried
    readRetried = true
    answered()
    if (retry) read()
  }
  Timer {
    id: readWatchdog
    interval: root.commandTimeoutMs
    onTriggered: root.giveUpRead()
  }
  // A file view for one read. No file yet is the ordinary state of an
  // account nobody has built one for, not an error.
  Component {
    id: readerFactory
    FileView {
      id: view
      property int generation: 0
      property bool isProfile: false
      printErrors: false
      signal done(bool ok)
      onLoaded: view.done(true)
      onLoadFailed: view.done(false)
    }
  }
  // Both files answer, in either order; the second answer is the read.
  // What the files hold, plus the choices on their way to the journal —
  // in hand or waiting — which are in memory and not yet on disk; then
  // every choice made after.
  property bool profileAnswered: false
  property bool journalAnswered: false
  property string profileText: ""
  property string journalText: ""
  function applyEntry(entry, builtMs) {
    if (!entry || typeof entry !== "object") return
    // A choice from before the build began — or in its first instant — is
    // in the archive the build read.
    if (Number(entry.t || 0) <= builtMs) return
    if (entry.k === "learn") profile = Brain.learnFeatures(profile || Brain.emptyProfile(accountId), entry.label, entry.name, entry.feats, entry.w)
    else if (entry.k === "departure" && profile) Brain.noteDeparture(profile)
  }
  function applyLine(line, builtMs) {
    var text = String(line || "").trim()
    if (text === "") return
    var entry = null
    try { entry = JSON.parse(text) } catch (e) { entry = null }
    applyEntry(entry, builtMs)
  }
  function answered() {
    if (!profileAnswered || !journalAnswered || readDone === reads) return
    readDone = reads
    reading = false
    readWatchdog.stop()
    dropViews()
    profile = Brain.load(profileText)
    var builtMs = profile ? Brain.builtMsOf(profile) : 0
    var lines = journalText.split("\n")
    var i
    for (i = 0; i < lines.length; i++) applyLine(lines[i], builtMs)
    if (running && running.kind === "append" && running.path === ownPath) applyLine(running.line, builtMs)
    for (i = 0; i < jobs.length; i++) if (jobs[i].kind === "append" && jobs[i].path === ownPath) applyLine(jobs[i].line, builtMs)
    loaded = true
    revision++
    restored()
    pump()
  }

  function suggest(labels, currentLabelId, summary, bodyText) {
    return Brain.suggest(profile, labels, currentLabelId, summary, bodyText, Brain.SUGGESTIONS)
  }

  // A choice: added to the label chosen, twice over when the brain had not
  // suggested it, and appended to the journal. A profile that was never
  // built starts here, from choices alone, and says so by its `built` of
  // zero.
  function learn(labelId, labelName, summary, bodyText, suggested) {
    learnFeatures(labelId, labelName, Brain.features(summary, bodyText), suggested)
  }
  function learnFeatures(labelId, labelName, feats, suggested) {
    var weight = suggested === true ? 1 : 2
    profile = Brain.learnFeatures(profile || Brain.emptyProfile(accountId), labelId, labelName, feats, weight)
    revision++
    append(ownPath, { t: Date.now(), k: "learn", label: String(labelId || ""), name: String(labelName || ""), feats: feats, w: weight })
  }

  function noteDeparture() {
    if (!profile) return
    Brain.noteDeparture(profile)
    revision++
    append(ownPath, { t: Date.now(), k: "departure" })
  }

  // Forgetting is both files going, and the counts with them, after any
  // append still in hand — and a read of them under way is let go, since
  // what it would bring back is what is being forgotten.
  function forget() {
    cancelRead()
    profile = null
    loaded = true
    revision++
    remove(ownPath)
  }

  // The commands, one at a time, in the order they were asked for: an
  // append of one line to a journal, or the removal of a profile and its
  // journal. Each carries the paths it is for — never whatever `path` says
  // by the time it runs — so an account switch cannot misfile one. A read
  // waits for the queue to drain, and the queue does not start a command
  // while a read is under way, so neither sees half of the other.
  property var jobs: []
  readonly property alias runnerProcess: runner
  // How long a command may take before it is stopped.
  property int commandTimeoutMs: 10000

  function append(profilePath, entry) {
    var line = JSON.stringify(entry)
    jobs = jobs.concat([{ kind: "append", path: profilePath, line: line }])
    pump()
  }
  function remove(profilePath) {
    // Appends still waiting for these files are for counts that are going.
    var kept = []
    for (var i = 0; i < jobs.length; i++) if (!(jobs[i].kind === "append" && jobs[i].path === profilePath)) kept.push(jobs[i])
    jobs = kept.concat([{ kind: "remove", path: profilePath }])
    pump()
  }
  property var running: null
  function pump() {
    if (running || runner.running || reading) return
    if (jobs.length === 0) {
      if (readPending) startRead()
      return
    }
    var queue = jobs.slice()
    running = queue.shift()
    jobs = queue
    if (running.kind === "append") {
      // The line arrives as an argument, not inside the script; the file is
      // made 0600 by the umask if it is new, in a directory made 0700.
      runner.command = ["sh", "-c", "umask 077; mkdir -p \"$1\" && chmod 700 \"$1\" && printf '%s\\n' \"$3\" >> \"$2\"",
        "sh", directory, journalFor(running.path), running.line]
    } else {
      runner.command = ["rm", "-f", running.path, journalFor(running.path)]
    }
    watchdog.restart()
    runner.running = true
  }
  function finished(exitCode) {
    var done = running
    running = null
    watchdog.stop()
    if (exitCode !== 0 && done) console.warn("omamail: the label profile " + done.kind + " failed (" + exitCode + ")")
    pump()
  }

  Process {
    id: runner
    onExited: function(exitCode) { root.finished(exitCode) }
    // A command that never exits — it did not start — must not hold the
    // rest behind it.
    onRunningChanged: if (!running && root.running) Qt.callLater(function() { if (root.running && !runner.running) root.finished(1) })
  }

  Timer {
    id: watchdog
    interval: root.commandTimeoutMs
    onTriggered: if (root.running) {
      console.warn("omamail: a label profile command did not finish in time")
      if (runner.running) runner.signal(15)
    }
  }

}
