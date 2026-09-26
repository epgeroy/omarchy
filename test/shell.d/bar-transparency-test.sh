#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const vm = require('vm')
const source = fs.readFileSync(root + '/shell/plugins/bar/Bar.qml', 'utf8')
// Execute the actual QML functions with compositor/process stand-ins. A color
// must remain usable on an empty output even when focus moves to a busy one.
const functions = source.slice(source.indexOf('  function setRequestedTransparency('), source.indexOf('  onTransparentOnlyWhenWorkspaceEmptyChanged:'))
const collector = source.slice(source.indexOf('    id: transparentForegroundProc'), source.indexOf('    target: Hyprland'))
const onRead = collector.match(/onRead: function\(line\) \{([\s\S]*?)\n      \}/)[1]
const surface = source.slice(source.indexOf('  component BarPanel:'))
const onTransparentChanged = surface.match(/onTransparentChanged: \{([\s\S]*?)\n    \}/)[1]

function monitor(name, occupied) {
  return { name, activeWorkspace: { toplevels: { values: occupied ? [{}] : [] } } }
}

function scene(conditional = true) {
  const empty = monitor('DP-1', false)
  const busy = monitor('DP-2', true)
  let refreshes = 0
  const state = {
    requestedTransparent: true,
    transparentOnlyWhenWorkspaceEmpty: conditional,
    transparencyRevision: 0,
    visibleSpecialWorkspaceNames: {},
    useTransparentForeground: false,
    transparent: false,
    themeForeground: '#ffffff',
    themeContrastForeground: '#101315',
    transparentForeground: '#ffffff',
    position: 'top',
    barSize: 26,
    colorHex: value => value,
    Qt: { callLater: callback => callback() },
    Hyprland: { focusedMonitor: busy, monitors: { values: [empty, busy] }, workspaces: { values: [] } },
    transparentForegroundTimer: { restart() { refreshes++ } },
    transparentForegroundProc: { running: false, command: [] }
  }
  state.root = state
  vm.createContext(state)
  vm.runInContext(functions + '\nfunction receiveForeground(line) {' + onRead + '\n}', state)
  return { state, empty, busy, refreshes: () => refreshes }
}

const mixed = scene()
mixed.state.syncTransparency()
assertEqual(mixed.refreshes(), 1, 'an empty secondary monitor requests contrast while the occupied monitor is focused')
assertEqual(mixed.state.transparent, false, 'the focused occupied monitor remains opaque')
mixed.state.refreshTransparentForeground()
assertEqual(mixed.state.transparentForegroundProc.running, true, 'the shared helper runs for an unfocused empty monitor')
mixed.state.receiveForeground('not a color')
assertEqual(mixed.state.useTransparentForeground, false, 'invalid helper output cannot enable contrast')
mixed.state.receiveForeground('#101315')
assertEqual(mixed.state.useTransparentForeground, true, 'the helper result is accepted for an unfocused empty monitor')
assertEqual(mixed.state.transparent, false, 'accepting shared contrast does not make the occupied monitor transparent')

mixed.state.Hyprland.focusedMonitor = mixed.empty
mixed.state.syncTransparency()
assertEqual(mixed.state.transparent, true, 'focusing the empty monitor uses conditional transparency immediately')
mixed.state.Hyprland.focusedMonitor = mixed.busy
mixed.state.syncTransparency()
assertEqual(mixed.state.useTransparentForeground, true, 'focusing an occupied monitor preserves shared contrast')
assertEqual(mixed.state.transparentForeground, '#101315', 'focus changes retain the sampled wallpaper color')
assertEqual(mixed.refreshes(), 1, 'focus changes reuse the available shared color')
assertEqual(mixed.state.shouldBeTransparent(mixed.empty), true, 'the empty monitor stays transparent after focus moves away')
mixed.state.transparentForegroundProc.running = false
mixed.state.scheduleTransparentForegroundRefresh()
mixed.state.refreshTransparentForeground()
assertEqual(mixed.refreshes(), 2, 'wallpaper changes can refresh contrast with an occupied monitor focused')
assertEqual(mixed.state.transparentForegroundProc.running, true, 'wallpaper refresh starts the shared helper for the empty monitor')

mixed.empty.activeWorkspace.toplevels.values.push({})
mixed.state.syncTransparency()
assertEqual(mixed.state.useTransparentForeground, false, 'shared contrast is released once every monitor is occupied')
mixed.state.receiveForeground('#101315')
assertEqual(mixed.state.useTransparentForeground, false, 'a late helper result cannot enable contrast when all monitors are occupied')
assertEqual(mixed.state.transparent, false, 'a late helper result cannot make an occupied monitor transparent')

const startup = scene()
startup.state.Hyprland.monitors.values = []
startup.state.syncTransparency()
assertEqual(startup.refreshes(), 0, 'startup waits for Hyprland monitor state')
startup.state.Hyprland.monitors.values = [startup.empty, startup.busy]
let localRefreshes = 0
vm.runInNewContext(onTransparentChanged, {
  root: startup.state,
  Qt: startup.state.Qt,
  scheduleTransparentForegroundRefresh() { localRefreshes++ }
})
assertEqual(startup.refreshes(), 1, 'an initially transparent surface wakes shared sampling without a raw event')
assertEqual(localRefreshes, 1, 'surface transparency changes still refresh the per-monitor sampler')

const special = scene()
special.state.visibleSpecialWorkspaceNames = { 'DP-1': 'special:scratchpad' }
special.state.Hyprland.workspaces.values = [{ name: 'special:scratchpad', toplevels: { values: [{}] } }]
special.state.syncTransparency()
assertEqual(special.refreshes(), 0, 'a visible populated scratchpad does not request shared transparency')
special.state.visibleSpecialWorkspaceNames = { 'DP-1': '' }
special.state.syncTransparency()
assertEqual(special.refreshes(), 1, 'hiding the scratchpad requests contrast for the now-empty monitor')
special.state.setRequestedTransparency(false)
assertEqual(special.state.useTransparentForeground, false, 'disabling transparency clears shared contrast')
special.state.receiveForeground('#101315')
assertEqual(special.state.transparent, false, 'a late helper result cannot re-enable disabled transparency')

const standard = scene(false)
standard.state.syncTransparency()
assertEqual(standard.state.transparent, false, 'ordinary transparency waits for the wallpaper helper')
standard.state.receiveForeground('#101315')
assertEqual(standard.state.transparent, true, 'ordinary transparency activates after a valid helper result')
JS
