import QtQuick

Item {
  property var command: []
  property bool running: false
  property bool stdinEnabled: false
  property string jobMode: ""
  property string written: ""
  property var stdout: StdioCollector {}
  property var stderr: StdioCollector {}
  signal started()
  signal exited(int exitCode)

  // Signals sent to the process, for a test to see; the stub does not exit
  // for them, a test says when it did.
  property var signalled: []
  function write(value) { written += String(value || "") }
  function signal(number) { signalled = signalled.concat([Number(number)]) }
}
