import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the two questions the widget asks the system, and nothing else.
//
//   omarchy-update-available   is Omarchy behind? (drives whether the icon shows)
//   bin/omarchy-update-scan    what exactly would change? (drives the panel)
//
// Both are read-only. The scan syncs a throwaway pacman database, never the
// real one, so nothing here can leave the system in a half-updated state or
// take a lock a real pacman run needs.
//
// Neither answer is trusted as it arrives. Both go through Model, which caps
// rows and string lengths and keeps only the fields the panel draws, so what
// reaches `report` is already bounded before a Repeater can turn it into
// delegates that outlive the panel.
Item {
  id: root

  property string scanPath: ""
  property int staleAfterMs: 10 * 60 * 1000

  property bool updateAvailable: false
  property string availableSummary: ""

  property bool scanning: false
  property var report: null
  property double scannedAt: 0
  property string scanError: ""

  readonly property bool stale: !report || (Date.now() - scannedAt) > staleAfterMs

  signal scanFinished()

  // Cheap check: is the icon warranted at all. Leaves the temporary database
  // freshly synced as a side effect, which is why the scan that follows can
  // skip its own sync and cost nothing.
  function checkAvailable() {
    if (!availableProc.running)
      availableProc.running = true
  }

  // `sync` false reuses the database the availability check just synced.
  function scan(sync) {
    if (scanning || scanPath === "")
      return
    scanProc.command = sync ? [scanPath] : [scanPath, "--nosync"]
    scanning = true
    scanProc.running = true
  }

  function scanIfStale() {
    if (stale)
      scan(true)
  }

  Process {
    id: availableProc
    running: false
    command: ["omarchy-update-available"]
    stdout: StdioCollector {
      id: availableOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      root.updateAvailable = exitCode === 0
      root.availableSummary = exitCode === 0 ? Model.plain(String(availableOut.text || "").trim(), 160) : ""
      // The check just synced the temporary database. Reading the detail now
      // is free, and it means the tooltip can say something true before the
      // panel is ever opened.
      if (root.updateAvailable)
        root.scan(false)
    }
  }

  Process {
    id: scanProc
    running: false
    command: []
    stdout: StdioCollector {
      id: scanOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      root.scanning = false
      var text = String(scanOut.text || "").trim()
      if (text === "") {
        root.scanError = "The update scan returned nothing."
        root.scanFinished()
        return
      }
      var parsed = Model.parseReport(text)
      if (!parsed) {
        root.scanError = "Could not parse the update scan output."
        root.scanFinished()
        return
      }
      root.report = parsed
      root.scanError = parsed.ok ? "" : (parsed.error || "Could not read pending updates.")
      root.scannedAt = Date.now()
      root.scanFinished()
    }
  }

  // Watchdog. A mirror that accepts the connection and then stalls would
  // otherwise leave the panel spinning with no way back to a usable state.
  Timer {
    interval: 150000
    running: root.scanning
    repeat: false
    onTriggered: {
      if (!root.scanning)
        return
      scanProc.running = false
      root.scanning = false
      root.scanError = "The update check timed out. Try refreshing."
      root.scanFinished()
    }
  }
}
