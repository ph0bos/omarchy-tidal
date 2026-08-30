import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../lib/TidalApi.js" as Tidal

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

  // idle | starting | url | waiting | finishing | ok | fail
  property string authState: "idle"
  property string authMessage: ""
  property string loginUrl: ""

  // Reported by the helper once it starts waiting. Without wl-paste the
  // clipboard watcher cannot work and the paste field is the only way through;
  // without a browser opener the address has to be carried across by hand.
  property bool clipboardWatching: true
  property bool browserOpened: true

  readonly property bool busy: authState === "starting" || authState === "url"
    || authState === "waiting" || authState === "finishing"
  readonly property bool signedIn: svc ? svc.signedIn : false

  readonly property bool backendUp: svc ? svc.backendState === "up" : false
  readonly property bool mprisUp: svc ? svc.connected : false
  readonly property bool companionUp: svc ? svc.companionAvailable : false
  readonly property bool ready: backendUp && mprisUp && companionUp && signedIn

  // ---- the account ----
  //
  // Which account this is, so "sign out" is a decision rather than a gamble.
  // Fetched here rather than held in the service: it is settings-surface
  // detail, read when the surface is open and dropped when it closes.
  property var account: null

  function refreshAccount() {
    if (!root.signedIn) { root.account = null; return }
    Tidal.authStatus(function(info) {
      if (!root.alive) return
      root.account = info && info.logged_in ? info : null
    }, function() {
      if (root.alive) root.account = null
    })
  }

  onSignedInChanged: root.refreshAccount()
  Component.onCompleted: root.refreshAccount()

  readonly property string accountName: account && account.name ? String(account.name) : ""
  readonly property string accountEmail: {
    if (!account) return ""
    return String(account.email || account.username || "")
  }
  readonly property string accountQuality: account && account.quality
    ? String(account.quality).replace(/_/g, " ").toLowerCase() : ""

  // The wizard is not always the reason the plugin cannot play: mopidy may be
  // down, or the companion missing. Each check says what to do about itself,
  // because "○ Mopidy running" on its own is a diagnosis without a treatment.
  readonly property var checks: [
    {
      label: "Mopidy running",
      ok: root.backendUp,
      hint: "Not answering on 127.0.0.1:6680. Run:  omarchy-tidal-setup all"
    },
    {
      label: "MPRIS connected",
      ok: root.mprisUp,
      hint: "Mopidy is up but is not publishing MPRIS. mopidy-mpris needs "
            + "mopidy 4.0 or newer -- the repo package is a pre-release."
    },
    {
      label: "Companion extension",
      ok: root.companionUp,
      hint: "Lyrics, artwork and the TIDAL pages need it. Run:  "
            + "omarchy-tidal-setup backend"
    },
    {
      label: "Signed in to TIDAL",
      ok: root.signedIn,
      hint: "Sign in below. A TIDAL subscription is required."
    }
  ]

  function copyLoginUrl() {
    if (root.loginUrl === "") return
    Quickshell.execDetached(["bash", "-c",
      "printf %s " + Util.shellQuote(root.loginUrl) + " | wl-copy"])
  }

  function signOut() {
    logoutProcess.running = false
    logoutProcess.running = true
  }

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
    root.pasteError = ""
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

  property string pasteError: ""

  function submitPastedUrl() {
    var text = pasteField.text
    if (text.length === 0) return
    // The helper only acts on the redirect TIDAL lands on, and silently
    // ignores anything else. Say so here instead: an emptied field and no
    // reaction is the worst possible answer.
    if (text.indexOf("tidal.com/android/login/auth") === -1 || text.indexOf("code=") === -1) {
      root.pasteError = "That is not the address TIDAL redirected to. It "
        + "starts with https://tidal.com/android/login/auth and contains code=."
      return
    }
    root.pasteError = ""
    handoffFile.setText(text)
    pasteField.text = ""
  }

  Process {
    id: logoutProcess
    command: [root.authBin, "logout"]
    running: false
    onExited: {
      if (!root.alive) return
      root.authState = "idle"
      root.authMessage = ""
      root.loginUrl = ""
      if (root.svc) Qt.callLater(root.svc.probeBackend)
    }
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
      // A status file outlives the process that wrote it. Reopening the wizard
      // an hour later should not resume a sign-in that timed out long ago.
      var age = Date.now() / 1000 - Number(payload.ts || 0)
      if (age > 900) return
      root.authState = String(payload.state)
      root.authMessage = String(payload.message || "")
      if (payload.url) root.loginUrl = String(payload.url)
      if (payload.clipboard !== undefined) root.clipboardWatching = !!payload.clipboard
      if (payload.opened !== undefined) root.browserOpened = !!payload.opened
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
    spacing: Style.space(16)

    // ---- what this is ----
    Column {
      width: parent.width
      spacing: Style.space(3)

      Text {
        textFormat: Text.PlainText
        text: root.ready ? "Settings" : "Set up TIDAL"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        font.weight: Font.DemiBold
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        // Once everything is ready the block below says what to do next; two
        // copies of the same sentence reads as a mistake.
        visible: !root.ready
        wrapMode: Text.WordWrap
        text: "Four things have to be true before music comes out of it."
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    // ---- checklist ----
    Column {
      width: parent.width
      spacing: Style.space(9)

      Repeater {
        model: root.checks

        Column {
          id: checkItem
          required property var modelData
          width: column.width
          spacing: Style.space(3)

          Row {
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              // A tick for done and an open ring for outstanding: two shapes,
              // not two shades of the same dot.
              text: checkItem.modelData.ok ? "\uf00c" : "\uf10c"
              color: checkItem.modelData.ok ? Color.accent : Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              text: checkItem.modelData.label
              color: checkItem.modelData.ok ? root.foreground : Color.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // What to do about it, shown only while it is outstanding.
          Text {
            textFormat: Text.PlainText
            x: Style.space(24)
            width: parent.width - Style.space(24)
            visible: !checkItem.modelData.ok
            wrapMode: Text.WordWrap
            text: checkItem.modelData.hint
            color: Color.muted
            opacity: 0.75
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            lineHeight: 1.3
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

    // ---- the account ----
    //
    // Which account this is, so signing out is a decision rather than a
    // gamble about whose session is about to be thrown away.
    Column {
      width: parent.width
      spacing: Style.space(4)
      visible: root.signedIn && root.account !== null

      Text {
        textFormat: Text.PlainText
        text: "ACCOUNT"
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.3
        bottomPadding: Style.space(2)
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.accountName !== ""
        text: root.accountName
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.accountEmail !== ""
        text: root.accountEmail
        elide: Text.ElideRight
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.accountQuality !== ""
        text: "Streaming at " + root.accountQuality
        color: Color.muted
        opacity: 0.75
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // ---- options ----
    //
    // Omarchy's own Toggle, so a setting in this plugin looks like a setting
    // anywhere else in the shell.
    Column {
      width: parent.width
      spacing: Style.space(6)
      visible: root.signedIn

      Text {
        textFormat: Text.PlainText
        text: "OPTIONS"
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.3
        bottomPadding: Style.space(2)
      }

      Toggle {
        width: parent.width
        label: "Announce each track"
        description: "A notification with the sleeve, as playback moves on"
        checked: root.svc ? root.svc.notifyOnTrackChange : false
        onClicked: if (root.svc) root.svc.setNotify(!root.svc.notifyOnTrackChange)
      }
    }

    // ---- idle: offer sign-in ----
    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: !root.busy && root.authState !== "ok" && !root.signedIn

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.authState === "fail" ? Color.urgent : Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        lineHeight: 1.35
        text: root.authState === "fail"
          ? ("Sign-in failed: " + root.authMessage)
          : "Sign in to TIDAL to start playing. Your browser opens on TIDAL's "
            + "own page \u2014 nothing is typed here. A TIDAL subscription is "
            + "required; hi-res needs a plan that includes it."
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
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        text: root.browserOpened
          ? "1.  Sign in to TIDAL in the browser window that just opened."
          : "1.  Open this address in a browser and sign in to TIDAL."
      }

      // The address itself. Normally the browser has it already, but if
      // nothing could be opened this is the only way across -- and even when it
      // opened, a copyable link beats a window someone closed by accident.
      Row {
        width: parent.width
        spacing: Style.space(8)
        visible: root.loginUrl !== ""

        Text {
          textFormat: Text.PlainText
          id: urlText
          width: parent.width - copyButton.width - Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: root.loginUrl
          elide: Text.ElideRight
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          id: copyButton
          anchors.verticalCenter: parent.verticalCenter
          text: "Copy link"
          foreground: Color.muted
          accent: Color.accent
          onClicked: root.copyLoginUrl()
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        text: root.clipboardWatching
          ? "2.  When the page finishes, press Ctrl+L then Ctrl+C to copy the address."
          : "2.  When the page finishes, copy the address and paste it below."
      }

      Row {
        spacing: Style.space(8)
        visible: root.authState !== "finishing"

        Text {
          textFormat: Text.PlainText
          id: pulse
          anchors.verticalCenter: parent.verticalCenter
          text: "\u25cf"
          color: root.clipboardWatching ? Color.accent : Color.urgent
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
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          // wl-paste missing is not fatal -- the paste field still works -- but
          // waiting silently for a clipboard nobody can read is.
          text: root.clipboardWatching
            ? "Watching the clipboard \u2014 this finishes on its own."
            : "wl-paste is not installed, so the clipboard cannot be watched."
          color: Color.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // Restarting Mopidy takes a few seconds and the flow is not over until it
      // has, so it gets said rather than looking like a stall.
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: root.authState === "finishing"
        wrapMode: Text.WordWrap
        text: "Signed in. Restarting Mopidy with your session\u2026"
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      // Fallback for anyone whose clipboard manager swallows the copy.
      Column {
        width: parent.width
        spacing: Style.space(5)
        visible: root.authState !== "finishing"

        Row {
          width: parent.width
          spacing: Style.space(8)

          TextField {
            id: pasteField
            width: parent.width - pasteButton.width - Style.space(8)
            placeholderText: "Paste the address here"
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

        // Said before the paste is thrown away, rather than leaving an empty
        // field and no explanation.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.pasteError !== ""
          wrapMode: Text.WordWrap
          text: root.pasteError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Button {
        text: "Cancel"
        visible: root.authState !== "finishing"
        horizontalPadding: 0
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
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        // The account block above already says who is signed in; repeating it
        // here is only worth doing at the moment it becomes true.
        visible: root.authState === "ok"
        text: "Signed in. Mopidy restarted with your session."
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        wrapMode: Text.WordWrap
        color: Color.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        text: "Press Super+M to search, or Super+Shift+M for lyrics."
      }

      Button {
        text: "Sign out"
        horizontalPadding: 0
        foreground: Color.muted
        accent: Color.accent
        onClicked: root.signOut()
      }
    }
  }
}
