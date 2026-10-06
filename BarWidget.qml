import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Speaker icon in the bar with a popup listing every Sonos group plus Spotify
// search and grouping. All network work happens in the `sonos` helper next to
// this file, kept running in `serve` mode so a click never waits for it to
// start. Controls update the UI immediately; the helper confirms what the
// speakers report a moment later and polls every second while the popup is open.
Panel {
  id: root
  moduleName: "freber.sonos"
  ipcTarget: "freber.sonos"

  readonly property string helper: Qt.resolvedUrl("sonos").toString().replace(/^file:\/\//, "")
  readonly property var baseCommand: setting("hosts", "") !== ""
    ? [helper, "--hosts", String(setting("hosts", ""))] : [helper]

  property var groups: []
  property var rooms: []              // every speaker, with the coordinator ip of its group
  property string groupEdit: ""       // group that is expanded to speakers and chips
  property var pendingGroups: ({})    // room ip -> { group, until, alone, quiet } for joins/leaves in flight
  property bool loaded: false
  property string error: ""
  property real wheelAccumulator: 0
  property var volumeBaseline: null   // group and speaker volumes when a group drag began

  property string query: ""
  property var results: []
  property string searchError: ""
  property int selectedResult: 0
  property string targetIp: ""        // room search results play in
  property bool spotifyReady: true    // flips to false when Spotify isn't logged in
  property string spotifyClientId: "" // remembered so a re-login is one click
  property string connectError: ""

  readonly property var activeGroup: {
    for (var i = 0; i < groups.length; i++)
      if (groups[i].state === "PLAYING") return groups[i]
    return groups.length > 0 ? groups[0] : null
  }
  readonly property bool anyPlaying: !!activeGroup && activeGroup.state === "PLAYING"
  readonly property var targetGroup: {
    for (var i = 0; i < groups.length; i++)
      if (groups[i].ip === targetIp) return groups[i]
    return activeGroup
  }
  readonly property color dim: Qt.darker(bar ? bar.foreground : Color.foreground, 1.4)

  function glyph(code) { return String.fromCodePoint(code) }
  readonly property string iconSpeaker: glyph(0xF04C3)
  readonly property string iconPlay: glyph(0xF040A)
  readonly property string iconPause: glyph(0xF03E4)
  readonly property string iconNext: glyph(0xF04AD)
  readonly property string iconPrev: glyph(0xF04AE)
  readonly property string iconLink: glyph(0xF0337)
  readonly property string iconLogout: glyph(0xF0343)

  function request(msg) {
    if (helperProc.running) helperProc.write(JSON.stringify(msg) + "\n")
  }

  // Poll every second while the popup is open so changes made elsewhere show
  // up quickly; the bar icon only needs an occasional look.
  function watch() {
    request({ cmd: "watch", interval: opened ? 1 : 10, warm: opened && spotifyReady })
  }

  function receive(line) {
    var data
    try { data = JSON.parse(line) } catch (e) { return }
    if (data.type === "status") applyStatus(data)
    else if (data.type === "search") applySearch(data)
  }

  function applyStatus(data) {
    groups = data.groups || []
    // Keep showing requested group changes until the speakers report them.
    var pending = {}
    var now = Date.now()
    var fresh = data.rooms || []
    rooms = fresh.map(function(r) {
      var p = pendingGroups[r.ip]
      // A departing coordinator already "groups" itself; it is done once nobody else follows it.
      var done = p && (p.alone
        ? fresh.filter(function(m) { return m.group === r.ip }).length === 1
        : p.group === r.group)
      if (!p || done || now > p.until) return r
      pending[r.ip] = p
      return Object.assign({}, r, { group: p.group })
    })
    pendingGroups = pending
    volumeBaseline = null
    error = data.error || (groups.length === 0 ? "No Sonos speakers found" : "")
    loaded = true
    syncModels()
  }

  // Rows update in place so a poll never rebuilds a slider mid-drag.
  function syncList(model, list, defaults) {
    var same = model.count === list.length
    for (var i = 0; same && i < list.length; i++)
      same = model.get(i).ip === list[i].ip
    if (!same) model.clear()
    for (var j = 0; j < list.length; j++) {
      var item = Object.assign({}, defaults, list[j])
      if (same) model.set(j, item)
      else model.append(item)
    }
  }

  function syncModels() {
    syncList(groupModel, groups, { uuid: "", title: "", artist: "", state: "", volume: 0 })
    syncList(roomModel, rooms, { volume: 0 })
  }

  function patch(ip, fields) {
    groups = groups.map(function(g) { return g.ip === ip ? Object.assign({}, g, fields) : g })
    syncModels()
  }

  function patchRoom(ip, fields) {
    rooms = rooms.map(function(r) { return r.ip === ip ? Object.assign({}, r, fields) : r })
    syncModels()
  }

  function memberCount(ip) {
    var n = 0
    for (var i = 0; i < rooms.length; i++) if (rooms[i].group === ip) n++
    return n
  }

  function togglePlay(group) {
    if (!group) return
    var playing = group.state === "PLAYING"
    patch(group.ip, { state: playing ? "PAUSED_PLAYBACK" : "PLAYING" })
    request({ cmd: playing ? "pause" : "play", ip: group.ip })
  }

  function skip(group, direction) {
    if (!group) return
    request({ cmd: direction > 0 ? "next" : "prev", ip: group.ip })
  }

  function toggleMember(room, group) {
    if (room.ip === group.ip) { removeCoordinator(room, group); return }
    var joining = room.group !== group.ip
    var target = joining ? group.ip : room.ip
    var pending = Object.assign({}, pendingGroups)
    pending[room.ip] = { group: target, until: Date.now() + 10000 }
    pendingGroups = pending
    patchRoom(room.ip, { group: target })
    request(joining ? { cmd: "join", ip: room.ip, arg: group.uuid } : { cmd: "leave", ip: room.ip })
  }

  // The coordinator hands the group and its playback to another member, then
  // leaves; the expanded row follows the group to its new coordinator.
  function removeCoordinator(room, group) {
    var heir = null
    for (var i = 0; i < rooms.length && !heir; i++)
      if (rooms[i].group === group.ip && rooms[i].ip !== room.ip) heir = rooms[i]
    if (!heir) return

    var until = Date.now() + 10000
    var pending = Object.assign({}, pendingGroups)
    var names = []
    rooms = rooms.map(function(r) {
      if (r.group !== group.ip || r.ip === room.ip) return r
      names.push(r.name)
      pending[r.ip] = { group: heir.ip, until: until, quiet: true }
      return Object.assign({}, r, { group: heir.ip })
    })
    pending[room.ip] = { group: room.ip, until: until, alone: true }
    pendingGroups = pending

    groups = groups.map(function(g) {
      return g.ip === group.ip ? Object.assign({}, g, { ip: heir.ip, uuid: heir.uuid, name: names.join(" + ") }) : g
    }).concat([{ ip: room.ip, uuid: room.uuid, name: room.name, state: "STOPPED",
                 title: "", artist: "", volume: room.volume || 0 }])
      .sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1 })
    if (targetIp === group.ip) targetIp = heir.ip
    groupEdit = heir.ip
    syncModels()
    request({ cmd: "leave", ip: room.ip, arg: heir.uuid })
  }

  // The helper sends one level at a time per speaker, always the newest, so
  // levels never land out of order while a slider is dragged.
  function queueVolume(cmd, ip, volume) {
    request({ cmd: cmd, ip: ip, value: volume })
  }

  function setVolume(group, volume) {
    if (!group) return
    volume = Math.max(0, Math.min(100, Math.round(volume)))
    // Sonos scales each speaker by the same ratio as the group; mirror that now
    // from the volumes at drag start so rounding never drifts.
    if (!volumeBaseline || volumeBaseline.ip !== group.ip) {
      var speakers = {}
      for (var i = 0; i < rooms.length; i++)
        if (rooms[i].group === group.ip) speakers[rooms[i].ip] = rooms[i].volume || 0
      volumeBaseline = { ip: group.ip, volume: group.volume || 0, speakers: speakers }
    }
    var base = volumeBaseline
    rooms = rooms.map(function(r) {
      if (!(r.ip in base.speakers)) return r
      var v = base.volume > 0 ? base.speakers[r.ip] * volume / base.volume : volume
      return Object.assign({}, r, { volume: Math.max(0, Math.min(100, Math.round(v))) })
    })
    patch(group.ip, { volume: volume })
    queueVolume("volume", group.ip, volume)
  }

  function setRoomVolume(room, volume) {
    volume = Math.max(0, Math.min(100, Math.round(volume)))
    patchRoom(room.ip, { volume: volume })
    // Sonos reports a group's volume as the average of its speakers.
    var sum = 0, n = 0
    for (var i = 0; i < rooms.length; i++)
      if (rooms[i].group === room.group) { sum += rooms[i].volume || 0; n++ }
    volumeBaseline = null
    if (n > 0) patch(room.group, { volume: Math.round(sum / n) })
    queueVolume("speaker-volume", room.ip, volume)
  }

  function runSearch() {
    if (query.trim() === "") { results = []; searchError = ""; return }
    request({ cmd: "search", query: query })
  }

  function applySearch(data) {
    if (data.query !== query) return   // the helper answers the newest query too
    results = data.results || []
    searchError = data.error || (results.length === 0 ? "No results" : "")
    if (data.error && /log in/i.test(data.error)) spotifyReady = false
    selectedResult = 0
  }

  function playResult(result) {
    var group = targetGroup
    if (!result || !group) return
    patch(group.ip, { state: "PLAYING", title: result.title, artist: result.subtitle })
    request({ cmd: "play-uri", ip: group.ip, uri: result.uri })
    searchField.text = ""
  }

  function logoutSpotify() {
    Quickshell.execDetached([helper, "spotify-logout"])
    searchField.text = ""
    results = []
    spotifyReady = false
    connectError = ""
    Qt.callLater(function() { if (spotifyClientId === "") clientIdField.forceActiveFocus() })
  }

  function loginSpotify() {
    // A second click cancels a login that went wrong in the browser.
    if (loginProc.running) { loginProc.running = false; return }
    var clientId = clientIdField.text.trim() || spotifyClientId
    if (clientId === "") return
    connectError = ""
    loginProc.command = [helper, "spotify-login", clientId]
    loginProc.running = true
  }

  onOpenedChanged: {
    watch()
    if (!opened) return
    if (spotifyReady) searchField.selectAll()
    else if (!spotifyStatusProc.running) spotifyStatusProc.running = true
  }

  // Four bars bouncing out of phase: a stand-in spectrum while sound plays.
  component Equalizer: Item {
    id: eq
    property color color: Color.foreground
    property bool active: true

    Repeater {
      model: 4

      Rectangle {
        id: barRect
        required property int index
        readonly property real peak: [0.95, 0.6, 1.0, 0.7][index]
        width: Math.max(2, Math.round(eq.width / 6))
        x: Math.round((eq.width - 4 * width - 3 * Math.max(1, width / 2)) / 2 + index * (width + Math.max(1, width / 2)))
        y: eq.height - height
        height: eq.height * 0.3
        radius: width / 2
        color: eq.color

        SequentialAnimation on height {
          running: eq.active && eq.visible
          loops: Animation.Infinite
          NumberAnimation { to: eq.height * barRect.peak; duration: [380, 460, 320, 520][barRect.index]; easing.type: Easing.InOutSine }
          NumberAnimation { to: eq.height * 0.25; duration: [420, 340, 480, 300][barRect.index]; easing.type: Easing.InOutSine }
        }
      }
    }
  }

  // Text that rolls back and forth while the popup is open when it doesn't fit.
  component Marquee: Item {
    id: marquee
    property alias text: label.text
    property alias color: label.color
    property alias font: label.font
    readonly property real textWidth: label.implicitWidth
    readonly property real overflow: Math.max(0, label.implicitWidth - width)
    implicitHeight: label.implicitHeight
    clip: overflow > 0

    Text {
      id: label
      textFormat: Text.PlainText

      SequentialAnimation on x {
        running: root.opened && marquee.overflow > 0
        loops: Animation.Infinite
        onRunningChanged: if (!running) label.x = 0
        PauseAnimation { duration: 1500 }
        NumberAnimation { to: -marquee.overflow; duration: marquee.overflow * 30; easing.type: Easing.InOutSine }
        PauseAnimation { duration: 1200 }
        NumberAnimation { to: 0; duration: marquee.overflow * 30; easing.type: Easing.InOutSine }
      }
    }
  }

  component Caption: Text {
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.dim
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.caption
  }

  ListModel { id: groupModel }
  ListModel { id: roomModel }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The helper runs as long as the widget and exits when its stdin closes.
  Process {
    id: helperProc
    command: root.baseCommand.concat(["serve"])
    running: true
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.receive(line) } }
    onRunningChanged: if (running) root.watch()
    onExited: restartHelper.start()
  }

  Timer { id: restartHelper; interval: 1000; onTriggered: helperProc.running = true }

  Process {
    id: spotifyStatusProc
    command: [root.helper, "spotify-status"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.spotifyReady = data.loggedIn === true
          root.spotifyClientId = data.clientId || ""
        } catch (e) {}
      }
    }
  }

  // Opens the browser and waits for Spotify to redirect back to the helper.
  Process {
    id: loginProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = {}
        try { data = JSON.parse(text) } catch (e) { data = { error: "Login cancelled" } }
        if (data.ok) {
          root.spotifyReady = true
          root.spotifyClientId = loginProc.command[2]
          root.searchError = ""
          root.watch()
          clientIdField.text = ""
          Qt.callLater(function() { searchField.forceActiveFocus() })
        } else {
          root.connectError = data.error || "Login failed"
        }
      }
    }
  }

  Timer { id: searchDebounce; interval: 120; onTriggered: root.runSearch() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconSpeaker
    dimmed: !root.anyPlaying
    tooltipText: root.anyPlaying
      ? root.activeGroup.name + " · " + (root.activeGroup.title || "Playing")
      : "Sonos"
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.togglePlay(root.activeGroup)
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (!root.activeGroup) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps !== 0) root.setVolume(root.activeGroup, root.activeGroup.volume + wheel.steps * 2)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.spotifyReady ? searchField : clientIdField
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search field has focus and consumes typing; only keys it leaves
      // alone (Esc, Tab, Up/Down) arrive here.
      onCloseRequested: root.query !== "" ? searchField.text = "" : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0 && root.results.length > 0)
          root.selectedResult = Math.max(0, Math.min(root.results.length - 1, root.selectedResult + dy))
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: content.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: content.implicitHeight > scrollArea.height
        }

        Column {
          id: content
          width: scrollArea.availableWidth
          spacing: Style.space(8)

          // ---------- Spotify not set up: connect card instead of search ----------
          Column {
            visible: !root.spotifyReady
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "Connect Spotify to search"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            // First time only: Spotify needs your own app's Client ID.
            Caption {
              visible: root.spotifyClientId === ""
              width: parent.width
              wrapMode: Text.Wrap
              elide: Text.ElideNone
              text: "One-time setup: create an app on the Spotify dashboard with redirect URI http://127.0.0.1:8888/callback and Web API ticked, then paste its Client ID."
            }

            Row {
              visible: root.spotifyClientId === ""
              spacing: Style.space(6)

              Button {
                text: "Open Spotify dashboard"
                bordered: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: Quickshell.execDetached(["omarchy-launch-browser", "https://developer.spotify.com/dashboard"])
              }

              Button {
                id: copyUri
                property bool copied: false
                text: copied ? "Copied" : "Copy redirect URI"
                bordered: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: {
                  Quickshell.execDetached(["wl-copy", "http://127.0.0.1:8888/callback"])
                  copied = true
                  copiedReset.restart()
                }
                Timer { id: copiedReset; interval: 1500; onTriggered: copyUri.copied = false }
              }
            }

            TextField {
              id: clientIdField
              visible: root.spotifyClientId === ""
              width: parent.width
              foreground: root.bar.foreground
              placeholderText: "Client ID"
              onAccepted: root.loginSpotify()
            }

            Row {
              spacing: Style.space(10)

              Button {
                text: loginProc.running ? "Waiting for browser… (cancel)" : "Log in with Spotify"
                bordered: true
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                onClicked: root.loginSpotify()
              }

              Caption {
                anchors.verticalCenter: parent.verticalCenter
                text: root.connectError
                color: Color.urgent
              }
            }
          }

          Row {
            visible: root.spotifyReady
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: searchField
              width: parent.width - logoutButton.width - Style.space(6)
              foreground: root.bar.foreground
              placeholderText: root.targetGroup ? "Spotify · plays in " + root.targetGroup.name : "Search Spotify"
              onTextChanged: { root.query = text; searchDebounce.restart() }
              onAccepted: root.playResult(root.results[root.selectedResult])
            }

            PanelActionButton {
              id: logoutButton
              anchors.verticalCenter: searchField.verticalCenter
              iconText: root.iconLogout
              tooltipText: "Log out of Spotify"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.logoutSpotify()
            }
          }

          Caption {
            visible: root.query !== "" && root.searchError !== ""
            width: parent.width
            wrapMode: Text.Wrap
            text: root.searchError
          }

          // ---------- Where results play ----------
          Flow {
            visible: root.query !== "" && root.groups.length > 1
            width: parent.width
            spacing: Style.space(6)

            Caption {
              text: "Play in"
              height: Style.font.caption + Style.space(6)
              verticalAlignment: Text.AlignVCenter
            }

            Repeater {
              model: root.query !== "" ? groupModel : 0

              Rectangle {
                id: target
                required property var model
                readonly property bool selected: root.targetGroup && root.targetGroup.ip === model.ip
                width: Math.min(targetLabel.implicitWidth, content.width - Style.space(16)) + Style.space(16)
                height: targetLabel.implicitHeight + Style.space(6)
                radius: height / 2
                color: selected ? Color.accent : "transparent"
                border.width: 1
                border.color: selected ? Color.accent : Qt.darker(root.bar.foreground, 1.6)

                Text {
                  id: targetLabel
                  anchors.centerIn: parent
                  width: Math.min(implicitWidth, content.width - Style.space(16))
                  text: target.model.name
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: target.selected ? root.bar.background : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                TapHandler { onTapped: root.targetIp = target.model.ip }
              }
            }
          }

          // ---------- Search results ----------
          Column {
            visible: root.query !== ""
            width: parent.width

            Repeater {
              model: root.results

              Rectangle {
                id: result
                required property var modelData
                required property int index
                width: parent.width
                height: resultText.implicitHeight + Style.space(8)
                radius: Style.cornerRadius
                color: index === root.selectedResult || hover.hovered
                  ? Style.selectedFillFor(root.bar.foreground, Color.accent) : "transparent"

                Column {
                  id: resultText
                  x: Style.space(8)
                  width: parent.width - Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    width: parent.width
                    text: result.modelData.title
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Caption { width: parent.width; text: result.modelData.subtitle }
                }

                HoverHandler { id: hover }
                TapHandler { onTapped: root.playResult(result.modelData) }
              }
            }
          }

          Caption {
            visible: root.query === "" && root.groups.length === 0
            text: root.loaded ? root.error : "Looking for speakers…"
          }

          // ---------- Groups ----------
          Repeater {
            model: root.query === "" ? groupModel : 0

            Column {
              id: row
              required property var model
              readonly property bool playing: model.state === "PLAYING"
              readonly property bool expanded: root.groupEdit === model.ip
              readonly property int members: root.memberCount(model.ip)
              width: content.width
              spacing: 0

              Item {
                width: parent.width
                implicitHeight: Math.max(header.implicitHeight, controls.implicitHeight)

                Row {
                  id: header
                  anchors.left: parent.left
                  anchors.right: controls.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Equalizer {
                    id: rowEq
                    visible: row.playing
                    width: Style.font.body
                    height: Style.font.body * 0.8
                    anchors.verticalCenter: nameText.verticalCenter
                    color: Color.accent
                  }

                  Marquee {
                    id: nameText
                    width: Math.min(textWidth, header.width
                      - (rowEq.visible ? rowEq.width + header.spacing : 0)
                      - (badge.visible ? badge.width + header.spacing : 0))
                    text: row.model.name
                    color: root.groups.length > 1 && root.targetGroup && root.targetGroup.ip === row.model.ip
                      ? Color.accent : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true

                    // Clicking a room makes it the one search results play in.
                    TapHandler { onTapped: root.targetIp = row.model.ip }
                  }

                  // Grouped rooms get a pill with the speaker count.
                  Rectangle {
                    id: badge
                    visible: row.members > 1
                    anchors.verticalCenter: nameText.verticalCenter
                    width: badgeText.implicitWidth + Style.space(10)
                    height: badgeText.implicitHeight + Style.space(2)
                    radius: height / 2
                    color: Color.accent

                    Text {
                      id: badgeText
                      anchors.centerIn: parent
                      text: root.iconLink + " " + row.members
                      color: root.bar.background
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    TapHandler { onTapped: root.groupEdit = row.expanded ? "" : row.model.ip }
                  }
                }

                Row {
                  id: controls
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter

                  PanelActionButton {
                    iconText: root.iconLink
                    tooltipText: "Speakers and grouping"
                    foreground: row.expanded ? Color.accent : root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    onClicked: root.groupEdit = row.expanded ? "" : row.model.ip
                  }
                  PanelActionButton {
                    iconText: root.iconPrev
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    onClicked: root.skip(row.model, -1)
                  }
                  PanelActionButton {
                    iconText: row.playing ? root.iconPause : root.iconPlay
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    onClicked: root.togglePlay(row.model)
                  }
                  PanelActionButton {
                    iconText: root.iconNext
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    onClicked: root.skip(row.model, 1)
                  }
                }
              }

              // What's playing and the group volume share one line.
              Item {
                width: parent.width
                implicitHeight: Math.max(slider.implicitHeight, track.implicitHeight)

                Marquee {
                  id: track
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width * 0.5
                  text: [row.model.title, row.model.artist].filter(Boolean).join(" — ") || "Nothing playing"
                  color: root.dim
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                PanelSlider {
                  id: slider
                  anchors.left: track.right
                  anchors.leftMargin: Style.space(8)
                  anchors.right: percent.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  bar: root.bar
                  maximum: 100
                  step: 1
                  integer: true
                  value: row.model.volume || 0
                  onMoved: function(v) { root.setVolume(row.model, v) }
                  onReleased: function(v) { root.setVolume(row.model, v) }
                }

                Caption {
                  id: percent
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(24)
                  horizontalAlignment: Text.AlignRight
                  text: Math.round(slider.dragging ? slider.liveValue : (row.model.volume || 0))
                }
              }

              // ---------- Expanded: speaker volumes, then grouping chips ----------
              Repeater {
                model: row.expanded && row.members > 1 ? roomModel : 0

                Item {
                  id: speaker
                  required property var model
                  visible: model.group === row.model.ip
                  width: row.width
                  implicitHeight: visible ? speakerSlider.implicitHeight : 0

                  Caption {
                    id: speakerName
                    x: Style.space(12)
                    width: row.width * 0.5 - Style.space(12)
                    anchors.verticalCenter: parent.verticalCenter
                    text: speaker.model.name
                  }

                  PanelSlider {
                    id: speakerSlider
                    anchors.left: speakerName.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: speakerPercent.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    bar: root.bar
                    maximum: 100
                    step: 1
                    integer: true
                    value: speaker.model.volume || 0
                    onMoved: function(v) { root.setRoomVolume(speaker.model, v) }
                    onReleased: function(v) { root.setRoomVolume(speaker.model, v) }
                  }

                  Caption {
                    id: speakerPercent
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(24)
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(speakerSlider.dragging ? speakerSlider.liveValue : (speaker.model.volume || 0))
                  }
                }
              }

              Flow {
                visible: row.expanded
                width: parent.width
                spacing: Style.space(6)
                topPadding: Style.space(4)
                bottomPadding: Style.space(4)

                Repeater {
                  model: row.expanded ? roomModel : 0

                  Rectangle {
                    id: chip
                    required property var model
                    readonly property bool member: model.group === row.model.ip
                    readonly property bool pending: chip.model.ip in root.pendingGroups
                      && !root.pendingGroups[chip.model.ip].quiet
                    width: chipLabel.implicitWidth + Style.space(16)
                    height: chipLabel.implicitHeight + Style.space(6)
                    radius: height / 2
                    color: member ? Color.accent : "transparent"
                    border.width: 1
                    border.color: member ? Color.accent : Qt.darker(root.bar.foreground, 1.6)

                    Text {
                      id: chipLabel
                      anchors.centerIn: parent
                      text: chip.model.name
                      textFormat: Text.PlainText
                      color: chip.member ? root.bar.background : root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    // Pulses until the speakers confirm the join or leave.
                    SequentialAnimation on opacity {
                      running: chip.pending
                      loops: Animation.Infinite
                      onRunningChanged: if (!running) chip.opacity = 1
                      NumberAnimation { to: 0.35; duration: 450; easing.type: Easing.InOutSine }
                      NumberAnimation { to: 1; duration: 450; easing.type: Easing.InOutSine }
                    }

                    TapHandler { onTapped: root.toggleMember(chip.model, row.model) }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
