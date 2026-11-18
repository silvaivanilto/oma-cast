import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "core/Rpc.js" as Rpc
import "core/Paths.js" as Paths
import "core/Log.js" as Log
import "core/Schema.js" as Schema
import "core/Ranker.js" as Ranker
import "core/FleaSearch.js" as FleaSearch
import "core/Frecency.js" as Frecency
import "core/OmarchyMenu.js" as OmarchyMenu
import "core/RootSearch.js" as RootSearch
import "core/Calculator.js" as Calculator
import "core/ClipboardHistory.js" as ClipboardHistory
import "core/Themes.js" as Themes
import "core/Emoji.js" as Emoji
import "core/ScriptCommands.js" as ScriptCommands
import "core/Localize.js" as Localize
import "services"

Item {
  id: backend

  readonly property string version: "0.1.0"
  readonly property var paths: Paths.resolve(function(name) { return Quickshell.env(name) })
  readonly property string desktop: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") ? "hyprland" : "unknown"

  property var appLibrary: null
  property var summon: null

  property var config: Schema.withConfigDefaults(null)
  property bool directoriesReady: false
  readonly property bool ready: directoriesReady && settingsStore.loaded && frecencyStore.loaded && calculatorStore.loaded && emojiStore.loaded

  readonly property var registry: Rpc.createRegistry()
  readonly property double startedAt: Date.now()
  readonly property var deps: ({ Ranker: Ranker, Frecency: Frecency, OmarchyMenu: OmarchyMenu })

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
    onStringsChanged: {
      backend.languageRevision++
      if (backend.directoriesReady) rebuildTimer.restart()
    }
  }
  readonly property alias i18n: strings
  property int languageRevision: 0

  function t(key, fallback, args) {
    return Localize.format(strings.t(key, fallback), args)
  }

  function tn(key, count, fallback, args) {
    return Localize.format(strings.tn(key, count, fallback), args)
  }

  property var candidates: []
  property var candidatesById: ({})
  property int candidatesRevision: 0
  readonly property bool loading: menuSource.loading || themeSource.loading || nativeSearch.pending !== null || emojiSearch.pending !== null
  // Bumped when exchange rates or zone offsets arrive, so an open
  // calculator row re-evaluates. (double avoids 32-bit int overflow of Date.now())
  readonly property double calculatorRevision: (calculatorData.rates ? 1 : 0) + calculatorData.ratesFetchedAt + calculatorData.zonesAt

  signal notification(string method, var data)


  function call(method, data) { return Rpc.call(backend.registry, method, data) }
  function callSync(method, data) { return Rpc.callSync(backend.registry, method, data) }
  function cancelSearch() { nativeSearch.cancel(); emojiSearch.cancel() }

  function searchAsync(data, callback) {
    nativeSearch.cancel()
    var query = String(data && data.query || "").trim()
    var view = data && data.view
    if (query && view && view.kind === "emoji") {
      emojiSearch.search(Ranker.transliterate(query.toLowerCase()), "medium", function(matches) {
        callback(backend.callSync("rootSearch.search", Object.assign({}, data, { fleaHits: matches })))
      })
      return
    }
    if (!query || (view && view.kind !== "root")) {
      callback(backend.callSync("rootSearch.search", data))
      return
    }
    nativeSearch.search(Ranker.transliterate(query.toLowerCase()), backend.searchContext().sensitivity, function(matches) {
      callback(backend.callSync("rootSearch.search", Object.assign({}, data, { fleaHits: matches })))
    })
  }

  NativeSearch {
    id: nativeSearch
    onFailed: function(message) { backend.log("warning", "search", message) }
  }

  // A second flea helper over the emoji list; null hits fall back to Emoji.matchScore.
  NativeSearch {
    id: emojiSearch
    ids: backend.emoji.list.map(function(e) { return e.symbol })
    entries: FleaSearch.entries(Emoji.searchEntries(backend.emoji.list), Ranker.transliterate)
    onFailed: function(message) { backend.log("warning", "emoji-search", message) }
  }
  function subscribe(method, callback) { return Rpc.subscribe(backend.registry, method, callback) }

  function emit(method, data) {
    Rpc.emit(backend.registry, method, data, function(m, error) {
      backend.log("error", "rpc", "subscriber of " + m + " threw: " + error)
    })
    backend.notification(method, data)
  }

  function log(level, category, message, metadata) {
    if (!Log.shouldLog(level, backend.config.logLevel)) return
    var line = Log.format(level, category, message, metadata)
    var i = Log.levelIndex(level)
    if (i >= Log.levelIndex("error")) console.error(line)
    else if (i >= Log.levelIndex("warning")) console.warn(line)
    else if (i >= Log.levelIndex("info")) console.info(line)
    else console.log(line)
  }


  function appEntries() {
    if (backend.appLibrary) return backend.appLibrary.sortedEntries("").map(function(row) { return row.entry })
    return (DesktopEntries.applications.values || []).filter(function(e) { return !e.noDisplay })
  }

  function rebuildCandidates() {
    var next = []
    var apps = backend.appEntries()
    for (var i = 0; i < apps.length; i++) if (apps[i] && apps[i].id) next.push(RootSearch.appCandidate(apps[i]))
    next = next.concat(RootSearch.menuCandidates(menuSource.tree, menuSource.guards, menuSource.providerItems, backend.deps))
    for (var b = 0; b < RootSearch.BUILTINS.length; b++) next.push(RootSearch.builtinCandidate(RootSearch.BUILTINS[b]))
    // A built-in that replaces an Omarchy command hides that command.
    var superseded = ({})
    RootSearch.BUILTINS.forEach(function(d) { (d.supersedes || []).forEach(function(id) { superseded[id] = true }) })
    next = next.filter(function(c) { return !superseded[c.id] })
    for (var s = 0; s < scriptSource.commands.length; s++) next.push(ScriptCommands.candidate(scriptSource.commands[s]))
    next = next.map(function(c) { return Localize.candidate(c, backend.t, backend.tn, strings.language) })
    var byId = ({})
    for (var j = 0; j < next.length; j++) byId[next[j].id] = next[j]
    var entries = FleaSearch.entries(next, Ranker.transliterate)
    nativeSearch.cancel()
    backend.candidates = next
    backend.candidatesById = byId
    nativeSearch.ids = next.map(function(c) { return c.id })
    nativeSearch.entries = entries
    backend.candidatesRevision++
  }

  Timer {
    id: rebuildTimer
    interval: 30
    onTriggered: backend.rebuildCandidates()
  }

  function searchContext() {
    return {
      commands: settingsStore.loaded ? settingsStore.doc.commands : ({}),
      frecency: frecencyStore.loaded ? frecencyStore.doc.items : ({}),
      nowMs: Date.now(),
      sensitivity: settingsStore.loaded ? settingsStore.doc.general.rootSearchSensitivity : "medium"
    }
  }

  function decorated(id) {
    var c = backend.candidatesById[id]
    return c ? RootSearch.decorate(c, backend.searchContext(), backend.deps) : null
  }

  // ------------------------------------------------------------ calculator

  // 12- or 24-hour clock from config.json clockFormat, else the active Omarchy locale.
  readonly property bool hour12: backend.config.clockFormat === "auto"
    ? Qt.locale(Commons.I18n.formatLocale).timeFormat(Locale.ShortFormat).toLowerCase().indexOf("ap") >= 0
    : backend.config.clockFormat === "12h"

  function calculatorEnv() {
    return {
      nowMs: Date.now(),
      localOffset: -new Date().getTimezoneOffset(),
      hour12: backend.hour12,
      rates: backend.config.currencyRates ? calculatorData.rates : null,
      zones: calculatorData.zones,
      remToPxRate: backend.config.remToPxRate,
      workHoursPerDay: backend.config.workHoursPerDay
    }
  }

  function calculate(query) {
    try {
      return Calculator.evaluate(query, backend.calculatorEnv())
    } catch (e) {
      backend.log("error", "calculator", "evaluating failed: " + e, { query: query })
      return null
    }
  }

  function saveCalculation(entry) {
    calculatorStore.update(function(doc) {
      doc.history = Calculator.pushHistory(doc.history, {
        id: String(Date.now()), query: entry.query, result: entry.result, copy: entry.copy, kind: entry.kind
      }, Date.now())
    })
    backend.emit("calculator.historyStateChanged", null)
  }

  // An action on the inline Calculator row or a Calculator History entry.
  // entry: {query, result, copy, kind}; history: whether it is saved already.
  function calculatorAction(action, entry, historyId) {
    switch (action) {
      case "open":
      case "copy-answer":
        if (!historyId) backend.saveCalculation(entry)
        clipboard.copy(entry.copy)
        return { close: true, hud: backend.t("toast.copiedToClipboard", "Copied to Clipboard") }
      case "paste-answer":
        if (!historyId) backend.saveCalculation(entry)
        // Copies, waits for our window to unmap, then pastes.
        clipboard.paste(entry.copy)
        return { close: true }
      case "copy-question-answer":
        if (!historyId) backend.saveCalculation(entry)
        clipboard.copy(entry.query + " = " + entry.result)
        return { close: true, hud: backend.t("toast.copiedToClipboard", "Copied to Clipboard") }
      case "open-history":
        return { push: { kind: "calculator-history", title: backend.t("builtin.calculatorHistory.title", "Calculator History") } }
      case "delete-entry":
        calculatorStore.update(function(doc) { doc.history = doc.history.filter(function(h) { return h.id !== historyId }) })
        backend.emit("calculator.historyStateChanged", null)
        return { toast: { style: "success", title: backend.t("toast.entryDeleted", "Entry deleted") } }
      case "delete-all-entries":
        calculatorStore.update(function(doc) { doc.history = [] })
        backend.emit("calculator.historyStateChanged", null)
        return { toast: { style: "success", title: backend.t("toast.historyCleared", "History cleared") } }
    }
    throw new Error("Unknown action " + action)
  }

  function historyEntry(id) {
    var key = String(id).slice("calculator-history:".length)
    var list = calculatorStore.loaded ? calculatorStore.doc.history : []
    for (var i = 0; i < list.length; i++) if (list[i].id === key) return list[i]
    return null
  }

  // ---------------------------------------------------------------- emoji

  property string emojiRaw: ""
  property string emojiKeywordsRaw: ""
  readonly property var emoji: Emoji.parse(backend.emojiRaw, backend.emojiKeywordsRaw)

  function emojiEntry(id) {
    var symbol = String(id).slice("emoji:".length)
    var list = backend.emoji.list
    for (var i = 0; i < list.length; i++) if (list[i].symbol === symbol) return list[i]
    return null
  }

  function emojiState(filter) {
    var doc = emojiStore.loaded ? emojiStore.doc : { items: {}, pinned: [], skinTone: "none" }
    var nowSec = Date.now() / 1000
    var recent = Object.keys(doc.items).sort(function(a, b) {
      return Frecency.score(doc.items[b].anchor, nowSec) - Frecency.score(doc.items[a].anchor, nowSec)
    })
    return { pinned: doc.pinned, recent: recent, tone: doc.skinTone, filter: filter || "all" }
  }

  function emojiCandidate(id) {
    var e = backend.emojiEntry(id)
    if (!e) throw new Error("Unknown emoji " + id)
    var state = backend.emojiState()
    return { entry: e, candidate: Emoji.candidate(e, state.tone, state.pinned) }
  }

  function setPinned(symbol, pin) {
    emojiStore.update(function(doc) {
      doc.pinned = doc.pinned.filter(function(s) { return s !== symbol })
      if (pin) doc.pinned.push(symbol)
    })
    backend.emit("emojiPicker.stateChanged", null)
  }

  function emojiAction(action, id, query) {
    var found = backend.emojiCandidate(id)
    var e = found.entry, c = found.candidate
    function uprank() {
      emojiStore.update(function(doc) { doc.items[e.symbol] = Frecency.recordVisit(doc.items[e.symbol] || null, Date.now(), query || "") })
    }
    switch (action) {
      case "open":
      case "paste":
        uprank()
        clipboard.paste(c.symbol)
        return { close: true }
      case "copy":
        uprank()
        clipboard.copy(c.symbol)
        return { close: true, hud: backend.t("toast.copiedToClipboard", "Copied to Clipboard") }
      case "copy-name":
        clipboard.copy(c.title)
        return { close: true, hud: backend.t("toast.copiedToClipboard", "Copied to Clipboard") }
      case "pin":
      case "unpin":
        backend.setPinned(e.symbol, action === "pin")
        return { toast: { style: "success", title: action === "pin" ? backend.t("toast.pinned", "Pinned") : backend.t("toast.unpinned", "Unpinned") } }
      case "remove-recent":
        emojiStore.update(function(doc) { delete doc.items[e.symbol] })
        return { toast: { style: "success", title: backend.t("toast.removedRecent", "Removed from Recently Used") } }
      case "tone:none": case "tone:light": case "tone:medium-light": case "tone:medium": case "tone:medium-dark": case "tone:dark":
        backend.callSync("emojiPicker.setSkinTone", { tone: action.slice(5) })
        return { toast: { style: "success", title: backend.t("toast.skinToneSet", "Skin tone set") } }
      case "clear-recent":
        emojiStore.update(function(doc) { doc.items = {} })
        return { toast: { style: "success", title: backend.t("toast.recentCleared", "Recently Used cleared") } }
    }
    throw new Error("Unknown action " + action)
  }

  // ----------------------------------------------------- clipboard history

  // Our own write from the history comes back through the watcher; it moves
  // the entry up without counting as a new copy.
  property string clipboardSelfHash: ""
  property double clipboardSelfAt: 0

  // The focused app: the source of a copy, and where a paste lands.
  function activeApp() {
    var t = ToplevelManager.activeToplevel
    var appId = t ? String(t.appId || "") : ""
    if (!appId) return null
    var entry = DesktopEntries.heuristicLookup(appId)
    return { appId: appId, name: entry && entry.name ? String(entry.name) : appId }
  }

  function clipboardEntries() { return clipboardStore.loaded ? clipboardStore.doc.entries : [] }

  function clipboardEntry(id) {
    var key = String(id).replace(/^clipboard:/, "")
    var list = backend.clipboardEntries()
    for (var i = 0; i < list.length; i++) if (list[i].id === key) return list[i]
    return null
  }

  function clipboardInfo(entry) {
    var d = ClipboardHistory.detail(entry)
    var locale = Qt.locale(Commons.I18n.formatLocale)
    var info = Localize.infoRows(d.info, backend.t, backend.tn).map(function(row, idx) {
      var rawLabel = d.info[idx] && d.info[idx].label
      if (rawLabel === "Last copied" && entry.updatedAt)
        return { label: row.label, value: new Date(entry.updatedAt).toLocaleString(locale, Locale.ShortFormat) }
      if (rawLabel === "First copied" && entry.createdAt)
        return { label: row.label, value: new Date(entry.createdAt).toLocaleString(locale, Locale.ShortFormat) }
      return row
    })
    return Object.assign({}, d, { info: info })
  }

  // Only files inside our clipboard directory, whatever the store says.
  function deleteClipboardFiles(paths) {
    var dir = backend.paths.clipboard + "/"
    var mine = paths.filter(function(p) { return p.indexOf(dir) === 0 && p.indexOf("/..") < 0 })
    if (mine.length) Quickshell.execDetached(["rm", "-f", "--"].concat(mine))
  }

  // Applies mutate(entries) → entries, then retention, and deletes the files
  // no entry uses any more.
  function updateClipboard(mutate) {
    if (!clipboardStore.loaded) throw new Error(backend.t("error.clipboardNotLoaded", "Clipboard History is not loaded"))
    var orphans = []
    clipboardStore.update(function(doc) {
      var before = doc.entries
      var pruned = ClipboardHistory.prune(mutate(before), Date.now(), backend.config.clipboardHistoryDuration)
      var kept = ({})
      pruned.entries.forEach(function(e) { kept[e.id] = true })
      var gone = before.filter(function(e) { return !kept[e.id] }).concat(pruned.removed)
      orphans = ClipboardHistory.orphanedPaths(gone, pruned.entries)
      doc.entries = pruned.entries
    })
    backend.deleteClipboardFiles(orphans)
    backend.emit("clipboard.stateChanged", null)
  }

  function pruneClipboard() {
    if (!clipboardStore.loaded) return
    if (ClipboardHistory.prune(clipboardStore.doc.entries, Date.now(), backend.config.clipboardHistoryDuration).removed.length)
      backend.updateClipboard(function(entries) { return entries })
  }

  function recordClipboard(obs) {
    if (!clipboardStore.loaded || !obs || !obs.hash) return
    // The selection that was there when the watcher started is old news.
    if (obs.initial && backend.clipboardEntries().some(function(e) { return e.hash === obs.hash })) return
    delete obs.initial
    var source = backend.activeApp()
    if (ClipboardHistory.isDisabledSource(source, backend.config.clipboardDisabledApplications)) {
      backend.deleteClipboardFiles(ClipboardHistory.orphanedPaths([obs], backend.clipboardEntries()))
      return
    }
    obs.source = source
    var now = Date.now()
    var self = obs.hash === backend.clipboardSelfHash && now - backend.clipboardSelfAt < 5000
    var id = now.toString(36) + Math.floor(Math.random() * 1e6).toString(36)
    backend.updateClipboard(function(entries) { return ClipboardHistory.add(entries, obs, now, id, self).entries })
  }

  // Puts an entry back on the clipboard, pasting it into the focused app if asked.
  function writeClipboardEntry(e, paste) {
    backend.clipboardSelfHash = e.hash
    backend.clipboardSelfAt = Date.now()
    var mime = e.mime === "text/uri-list" || e.type === "image" ? e.mime : ""
    if (e.path) clipboard.copyFile(e.path, e.mime || "text/plain", paste)
    else if (paste) clipboard.paste(e.text, mime)
    else clipboard.copy(e.text, mime)
  }

  function clipboardAction(action, id, confirmed) {
    if (action === "delete-all-entries") {
      if (!confirmed) return { confirm: {
        title: backend.t("confirm.deleteClip.title", "Delete All Entries"),
        message: backend.t("confirm.deleteClip.message", "This removes every unpinned entry from Clipboard History. Pinned entries are kept."),
        primary: backend.t("confirm.deleteClip.primary", "Delete All"),
        destructive: true
      } }
      backend.updateClipboard(function(entries) { return entries.filter(function(e) { return typeof e.pinned === "number" }) })
      return { toast: { style: "success", title: backend.t("toast.historyCleared", "History cleared") } }
    }
    var e = backend.clipboardEntry(id)
    if (!e) throw new Error(backend.t("error.noSuchClipboard", "No such clipboard entry"))
    switch (action) {
      case "open":
      case "paste":
        backend.writeClipboardEntry(e, true)
        return { close: true }
      case "copy":
        backend.writeClipboardEntry(e, false)
        return { close: true, hud: backend.t("toast.copiedToClipboard", "Copied to Clipboard") }
      case "open-link":
        var files = ClipboardHistory.filePaths(e.text)
        var target = files.length ? files[0] : String(e.text || "").trim()
        if (/^https?:/i.test(target)) Util.execArgv(["omarchy-launch-browser", target])
        else Util.execArgv(["xdg-open", target])
        return { close: true }
      case "pin":
      case "unpin":
        backend.updateClipboard(function(entries) { return ClipboardHistory.setPinned(entries, e.id, action === "pin") })
        return { toast: { style: "success", title: action === "pin" ? backend.t("toast.pinned", "Pinned") : backend.t("toast.unpinned", "Unpinned") } }
      case "delete-entry":
        backend.updateClipboard(function(entries) { return entries.filter(function(x) { return x.id !== e.id }) })
        return { toast: { style: "success", title: backend.t("toast.entryDeleted", "Entry deleted") } }
    }
    throw new Error(backend.t("error.unknownAction", "Unknown action %1", [action]))
  }

  // ----------------------------------------------------------------- themes

  function themeEntry(id) {
    var slug = String(id).replace(/^theme:/, "")
    return themeSource.themes.filter(function(t) { return t.slug === slug })[0] || null
  }

  // ------------------------------------------------------------- execution

  function summonPlugin(id, payload) {
    if (backend.summon && backend.summon(id, payload)) return
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", id, payload || "{}"])
  }

  function runShell(command) {
    var summon = OmarchyMenu.summonAction(command)
    if (summon) backend.summonPlugin(summon.id, summon.payload)
    else Util.execDetached(command)
  }

  function recordVisit(id, query) {
    if (!frecencyStore.loaded) return
    frecencyStore.update(function(doc) {
      doc.items[id] = Frecency.recordVisit(doc.items[id] || null, Date.now(), query || "")
      if (query) doc.searchHistory = Schema.pushSearchHistory(doc.searchHistory, query)
    })
  }

  function updateCommand(id, mutator) {
    settingsStore.update(function(doc) {
      var current = doc.commands[id] || {}
      var next = mutator(JSON.parse(JSON.stringify(current)))
      var empty = true
      for (var k in next) if (next[k] !== null && next[k] !== undefined && next[k] !== "") empty = false
      if (empty) delete doc.commands[id]
      else doc.commands[id] = next
    })
    backend.emit("settings.commandSettingsChanged", { commandId: id })
  }

  function omarchyRouteFor(candidate) {
    if (candidate.kind === "omarchy-action") {
      var item = menuSource.tree.items[candidate.menuId]
      return item && item.parent ? item.parent : "root"
    }
    return candidate.kind === "omarchy-link" ? candidate.target : candidate.menuId
  }

  function openMenu(item) {
    if (item.provider && !OmarchyMenu.PROVIDERS[item.provider]) {
      backend.summonPlugin("omarchy.menu", JSON.stringify({ menu: item.id }))
      return { close: true }
    }
    return { push: { kind: "menu", menuId: item.id, title: item.label } }
  }

  function launchApp(candidate) {
    if (backend.appLibrary) backend.appLibrary.launch(candidate.appId, candidate.title)
    else Util.execArgv(["uwsm-app", "--", "gtk-launch", candidate.appId + ".desktop"])
  }

  function performAction(data) {
    var id = String(data && data.id || "")
    var action = String(data && data.action || "open")
    var query = String(data && data.query || "").trim()
    var candidate = backend.decorated(id)
    if (!candidate) throw new Error(backend.t("error.unknownCommand", "Unknown command %1", [id]))

    if (action === "open") {
      switch (candidate.kind) {
        case "app":
          backend.recordVisit(id, query)
          appFocuser.open(candidate)
          return { close: true }
        case "omarchy-action":
          if (candidate.disabled) return { toast: { style: "failure", title: backend.t("toast.alreadySetUp", "%1 is already set up", [candidate.title]) } }
          backend.recordVisit(id, query)
          backend.runShell(candidate.action)
          return { close: true }
        case "omarchy-menu":
          backend.recordVisit(id, query)
          return backend.openMenu(menuSource.tree.items[candidate.menuId])
        case "omarchy-link":
          backend.recordVisit(id, query)
          var target = menuSource.tree.items[candidate.target]
          if (!target) return { toast: { style: "failure", title: backend.t("toast.menuNotFound", "Menu %1 not found", [candidate.target]) } }
          return backend.openMenu(target)
        case "builtin":
          if (candidate.run.url) {
            var values = (data && data.arguments) || {}
            var missing = RootSearch.missingArgument(candidate.arguments, values)
            if (missing >= 0) throw new Error(backend.t("error.typeArgumentFirst", "Type a %1 first", [candidate.arguments[missing].placeholder.toLowerCase()]))
            backend.recordVisit(id, query)
            Util.execArgv(["omarchy-launch-browser", RootSearch.fillArguments(candidate.run.url, values)])
            return { close: true }
          }
          backend.recordVisit(id, query)
          if (candidate.run.push && candidate.run.push.kind === "theme") themeSource.refresh()
          if (candidate.run.push) return { push: candidate.run.push }
          if (candidate.run.summon) backend.summonPlugin(candidate.run.summon, candidate.run.payload || "{}")
          return { close: true }
        case "fallback":
          Util.execArgv(["omarchy-launch-browser", RootSearch.fallbackUrl(candidate, query)])
          return { close: true }
        case "script":
          var script = candidate.script
          var args = ScriptCommands.argv(script, (data && data.arguments) || {})
          if (args.error) {
            var badArg = typeof args.index === "number" ? script.arguments[args.index] : null
            var argVal = badArg ? String(((data && data.arguments) || {})[badArg.name] || "").trim() : ""
            if (badArg && badArg.required && !argVal)
              throw new Error(backend.t("error.typeArgumentFirst", "Type a %1 first", [badArg.placeholder.toLowerCase()]))
            if (badArg && argVal && badArg.type === "dropdown")
              throw new Error(backend.t("error.invalidOption", "%1 is not a %2 option", [argVal, badArg.placeholder.toLowerCase()]))
            throw new Error(args.error)
          }
          if (script.needsConfirmation && !(data && data.confirmed))
            return { confirm: { title: script.title, message: backend.t("confirm.script.message", "Are you sure you want to run this script?"), primary: backend.t("confirm.script.primary", "Run"), destructive: false } }
          backend.recordVisit(id, query)
          scriptRunner.run(script, args.argv)
          // silent closes and shows a HUD. shortcut: fullOutput and inline
          // run as compact (toast with the last line); add the output view
          // and inline refresh when a script needs them.
          if (script.mode === "silent") return { close: true }
          return { toast: { style: "success", title: backend.t("toast.runningScript", "Running %1…", [script.title]) } }
      }
      throw new Error("Cannot open " + id)
    }

    switch (action) {
      case "open-new":
        backend.recordVisit(id, query)
        backend.launchApp(candidate)
        return { close: true }
      case "open-in-omarchy-menu":
        backend.summonPlugin("omarchy.menu", JSON.stringify({ menu: backend.omarchyRouteFor(candidate) }))
        return { close: true }
      case "copy-command":
      case "copy-id":
        clipboard.copy(action === "copy-id" ? candidate.appId + ".desktop" : candidate.action)
        return { close: true, hud: backend.t("toast.copiedToClipboard", "Copied to Clipboard") }
      case "favorite-add":
      case "favorite-remove":
      case "favorite-up":
      case "favorite-down":
        var orders = RootSearch.reorderFavorites(settingsStore.doc.commands, id, action)
        settingsStore.update(function(doc) {
          for (var key in orders) {
            var entry = doc.commands[key] || {}
            if (orders[key] === null) delete entry.favoriteOrder
            else entry.favoriteOrder = orders[key]
            if (Object.keys(entry).length === 0) delete doc.commands[key]
            else doc.commands[key] = entry
          }
        })
        var titles = {
          "favorite-add": backend.t("toast.favoriteAdd", "Added to Favorites"),
          "favorite-remove": backend.t("toast.favoriteRemove", "Removed from Favorites"),
          "favorite-up": backend.t("toast.favoriteUp", "Moved Up"),
          "favorite-down": backend.t("toast.favoriteDown", "Moved Down")
        }
        return { toast: { style: "success", title: titles[action] } }
      case "set-alias":
        return { push: { kind: "alias", commandId: id, title: backend.t("toast.aliasFor", "Alias for %1", [candidate.title]), value: candidate.alias } }
      case "remove-alias":
        backend.updateCommand(id, function(s) { delete s.alias; return s })
        return { toast: { style: "success", title: backend.t("toast.aliasRemoved", "Alias removed") } }
      case "reset-ranking":
        frecencyStore.update(function(doc) { delete doc.items[id] })
        return { toast: { style: "success", title: backend.t("toast.rankingReset", "Ranking reset") } }
      case "disable":
        backend.updateCommand(id, function(s) { s.enabled = false; return s })
        // Undo on Ctrl+T: there is no settings window to re-enable it yet.
        return { toast: { style: "success", title: backend.t("toast.commandDisabled", "%1 disabled", [candidate.title]), actions: [
          { id: "undo", title: backend.t("toast.undo", "Undo"), done: backend.t("toast.commandEnabled", "%1 enabled", [candidate.title]),
            call: { method: "settings.updateCommandSettings", data: { commandId: id, enabled: true } } }
        ] } }
    }
    throw new Error("Unknown action " + action)
  }


  function registerServices() {
    Rpc.register(backend.registry, "system", {
      healthPing: function() { return null },
      healthDatabase: function() {
        var t0 = Date.now()
        JSON.stringify(settingsStore.doc)
        JSON.stringify(frecencyStore.doc)
        return {
          workMs: Date.now() - t0,
          settings: { loaded: settingsStore.loaded, readOnly: settingsStore.readOnly, error: settingsStore.lastError },
          frecency: { loaded: frecencyStore.loaded, readOnly: frecencyStore.readOnly, error: frecencyStore.lastError },
          loaded: settingsStore.loaded, readOnly: settingsStore.readOnly, error: settingsStore.lastError
        }
      },
      info: function() {
        return {
          version: backend.version,
          desktop: backend.desktop,
          ready: backend.ready,
          uptimeMs: Date.now() - backend.startedAt,
          candidates: backend.candidates.length,
          appLibrary: !!backend.appLibrary,
          methods: Rpc.methods(backend.registry)
        }
      },
      getPaths: function() { return backend.paths }
    })

    Rpc.register(backend.registry, "settings", {
      getGeneralSettings: function() {
        if (!settingsStore.loaded) throw new Error("settings not loaded")
        return settingsStore.doc.general
      },
      updateGeneralSettings: function(data) {
        if (!settingsStore.loaded) throw new Error("settings not loaded")
        if (settingsStore.readOnly) throw new Error("settings are read-only: " + (settingsStore.lastError || "written by a newer build"))
        var patch = data && typeof data === "object" ? data : {}
        var current = settingsStore.doc.general
        for (var key in patch) {
          if (current[key] === undefined) throw new Error("Unknown general setting " + key)
          if (typeof patch[key] !== typeof current[key]) throw new Error("Setting " + key + " must be a " + typeof current[key])
          var choices = Schema.generalChoices[key]
          if (choices && choices.indexOf(patch[key]) < 0) throw new Error("Setting " + key + " must be one of " + choices.join(", "))
        }
        settingsStore.update(function(doc) { for (var k in patch) doc.general[k] = patch[k] })
        backend.emit("settings.generalSettingsChanged", settingsStore.doc.general)
        return settingsStore.doc.general
      },
      getAllCommandSettings: function() { return settingsStore.doc.commands },
      getCommandSettings: function(data) { return settingsStore.doc.commands[String(data && data.commandId || "")] || {} },
      updateCommandSettings: function(data) {
        var id = String(data && data.commandId || "")
        if (!backend.candidatesById[id]) throw new Error("Unknown command " + id)
        if (data.alias !== undefined && data.alias !== null) {
          var alias = String(data.alias).trim().toLowerCase()
          if (/\s/.test(alias)) throw new Error(backend.t("error.aliasSpaces", "An alias cannot contain spaces"))
          var commands = settingsStore.doc.commands
          for (var other in commands) {
            if (other !== id && commands[other].alias === alias && alias) throw new Error(backend.t("error.aliasUsed", "Alias “%1” is already used by %2", [alias, (backend.candidatesById[other] || {}).title || other]))
          }
        }
        backend.updateCommand(id, function(s) {
          if (data.alias !== undefined) { if (data.alias) s.alias = String(data.alias).trim().toLowerCase(); else delete s.alias }
          if (data.enabled !== undefined) { if (data.enabled === false) s.enabled = false; else delete s.enabled }
          return s
        })
        return settingsStore.doc.commands[id] || {}
      }
    })

    Rpc.register(backend.registry, "rootSearch", {
      search: function(data) {
        var query = String(data && data.query || "")
        var view = data && data.view
        var viewKind = view && view.kind ? String(view.kind) : "root"
        var ctx = backend.searchContext()
        if (data && data.fleaHits) ctx.fleaHits = data.fleaHits
        var sections
        if (view && view.kind === "menu") sections = RootSearch.submenuSections(backend.candidates, view.menuId, query, ctx, backend.deps)
        else if (view && view.kind === "theme")
          sections = Themes.sections(themeSource.themes, themeSource.current, query)
        else if (view && view.kind === "clipboard") sections = ClipboardHistory.sections(backend.clipboardEntries(), query, String(data && data.filter || "all"), ctx.nowMs)
        else if (view && view.kind === "emoji") sections = Emoji.sections(backend.emoji.list, query, Object.assign(backend.emojiState(), { fleaHits: data.fleaHits || null }))
        else if (view && view.kind === "calculator-history") sections = RootSearch.historySections(calculatorStore.doc.history, query, ctx.nowMs, Calculator.filterHistory)
        else {
          ctx.filter = String(data && data.filter || "all")
          if (query.trim() && ctx.filter === "all") ctx.calculation = backend.calculate(query)
          sections = RootSearch.rootSections(backend.candidates, query, ctx, backend.deps)
        }
        if (view && view.kind === "emoji") return sections.map(function(s) { return Localize.section(s, viewKind, backend.t, backend.tn, strings.language) })
        return sections.map(function(s) {
          return Localize.section({ id: s.id, title: s.title, rows: s.rows.map(function(r) { return r.candidate }) }, viewKind, backend.t, backend.tn, strings.language)
        })
      },
      getActions: function(data) {
        var rowId = String(data && data.id || "")
        var actions
        if (rowId === RootSearch.CALCULATOR_ID) actions = RootSearch.actionsFor({ kind: "calculator" })
        else if (rowId.indexOf("calculator-history:") === 0) actions = RootSearch.actionsFor({ kind: "calculator-history" })
        else if (rowId.indexOf("theme:") === 0) {
          var shown = backend.themeEntry(rowId)
          if (!shown) throw new Error("No such theme")
          actions = Themes.actionsFor(shown, themeSource.current)
        } else if (rowId.indexOf("clipboard:") === 0) {
          var clip = backend.clipboardEntry(rowId)
          if (!clip) throw new Error("No such clipboard entry")
          var app = backend.activeApp()
          actions = ClipboardHistory.actionsFor(clip, app ? app.name : "")
        } else if (rowId.indexOf("emoji:") === 0) {
          actions = Emoji.actionsFor(backend.emojiCandidate(rowId).candidate, backend.emojiState().tone)
        } else {
          var candidate = backend.decorated(rowId)
          if (!candidate) {
            var fallback = RootSearch.FALLBACKS.filter(function(f) { return f.id === data.id })[0]
            if (!fallback) throw new Error(backend.t("error.unknownCommand", "Unknown command %1", [data && data.id]))
            actions = RootSearch.actionsFor({ kind: "fallback", title: fallback.title })
          } else {
            actions = RootSearch.actionsFor(candidate)
          }
        }
        return actions.map(function(a) { return Localize.action(a, backend.t) })
      },
      getItemInfo: function(data) {
        var rowId = String(data && data.id || "")
        var nowMs = Date.now()
        var info
        if (rowId === RootSearch.CALCULATOR_ID) {
          var calc = backend.calculate(String(data.query || ""))
          info = calc ? RootSearch.aboutFor(RootSearch.calculatorCandidate(calc), nowMs) : []
        } else if (rowId.indexOf("calculator-history:") === 0) {
          var entry = backend.historyEntry(rowId)
          info = entry ? RootSearch.aboutFor(RootSearch.historyCandidate(entry, nowMs), nowMs) : []
        } else if (rowId.indexOf("clipboard:") === 0) {
          var clip = backend.clipboardEntry(rowId)
          return clip ? backend.clipboardInfo(clip).info : []
        } else if (rowId.indexOf("emoji:") === 0) {
          var found = backend.emojiCandidate(rowId)
          info = Emoji.aboutFor(found.candidate, found.entry)
        } else {
          var candidate = backend.decorated(rowId)
          if (!candidate) {
            var f = RootSearch.FALLBACKS.filter(function(x) { return x.id === rowId })[0]
            if (!f) throw new Error(backend.t("error.unknownCommand", "Unknown command %1", [rowId]))
            info = RootSearch.aboutFor({ id: f.id, kind: "fallback", title: f.title, typeLabel: "Fallback", url: f.url }, nowMs)
          } else {
            info = RootSearch.aboutFor(candidate, nowMs)
          }
        }
        return Localize.infoRows(info, backend.t, backend.tn)
      },
      performAction: function(data) {
        if (data && String(data.id).indexOf("theme:") === 0) {
          var theme = backend.themeEntry(data.id)
          if (!theme) throw new Error(backend.t("error.noSuchTheme", "No such theme"))
          themeSource.apply(theme.slug)
          return { close: true }
        }
        if (data && String(data.id).indexOf("clipboard:") === 0)
          return backend.clipboardAction(String(data.action || "open"), data.id, !!data.confirmed)
        // Destructive commands come back as a confirmation unless confirmed.
        if (!(data && data.confirmed)) {
          var confirm = RootSearch.confirmationFor(String(data && data.id || ""), String(data && data.action || "open"))
          if (confirm) return { confirm: Localize.confirmation(confirm, backend.t) }
        }
        var fallback = RootSearch.FALLBACKS.filter(function(f) { return f.id === (data && data.id) })[0]
        if (fallback) {
          Util.execArgv(["omarchy-launch-browser", RootSearch.fallbackUrl(fallback, data.query)])
          return { close: true }
        }
        // The calculator row is the query itself, evaluated again.
        if (data && data.id === RootSearch.CALCULATOR_ID) {
          var calc = backend.calculate(String(data.query || ""))
          if (!calc) throw new Error(backend.t("error.nothingToCalculate", "Nothing to calculate"))
          return backend.calculatorAction(String(data.action || "open"), { query: calc.input, result: calc.result, copy: calc.copy, kind: calc.kind }, "")
        }
        if (data && String(data.id).indexOf("calculator-history:") === 0) {
          var entry = backend.historyEntry(data.id)
          if (!entry) throw new Error(backend.t("error.noSuchHistory", "No such history entry"))
          return backend.calculatorAction(String(data.action || "open"), entry, entry.id)
        }
        if (data && String(data.id).indexOf("emoji:") === 0) {
          var confirmClear = String(data.action) === "clear-recent" && !data.confirmed
          if (confirmClear) return { confirm: Localize.confirmation({ title: "Clear Recently Used", message: "This forgets every emoji you have pasted or copied.", primary: "Clear", destructive: true }, backend.t) }
          return backend.emojiAction(String(data.action || "open"), data.id, String(data.query || ""))
        }
        return backend.performAction(data)
      },
      getSearchHistory: function() { return frecencyStore.loaded ? frecencyStore.doc.searchHistory : [] }
    })

    // Names from Raycast's calculator namespace (ref 02 §2).
    Rpc.register(backend.registry, "calculator", {
      calculate: function(data) { return backend.calculate(String(data && data.query || "")) },
      historyGetAll: function() { return calculatorStore.loaded ? calculatorStore.doc.history : [] },
      historyDelete: function(data) { return backend.calculatorAction("delete-entry", null, String(data && data.id || "")) },
      historyDeleteAll: function() { return backend.calculatorAction("delete-all-entries", null, "") },
      refreshCurrencies: function() {
        if (!backend.config.currencyRates) throw new Error(backend.t("error.currencyRatesOff", "currencyRates is off in config.json"))
        calculatorData.fetchRates()
        return null
      },
      getCurrencies: function() {
        var r = calculatorData.rates
        return {
          enabled: backend.config.currencyRates,
          date: r ? r.date : null,
          base: r ? r.base : null,
          currencies: r ? Object.keys(r.rates).concat([r.base]).sort() : [],
          fetchedAt: calculatorData.ratesFetchedAt || null,
          zones: Object.keys(calculatorData.zones).length
        }
      }
    })

    // Names from Raycast's emojiPicker namespace (ref 02 §2); setSkinTone and
    // getSkinTone stand in for its preference [D].
    Rpc.register(backend.registry, "emojiPicker", {
      search: function(data) { return Emoji.sections(backend.emoji.list, String(data && data.query || ""), backend.emojiState(data && data.filter)) },
      get: function(data) { return backend.emojiCandidate("emoji:" + String(data && data.symbol || "")).candidate },
      pin: function(data) { backend.emojiCandidate("emoji:" + data.symbol); backend.setPinned(String(data.symbol), true); return null },
      unpin: function(data) { backend.setPinned(String(data && data.symbol || ""), false); return null },
      uprank: function(data) { backend.emojiAction("open", "emoji:" + String(data && data.symbol || ""), ""); return null },
      resetRanking: function(data) { return backend.emojiAction("remove-recent", "emoji:" + String(data && data.symbol || ""), "") },
      getSkinTone: function() { return emojiStore.loaded ? emojiStore.doc.skinTone : "none" },
      setSkinTone: function(data) {
        var tone = String(data && data.tone || "")
        if (!Emoji.TONES.some(function(t) { return t.id === tone })) throw new Error("Skin tone must be one of " + Emoji.TONES.map(function(t) { return t.id }).join(", "))
        emojiStore.update(function(doc) { doc.skinTone = tone })
        backend.emit("emojiPicker.stateChanged", null)
        return tone
      }
    })

    // Names from Raycast's clipboard namespace (ref 02 §2); getDetail feeds
    // the detail pane [D].
    Rpc.register(backend.registry, "clipboard", {
      getAll: function() { return backend.clipboardEntries() },
      getDetail: function(data) {
        var e = backend.clipboardEntry(String(data && data.id || ""))
        return e ? backend.clipboardInfo(e) : null
      },
      copy: function(data) { return backend.clipboardAction("copy", String(data && data.id || ""), true) },
      paste: function(data) { return backend.clipboardAction("paste", String(data && data.id || ""), true) },
      pin: function(data) { return backend.clipboardAction("pin", String(data && data.id || ""), true) },
      unpin: function(data) { return backend.clipboardAction("unpin", String(data && data.id || ""), true) },
      "delete": function(data) { return backend.clipboardAction("delete-entry", String(data && data.id || ""), true) },
      deleteAll: function() { return backend.clipboardAction("delete-all-entries", "", true) }
    })

    Rpc.register(backend.registry, "themes", {
      getAll: function() { return { current: themeSource.current, themes: themeSource.themes } },
      getDetail: function(data) {
        var t = backend.themeEntry(String(data && data.id || ""))
        if (!t) return null
        var d = Themes.detail(t, themeSource.current)
        return Object.assign({}, d, { info: Localize.infoRows(d.info, backend.t, backend.tn) })
      }
    })

    Rpc.register(backend.registry, "frecency", {
      visit: function(data) { backend.recordVisit(String(data.id), String(data.query || "")); return null },
      get: function(data) {
        var entry = frecencyStore.doc.items[String(data && data.id || "")]
        return entry ? { anchor: entry.anchor, openedAt: entry.openedAt, score: Frecency.score(entry.anchor, Date.now() / 1000), searchTerms: entry.searchTerms } : null
      }
    })
  }

  Component.onCompleted: {
    registerServices()
    mkdirs.running = true
  }

  onAppLibraryChanged: rebuildTimer.restart()

  Connections {
    target: backend.appLibrary
    ignoreUnknownSignals: true
    function onAppsChanged() { rebuildTimer.restart() }
  }

  Connections {
    target: backend.appLibrary ? null : DesktopEntries.applications
    ignoreUnknownSignals: true
    function onValuesChanged() { rebuildTimer.restart() }
  }

  Component.onDestruction: { settingsStore.flush(); frecencyStore.flush(); calculatorStore.flush(); emojiStore.flush(); clipboardStore.flush() }
  onNotification: function(method, data) {
    if (method === "window.visibilityChanged" && data && data.visible) {
      menuSource.refresh()
      scriptSource.refresh()
      calculatorData.refresh()
      backend.pruneClipboard()
    }
  }

  // Clipboard text goes over stdin, never argv (other users can read argv).
  function copyText(text) { clipboard.copy(text) }

  ClipboardWriter {
    id: clipboard
    onFailed: function(message) { backend.log("error", "clipboard", message, null) }
  }

  ClipboardWatcher {
    directory: backend.directoriesReady && clipboardStore.loaded ? backend.paths.clipboard : ""
    enabled: backend.config.clipboardHistory
    onCaptured: function(observation) { backend.recordClipboard(observation) }
    onMessage: function(level, text) { backend.log(level, "clipboard", text, null) }
  }

  ThemeSource {
    id: themeSource
    onLoaded: backend.emit("themes.changed", null)
  }

  ScriptCommandSource {
    id: scriptSource
    directory: backend.directoriesReady ? backend.paths.scriptCommands : ""
    onDirectoryChanged: refresh()
    onRevisionChanged: rebuildTimer.restart()
    onMessage: function(level, text, metadata) { backend.log(level, "script-commands", text, metadata) }
  }

  // Launcher.qml shows the result as a toast while the window is open, else a HUD.
  ScriptRunner {
    id: scriptRunner
    onFinished: function(command, result) {
      var title = result.title
      if (title === command.title + " finished") {
        title = backend.t("toast.scriptFinished", "%1 finished", [command.title])
      } else {
        var m = title.match(/^[\s\S]+ failed \(exit (\d+)\)$/)
        if (m && title === command.title + " failed (exit " + m[1] + ")")
          title = backend.t("toast.scriptFailed", "%1 failed (exit %2)", [command.title, m[1]])
      }
      backend.emit("scriptCommands.finished", { mode: command.mode, style: result.style, title: title })
    }
  }

  AppFocuser {
    id: appFocuser
    onLaunchRequested: function(candidate) { backend.launchApp(candidate) }
  }


  Process {
    id: mkdirs
    // Creates directories owner-only and repairs modes left readable by older builds.
    command: Paths.setupArgv(backend.paths, [Schema.documents.settings.file, Schema.documents.frecency.file, Schema.documents.calculator.file, Schema.documents.emoji.file, Schema.documents.clipboard.file]
      .map(function(file) { return backend.paths.db + "/" + file }))
    onExited: function(exitCode) {
      if (exitCode !== 0) backend.log("error", "paths", "could not create data directories", { exitCode: exitCode })
      backend.directoriesReady = true
    }
  }

  OmarchyMenuSource {
    id: menuSource
    language: strings.language
    onRevisionChanged: rebuildTimer.restart()
    onMessage: function(level, text, metadata) { backend.log(level, "omarchy-menu", text, metadata) }
  }

  JsonStore {
    id: settingsStore
    ready: backend.directoriesReady
    path: backend.paths.db + "/" + Schema.documents.settings.file
    migrations: Schema.documents.settings.migrations
    onMessage: function(level, text, metadata) { backend.log(level, "store", text, metadata) }
  }

  JsonStore {
    id: frecencyStore
    ready: backend.directoriesReady
    path: backend.paths.db + "/" + Schema.documents.frecency.file
    migrations: Schema.documents.frecency.migrations
    onMessage: function(level, text, metadata) { backend.log(level, "store", text, metadata) }
  }

  JsonStore {
    id: calculatorStore
    ready: backend.directoriesReady
    path: backend.paths.db + "/" + Schema.documents.calculator.file
    migrations: Schema.documents.calculator.migrations
    onMessage: function(level, text, metadata) { backend.log(level, "store", text, metadata) }
  }

  JsonStore {
    id: emojiStore
    ready: backend.directoriesReady
    path: backend.paths.db + "/" + Schema.documents.emoji.file
    migrations: Schema.documents.emoji.migrations
    onMessage: function(level, text, metadata) { backend.log(level, "store", text, metadata) }
  }

  FileView {
    path: decodeURIComponent(Qt.resolvedUrl("data/emoji.json").toString().replace(/^file:\/\//, ""))
    printErrors: false
    onLoaded: backend.emojiRaw = text()
    onLoadFailed: backend.log("error", "emoji", "could not read " + path)
  }

  // Omarchy's emoji keywords (MIT, read in place) make searches like "lol" work.
  FileView {
    path: Quickshell.env("OMARCHY_PATH") ? Quickshell.env("OMARCHY_PATH") + "/shell/plugins/emojis/emojis.json" : ""
    printErrors: false
    onLoaded: backend.emojiKeywordsRaw = text()
  }

  JsonStore {
    id: clipboardStore
    ready: backend.directoriesReady
    path: backend.paths.db + "/" + Schema.documents.clipboard.file
    migrations: Schema.documents.clipboard.migrations
    onMessage: function(level, text, metadata) { backend.log(level, "store", text, metadata) }
    onLoadedChanged: if (loaded) backend.pruneClipboard()
  }

  CalculatorData {
    id: calculatorData
    cacheDir: backend.directoriesReady ? backend.paths.cache : ""
    ratesEnabled: backend.config.currencyRates
    onMessage: function(level, text, metadata) { backend.log(level, "calculator", text, metadata) }
  }

  readonly property int dataRevision: candidatesRevision + (settingsStore.loaded ? 1 : 0) + (frecencyStore.loaded ? 1 : 0)
  property int storeRevision: 0
  Connections { target: settingsStore; function onChanged() { backend.storeRevision++ } }
  Connections { target: frecencyStore; function onChanged() { backend.storeRevision++ } }
  Connections { target: calculatorStore; function onChanged() { backend.storeRevision++ } }
  Connections { target: emojiStore; function onChanged() { backend.storeRevision++ } }

  FileView {
    path: backend.directoriesReady ? backend.paths.configFile : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        backend.config = Schema.withConfigDefaults(JSON.parse(text()))
      } catch (e) {
        backend.config = Schema.withConfigDefaults(null)
        backend.log("warning", "config", "ignoring unreadable " + path + ": " + e)
      }
    }
    onLoadFailed: backend.config = Schema.withConfigDefaults(null)
  }
}
