import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Law 17: the page never scrolls. Mode switch and filter on top, a fixed-height
// machine list that scrolls in place, one footer line. Click a machine, or type
// to filter and press Enter, and gliff opens on it.
Panel {
  id: panel
  moduleName: "nixfred.gliff"
  manageIpc: false

  required property var widget

  readonly property color foreground: widget.bar ? widget.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color faint: Util.alpha(foreground, 0.08)
  readonly property color accent: Color.accent
  readonly property string fontFamily: widget.bar ? widget.bar.fontFamily : Style.font.family
  readonly property int rowHeight: Style.space(40)
  readonly property int headerHeight: Style.space(24)
  readonly property int listHeight: Style.space(300)

  property int cursor: 0
  property bool escHeld: false

  // ---- rows ---------------------------------------------------------------

  function hostPart(target) {
    var at = String(target).lastIndexOf("@")
    return (at >= 0 ? String(target).slice(at + 1) : String(target)).toLowerCase()
  }
  function shortName(target) { return hostPart(target).split(".")[0] }

  // Everything the list shows: section headers and machine rows, filtered.
  readonly property var rows: {
    var q = filter.text.trim().toLowerCase()
    var online = {}
    var peers = widget.peers || []
    for (var i = 0; i < peers.length; i++) {
      online[hostPart(peers[i].target)] = true
      online[String(peers[i].name).toLowerCase()] = true
    }
    var seen = {}
    var out = []
    function matches(label, target) {
      return q === "" || label.toLowerCase().indexOf(q) >= 0 || target.toLowerCase().indexOf(q) >= 0
    }
    var savedRows = []
    var saved = widget.saved || []
    for (var s = 0; s < saved.length; s++) {
      var host = hostPart(saved[s])
      seen[host] = true
      seen[shortName(saved[s])] = true
      var label = shortName(saved[s])
      if (!matches(label, saved[s])) continue
      savedRows.push({ kind: "host", label: label, target: saved[s], online: !!(online[host] || online[label]) })
    }
    var tailRows = []
    for (var p = 0; p < peers.length; p++) {
      if (seen[hostPart(peers[p].target)] || seen[String(peers[p].name).toLowerCase()]) continue
      if (!matches(peers[p].name, peers[p].target)) continue
      tailRows.push({ kind: "host", label: peers[p].name, target: peers[p].target, online: true })
    }
    if (savedRows.length > 0) out.push({ kind: "header", label: "USED BEFORE" })
    out = out.concat(savedRows)
    if (tailRows.length > 0) out.push({ kind: "header", label: "OMARCHY ON YOUR TAILNET" })
    return out.concat(tailRows)
  }
  readonly property var hostRows: rows.filter(function(r) { return r.kind === "host" })
  onHostRowsChanged: cursor = Math.max(0, Math.min(cursor, hostRows.length - 1))

  function activate() {
    var typed = filter.text.trim()
    if (hostRows.length > 0) widget.connect(hostRows[Math.max(0, Math.min(cursor, hostRows.length - 1))].target)
    else if (typed !== "") widget.connect(typed)
  }
  function move(dy) {
    if (hostRows.length === 0) return
    cursor = (cursor + dy + hostRows.length) % hostRows.length
    var idx = 0
    for (var i = 0; i < rows.length; i++) if (rows[i].kind === "host" && idx++ === cursor) { list.positionViewAtIndex(i, ListView.Contain); break }
  }

  onOpenedChanged: {
    if (opened) { filter.text = ""; cursor = 0; escHeld = false }
  }

  // ---- window -------------------------------------------------------------

  KeyboardPanel {
    id: kpanel
    anchorItem: panel.widget.anchorItem
    owner: panel.widget
    bar: panel.widget.bar
    open: panel.opened
    focusTarget: filter
    contentWidth: kpanel.fittedContentWidth(Style.space(460))
    contentHeight: kpanel.fittedContentHeight(content.implicitHeight, Style.space(640))

    // Hold the keyboard while open so Esc never leaks to the window beneath,
    // and close on the Esc release (see the Burn Bar 2.3.1 root cause).
    WlrLayershell.keyboardFocus: panel.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: filter.activeFocus
      onCloseRequested: panel.escHeld = true
      onMoveRequested: function(dx, dy) { panel.move(dy) }
      onActivateRequested: panel.activate()
      Keys.onReleased: function(event) {
        if (event.key === Qt.Key_Escape && panel.escHeld) { panel.escHeld = false; panel.widget.close(); event.accepted = true }
      }

      ColumnLayout {
        id: content
        width: parent.width
        spacing: Style.space(10)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          Text {
            text: String.fromCodePoint(0xF08B2)
            color: panel.accent
            font.family: panel.fontFamily
            font.pixelSize: Style.font.subtitle
          }
          Text {
            text: "GLIFF"
            color: panel.foreground
            font.family: panel.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            font.letterSpacing: 3
          }
          Item { Layout.fillWidth: true }
          ButtonGroup {
            options: [{ value: "mirror", label: "Mirror screen", tooltip: "Show the remote's focused screen" },
                      { value: "private", label: "Private screen", tooltip: "Create a screen that follows this window" }]
            value: panel.widget.mode
            foreground: panel.foreground
            accent: panel.accent
            fontFamily: panel.fontFamily
            focusable: false
            onChanged: function(v) { panel.widget.mode = v }
          }
        }

        TextField {
          id: filter
          Layout.fillWidth: true
          foreground: panel.foreground
          accent: panel.accent
          placeholderText: "Filter, or type user@host and press Enter"
          font.family: panel.fontFamily
          onAccepted: panel.activate()
          Keys.onDownPressed: panel.move(1)
          Keys.onUpPressed: panel.move(-1)
          Keys.onEscapePressed: panel.escHeld = true
          Keys.onReleased: function(event) {
            if (event.key === Qt.Key_Escape && panel.escHeld) { panel.escHeld = false; panel.widget.close(); event.accepted = true }
          }
        }

        // The only scroller on the page, in its own fixed box.
        Rectangle {
          Layout.fillWidth: true
          Layout.preferredHeight: panel.listHeight
          radius: Style.space(6)
          color: panel.faint
          clip: true

          ListView {
            id: list
            anchors.fill: parent
            anchors.margins: Style.space(4)
            model: panel.rows
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            spacing: Style.space(2)

            delegate: Item {
              id: row
              required property var modelData
              required property int index
              readonly property bool isHeader: modelData.kind === "header"
              readonly property int hostIndex: {
                if (isHeader) return -1
                var n = 0
                for (var i = 0; i < index; i++) if (panel.rows[i].kind === "host") n++
                return n
              }
              readonly property bool current: !isHeader && hostIndex === panel.cursor
              width: list.width
              height: isHeader ? panel.headerHeight : panel.rowHeight

              Text {
                visible: row.isHeader
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData.label
                color: panel.dim
                font.family: panel.fontFamily
                font.pixelSize: Style.font.bodySmall * 0.9
                font.letterSpacing: 2
              }

              Rectangle {
                visible: !row.isHeader
                anchors.fill: parent
                radius: Style.space(5)
                color: mouse.containsMouse || row.current ? Util.alpha(panel.accent, 0.18) : "transparent"
                border.width: row.current ? 1 : 0
                border.color: Util.alpha(panel.accent, 0.6)

                Rectangle {
                  id: dot
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  color: row.modelData.online ? Color.accent : Util.alpha(panel.foreground, 0.25)
                }
                Column {
                  anchors.left: dot.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: row.modelData.label || ""
                    color: panel.foreground
                    font.family: panel.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: row.modelData.target || ""
                    color: panel.dim
                    font.family: panel.fontFamily
                    font.pixelSize: Style.font.bodySmall * 0.9
                  }
                }
                MouseArea {
                  id: mouse
                  anchors.fill: parent
                  hoverEnabled: true
                  onEntered: panel.cursor = row.hostIndex
                  onClicked: panel.widget.connect(row.modelData.target)
                }
              }
            }

            Text {
              visible: panel.rows.length === 0
              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              color: panel.dim
              font.family: panel.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: filter.text.trim() !== "" ? "No match. Press Enter to connect to \"" + filter.text.trim() + "\"."
                    : panel.widget.peersLoaded ? (panel.widget.probing > 0 ? "Checking your tailnet for Omarchy machines…" : "No Omarchy machines found. Type user@host above and press Enter.")
                    : "Looking for machines…"
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          Text {
            Layout.fillWidth: true
            elide: Text.ElideRight
            color: panel.widget.installed && panel.widget.peersError === "" ? panel.dim : Color.urgent
            font.family: panel.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: !panel.widget.installed ? "gliff is not installed. Run: omarchy pkg add gliff"
                  : panel.widget.peersError !== "" ? panel.widget.peersError + " (showing used-before machines only)"
                  : panel.widget.probing > 0 ? "Checking " + panel.widget.probing + " tailnet machine" + (panel.widget.probing === 1 ? "" : "s") + " for Omarchy…"
                  : panel.widget.mode === "private" ? "Private screen: a new remote screen sized to the window"
                  : "Mirror: the remote's focused screen"
          }
          Button {
            text: "Open Gliff"
            onClicked: panel.widget.connect("")
          }
        }
      }
    }
  }
}
