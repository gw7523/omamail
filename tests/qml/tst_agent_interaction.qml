import QtQuick
import QtTest
import "../../components" as C
import "../../agent" as AI
import "../../agent/Agent.js" as Agent

Item {
  width: 800; height: 650
  QtObject {
    id: service
    property bool hasAgent: true
    property bool agentStarting: false
    property string agentError: ""
    property string activeAccountId: "imap:ada@example.com"
    property string agentShownId: ""
    property string agentShownOutput: ""
    property var jobs: []
    property bool accept: true
    property int calls: 0
    property string requestedId: ""
    function agentJobFor(id, account) { return Agent.jobFor(jobs,id,account) }
    function agentSelectionJob(ids, account) { return Agent.selectionJob(jobs,ids,account) }
    function agentJobsForDraft(fields) { return Agent.draftJobs(jobs,fields.accountId,fields.draftKey) }
    function showAgentJob(id) { agentShownId=id }
    function acknowledgeAgentJob(id) {}
    function askAgent(id, prompt, account) { requestedId=id; calls++; if (accept) agentStarting=true; return accept }
    function askAgentMany(ids, prompt, account) { return askAgent(ids[0],prompt,account) }
    function askAgentDraft(fields, prompt) { return askAgent("",prompt,fields.accountId) }
  }
  QtObject {
    id: draft
    property var fields: ({accountId:"imap:ada@example.com",draftKey:"d1",body:"Original",subject:"Plan"})
    property string applied: ""
    function currentFields() { return fields }
    function insertAtCursor(text) { applied=text }
    function replaceBody(text) { applied=text }
  }
  C.AgentPrompt {
    id: popup
    service: service
    onFocusRequested: takeFocus()
    textColor: Qt.rgba(0.93,0.93,0.93,1); accentColor: Qt.rgba(0.66,0.8,0.93,1); urgentColor: Qt.rgba(0.93,0.66,0.66,1); dimColor: Qt.rgba(0.6,0.6,0.6,1)
    popupBackgroundColor: Qt.rgba(0.13,0.13,0.13,1); popupBorderColor: Qt.rgba(0.26,0.26,0.26,1); panelFontFamily: "monospace"
  }
  AI.AgentRunner { id: runner; pluginDir:"/synthetic" }
  TestCase {
    name: "AgentInteraction"
    when: windowShown
    function init() {
      popup.close(); popup.composer=null
      service.jobs=[];service.agentStarting=false;service.agentError="";service.calls=0;service.accept=true
      service.agentShownOutput="";service.agentShownId="";draft.applied=""
      draft.fields={accountId:service.activeAccountId,draftKey:"d1",body:"Original",subject:"Plan"}
    }
    function test_mouse_submit_keeps_popup_and_shows_async_error() {
      popup.openCenteredFor("m1","Mail")
      tryCompare(popup,"opened",true)
      var field=findChild(popup,"agent-prompt-field")
      field.text="Summarize"
      var button=findChild(popup,"agent-ask-button")
      verify(waitForRendering(popup))
      verify(waitForItemPolished(button))
      verify(button.enabled)
      verify(button.visible)
      mouseClick(button,button.width/2,button.height/2)
      compare(service.calls,1)
      compare(popup.opened,true)
      service.agentStarting=false
      service.agentError="The system terminal could not launch"
      compare(popup.errorText,service.agentError)
      compare(field.text,"Summarize")
    }
    function test_preset_is_editable_and_does_not_submit() {
      popup.openCenteredFor("m1", "Mail")
      var field = findChild(popup, "agent-prompt-field")
      verify(waitForRendering(popup))
      mouseClick(field, field.width - 8, field.height / 2)
      tryCompare(field.popup, "visible", true)
      keyClick(Qt.Key_Down)
      keyClick(Qt.Key_Return)
      tryCompare(field.popup, "visible", false)
      compare(service.calls, 0)
      compare(field.text, field.model[field.currentIndex].prompt)
      var editor = findChild(popup, "agent-prompt-editor")
      editor.forceActiveFocus()
      keyClick(Qt.Key_End)
      keyClick(Qt.Key_X)
      verify(field.text.endsWith("x"))
      keyClick(Qt.Key_Return)
      compare(service.calls, 1)
    }
    function test_close_icon_and_ask_position() {
      popup.openCenteredFor("m1", "Mail")
      var field = findChild(popup, "agent-prompt-field")
      var ask = findChild(popup, "agent-ask-button")
      compare(field.mapToItem(popup, 0, 0).y, ask.mapToItem(popup, 0, 0).y)
      verify(ask.mapToItem(popup, 0, 0).x > field.mapToItem(popup, 0, 0).x)
      var close = findChild(popup, "agent-close-button")
      verify(waitForRendering(popup))
      mouseClick(close, close.width / 2, close.height / 2)
      compare(popup.opened, false)
    }
    function test_return_cannot_submit_while_starting() {
      popup.openCenteredFor("m1","Mail")
      tryCompare(popup,"opened",true)
      verify(popup.submit("First"))
      var field=findChild(popup,"agent-prompt-field")
      field.forceActiveFocus()
      keyClick(Qt.Key_Return)
      compare(service.calls,1)
      compare(popup.submit("Second"),false)
    }
    function test_rejected_request_stays_open_with_prompt() {
      service.accept=false
      popup.openCenteredFor("m1","Mail")
      tryCompare(popup,"opened",true)
      compare(popup.submit("Keep my question"),false)
      verify(popup.errorText.length>0)
      compare(findChild(popup,"agent-prompt-field").text,"Keep my question")
      compare(popup.opened,true)
    }
    function test_full_plaintext_result_and_draft_identity() {
      popup.composer=draft
      popup.open()
      tryCompare(popup,"opened",true)
      service.jobs=[{id:"j1",accountId:service.activeAccountId,draftKey:"d1",kind:"draft",state:"running",resultReady:true,draftFingerprint:Agent.draftFingerprint(draft.fields)}]
      service.agentShownOutput="<b>Plain text</b>\n" + Array(100).join("Whole answer\n")
      compare(findChild(popup,"agent-result").text,service.agentShownOutput)
      verify(popup.applyAnswer(false))
      compare(draft.applied,service.agentShownOutput)
      draft.fields={accountId:service.activeAccountId,draftKey:"d2",body:"Different"}
      tryCompare(popup,"opened",false)
      draft.applied=""
      compare(popup.applyAnswer(true),false)
      compare(draft.applied,"")
    }
    function test_one_checked_message_submits_its_id() {
      popup.openForSelection(["only"],0,0)
      tryCompare(popup,"opened",true)
      verify(popup.submit("Explain"))
      compare(service.requestedId,"only")
    }

    function test_selection_does_not_show_single_message_result() {
      service.jobs=[{id:"old",messageId:"m1",accountId:service.activeAccountId,state:"running"}]
      popup.openForSelection(["m1","m2"],0,0)
      tryCompare(popup,"opened",true)
      compare(popup.job,null)
      compare(popup.working,false)
      verify(popup.submit("Compare both"))
    }

    function test_switching_result_while_reading_retries_latest_id() {
      runner.show("one")
      var shower=null
      for (var i=0;i<runner.children.length;i++) {
        var child=runner.children[i]
        if(child.command && child.command.indexOf("show")>=0) shower=child
      }
      verify(shower!==null)
      runner.show("two")
      shower.stdout.text=JSON.stringify({job:{id:"one"},output:"Old"})
      shower.running=false;shower.exited(0)
      compare(shower.command[shower.command.length-1],"two")
      compare(shower.running,true)
      compare(runner.shownOutput,"")
      shower.stdout.text=JSON.stringify({job:{id:"two"},output:"Latest"})
      shower.running=false;shower.exited(0)
      compare(runner.shownOutput,"Latest")
    }
  }
}
