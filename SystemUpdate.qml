import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar's update indicator, with the review step the stock widget skips.
//
// Stock behaviour was: icon appears when Omarchy is behind, click runs
// omarchy-update, which upgrades the entire system. The gap is that the icon
// reports one package and the click changes every package. This adds the
// reading between them.
//
//   left click   open the panel and read what would change
//   right click  run omarchy-update straight away, as the stock icon did
//
// The icon still appears only when Omarchy itself is behind. Showing it for
// any pending package would light it up most days on Arch and cost it every
// bit of the meaning it has now.
//
// With `newsAlerts` on, it also appears for an unread post on omarchy.org's
// news feed, as a newspaper rather than the update arrows, so the two never
// read as the same thing. Both share one panel: news on top, packages below.
Panel {
  id: root
  // Kept as the built-in id on purpose: the shell routes IPC for a cloned
  // plugin through its source id, so `omarchy-shell omarchy.system-update ...`
  // keeps working against this copy.
  moduleName: "omarchy.system-update"
  ipcTarget: "omarchy.system-update"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var report: service.report
  readonly property bool hasData: report && report.ok
  readonly property bool reboots: Model.needsReboot(report)

  readonly property bool hasUpdate: service.updateAvailable
  readonly property bool newsOn: root.setting("newsAlerts", "Off") === "On"
  readonly property var unreadNews: service.unreadNews
  readonly property int newsCount: unreadNews.length

  property string filterText: ""
  readonly property var allSections: root.hasData ? Model.sections(root.report) : []
  readonly property var shownSections: Model.filterSections(allSections, filterText)
  readonly property bool filtering: filterText.trim() !== ""

  function runUpdate() {
    if (!hasUpdate)
      return
    if (bar)
      bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-update")
    close()
  }

  function refresh() {
    service.checkAvailable()
    service.checkNews("")
  }

  // Another monitor's copy marked the news read. Re-read its record rather
  // than fetch, so three monitors never mean three requests.
  function refreshNews() {
    service.checkNews("--cached")
  }

  function markNewsRead() {
    if (newsCount > 0)
      service.checkNews("--mark-read")
  }

  function openNews(link) {
    var safe = Model.safeNewsLink(link)
    if (safe !== "")
      Util.execArgv(["omarchy-launch-browser", safe])
  }

  function clear() {
    service.updateAvailable = false
  }

  function scrollBy(steps) {
    if (!panelFlick)
      return
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    panelFlick.contentY = Math.max(0, Math.min(maxY, panelFlick.contentY + steps * Style.space(48)))
  }

  visible: hasUpdate || newsCount > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    if (panelFlick)
      panelFlick.contentY = 0
    filterField.text = ""
    // Cached results are shown immediately; a stale cache refreshes behind
    // them. Opening the panel should never be a blank three-second wait.
    if (hasUpdate)
      service.scanIfStale()
    Qt.callLater(function () {
      keyCatcher.forceActiveFocus()
    })
  }

  Service {
    id: service
    scanPath: String(Qt.resolvedUrl("bin/omarchy-update-scan")).replace(/^file:\/\//, "")
    checkPath: String(Qt.resolvedUrl("bin/omarchy-update-check")).replace(/^file:\/\//, "")
    staleAfterMs: Math.max(1, root.setting("staleAfterMinutes", 10)) * 60000
    newsPath: String(Qt.resolvedUrl("bin/omarchy-update-news")).replace(/^file:\/\//, "")
    newsEnabled: root.newsOn
    onNewsMarkedRead: root.broadcastAll("refreshNews")
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void {
      root.open()
    }
    function close(): void {
      root.close()
    }
    function show(): void {
      root.open()
    }
    function hide(): void {
      root.close()
    }
    function toggle(): void {
      root.toggle()
    }
    function refresh(): void {
      root.broadcastAll("refresh")
    }
    function clear(): void {
      root.broadcastAll("clear")
    }
    function markNewsRead(): void {
      root.markNewsRead()
    }
  }

  // Panel has no broadcast() of its own (that lives on BarWidget), but a bar
  // surface still exists per monitor, so a refresh has to reach every copy or
  // the other screens keep a stale icon.
  function broadcastAll(method) {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i][method] === "function")
        items[i][method]()
    }
  }

  Timer {
    interval: Math.max(1, root.setting("checkIntervalHours", 6)) * 3600000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.hasUpdate ? "" : "\uf1ea"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    active: root.opened
    tooltipText: Model.barTooltip(root.report, service.scanning, root.hasUpdate, root.newsCount)
    onPressed: function (buttonCode) {
      // Right click only ever means "update". With nothing to update it opens
      // the panel like a left click, rather than doing nothing at all.
      if (buttonCode === Qt.RightButton && root.hasUpdate)
        root.runUpdate()
      else
        root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (dy !== 0)
          root.scrollBy(dy)
      }
      // Deliberately no onActivateRequested. Enter and Space both arrive here,
      // and in a panel whose only action upgrades the whole system, neither is
      // a gesture anyone means. The arrows here scroll the list rather than
      // move a cursor between controls, so there is nothing for Enter to
      // activate anyway: reading the list would have been the thing that armed
      // it. `u` stays the keyboard path, it is a deliberate letter and the
      // footer says so.
      //
      // While the filter has focus every key goes to it, so typing a package
      // with a "u" in its name can never start an update.
      blocked: filterField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function (direction) {
        root.switchPanel(direction)
      }
      onTextKey: function (t) {
        if (t === "/" && filterField.visible)
          filterField.forceActiveFocus()
        else if ((t === "r" || t === "R") && root.hasUpdate)
          service.scan(true)
        else if (t === "u" || t === "U")
          root.runUpdate()
        else if (t === "n" || t === "N")
          root.markNewsRead()
      }

      ColumnLayout {
        id: body
        anchors.fill: parent
        spacing: Style.space(12)

        // Header and action are pinned; only the change list scrolls. The
        // decision you came here to make should never be scrolled off screen.
        PanelHero {
          Layout.fillWidth: true
          // Built in Model, not here: it is package-controlled version text
          // going into a shared component whose textFormat this plugin does
          // not own, so it is flattened before it gets there.
          title: root.hasUpdate ? Model.heroTitle(root.report, service.availableSummary) : "Omarchy news"
          meta: !root.hasUpdate ? Model.newsLine(root.newsCount) : (service.scanning && !root.hasData ? "Reading pending changes" : (root.hasData ? Model.summary(root.report) : ""))
          detail: root.reboots ? "REBOOT" : ""
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              text: root.hasUpdate ? "" : "\uf1ea"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display

              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: 1400
                loops: Animation.Infinite
                running: service.scanning
              }
            }
          }

          trailingControl: Component {
            PanelActionButton {
              iconText: ""
              tooltipText: "Re-check the mirrors"
              visible: root.hasUpdate
              enabled: !service.scanning
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: service.scan(true)
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: service.scanError
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Stated plainly and up front, because it is the one consequence of
        // this update that outlives the update.
        Text {
          Layout.fillWidth: true
          visible: root.reboots
          text: "A new kernel or compositor is in this set. Omarchy will offer a reboot when it finishes."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          Layout.fillWidth: true
          visible: root.hasData || root.newsCount > 0
          foreground: root.foreground
        }

        // Pinned above the list rather than inside it, so it is still there
        // after scrolling to the bottom of a two-hundred-package update.
        TextField {
          id: filterField
          Layout.fillWidth: true
          visible: root.hasUpdate && root.allSections.length > 0
          placeholderText: "Filter packages  ( / )"
          foreground: root.foreground
          font.family: root.fontFamily
          onTextChanged: {
            root.filterText = text
            if (panelFlick)
              panelFlick.contentY = 0
          }
          // Esc clears a filter first and leaves the field second, so it takes
          // two presses to close the panel from a filtered list, never one
          // press that loses what was typed. Enter hands the keys back to the
          // list so j and k scroll again.
          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Escape) {
              if (text !== "")
                text = ""
              else
                keyCatcher.forceActiveFocus()
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              keyCatcher.forceActiveFocus()
              event.accepted = true
            }
          }
        }

        Flickable {
          id: panelFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredHeight: column.implicitHeight
          contentWidth: width
          contentHeight: column.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
          }

          Column {
            id: column
            width: panelFlick.width
            spacing: Style.space(14)

            // News first. It is the shorter list, and the one that goes away
            // once read, where the packages stay until the update runs.
            Column {
              visible: root.newsCount > 0
              width: column.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "NEWS  " + root.newsCount
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                width: parent.width
                text: "From omarchy.org/news. Click a post to open it, n marks them read."
                textFormat: Text.PlainText
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                bottomPadding: Style.space(2)
              }

              Repeater {
                model: root.unreadNews
                NewsRow {
                  required property var modelData
                  width: parent.width
                  item: modelData
                }
              }

              Button {
                text: "Mark read"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                tooltipText: "Hides the newspaper until the next post"
                onClicked: root.markNewsRead()
              }
            }

            Text {
              visible: root.hasUpdate && root.hasData && root.allSections.length === 0
              width: parent.width
              text: "Nothing else is pending. Only Omarchy itself would change."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.hasUpdate && root.filtering && root.allSections.length > 0 && root.shownSections.length === 0
              width: parent.width
              text: "No pending package matches \"" + Model.plain(root.filterText.trim(), 60) + "\"."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.hasUpdate ? root.shownSections : []

              Column {
                required property var modelData
                width: column.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: modelData.title + "  " + modelData.rows.length
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  visible: modelData.note !== ""
                  width: parent.width
                  text: modelData.note
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  bottomPadding: Style.space(2)
                }

                Repeater {
                  model: modelData.rows
                  ChangeRow {
                    required property var modelData
                    width: parent.width
                    row: modelData
                  }
                }
              }
            }

            // A capped list has to admit it. The header above counts the whole
            // update, so without this line the two quietly disagree.
            Text {
              visible: text !== ""
              width: parent.width
              text: root.hasUpdate && root.hasData ? Model.omittedNote(root.report) : ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              topPadding: Style.space(2)
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          visible: root.hasUpdate
          foreground: root.foreground
        }

        Button {
          Layout.fillWidth: true
          visible: root.hasUpdate
          text: root.hasData ? "Update now" : "Update now (unreviewed)"
          iconText: ""
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          tooltipText: "Runs omarchy-update in a terminal"
          onClicked: root.runUpdate()
        }

        Text {
          Layout.fillWidth: true
          text: {
            var keys = []
            if (root.hasUpdate)
              keys.push("u update", "r re-check")
            if (filterField.visible)
              keys.push("/ filter")
            if (root.newsCount > 0)
              keys.push("n read")
            keys.push("esc close")
            return keys.join(" . ")
          }
          textFormat: Text.PlainText
          color: Qt.darker(root.foreground, 2.0)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }
    }
  }

  // One package. Name and where it comes from on the left, the version move
  // and the download on the right, so a column of these reads top to bottom
  // as "what" then "how much".
  component ChangeRow: Item {
    id: changeRow

    property var row: null

    implicitHeight: rowLabels.implicitHeight + Style.space(6)

    Column {
      id: rowLabels
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: changeRow.row ? changeRow.row.name : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          Layout.fillWidth: true
        }

        BorderSurface {
          visible: changeRow.row && changeRow.row.tag !== ""
          implicitWidth: tagText.implicitWidth + Style.space(8)
          implicitHeight: tagText.implicitHeight + Style.space(2)
          color: "transparent"
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec("normal", changeRow.row && changeRow.row.tag === "reboot" ? root.urgent : root.foreground, Color.accent)

          Text {
            id: tagText
            anchors.centerIn: parent
            text: changeRow.row ? Model.tagLabel(changeRow.row.tag) : ""
            textFormat: Text.PlainText
            color: changeRow.row && changeRow.row.tag === "reboot" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          text: changeRow.row ? Model.rowMeta(changeRow.row) : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }
      }

      Text {
        width: parent.width
        text: changeRow.row ? changeRow.row.from + " -> " + changeRow.row.to : ""
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.9)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // One post. Title, then date and the feed's one-line summary. The whole row
  // opens the post, and only ever an omarchy.org link: openNews checks it
  // again, here in the shell, whatever the script said.
  component NewsRow: Item {
    id: newsRow

    property var item: null
    readonly property bool opens: item ? Model.safeNewsLink(item.link) !== "" : false

    implicitHeight: newsLabels.implicitHeight + Style.space(6)

    Column {
      id: newsLabels
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        text: newsRow.item ? newsRow.item.title : ""
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.underline: newsMouse.containsMouse && newsRow.opens
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: newsRow.item ? [Model.newsDate(newsRow.item.date), newsRow.item.summary].filter(function (part) {
          return part !== ""
        }).join("  .  ") : ""
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.9)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: newsMouse
      anchors.fill: parent
      enabled: newsRow.opens
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openNews(newsRow.item.link)
    }
  }
}
