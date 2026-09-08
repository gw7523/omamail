import QtQuick

QtObject {
  property string path: ""
  property bool watchChanges: false
  property bool printErrors: false
  property bool atomicWrites: false
  signal loaded()
  signal fileChanged()
  signal loadFailed()
  signal saved()
  signal saveFailed(string error)

  // What was last written, and where, for a test to read; nothing touches
  // the disk. A write says it landed a moment later, as the real one does.
  property string writtenPath: ""
  property string writtenText: ""
  function reload() {}
  function text() { return "" }
  function setText(value) {
    writtenPath = path
    writtenText = String(value)
    Qt.callLater(function() { saved() })
  }
}
