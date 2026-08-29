import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// First-run setup and Tidal sign-in, without ever opening a terminal.
//
// Signing in to Tidal is awkward on every Linux client for the same reason:
// Tidal's PKCE flow redirects to https://tidal.com/android/login/auth, a remote
// URL, so nothing local can catch the callback. The usual answer is "paste this
// address into a form".
//
// Instead, `omarchy-tidal-auth` watches the clipboard. The user signs in, hits
// Ctrl+L Ctrl+C, and sign-in finishes on its own. The paste field below stays
// as a fallback for anyone whose clipboard manager gets in the way.
//
// Progress arrives through a JSON status file rather than parsed stdout: the
// file survives a plugin hot-reload mid-login, and it is the same handoff idiom
// Omarchy's own image picker uses.
Item {
  id: root

  property var svc: null
  property string pluginDir: ""
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"
  readonly property string statusPath: runtimeDir + "/omarchy-tidal-auth.json"
  readonly property string handoffPath: runtimeDir + "/omarchy-tidal-handoff.txt"
  readonly property string authBin: pluginDir + "/bin/omarchy-tidal-auth"

  // idle | starting | url | waiting | ok | fail
  property string authState: "idle"
  property string authMessage: ""
  property string loginUrl: ""

  readonly property bool busy: authState === "starting" || authState === "url" || authState === "waiting"
  readonly property bool signedIn: svc ? svc.signedIn : false

  // Same hot-reload hazard as the service: a status-file change or a process
  // exit can land after this object is gone.
  property bool alive: true
  Component.onDestruction: {
    root.alive = false
    authProcess.running = false
  }

  implicitHeight: column.implicitHeight

  function startLogin() {
    root.authState = "starting"
    root.authMessage = ""
    root.loginUrl = ""
    pasteField.text = ""
    handoffFile.setText("")
    authProcess.running = false
    authProcess.running = true
  }

  function cancelLogin() {
    authProcess.running = false
    root.authState = "idle"
    root.authMessage = ""
  }

  function submitPastedUrl() {
    if (pasteField.text.length === 0) return
    handoffFile.setText(pasteField.text)
    pasteField.text = ""
  }

  Process {
    id: authProcess
    command: [
      root.authBin, "login",
      "--open",
      "--handoff", root.handoffPath,
      "--status-file", root.statusPath,
      "--timeout", "600"
    ]
    running: false

    onExited: function(exitCode) {
      if (!root.alive) return
      // A non-zero exit with no status update means the helper itself failed
      // to start -- most likely tidalapi is missing.
      if (exitCode !== 0 && root.authState !== "fail" && root.authState !== "ok") {
        root.authState = "fail"
        root.authMessage = "the sign-in helper could not run"
      }
    }
  }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      if (!root.alive) return
      var payload
      try {
        payload = JSON.parse(text())
      } catch (e) {
        return
      }
      if (!payload || !payload.state) return
      root.authState = String(payload.state)
      root.authMessage = String(payload.message || "")
      if (payload.url) root.loginUrl = String(payload.url)
      if (root.authState === "ok" && root.svc) {
        // mopidy has just restarted; re-probe rather than wait for the tick.
        Qt.callLater(root.svc.probeBackend)
      }
    }
  }

  FileView {
    id: handoffFile
    path: root.handoffPath
    printErrors: false
    atomicWrites: true
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(14)

    // ---- checklist ----
    Column {
      width: parent.width
      spacing: Style.space(7)

      Repeater {
        model: [
          { label: "Mopidy running", ok: root.svc ? root.svc.backendState === "up" : false },
          { label: "MPRIS connected", ok: root.svc ? root.svc.connected : false },
          { label: "Companion extension", ok: root.svc ? root.svc.companionAvailable : false },
          { label: "Signed in to TIDAL", ok: root.signedIn }
        ]

        Row {
          id: checkRow
          required property var modelData
          spacing: Style.space(10)

          Text {
            text: checkRow.modelData.ok ? "●" : "○"
            color: checkRow.modelData.ok ? Color.accent : Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            text: checkRow.modelData.label
            color: checkRow.modelData.ok ? root.foreground : Color.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }
      }
    }

    Rectangle {
      width: parent.width
      height: Math.max(1, Style.space(1))
      color: Color.menu.border
      opacity: 0.45
    }

    // ---- idle: offer sign-in ----
    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: !root.busy && root.authState !== "ok" && !root.signedIn

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.authState === "fail" ? Color.urgent : Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        text: root.authState === "fail"
          ? ("Sign-in failed: " + root.authMessage)
          : "Sign in to TIDAL to start playing. Your browser opens on TIDAL's own page — nothing is typed here."
      }

      Button {
        text: root.authState === "fail" ? "Try again" : "Sign in to TIDAL"
        bordered: true
        focusable: true
        foreground: root.foreground
        accent: Color.accent
        onClicked: root.startLogin()
      }
    }

    // ---- in progress ----
    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: root.busy

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        text: "1.  Sign in to TIDAL in the browser window that just opened."
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        text: "2.  When the page finishes, press Ctrl+L then Ctrl+C to copy the address."
      }

      Row {
        spacing: Style.space(8)

        Text {
          id: pulse
          anchors.verticalCenter: parent.verticalCenter
          text: "●"
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall

          SequentialAnimation on opacity {
            running: root.busy
            loops: Animation.Infinite
            NumberAnimation { to: 0.25; duration: 700; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "Watching the clipboard — this finishes on its own."
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // Fallback for anyone whose clipboard manager swallows the copy.
      Row {
        width: parent.width
        spacing: Style.space(8)

        TextField {
          id: pasteField
          width: parent.width - pasteButton.width - Style.space(8)
          foreground: root.foreground
          accent: Color.accent
          onAccepted: root.submitPastedUrl()
        }

        Button {
          id: pasteButton
          text: "Paste"
          bordered: true
          focusable: true
          foreground: root.foreground
          accent: Color.accent
          onClicked: root.submitPastedUrl()
        }
      }

      Button {
        text: "Cancel"
        foreground: Color.muted
        accent: Color.accent
        onClicked: root.cancelLogin()
      }
    }

    // ---- done ----
    Column {
      width: parent.width
      spacing: Style.space(8)
      visible: root.authState === "ok" || (root.signedIn && !root.busy)

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        text: root.authState === "ok"
          ? "Signed in. Mopidy restarted with your session."
          : "Signed in to TIDAL."
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        text: "Press Super+M to search, or Super+Shift+M for lyrics."
      }
    }
  }
}
