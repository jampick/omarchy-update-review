import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the questions the widget asks the system, and nothing else.
//
//   bin/omarchy-update-check   is Omarchy behind? (drives whether the icon shows)
//   bin/omarchy-update-scan    what exactly would change? (drives the panel)
//   bin/omarchy-update-news    anything unread on omarchy.org? (opt-in)
//
// Neither is run directly. Both go through bin/omarchy-update-bounded, which
// gives each one a process group, a deadline and a byte cap of its own. That
// matters because a Process here can only stop the child it started, while
// both producers are trees of timeout, checkupdates, pacman, git, jq and awk;
// and because StdioCollector has no size limit, so a cap applied on this side
// would already have buffered whatever it was meant to be limiting.
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
  property string checkPath: ""
  property int staleAfterMs: 10 * 60 * 1000

  property bool updateAvailable: false
  property string availableSummary: ""

  property bool scanning: false
  property var report: null
  property double scannedAt: 0
  property string scanError: ""

  readonly property bool stale: !report || (Date.now() - scannedAt) > staleAfterMs

  property string newsPath: ""
  property bool newsEnabled: false
  property var news: null
  readonly property var unreadNews: newsEnabled ? Model.unreadNews(news) : []

  signal scanFinished()
  signal newsMarkedRead()

  // `mode` is "" to fetch, "--cached" to re-read the last fetch without the
  // network, or "--mark-read". A request that arrives while one is running is
  // kept, not dropped, because a mark-read lost behind a fetch would leave the
  // icon lit for news already read.
  property string pendingNewsMode: ""
  property bool newsQueued: false

  function checkNews(mode) {
    if (newsPath === "" || (!newsEnabled && mode !== "--mark-read"))
      return
    if (newsProc.running) {
      if (!newsQueued || mode === "--mark-read")
        pendingNewsMode = mode || ""
      newsQueued = true
      return
    }
    newsProc.command = mode ? [newsPath, mode] : [newsPath]
    newsProc.running = true
  }

  onNewsEnabledChanged: {
    if (newsEnabled)
      checkNews("")
    else
      news = null
  }

  // A setting that is already On when the widget loads never changes, so the
  // handler above never fires, and the panel's first refresh can run before
  // the binding has settled. Asked once more after load, so news shows up
  // without waiting a whole interval.
  Component.onCompleted: Qt.callLater(function () {
    if (root.newsEnabled && !root.news)
      root.checkNews("")
  })

  // Cheap check: is the icon warranted at all. Leaves the temporary database
  // freshly synced as a side effect, which is why the scan that follows can
  // skip its own sync and cost nothing.
  function checkAvailable() {
    if (checkPath === "")
      return
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
    command: [root.checkPath]
    stdout: StdioCollector {
      id: availableOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      // Only 0 and 1 are answers. Anything else (3 from the check, 124 and
      // 125 from the boundary) means it could not tell, and the icon keeps
      // what it last knew. Reading those as "current" is what used to hide a
      // waiting update until the next tick, on whichever monitors lost the
      // race for the database.
      if (exitCode !== 0 && exitCode !== 1) {
        retryTimer.restart()
        return
      }
      retryTimer.stop()
      root.updateAvailable = exitCode === 0
      root.availableSummary = exitCode === 0 ? Model.plain(String(availableOut.text || "").trim(), 160) : ""
      // The check just synced the temporary database. Reading the detail now
      // is free, and it means the tooltip can say something true before the
      // panel is ever opened.
      if (root.updateAvailable)
        root.scan(false)
    }
  }

  // Short, because a failed check is nearly always a passing condition: a
  // network that has not come up yet after resume, or a mirror having a bad
  // minute. Waiting a full interval for the next try is how an update sat
  // unannounced for a day.
  Timer {
    id: retryTimer
    interval: 15 * 60 * 1000
    repeat: false
    onTriggered: root.checkAvailable()
  }

  Process {
    id: newsProc
    running: false
    command: []
    stdout: StdioCollector {
      id: newsOut
      waitForEnd: true
    }
    onExited: function (exitCode) {
      var marking = newsProc.command.length > 1 && newsProc.command[1] === "--mark-read"
      var parsed = Model.parseNews(newsOut.text)
      // A failed fetch keeps the posts already known, the same way a failed
      // update check keeps the icon.
      if (parsed && parsed.ok)
        root.news = parsed
      if (marking)
        root.newsMarkedRead()
      if (root.newsQueued) {
        var next = root.pendingNewsMode
        root.newsQueued = false
        root.pendingNewsMode = ""
        root.checkNews(next)
      }
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
      // 124 and 125 are the boundary's, not the scan's. The scan always exits
      // 0 with a JSON sentence explaining itself, so these two mean it was
      // stopped rather than that it answered, and there is nothing to parse.
      if (exitCode === 124 || exitCode === 125) {
        root.scanError = "The update check timed out. Try refreshing."
        root.scanFinished()
        return
      }
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

  // Backstop only. The scan carries its own deadline, and that one can
  // actually stop the work rather than just stop waiting for it, so it is set
  // to fire first. This is here for the case where the process never reports
  // at all, which would otherwise leave the panel spinning with no way back to
  // a usable state.
  Timer {
    interval: 170000
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
