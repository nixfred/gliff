import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Gliff bar button. The widget owns all of its data (gliff's saved machines,
// tailscale peers, whether gliff is installed) because a widget cannot rely on
// a service under a third-party bar. The panel only asks and relays.
BarWidget {
  id: root
  moduleName: "nixfred.gliff"
  property var anchorItem: button

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null ? fallback : v
  }
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property bool showTailnet: String(setting("showTailnet", true)) !== "false"
  readonly property string sshUser: String(setting("defaultUser", "")) !== "" ? String(setting("defaultUser", "")) : Quickshell.env("USER")

  // "mirror" shows the remote's focused screen; "private" adds --headless.
  property string mode: String(setting("defaultMode", "mirror")) === "private" ? "private" : "mirror"
  property bool installed: true
  property bool installChecked: false
  property var saved: []      // user@host strings from gliff's config.toml
  property var candidates: [] // { name, target } online Linux tailnet nodes
  property var probed: ({})   // target -> true when the machine has /usr/share/omarchy
  property var peers: []      // candidates that answered "omarchy"
  property int probing: 0     // machines still being asked
  property bool peersLoaded: false
  property string peersError: ""

  implicitWidth: vertical ? barSize : Math.max(Style.space(30), glyph.implicitWidth + Style.space(16))
  implicitHeight: vertical ? Style.space(34) : barSize

  // ---- data ---------------------------------------------------------------

  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/gliff/config.toml"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.saved = root.parseMachines(text())
    onLoadFailed: root.saved = []
  }

  // gliff writes `machines = ["user@a", "user@b"]`, possibly over several lines.
  function parseMachines(toml) {
    var m = /^\s*(?:machines|recent_machines)\s*=\s*\[([\s\S]*?)\]/m.exec(toml || "")
    if (!m) return []
    var out = [], re = /"((?:[^"\\]|\\.)*)"|'([^']*)'/g, x
    while ((x = re.exec(m[1])) !== null) {
      var s = (x[1] !== undefined ? x[1] : x[2]).trim()
      if (s !== "" && out.indexOf(s) < 0) out.push(s)
    }
    return out
  }

  Process {
    id: tailscale
    command: ["tailscale", "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: root.parsePeers(text)
    }
    onExited: function(code) {
      if (code !== 0) { root.peers = []; root.peersLoaded = true; root.peersError = "tailscale unavailable" }
    }
  }

  function parsePeers(text) {
    var j
    try { j = JSON.parse(text) } catch (e) { peers = []; peersLoaded = true; peersError = "tailscale unavailable"; return }
    var selfName = j.Self ? j.Self.HostName : ""
    // Machines on your own tailnet are reached by short name, the way you ssh
    // to them and the way known_hosts remembers them. Nodes shared in from
    // another tailnet only resolve by their full name.
    var selfDomain = j.Self ? String(j.Self.DNSName || "").replace(/\.$/, "").split(".").slice(1).join(".") : ""
    var out = []
    var list = j.Peer || {}
    for (var k in list) {
      var p = list[k]
      if (!p.Online || p.OS !== "linux" || p.HostName === selfName) continue
      var dns = String(p.DNSName || "").replace(/\.$/, "")
      if (dns === "") continue
      var parts = dns.split(".")
      var sameNet = selfDomain !== "" && parts.slice(1).join(".") === selfDomain
      out.push({ name: p.HostName, target: sshUser + "@" + (sameNet ? parts[0] : dns) })
    }
    out.sort(function(a, b) { return a.name.localeCompare(b.name) })
    candidates = out
    peersLoaded = true
    peersError = ""
    applyProbed()
    probeUnknown()
  }

  function applyProbed() {
    peers = candidates.filter(function(c) { return probed[c.target] === true })
  }

  // Only Omarchy machines belong in the tailnet list, and tailscale cannot say
  // which those are. Ask each online Linux node once, read-only and without
  // prompts: BatchMode never asks for a password, so a machine we cannot reach
  // by key is simply left out. Answers are kept until the shell restarts.
  property var asked: ({})
  Process {
    id: probe
    stdout: SplitParser {
      onRead: function(line) {
        var f = line.split("\t")
        if (f.length < 2) return
        var p = root.probed
        p[f[0]] = f[1] === "omarchy"
        root.probed = p
        root.probing = Math.max(0, root.probing - 1)
        root.applyProbed()
      }
    }
    onExited: root.probing = 0
  }
  function probeUnknown() {
    if (probe.running) return
    var todo = []
    for (var i = 0; i < candidates.length; i++) {
      var t = candidates[i].target
      if (asked[t] === undefined) { asked[t] = true; todo.push(t) }
    }
    if (todo.length === 0) return
    probing = todo.length
    probe.command = ["sh", "-c",
      'for t in "$@"; do ( r=$(ssh -o BatchMode=yes -o ConnectTimeout=4 "$t" "test -d /usr/share/omarchy && echo omarchy" 2>/dev/null); printf "%s\\t%s\\n" "$t" "$r" ) & done; wait',
      "gliff-probe"].concat(todo)
    probe.running = true
  }

  Process {
    id: which
    command: ["sh", "-c", "command -v gliff >/dev/null"]
    onExited: function(code) { root.installed = code === 0; root.installChecked = true }
  }

  function refresh() {
    which.running = false; which.running = true
    configFile.reload()
    if (showTailnet) { tailscale.running = false; tailscale.running = true }
  }
  Component.onCompleted: refresh()

  // ---- actions ------------------------------------------------------------

  // Opens gliff on `target` ("user@host"). Empty target opens the bare app,
  // which shows its own tabs or an address bar.
  function connect(target) {
    var args = ["gliff"]
    if (mode === "private" && target !== "") args.push("--headless")
    if (target !== "") args.push(target)
    Quickshell.execDetached(args)
    close()
  }

  // ---- bar button ---------------------------------------------------------

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    active: false
    useActiveColor: false
    tooltipText: !root.installed ? "Gliff is not installed. Run: omarchy pkg add gliff" : "Gliff: open a remote desktop"

    Text {
      id: glyph
      anchors.centerIn: parent
      text: String.fromCodePoint(0xF0379)
      color: root.installed ? root.foreground : Util.alpha(root.foreground, 0.4)
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall * 1.25
    }

    onPressed: function(code) {
      if (root.bar) root.bar.hideTooltip(root)
      root.toggle()
    }
  }

  readonly property bool opened: panel.opened
  function open() { root.refresh(); panel.controller.show() }
  function close() { panel.controller.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() { close() }
  readonly property bool popoutSwitchClosing: false

  GliffPanel {
    id: panel
    widget: root
  }

  IpcHandler {
    target: "nixfred.gliff"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function connect(target: string): void { root.connect(target) }
    function status(): string {
      return JSON.stringify({ installed: root.installed, mode: root.mode, saved: root.saved, candidates: root.candidates, peers: root.peers, probing: root.probing, peersError: root.peersError })
    }
  }
}
