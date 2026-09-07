import QtQuick
import "Model.js" as Model
import "../providers/Registry.js" as Provider

// Several rows at once: the ticked ones. One optimistic edit for the lot,
// one request where the client takes a list and one per row where it
// answers per message. Each row expands to its counted members the way a
// single action does, so a conversation row marked read reads as one
// across the rail as well as in the list. A second caller of the account's
// optimistic and restore machinery, kept beside it rather than in it: the
// account file is at its size ceiling.
QtObject {
  id: batch

  required property var account

  function run(ids, action) {
    var wanted = []
    var given = Array.isArray(ids) ? ids : []
    for (var g = 0; g < given.length; g++) wanted.push(String(given[g]))
    if (!account.ready || wanted.length === 0) return false
    if (account.refuseUnavailableAction(action)) return false
    // One mutation in flight at a time, for the same reason `act` waits: the
    // rows go back by the index they held. The line is per row, so a batch
    // asked for while another action finishes joins it one row at a time.
    if (account.pendingAction !== "") {
      for (var q = 0; q < wanted.length; q++) account.queueAction(wanted[q], action, account.cacheKey, false, false)
      return true
    }
    var sourceLabelId = account.hasLabels ? account.rawLabelId : ""
    var change = action === "trash" || action === "untrash"
      ? { add: [], remove: [] } : Model.labelChangesFor(action, sourceLabelId)
    if (!change) return false
    var rows = []
    var listed = []
    for (var l = 0; l < account.messages.length; l++) {
      if (wanted.indexOf(String(account.messages[l].id)) < 0) continue
      rows.push(account.messages[l])
      listed.push(String(account.messages[l].id))
    }
    if (listed.length === 0) return false

    // The account.messages this action is sent for: every row's counted members, as
    // for a single action, so no client expands anything.
    var conversationAction = Model.actionScope(action) === "conversation"
    var targets = []
    var targetsOf = ({})
    for (var r = 0; r < rows.length; r++) {
      var own = Model.actionTargets(rows[r], action)
      targetsOf[String(rows[r].id)] = own
      for (var o = 0; o < own.length; o++) {
        if (targets.indexOf(own[o]) < 0) targets.push(own[o])
      }
    }
    if (targets.length === 0) return false

    var actionQuery = account.cacheKey
    var actionEstimate = account.resultEstimate
    var actionToken = account.nextPageToken
    var before = account.messages.slice()
    var beforePreview = account.previewMessages.slice()
    var beforeSelected = account.selectedMessage
    var selectedWas = account.selectedId
    var interrupted = account.listLoading
    if (interrupted) {
      account.listSerial++
      account.abortRequest(account.listHandle)
      account.listHandle = null
      account.listLoading = false
      account.nextPageToken = ""
      actionToken = ""
    }

    // Every member summary the rail holds for a target takes the change; a
    // representative takes its row's, block and all. What each was is kept
    // so a refusal can put it back.
    var memberBefore = ({})
    var memberAfter = ({})
    var changedMembers = []
    function rememberBefore(id, summary) {
      if (changedMembers.indexOf(id) < 0) {
        changedMembers.push(id)
        memberBefore[id] = summary
      }
    }
    for (var t = 0; t < targets.length; t++) {
      var known = account.memberSummaries[targets[t]]
      if (!known) continue
      var after = Model.applyLabelChange(known, action, sourceLabelId)
      if (!after || after === known) continue
      rememberBefore(targets[t], known)
      memberAfter[targets[t]] = after
    }

    var next = []
    var nextPreview = account.previewMessages.slice()
    var unreadDelta = 0
    var selectedGone = false
    var removedIds = []
    for (var j = 0; j < account.messages.length; j++) {
      var row = account.messages[j]
      var rowId = String(row.id)
      if (listed.indexOf(rowId) < 0) {
        next.push(row)
        continue
      }
      var updated
      if (conversationAction) {
        // Every counted member was sent the same patch, so the row says so
        // at once rather than waiting for the next read to agree.
        updated = Model.applyLabelChange(row, action, sourceLabelId,
          Model.threadAfterAction(row, action))
      } else {
        var ownLabels = Model.applyLabelChange(row, action, sourceLabelId)
        var nextMembers = ({})
        for (var held in account.memberSummaries) nextMembers[held] = account.memberSummaries[held]
        for (var changed in memberAfter) nextMembers[changed] = memberAfter[changed]
        nextMembers[rowId] = ownLabels
        updated = Model.rowWithThread(ownLabels,
          Model.threadAfterMemberChange(row, nextMembers))
      }
      if (account.memberSummaries[rowId]) {
        rememberBefore(rowId, account.memberSummaries[rowId])
        memberAfter[rowId] = updated
      }
      if (action === "markRead" && row.unread && !updated.unread) unreadDelta--
      if (action === "markUnread" && !row.unread && updated.unread) unreadDelta++
      var survives = Model.survivesAction(account.mailboxKey, action, account.rawQuery, account.hasLabels,
        sourceLabelId, updated)
      if (survives) next.push(updated)
      else removedIds.push(rowId)
      if (Model.indexById(nextPreview, rowId) >= 0) {
        nextPreview = updated.unread
          ? Model.replaceById(nextPreview, updated)
          : Model.removeById(nextPreview, rowId)
      }
      if (Model.rowHoldsMember(row, account.selectedId)) {
        if (!survives) selectedGone = true
        else if (account.selectedId === rowId) account.selectedMessage = updated
        else if (memberAfter[account.selectedId]) account.selectedMessage = memberAfter[account.selectedId]
        else if (targets.indexOf(account.selectedId) >= 0 && account.selectedMessage)
          account.selectedMessage = Model.applyLabelChange(account.selectedMessage, action, sourceLabelId)
      }
    }
    if (changedMembers.length > 0) account.mergeMembers(memberAfter)
    account.inboxUnread = Math.max(0, account.inboxUnread + unreadDelta)
    var opaqueQuery = account.effectiveQuery
      !== Provider.query(account.providerId, account.mailboxKey, "", "")
    var invalidatesPage = removedIds.length > 0 || opaqueQuery
    account.messages = next
    account.previewMessages = nextPreview
    if (selectedGone) account.clearSelection()
    if (invalidatesPage) account.nextPageToken = ""
    var optimistic = account.messages.slice()
    var optimisticToken = account.nextPageToken
    if (!interrupted) account.rememberList()
    account.pendingActionQuery = actionQuery
    account.pendingAction = action

    // The member summaries behind a set of rows go back with them.
    function restoreMembersOf(rowIds) {
      for (var f = 0; f < rowIds.length; f++) {
        var owned = targetsOf[rowIds[f]] || []
        for (var m = 0; m < owned.length; m++) {
          if (memberBefore[owned[m]] !== undefined) account.rememberMember(memberBefore[owned[m]])
        }
        if (memberBefore[rowIds[f]] !== undefined) account.rememberMember(memberBefore[rowIds[f]])
      }
    }

    // A failure is not proof that nothing changed. One request per row
    // reports each on its own, and only the rows whose request failed go
    // back where they were. A provider that answers a whole batch with one
    // word — Gmail's batchModify, IMAP's plan across folders — may have done
    // part of it, so its failure is answered by reading the list again from
    // the server rather than by restoring rows the server may no longer have.
    var done = function(payload, error, failedIds) {
      account.pendingAction = ""
      account.pendingActionQuery = ""
      if (error) {
        var partial = Array.isArray(failedIds)
        if (partial && account.cacheKey === actionQuery
            && !account.deferredLoadCleared(actionQuery)) {
          account.messages = Model.restoreRows(account.messages, before, failedIds)
          account.previewMessages = Model.restoreRows(account.previewMessages, beforePreview, failedIds)
          restoreMembersOf(failedIds)
          if (!selectedGone && beforeSelected && beforeSelected.id === account.selectedId)
            account.selectedMessage = beforeSelected
          if (!interrupted) account.rememberList()
          account.refreshCounts()
          var note = Model.batchFailureNote(listed.length, failedIds.length, account.actionLabel(action), error)
          account.fail(note)
          // The refused rows are back, but the page is not whole: a refresh
          // that waited on this action still has to run, and a page token
          // the optimistic update cleared is read again from the server
          // rather than put back, because the rows that did go are gone and
          // the old token names a page that no longer starts where it did.
          if (account.resumeDeferredListLoad(actionQuery, note)) return
          if (invalidatesPage) account.loadMessages(false, true, note)
          return
        }
        if (partial) {
          // The view moved on while the batch ran — to another query, or
          // cleared for a reload of this one — so the pre-action page must
          // not come back, on screen or in the cache: the rows that did go
          // are gone from the server. Only the refused rows are put back,
          // into the cache that the next look at this query paints from
          // before it reads the server, and the page token is left empty
          // so that read starts from the top.
          restoreMembersOf(failedIds)
          var partNote = Model.batchFailureNote(listed.length, failedIds.length, account.actionLabel(action), error)
          account.fail(partNote)
          if (account.cache.loaded) {
            account.cache.putQuery(actionQuery, ({
              summaries: Model.restoreRows(optimistic, before, failedIds),
              estimate: actionEstimate, nextPageToken: ""
            }))
          }
          if (account.resumeDeferredListLoad(actionQuery, partNote)) return
          if (account.cacheKey === actionQuery) account.loadMessages(false, true, partNote)
          return
        }
        restoreMembersOf(listed)
        if (selectedWas !== "" && account.selectedId === selectedWas) account.selectedMessage = beforeSelected
        account.fail(error)
        if (account.resumeDeferredListLoad(actionQuery, error)) return
        if (account.cacheKey === actionQuery) account.loadMessages(false, true, error)
        else if (account.cache.loaded) {
          // Not on screen: the old page goes back into the cache so the next
          // visit reads the server rather than the optimistic guess.
          account.cache.putQuery(actionQuery, ({
            summaries: before, estimate: actionEstimate, nextPageToken: actionToken
          }))
        }
        return
      }
      account.note(Model.batchNote(listed.length, account.actionLabel(action)))
      account.refreshCounts()
      if (interrupted && account.deferredLoadCleared(actionQuery)
          && account.cache.loaded) {
        account.cache.putQuery(actionQuery, ({
          summaries: optimistic,
          estimate: actionEstimate,
          nextPageToken: optimisticToken
        }))
      }
      if (account.resumeDeferredListLoad(actionQuery, "")) return
      if (interrupted && account.cacheKey === actionQuery) {
        account.rememberList()
        account.loadMessages(false, true, "")
      } else if (interrupted && account.cache.loaded) {
        account.cache.putQuery(actionQuery, ({
          summaries: optimistic,
          estimate: actionEstimate,
          nextPageToken: optimisticToken
        }))
      } else if (invalidatesPage && account.cacheKey === actionQuery) {
        account.loadMessages(false, true, "")
      }
      if (account.active && account.cacheKey !== actionQuery)
        account.loadMessages(false, true, "")
    }

    if (action === "trash" || action === "untrash") {
      // One request per row, so each answers for itself: `trashMessage` and
      // `untrashMessage` take a row's whole list of members on every client.
      var remaining = listed.length
      var firstError = ""
      var failed = []
      var each = function(rowId) {
        return function(payload, error) {
          if (error) {
            if (firstError === "") firstError = String(error)
            failed.push(rowId)
          }
          remaining--
          if (remaining === 0) done(null, firstError, failed)
        }
      }
      for (var d = 0; d < listed.length; d++) {
        var owned = targetsOf[listed[d]]
        var sent = owned.length > 1 ? owned : owned[0]
        if (action === "trash") account.api.trashMessage(sent, each(listed[d]))
        else account.api.untrashMessage(sent, each(listed[d]))
      }
    } else {
      account.api.batchModify(targets, change.add, change.remove, done)
    }
    return true
  }
}
