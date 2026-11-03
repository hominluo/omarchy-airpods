import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import qs.Ui
import qs.Commons

// Bluetooth headphones control panel (written for the AirPods, hence the id).
//
// Why this exists as its own plugin rather than a patch to omarchy.audio:
// the stock audio panel is a good general mixer and should keep receiving
// upstream fixes. Everything here is specific to one fragile Bluetooth
// controller, so it lives beside it instead of forking it.
//
// Since 2026-09-21 it follows whichever headphones or headset is connected
// (Surface Headphones prompted it): the call/music trouble below comes from
// this iMac's controller, not from the AirPods, so every pair hits it. The
// codec rows come from what `bt-call info` says the connected pair offers.
//
// What it manages (as of 2026-09-12):
//  - Call vs music: HFP carries mic and playback on one channel, A2DP has no
//    mic at all, so every call is a profile switch. WirePlumber's autoswitch
//    does it; bt-call-watch.service adds hysteresis because two upstream
//    regressions (wireplumber#1013, pipewire!2997) kill the mic on rapid
//    switches. This panel shows that and lets you pin either side.
//  - Call codec: mSBC (16 kHz) works on this Apple Broadcom controller only
//    with the btbcm_apple_quirk kernel module (btbcm-apple-quirk-dkms). If a
//    kernel upgrade drops it, mSBC calls go silent while the link looks fine;
//    the panel shows the module state and offers CVSD as the escape hatch.
//
// All state comes from `bt-call info`, which is deliberately cheap and never
// records. Never call `bt-call status` from here: it records for six seconds.
Panel {
  id: root
  moduleName: "io.github.hominluo.airpods"
  ipcTarget: "io.github.hominluo.airpods"

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  // The helper scripts live in the repository, so `omarchy plugin add` is the
  // whole install: nothing has to be copied into ~/.local/bin.
  readonly property string tool: root.pluginDir + "/bin/bt-call"

  // Any connected headphones or headset. BlueZ derives the icon from the
  // Class of Device (audio-headphones / audio-headset), so this skips
  // speakers, controllers and keyboards. Which pair the controls act on is
  // bt-call's choice (the first PipeWire bluez card); the hero shows its name.
  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var device: {
    var list = root.devices
    for (var i = 0; i < list.length; i++) {
      var d = list[i]
      if (d && d.connected === true && /^audio-head(phones|set)/.test(String(d.icon))) return d
    }
    return null
  }
  readonly property bool connected: !!device

  property string infoName: "Headphones"
  property string infoMode: "auto"
  property string infoProfile: ""
  property string infoCodec: ""
  property bool infoInCall: false
  property string infoUsers: ""
  property string infoDaemon: ""
  property bool infoQuirk: true
  property string infoHfpCodecs: ""
  property var infoA2dpCodecs: []
  property string infoA2dpPick: ""
  property bool busy: false

  // Suppress the connect popup for the first few seconds of a shell session.
  // Without it, logging in (or `omarchy restart shell`) reads as a fresh
  // connection and throws the panel in your face every time.
  property bool popupArmed: false

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : Style.hoverFillFor(Color.foreground, Color.accent)
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : Style.selectedFillFor(Color.foreground, Color.accent)

  readonly property bool msbcOffered: root.infoHfpCodecs.indexOf("msbc") >= 0

  // Playback codecs PipeWire may offer, best first. Anything not listed still
  // gets a row (sorted last, name upper-cased) so a new pair is never hidden.
  // Blurbs say what the codec is, never which brand it suits: the same row
  // shows for every pair. Bitrates are PipeWire's usual ones; SBC-XQ ranks
  // above AAC because it carries about twice the bits (the Galaxy Buds2 get
  // 480 kbps, 48 kHz dual channel at bitpool 37, measured 2026-09-22).
  readonly property var codecInfo: ({
    "ldac":    { rank: 0, title: "LDAC",    label: "LDAC · HIGH QUALITY",    blurb: "Sony · 330–990 kbps, adapts to the signal" },
    "aptx-hd": { rank: 1, title: "aptX HD", label: "APTX HD · HIGH QUALITY", blurb: "Qualcomm · 24-bit · about 576 kbps" },
    "sbc-xq":  { rank: 2, title: "SBC-XQ",  label: "SBC-XQ · HIGH QUALITY",  blurb: "About 450–550 kbps · SBC at its highest bitrate" },
    "aac":     { rank: 3, title: "AAC",     label: "AAC · HIGH QUALITY",     blurb: "Up to 320 kbps · efficient, more detail per bit" },
    "aptx":    { rank: 4, title: "aptX",    label: "APTX · GOOD QUALITY",    blurb: "Qualcomm · about 384 kbps, steady" },
    "sbc":     { rank: 5, title: "SBC",     label: "SBC · STANDARD",         blurb: "About 330 kbps · works with every headset" }
  })

  function codecTitle(c) { return root.codecInfo[c] ? root.codecInfo[c].title : c.toUpperCase() }
  function codecBlurb(c) { return root.codecInfo[c] ? root.codecInfo[c].blurb : "" }

  readonly property var playbackCodecs: {
    var list = root.infoA2dpCodecs.slice()
    list.sort(function(a, b) {
      var ra = root.codecInfo[a] ? root.codecInfo[a].rank : 99
      var rb = root.codecInfo[b] ? root.codecInfo[b].rank : 99
      return ra - rb
    })
    return list
  }

  readonly property string codecLabel: {
    if (root.infoInCall && root.infoCodec === "msbc") return root.infoQuirk ? "IN CALL · mSBC 16 kHz" : "IN CALL · mSBC — KERNEL FIX MISSING"
    if (root.infoInCall) return "IN CALL · CVSD 8 kHz"
    if (root.codecInfo[root.infoCodec]) return root.codecInfo[root.infoCodec].label
    if (root.infoCodec !== "") return root.infoCodec.toUpperCase()
    return root.connected ? "CONNECTED" : "DISCONNECTED"
  }

  function applyInfo(raw) {
    var lines = String(raw).trim().split("\n")
    var kv = {}
    for (var i = 0; i < lines.length; i++) {
      var idx = lines[i].indexOf("=")
      if (idx > 0) kv[lines[i].slice(0, idx)] = lines[i].slice(idx + 1)
    }
    if (kv["name"]) root.infoName = kv["name"]
    root.infoMode = kv["mode"] || "auto"
    root.infoProfile = kv["profile"] || ""
    root.infoCodec = kv["codec"] || ""
    root.infoInCall = kv["incall"] === "yes"
    root.infoUsers = kv["users"] || ""
    root.infoDaemon = kv["daemon"] || ""
    root.infoQuirk = kv["quirk"] !== "missing"
    root.infoHfpCodecs = kv["hfp_codecs"] || ""
    root.infoA2dpCodecs = kv["a2dp_codecs"] ? kv["a2dp_codecs"].split(",") : []
    root.infoA2dpPick = kv["a2dp_pick"] || ""
    root.busy = false
  }

  function refreshInfo() {
    if (!infoProc.running) infoProc.running = true
  }

  function runTool(args) {
    if (actionProc.running) return
    root.busy = true
    actionProc.command = [root.tool].concat(args)
    actionProc.running = true
  }

  function setMode(m) { runTool(["mode", m]) }
  function setCodec(c) { runTool(["codec", c]) }

  onConnectedChanged: {
    if (root.connected) {
      root.refreshInfo()
      if (root.popupArmed) root.open()
    } else {
      root.close()
    }
  }

  Timer { interval: 8000; running: true; repeat: false; onTriggered: root.popupArmed = true }

  Process {
    id: infoProc
    command: [root.tool, "info"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyInfo(text)
    }
  }

  Process {
    id: actionProc
    command: [root.tool, "info"]
    onExited: root.refreshInfo()
  }

  // The call watchdog ships with the plugin instead of being a systemd unit:
  // the bar widget starts it, Quickshell kills it on reload, and the daemon
  // holds a lock so a reload overlap cannot leave two of them fighting. This is
  // what keeps `omarchy plugin add` the only installation step.
  Process {
    id: daemonProc
    command: [root.pluginDir + "/bin/bt-call-daemon"]
    running: true
    onExited: daemonRestart.restart()
  }

  Timer {
    id: daemonRestart
    interval: 5000
    onTriggered: daemonProc.running = true
  }

  Component.onDestruction: daemonProc.running = false

  // Poll only while the panel is visible. The bar icon needs nothing but the
  // Bluetooth connection state, which arrives as a signal, so there is no
  // reason to run pw-dump every few seconds in the background.
  Timer {
    interval: root.opened ? 2000 : 15000
    running: root.connected
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshInfo()
  }

  implicitWidth: root.connected ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight
  visible: root.connected

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // 󰋎 md-headset — the mic boom distinguishes it from the stock audio panel's
    // 󰋋 md-headphones, which appears the moment headphones become the output.
    // 󰋐 md-headset_off in Music mode, where the mic really is dead: joining a
    // call there fails silently, so it is worth seeing from the bar.
    text: root.infoMode === "music" ? "󰋐" : "󰋎"
    onPressed: root.toggle()
  }

  // A selectable row, styled like the audio panel's device rows.
  component ChoiceRow: CursorSurface {
    id: choice
    required property string glyph
    required property string title
    required property string subtitle
    required property bool active
    property bool enabledRow: true
    signal picked()

    current: active
    foreground: root.bar ? root.bar.foreground : Color.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    opacity: enabledRow ? 1.0 : 0.4
    implicitHeight: choiceInner.implicitHeight + Style.spacing.xl

    Row {
      id: choiceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: choice.glyph
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - Style.space(22) - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          text: choice.title
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: choice.active
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          visible: choice.subtitle !== ""
          text: choice.subtitle
          color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: choice.enabledRow ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: choice.hasCursor = true
      onExited: choice.hasCursor = false
      onClicked: if (choice.enabledRow && !root.busy) choice.picked()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // No height cap: size to the content (KeyboardPanel still bounds it to the screen).
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      // Plain column, no ScrollView: everything fits, and a flickable would
      // add drag/overshoot behaviour that has nothing to scroll.
      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.infoMode === "music" ? "󰋐" : "󰋎"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.infoName
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.codecLabel
              color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Mode ----------
        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "MODE"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          ChoiceRow {
            width: parent.width
            glyph: "󰁪"
            title: "Automatic"
            subtitle: "Switches automatically when an app opens the mic"
            active: root.infoMode === "auto"
            onPicked: root.setMode("auto")
          }

          ChoiceRow {
            width: parent.width
            glyph: "󰏲"
            title: "Call"
            subtitle: root.msbcOffered
              ? "Mic stays live · voice quality (mSBC 16 kHz)"
              : "Mic stays live · voice quality (CVSD 8 kHz)"
            active: root.infoMode === "call"
            onPicked: root.setMode("call")
          }

          ChoiceRow {
            width: parent.width
            glyph: "󰝚"
            title: "Music"
            subtitle: "Full quality · mic off, even during calls"
            active: root.infoMode === "music"
            onPicked: root.setMode("music")
          }
        }

        // ---------- Call codec ----------
        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: root.infoInCall ? "CALL CODEC" : "CALL CODEC — PICK DURING A CALL"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          ChoiceRow {
            width: parent.width
            glyph: "󰍬"
            title: "mSBC"
            subtitle: root.msbcOffered
              ? (root.infoQuirk ? "16 kHz wideband · default" : "16 kHz · SILENT without the kernel fix")
              : "Not offered by this connection"
            active: root.infoInCall && root.infoCodec === "msbc"
            enabledRow: root.infoInCall && root.msbcOffered
            onPicked: root.setCodec("msbc")
          }

          ChoiceRow {
            width: parent.width
            glyph: "󰍬"
            title: "CVSD"
            subtitle: "8 kHz narrowband · works even without the kernel fix"
            active: root.infoInCall && root.infoCodec === "cvsd"
            enabledRow: root.infoInCall
            onPicked: root.setCodec("cvsd")
          }
        }

        // ---------- Playback quality ----------
        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            // bt-call-watch returns to the pair's own pick after the call, not to
            // PipeWire's default, so say which one that will be.
            text: !root.infoInCall ? "PLAYBACK QUALITY"
              : root.infoA2dpPick !== "" ? "PLAYBACK QUALITY — " + root.codecTitle(root.infoA2dpPick).toUpperCase() + " AFTER THE CALL"
              : "PLAYBACK QUALITY — UNAVAILABLE IN A CALL"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          // Only what the connected pair negotiated: AAC on the AirPods and the
          // Galaxy Buds2, aptX on the Surface Headphones, SBC/SBC-XQ on nearly everything.
          Repeater {
            model: root.playbackCodecs

            ChoiceRow {
              required property string modelData
              width: parent.width
              glyph: "󰘮"
              title: root.codecTitle(modelData)
              subtitle: root.codecBlurb(modelData)
              active: root.infoCodec === modelData
              enabledRow: !root.infoInCall
              onPicked: root.setCodec(modelData)
            }
          }
        }

        // ---------- Link ----------
        PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

        Column {
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "LINK"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: {
              var bits = []
              bits.push("profile " + (root.infoProfile || "—"))
              bits.push(root.infoUsers !== ""
                ? "mic held by " + root.infoUsers
                : "mic idle")
              bits.push("watchdog " + (root.infoDaemon || "?"))
              bits.push("kernel mSBC fix " + (root.infoQuirk ? "active" : "MISSING"))
              return bits.join("  ·  ")
            }
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          // The one failure that can come back silently after a kernel upgrade:
          // DKMS did not rebuild btbcm_apple_quirk, so mSBC links carry garbage.
          Text {
            textFormat: Text.PlainText
            visible: !root.infoQuirk
            width: parent.width
            wrapMode: Text.WordWrap
            text: "btbcm_apple_quirk is not loaded: mSBC calls will be silent. Use CVSD for now, then rebuild btbcm-apple-quirk (dkms) and reboot."
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            topPadding: Style.space(4)
          }

          // Shown only when it is actually relevant: an app pinning the mic is
          // the usual reason playback is stuck in call quality, and it is not obvious.
          Text {
            textFormat: Text.PlainText
            visible: root.infoInCall && root.infoUsers !== "" && root.infoMode === "auto"
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.infoUsers + " is holding the mic, so playback stays in call quality. Pick Music to force it back."
            color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            topPadding: Style.space(4)
          }
        }
      }
    }
  }
}
