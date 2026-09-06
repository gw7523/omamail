import QtQuick
import "Model.js" as Model
import "../providers/Registry.js" as Provider

// Changes to the label list — create beside or beneath a label, rename it,
// move it under another, delete it — and the counts of the labels watched
// for new mail. Every change goes to the provider first and reads the list
// back from the server after: a label is the server's fact, not this
// window's, and a Gmail label's id is only known once Gmail has made it.
// Beside the account rather than in it, which is at its size ceiling.
QtObject {
  id: labelActions

  required property var account

  // The account.labels watched for new mail, by id: set from the account entry, and
  // counted on every refresh the way the inbox is. A count that grew says so
  // on the status line; the rail's row carries the number either way.
  property bool monitoredLoading: false

  function refreshMonitored() {
    var ids = Array.isArray(account.monitoredIds) ? account.monitoredIds : []
    if (!account.ready || monitoredLoading || ids.length === 0) return
    monitoredLoading = true
    var remaining = ids.length
    var grown = []
    for (var i = 0; i < ids.length; i++) {
      (function(labelId) {
        account.api.getLabelCounts(labelId, function(counts, error) {
          if (!root) return
          remaining--
          if (!error && counts) {
            var index = Model.indexById(account.labels, labelId)
            if (index >= 0) {
              var before = Math.max(0, Math.floor(Number(account.labels[index].unread) || 0))
              var after = Math.max(0, Math.floor(Number(counts.unread) || 0))
              var updated = {}
              for (var key in account.labels[index]) updated[key] = account.labels[index][key]
              updated.unread = after
              updated.total = Math.max(0, Math.floor(Number(counts.total) || 0))
              account.labels = Model.replaceById(account.labels, updated)
              if (after > before && monitoredSeen[labelId] !== undefined)
                grown.push({ name: String(updated.name || labelId), delta: after - before })
              var seen = {}
              for (var k in monitoredSeen) seen[k] = monitoredSeen[k]
              seen[labelId] = after
              monitoredSeen = seen
            }
          }
          if (remaining === 0) {
            monitoredLoading = false
            if (grown.length > 0) account.note(Model.monitoredNote(grown))
            account.cache.putLabels(account.labels)
          }
        })
      })(String(ids[i]))
    }
  }

  // The last count each watched label was seen at, so a refresh knows growth
  // from the first read. Not persisted: a restart reads once and says nothing.
  property var monitoredSeen: ({})

  // Whether the label list can be changed from here, and the four changes:
  // create beside or beneath a label, rename it, move it under another,
  // delete it. Every one goes to the provider first and reloads the list
  // from the server after — a label is the server's fact, not this window's,
  // and a Gmail label's id is only known once Gmail has made it.
  readonly property bool canManageLabels: Provider.can(account.providerId, "manageLabels")

  function labelById(id) {
    var index = Model.indexById(account.labels, id)
    return index >= 0 ? account.labels[index] : null
  }

  // The path as a person reads it: the decoded name, which on IMAP is what
  // LIST's modified-UTF-7 spelled and on Gmail is the name itself. The wire
  // name — the id — is what goes back to the server for a folder it has.
  function labelPathOf(label) {
    return label ? String(label.name || label.rawName || "") : ""
  }

  function labelByPath(path) {
    for (var i = 0; i < account.labels.length; i++) if (labelPathOf(account.labels[i]) === String(path || "")) return account.labels[i]
    return null
  }

  function createLabel(parentPath, leaf) {
    if (!account.ready || !canManageLabels) return false
    var parent = labelByPath(parentPath)
    var delimiter = Model.labelDelimiter(parent || (account.labels.length > 0 ? account.labels[0] : null))
    var problem = Model.labelNameProblem(leaf, delimiter)
    if (problem !== "") { account.fail(problem); return false }
    var name = Model.labelPathJoin(parentPath, leaf, delimiter)
    account.api.createLabel(name, function(payload, error) {
      if (!root) return
      if (error) { account.fail("Could not create " + name + ": " + String(error)); return }
      account.note("Created " + name)
      reloadLabels()
    })
    return true
  }

  function renameLabel(id, leaf) {
    var label = labelById(id)
    if (!account.ready || !canManageLabels || !label) return false
    var delimiter = Model.labelDelimiter(label)
    var problem = Model.labelNameProblem(leaf, delimiter)
    if (problem !== "") { account.fail(problem); return false }
    var path = labelPathOf(label)
    var name = Model.labelPathJoin(Model.labelParent(path, delimiter), leaf, delimiter)
    if (name === path) return false
    account.api.renameLabel(String(label.id), name, function(payload, error) {
      if (!root) return
      if (error) { account.fail("Could not rename " + path + ": " + String(error)); return }
      account.note("Renamed to " + name)
      afterLabelMoved(label, name)
    })
    return true
  }

  function moveLabel(id, newParentPath) {
    var label = labelById(id)
    if (!account.ready || !canManageLabels || !label) return false
    var delimiter = Model.labelDelimiter(label)
    var path = labelPathOf(label)
    var name = Model.labelPathJoin(newParentPath, Model.labelLeaf(path, delimiter), delimiter)
    if (name === path) return false
    account.api.renameLabel(String(label.id), name, function(payload, error) {
      if (!root) return
      if (error) { account.fail("Could not move " + path + ": " + String(error)); return }
      account.note("Moved to " + name)
      afterLabelMoved(label, name)
    })
    return true
  }

  function deleteLabel(id) {
    var label = labelById(id)
    if (!account.ready || !canManageLabels || !label) return false
    var path = labelPathOf(label)
    account.api.deleteLabel(String(label.id), function(payload, error) {
      if (!root) return
      if (error) { account.fail("Could not delete " + path + ": " + String(error)); return }
      account.note("Deleted " + path)
      // The list this window was looking at may have been the label just
      // deleted; the inbox is the honest place to stand then.
      if (account.rawLabelId === String(label.id)) account.selectMailbox("inbox")
      reloadLabels()
    })
    return true
  }

  // The label on screen follows its own rename. Its new wire name is the
  // server's to spell, so the list is read again first and the label is
  // found by the name it now has; a rename of a label not on screen only
  // reloads.
  property string followLabelPath: ""

  function afterLabelMoved(label, newPath) {
    var wasOpen = account.rawQuery !== "" && account.rawQuery === Provider.labelQuery(account.providerId, String(label.rawName || label.name || ""))
    followLabelPath = wasOpen ? String(newPath || "") : ""
    reloadLabels()
  }

  function reloadLabels() {
    if (!account.ready) return
    account.api.getLabels(function(result, error) {
      if (!root || error) return
      account.labels = result
      account.cache.putLabels(result)
      if (followLabelPath !== "") {
        var moved = labelByPath(followLabelPath)
        followLabelPath = ""
        if (moved) account.selectLabel(String(moved.rawName || moved.name || ""), String(moved.id || ""))
        else account.selectMailbox("inbox")
      }
    })
  }
}
