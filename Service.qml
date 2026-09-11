import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The single owner of night light state.
//
// Everything that reads this can exist more than once on screen: bar widgets
// are instantiated once per monitor, and an indicator mark is instantiated
// twice over (the active strip and the hover fold-out). If each copy ran its
// own Process they would drift, and a click on one copy would leave the others
// showing stale state. So all the shelling out happens here, exactly once, and
// the visual pieces only read properties and call these functions.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginDir: Model.pluginDirFromUrl(Qt.resolvedUrl("."))
  // Absolute path: the shell's PATH starts with $OMARCHY_PATH/bin, so a bare
  // name would resolve to a packaged command and never reach ours.
  readonly property string cli: root.pluginDir + "/bin/nightlight-auto"

  property var status: Model.emptyStatus()
  property var steps: []
  // The whole `show --json` payload: steps plus the phase boundaries.
  property var ladder: ({})
  property bool busy: false

  readonly property bool ok: status.ok
  // False until the user has agreed to what setup changes. Until then this
  // plugin has written nothing to their configuration.
  readonly property bool isSetup: status.setup
  property string disclosure: ""
  readonly property bool running: status.running
  readonly property bool paused: status.paused
  // "auto" | "on" | "off". on/off are manual holds; auto follows the ladder.
  readonly property string mode: status.mode
  // "Tinted" means the schedule is actually warming the screen right now, as
  // opposed to sitting on the untinted day profile.
  // A numeric day_temp gives the day profile a temperature too, so the day is
  // told apart by the clock (status.daytime), not by the value.
  readonly property bool tinted: status.ok && status.mode !== "off"
                                 && (status.mode === "on"
                                     || (!status.daytime && status.scheduledTemperature !== null))
  readonly property var temperature: status.mode === "on" ? status.nightTemp
                                     : status.mode === "off" ? null
                                     : status.scheduledTemperature

  // 0 at the start of the evening ramp, 1 at its deepest point.
  readonly property real rampFraction: Model.rampFraction(
    status.scheduledTemperature, status.eveningTemp, status.nightTemp)

  // "day" | "dusk" | "night" | "deep". Consumers map this to a glyph; keeping
  // the thresholds here means the bar widget and any indicator mark reading
  // this service can never disagree about which stage we are in.
  readonly property string stage: Model.rampStage(root.tinted, root.rampFraction, root.mode)
  readonly property string stageLabel: Model.stageLabel(root.stage)

  signal changed()

  function refresh() {
    if (!statusProc.running) statusProc.running = true
    if (!stepsProc.running) stepsProc.running = true
    if (!root.isSetup && root.disclosure === "" && !disclosureProc.running)
      disclosureProc.running = true
  }

  function run(args) {
    if (root.busy) return
    root.busy = true
    actionProc.command = [root.cli].concat(args)
    actionProc.running = true
  }

  // Runs setup non-interactively. Only ever called from a control that has the
  // disclosure text on screen next to it -- the button IS the consent.
  function acceptSetup() { run(["setup", "--yes"]) }

  function pause() { run(["pause"]) }
  function resume() { run(["resume"]) }
  function togglePause() { run(["toggle"]) }
  function setMode(mode) { run([mode === "on" ? "on" : mode === "off" ? "off" : "auto"]) }
  function rebuild() { run(["generate", "--force"]) }

  Process {
    id: statusProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.status = Model.parseStatus(text)
        root.changed()
      }
    }
  }

  Process {
    id: stepsProc
    command: [root.cli, "show", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "").trim())
          root.steps = (data && data.steps) ? data.steps : []
          root.ladder = data || ({})
        } catch (e) {
          root.steps = []
          root.ladder = ({})
        }
      }
    }
  }

  // `setup --print` writes nothing; it just reports what setup would change.
  Process {
    id: disclosureProc
    command: [root.cli, "setup", "--print"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.disclosure = String(text || "").trim()
    }
  }

  Process {
    id: actionProc
    onExited: {
      root.busy = false
      // A pause or rebuild restarts hyprsunset, which takes a moment to come
      // back and answer, so re-read once it has settled as well as immediately.
      Qt.callLater(root.refresh)
      settleTimer.restart()
    }
  }

  Timer { id: settleTimer; interval: 1500; onTriggered: root.refresh() }

  // The schedule only steps every few minutes, so this can be lazy.
  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.refresh() }

  Component.onCompleted: refresh()

  IpcHandler {
    target: "contra.nightlight"

    function status(): string {
      return JSON.stringify({
        setup: root.isSetup,
        paused: root.paused,
        running: root.running,
        temperature: root.temperature,
        tinted: root.tinted
      })
    }

    function refresh(): void { root.refresh() }
    function pause(): string { root.pause(); return "paused" }
    function resume(): string { root.resume(); return "resumed" }
    function toggle(): string { root.togglePause(); return root.paused ? "resuming" : "pausing" }
    function rebuild(): string { root.rebuild(); return "rebuilding" }
    function on(): string { root.setMode("on"); return "on" }
    function off(): string { root.setMode("off"); return "off" }
    function auto(): string { root.setMode("auto"); return "auto" }
    function mode(): string { return root.mode }
  }
}
