import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "hverbruggen.omabisync"
  ipcTarget: "hverbruggen.omabisync"
  manageIpc: false

  readonly property var status: sync.status
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool failed: status.state === "failed" || status.state === "missing"
  readonly property bool syncing: status.state === "syncing"
  readonly property string heroMeta: Model.stateText(status, sync.nowMs)
  // Change groups the user has expanded, keyed by group key.
  property var expandedGroups: ({})

  function toggleGroup(key) {
    var next = {}
    for (var k in expandedGroups) next[k] = expandedGroups[k]
    next[key] = !next[key]
    expandedGroups = next
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    if (panelFlick) panelFlick.contentY = 0
    sync.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: sync
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { sync.refresh(); return "ok" }
    function syncNow(): string { sync.syncNow(); return "ok" }
    function status(): string { return root.status.state + ": " + root.heroMeta }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.stateGlyph(root.status.state)
    active: root.failed
    dimmed: root.status.state === "paused"
    tooltipText: root.opened ? "" : "Sync: " + root.heroMeta
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) sync.refresh()
      else if (buttonCode === Qt.MiddleButton) sync.openJournal()
      else root.toggle()
    }

    // A blinking dot in the glyph's bottom-right corner while a run is in progress.
    Rectangle {
      id: syncDot
      parent: button
      z: 10
      readonly property real size: 2
      visible: root.syncing
      width: size
      height: size
      radius: size / 2
      color: button.foreground
      x: Math.round(button.width / 2 + Style.bar.iconCanvas * 0.34)
      y: Math.round(button.height / 2 + Style.bar.iconCanvas * 0.30)

      SequentialAnimation on opacity {
        running: root.syncing
        loops: Animation.Infinite
        NumberAnimation { from: 1.0; to: 0.15; duration: 700; easing.type: Easing.InOutQuad }
        NumberAnimation { from: 0.15; to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = String(t).toLowerCase()
        if (k === "r") sync.refresh()
        else if (k === "s") sync.syncNow()
        else if (k === "j") sync.openJournal()
        else if (k === "o") sync.openFolder()
        else if (k === "p") sync.toggleTimer()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "omabisync"
            meta: (root.status.remote !== "" ? root.status.remote + " · " : "") + root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.status.state === "paused" ? 0.5 : 1.0
            iconComponent: Component {
              Text {
                text: Model.stateGlyph(root.status.state)
                color: root.failed ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            // Pauses or resumes the timer (not the run in progress).
            trailingControl: Component {
              ToggleSwitch {
                id: timerSwitch
                visible: root.status.timerExists === true
                checked: sync.timerOn
                busy: sync.busy
                foreground: hero.foreground
                onToggled: sync.toggleTimer()

                PanelToolTip {
                  visible: timerSwitch.containsMouse
                  text: sync.timerOn ? "Pause the timer (p)" : "Resume the timer (p)"
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: sync.actionStatus !== "" || sync.lastError !== ""
            width: parent.width
            text: sync.actionStatus !== "" ? sync.actionStatus : sync.lastError
            color: sync.lastError !== "" && sync.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair { label: "Local"; value: root.status.local || "—" }
            InfoPair { label: "Synced files"; value: Model.listingText(root.status.listing) }
            InfoPair {
              visible: Model.quotaText(root.status.quota) !== ""
              label: "Remote storage"
              value: Model.quotaText(root.status.quota)
            }
            InfoPair { label: "Next sync"; value: Model.nextRunText(root.status, sync.nowMs) }
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              iconText: "󰑓"
              text: root.syncing ? "Syncing…" : "Sync now"
              tooltipText: "Start a sync run (s)"
              enabled: !root.syncing && root.status.state !== "missing"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: sync.syncNow()
            }
            Button {
              iconText: "󰆍"
              text: "Journal"
              tooltipText: "Follow the journal in a terminal (j)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: { sync.openJournal(); root.close() }
            }
            Button {
              iconText: "󰉋"
              text: "Folder"
              tooltipText: "Open the local folder (o)"
              enabled: root.status.local !== ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: { sync.openFolder(); root.close() }
            }
          }

          Column {
            visible: root.status.errors.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "RECENT ERRORS"
              foreground: root.urgent
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.status.errors
              Text {
                required property var modelData
                textFormat: Text.PlainText
                width: parent.width
                text: Model.clockTime(modelData.ts) + "  " + modelData.message
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
                maximumLineCount: 3
                elide: Text.ElideRight
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "RECENT RUNS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            EmptyNote { visible: root.status.runs.length === 0; text: "No runs in the journal yet." }

            Repeater {
              model: root.status.runs
              RunRow {
                required property var modelData
                width: parent.width
                run: modelData
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "RECENT CHANGES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            EmptyNote {
              visible: root.status.changes.length === 0
              text: "No files changed in the last " + sync.historyDays + " days."
            }

            Repeater {
              model: root.status.changes
              Column {
                id: groupColumn
                required property var modelData
                readonly property bool single: modelData.count === 1 && modelData.files.length === 1 && !modelData.files[0].folded
                readonly property bool expanded: !single && root.expandedGroups[modelData.key] === true
                width: parent.width
                spacing: Style.space(2)

                ListRow {
                  width: parent.width
                  glyph: Model.actionGlyph(groupColumn.modelData.kind)
                  glyphColor: groupColumn.modelData.kind === "conflict" ? root.urgent : root.foreground
                  title: Model.changeTitle(groupColumn.modelData)
                  meta: Model.changeMeta(groupColumn.modelData, sync.nowMs)
                  trailing: groupColumn.single ? "" : (groupColumn.expanded ? "󰅀" : "󰅂")
                  clickable: true
                  onActivated: {
                    if (groupColumn.single) {
                      sync.openPath(groupColumn.modelData.files[0].path, groupColumn.modelData.kind)
                      root.close()
                    } else {
                      root.toggleGroup(groupColumn.modelData.key)
                    }
                  }
                }

                Repeater {
                  model: groupColumn.expanded ? groupColumn.modelData.files : []
                  FileLine {
                    required property var modelData
                    width: groupColumn.width
                    text: Model.fileTitle(groupColumn.modelData, modelData)
                    onActivated: {
                      sync.openPath(modelData.path, groupColumn.modelData.kind)
                      root.close()
                    }
                  }
                }

                Text {
                  visible: groupColumn.expanded && groupColumn.modelData.moreCount > 0
                  textFormat: Text.PlainText
                  leftPadding: Style.space(36)
                  text: "… and " + groupColumn.modelData.moreCount + " more (see Journal)"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }

  // One compact line per run: result, start time, duration, transfers, and
  // what bisync detected on each side.
  component RunRow: RowLayout {
    property var run: ({})
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: Model.runGlyph(run)
      color: run.result === "failed" ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Layout.leftMargin: Style.space(10)
    }
    Text {
      textFormat: Text.PlainText
      text: Model.clockTime(run.startTs)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      textFormat: Text.PlainText
      text: Model.duration(run.durationSec)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Layout.preferredWidth: Style.space(48)
    }
    Text {
      textFormat: Text.PlainText
      text: Model.runCounts(run)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      textFormat: Text.PlainText
      text: Model.runDetected(run)
      color: run.result === "failed" ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      Layout.fillWidth: true
      Layout.rightMargin: Style.space(10)
    }
  }

  // A file inside an expanded change group.
  component FileLine: CursorSurface {
    id: fileLine
    property string text: ""
    signal activated()

    hasCursor: fileMouse.containsMouse
    foreground: root.foreground
    implicitHeight: fileText.implicitHeight + Style.space(6)

    MouseArea {
      id: fileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: fileLine.activated()
    }

    Text {
      id: fileText
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(36)
      anchors.rightMargin: Style.space(10)
      text: fileLine.text
      color: root.foreground
      opacity: 0.85
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
    }
  }

  component ListRow: CursorSurface {
    id: row
    property string glyph: ""
    property color glyphColor: root.foreground
    property string title: ""
    property string meta: ""
    property bool clickable: false
    property string trailing: ""
    signal activated()

    hasCursor: clickable && rowMouse.containsMouse
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: row.clickable
      cursorShape: row.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: row.activated()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: row.glyph
        color: row.glyphColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.meta
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: row.trailing !== ""
        textFormat: Text.PlainText
        text: row.trailing
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }

  component EmptyNote: Text {
    textFormat: Text.PlainText
    width: parent ? parent.width : 0
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    horizontalAlignment: Text.AlignHCenter
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideLeft
  }
}
