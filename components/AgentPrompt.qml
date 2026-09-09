import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "../agent/Agent.js" as Agent

// One contextual surface for mail and drafts. System AI runs in its terminal;
// only its explicit plaintext result comes back here, where the owner applies it.
FocusScope {
  id: root
  required property color textColor
  required property color accentColor
  required property color urgentColor
  required property color dimColor
  required property color popupBackgroundColor
  required property color popupBorderColor
  required property string panelFontFamily
  property var service: null
  property var composer: null
  property string messageId: ""
  property var messageIds: []
  property string subject: ""
  property string accountId: ""
  property var returnFocus: null
  property string localError: ""
  readonly property var fields: composer ? composer.currentFields() : ({})
  readonly property bool overSelection: messageIds.length > 1
  property bool opened: false
  visible: opened
  readonly property var job: {
    if (!service || !service.hasAgent) return null
    if (composer) {
      var drafts = service.agentJobsForDraft(fields)
      return drafts.length > 0 ? drafts[0] : null
    }
    if (overSelection) return service.agentSelectionJob(messageIds, accountId)
    var id = messageId
    return id !== "" ? service.agentJobFor(id, accountId) : null
  }
  readonly property bool working: Agent.isActive(job) || (!!service && !!service.agentStarting)
  readonly property string output: service && job && service.agentShownId === String(job.id)
    ? service.agentShownOutput : ""
  readonly property string answer: composer ? Agent.draftAnswer(job, output) : output
  readonly property bool draftChanged: !!composer && !!job && !!job.draftFingerprint
    && job.draftFingerprint !== Agent.draftFingerprint(fields)
  readonly property string errorText: localError || (service ? service.agentError || "" : "")
  signal dismissed()
  signal focusRequested()
  signal editingChanged(bool editing)
  onActiveFocusChanged: if (opened) editingChanged(activeFocus)
  anchors.fill: parent
  z: 60

  function watchJob() {
    if (!opened || !service || !job) return
    service.showAgentJob(String(job.id))
    if (job.resultReady || !Agent.isActive(job)) service.acknowledgeAgentJob(String(job.id))
  }
  onJobChanged: watchJob()
  onFieldsChanged: if (composer && opened && fields.draftKey !== openedDraftKey) close()
  property string openedDraftKey: ""

  function takeFocus() { field.contentItem.forceActiveFocus() }
  function openAt(sceneX, sceneY) { open() }
  function open() {
    localError = ""
    openedDraftKey = String(fields.draftKey || "")
    if (!opened) returnFocus = root.Window.activeFocusItem
    opened = true
    root.focusRequested()
    watchJob()
  }
  function openFor(id, subjectText, sceneX, sceneY) {
    var next = String(id || "")
    if (next !== messageId) field.text = ""
    messageId = next
    messageIds = []
    subject = String(subjectText || "")
    accountId = service ? String(service.activeAccountId || "") : ""
    openAt(sceneX, sceneY)
  }
  function openForSelection(ids, sceneX, sceneY) {
    field.text = ""
    messageIds = Array.isArray(ids) ? ids.slice() : []
    messageId = messageIds.length === 1 ? String(messageIds[0]) : ""
    subject = Agent.pluralizeMessages(messageIds.length)
    accountId = service ? String(service.activeAccountId || "") : ""
    openAt(sceneX, sceneY)
  }
  function openCenteredFor(id, subjectText) { openFor(id, subjectText, 0, 0) }
  function close() {
    if (!opened) return
    opened = false
    root.dismissed()
    var previous = returnFocus
    returnFocus = null
    Qt.callLater(function() {
      if (previous && previous.visible) previous.forceActiveFocus()
    })
  }
  function submit(promptText) {
    if (!service || working) return false
    var prompt = String(promptText || "").trim()
    if (prompt === "") return false
    field.text = prompt
    localError = ""
    var accepted = composer ? service.askAgentDraft(fields, prompt)
      : (overSelection ? service.askAgentMany(messageIds, prompt, accountId)
        : service.askAgent(messageId, prompt, accountId))
    if (!accepted) localError = service.agentError || "AI could not start. Check the message and try again."
    return accepted
  }
  function applyAnswer(replace) {
    if (!composer || !job || answer === "") return false
    // Re-resolve ownership immediately before editing, even if a From menu
    // or a restored draft changed under the response.
    var matches = service.agentJobsForDraft(composer.currentFields())
    if (matches.length === 0 || String(matches[0].id) !== String(job.id)) return false
    if (replace) composer.replaceBody(answer)
    else composer.insertAtCursor(answer)
    return true
  }

  Rectangle {
    id: dock
    anchors.fill: parent
    color: root.popupBackgroundColor
    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: 1
      color: root.popupBorderColor
    }
    Column {
      id: content
      anchors.fill: parent
      anchors.margins: Style.space(12)
      spacing: Style.space(8)
      Row {
        width: parent.width
        Text {
          width: parent.width - closeButton.width
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.composer ? "AI · " + (root.fields.subject || "Draft")
            : "AI · " + (root.subject || "Message")
          color: root.textColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }
        Button {
          id: closeButton
          objectName: "agent-close-button"
          width: Style.space(24)
          height: Style.space(24)
          bordered: true
          focusable: true
          horizontalPadding: 0
          verticalPadding: 0
          foreground: root.dimColor
          accent: root.accentColor
          fontFamily: root.panelFontFamily
          tooltipText: "Close AI · Esc"
          Accessible.name: "Close AI"
          ActionIcon {
            anchors.centerIn: parent
            name: "close"
            iconSize: Style.font.iconSmall
            color: root.dimColor
            fontFamily: root.panelFontFamily
          }
          onClicked: root.close()
        }
      }
      Row {
        width: parent.width
        spacing: Style.space(6)
        QQC.ComboBox {
          id: field
          objectName: "agent-prompt-field"
          property alias text: field.editText
          width: parent.width - askButton.width - parent.spacing
          implicitHeight: Math.max(askButton.height, Style.spacing.controlHeight)
          editable: true
          currentIndex: -1
          model: root.composer ? Agent.draftAsks() : Agent.mailAsks(root.overSelection)
          textRole: "label"
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.bodySmall
          Accessible.name: "Ask AI"
          onActivated: function(index) { editText = model[index].prompt }
          onAccepted: root.submit(editText)
          contentItem: QQC.TextField {
            objectName: "agent-prompt-editor"
            text: field.editText
            color: root.textColor
            font: field.font
            placeholderText: root.composer ? "Ask about this draft" : "Ask about this mail"
            placeholderTextColor: root.dimColor
            selectionColor: root.accentColor
            selectedTextColor: root.popupBackgroundColor
            background: null
            selectByMouse: true
            onTextEdited: field.editText = text
            Accessible.name: "Ask AI"
          }
          indicator: ActionIcon {
            name: "chevronDown"
            color: root.dimColor
            fontFamily: root.panelFontFamily
            x: field.width - width - Style.space(6)
            y: (field.height - height) / 2
          }
          rightPadding: indicator.width + Style.space(12)
          background: Rectangle {
            color: field.popup.visible ? Style.selectedFillFor(root.textColor, root.accentColor)
              : Style.normalFillFor(root.textColor, root.accentColor)
            border.width: 1
            border.color: field.activeFocus ? root.accentColor : root.popupBorderColor
          }
          delegate: QQC.ItemDelegate {
            required property int index
            required property var modelData
            width: field.width
            highlighted: field.highlightedIndex === index
            contentItem: Text {
              text: modelData.label
              textFormat: Text.PlainText
              color: root.textColor
              font: field.font
              elide: Text.ElideRight
            }
            background: Rectangle {
              color: parent.highlighted ? Style.selectedFillFor(root.textColor, root.accentColor)
                : Style.normalFillFor(root.textColor, root.accentColor)
            }
          }
          popup: QQC.Popup {
            width: field.width
            implicitHeight: Math.min(contentItem.implicitHeight + topPadding + bottomPadding, Style.space(280))
            padding: Style.space(4)
            function place() {
              var top = field.mapToItem(null, 0, 0).y
              var windowHeight = root.Window.height
              var next = top + field.height
              if (next + height > windowHeight) next = top - height
              y = Math.max(0, Math.min(next, windowHeight - height)) - top
            }
            onOpened: place()
            onHeightChanged: if (visible) place()
            contentItem: ListView {
              clip: true
              implicitHeight: contentHeight
              model: field.popup.visible ? field.delegateModel : null
              currentIndex: field.highlightedIndex
              QQC.ScrollIndicator.vertical: QQC.ScrollIndicator {}
            }
            background: Rectangle {
              color: root.popupBackgroundColor
              border.color: root.popupBorderColor
            }
          }
        }
        Button {
          id: askButton
          objectName: "agent-ask-button"
          text: "Ask AI..."
          foreground: root.textColor
          accent: root.accentColor
          bordered: true
          fontFamily: root.panelFontFamily
          fontSize: Style.font.caption
          focusable: true
          enabled: !root.working && String(field.text || "").trim() !== ""
          onClicked: root.submit(field.text)
        }
      }
      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.errorText || (root.service && root.service.agentStarting ? "Preparing mail and starting AI..."
          : (root.job ? Agent.stateLabel(root.job) + (Agent.isActive(root.job) ? " · Continue in the system AI terminal" : "")
            : "Opens your system AI. Its answer appears here."))
        color: root.errorText !== "" ? root.urgentColor : root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
      Flickable {
        id: answerFlick
        width: parent.width
        height: Math.max(Style.space(32), content.height - y - controls.implicitHeight - Style.space(16)
          - (changedNotice.visible ? changedNotice.implicitHeight + Style.space(8) : 0))
        contentWidth: width
        contentHeight: answerText.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        WheelScroller { view: answerFlick }
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        TextEdit {
          id: answerText
          objectName: "agent-result"
          width: answerFlick.width
          textFormat: TextEdit.PlainText
          text: root.output || Agent.detailText(root.job)
          readOnly: true
          selectByMouse: true
          activeFocusOnTab: true
          color: root.textColor
          selectionColor: root.accentColor
          selectedTextColor: root.popupBackgroundColor
          font.family: root.panelFontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: TextEdit.Wrap
          Accessible.name: "AI result"
        }
      }
      Text {
        id: changedNotice
        width: parent.width
        visible: root.draftChanged
        text: "This draft changed after the request. Review before inserting or replacing."
        color: root.dimColor
        font.family: root.panelFontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
      Flow {
        id: controls
        width: parent.width
        spacing: Style.space(6)
        Button {
          text: "Close session"
          tooltipText: "Close the AI terminal session; background tools may continue."
          visible: Agent.isActive(root.job)
          foreground: root.urgentColor
          accent: root.urgentColor
          bordered: true
          fontFamily: root.panelFontFamily
          fontSize: Style.font.caption
          focusable: true
          onClicked: root.service.cancelAgentJob(String(root.job.id))
        }
        Button {
          text: "Copy"
          visible: root.output !== ""
          foreground: root.textColor
          accent: root.accentColor
          bordered: true
          fontFamily: root.panelFontFamily
          fontSize: Style.font.caption
          focusable: true
          onClicked: { answerText.selectAll(); answerText.copy(); answerText.deselect() }
        }
        Button {
          objectName: "agent-insert"
          text: "Insert at cursor"
          visible: !!root.composer && root.answer !== ""
          foreground: root.textColor
          accent: root.accentColor
          bordered: true
          fontFamily: root.panelFontFamily
          fontSize: Style.font.caption
          focusable: true
          onClicked: root.applyAnswer(false)
        }
        Button {
          objectName: "agent-replace"
          text: "Replace body"
          visible: !!root.composer && root.answer !== ""
          foreground: root.textColor
          accent: root.accentColor
          bordered: true
          fontFamily: root.panelFontFamily
          fontSize: Style.font.caption
          focusable: true
          onClicked: root.applyAnswer(true)
        }
      }
    }
  }
}
