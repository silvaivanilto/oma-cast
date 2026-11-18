// Pure localization helpers shared by Backend.qml and unit tests.
// Never imports other core/ modules; callers supply t(key, fallback) and
// tn(key, count, fallback) backed by Omarchy's Commons.Translations.

function format(template, args) {
  var out = String(template)
  if (!args || !args.length) return out
  for (var i = 0; i < args.length; i++) {
    out = out.split("%" + (i + 1)).join(String(args[i]))
  }
  return out
}

function relativeTime(text, t, tn) {
  var s = String(text || "")
  if (!s) return s
  if (s === "Just now") return t("time.justNow", s)
  if (s === "Yesterday") return t("time.yesterday", s)
  if (s === "Today") return t("calc.Today", s)
  if (s === "Tomorrow") return t("calc.Tomorrow", s)
  var m = s.match(/^(\d+)\s*(?:m|min) ago$/)
  if (m) return format(tn("time.minutesAgo", Number(m[1]), "%1 min ago"), [m[1]])
  var h = s.match(/^(\d+)\s*h ago$/)
  if (h) return format(tn("time.hoursAgo", Number(h[1]), "%1 h ago"), [h[1]])
  var d = s.match(/^(\d+) days ago$/)
  if (d) return format(tn("time.daysAgo", Number(d[1]), "%1 days ago"), [d[1]])
  var cd = s.match(/^([\d,]+) days ago$/)
  if (cd) return format(tn("calc.daysAgo", Number(cd[1].replace(/,/g, "")), "%1 days ago"), [cd[1]])
  var ind = s.match(/^In ([\d,]+) days$/)
  if (ind) return format(tn("calc.inDays", Number(ind[1].replace(/,/g, "")), "In %1 days"), [ind[1]])
  return s
}

var BUILTIN_KEYS = {
  "builtin:google-search": { title: "builtin.google.title", subtitle: "type.Quicklink" },
  "builtin:duckduckgo-search": { title: "builtin.duckduckgo.title", subtitle: "type.Quicklink" },
  "builtin:omarchy-menu": { title: "builtin.omarchyMenu.title", subtitle: "builtin.omarchyMenu.subtitle" },
  "builtin:clipboard-history": { title: "builtin.clipboard.title", subtitle: "builtin.clipboard.subtitle", pushTitle: "builtin.clipboard.title" },
  "builtin:switch-theme": { title: "builtin.theme.title", subtitle: "builtin.theme.subtitle", pushTitle: "builtin.theme.title" },
  "builtin:emoji-picker": { title: "builtin.emoji.title", subtitle: "builtin.emoji.subtitle", pushTitle: "builtin.emoji.title" },
  "builtin:calculator-history": { title: "builtin.calculatorHistory.title", subtitle: "builtin.calculatorHistory.subtitle", pushTitle: "builtin.calculatorHistory.title" }
}

var FALLBACK_KEYS = {
  "fallback:google": "builtin.google.title",
  "fallback:duckduckgo": "builtin.duckduckgo.title"
}

var SECTION_KEYS = {
  "Favorites": "section.favorites",
  "Suggestions": "section.suggestions",
  "Commands": "section.commands",
  "Applications": "section.applications",
  "Calculator": "section.calculator",
  "Results": "section.results",
  "Pinned": "section.pinned",
  "Today": "section.today",
  "Yesterday": "section.yesterday",
  "Earlier": "section.earlier",
  "Recently Used": "section.recentlyUsed"
}

var FILTER_KEYS = {
  "all": "filter.all",
  "applications": "filter.applications",
  "commands": "filter.commands",
  "text": "filter.text",
  "image": "filter.images",
  "file": "filter.files",
  "link": "filter.links",
  "color": "filter.colors"
}

function typeLabel(label, t, tn) {
  if (!label) return label
  var key = "type." + label
  var mapped = t(key, "")
  if (mapped) return mapped
  return relativeTime(label, t, tn)
}

function calcCaption(caption, t, tn, lang) {
  if (!caption) return caption
  var key = "calc." + caption
  var mapped = t(key, "")
  if (mapped) return mapped
  var unit = t("unit." + caption, "")
  if (unit) return unit
  var cur = String(caption).match(/^.+ \(([A-Z]{3})\)$/)
  if (cur) {
    var c = t("currency." + cur[1], "")
    if (c) return c
  }
  var rel = relativeTime(caption, t, tn)
  if (rel !== caption) return rel
  return calcDate(caption, t, lang)
}

var PT_UNITS = ["", "um", "dois", "três", "quatro", "cinco", "seis", "sete", "oito", "nove",
  "dez", "onze", "doze", "treze", "quatorze", "quinze", "dezesseis", "dezessete", "dezoito", "dezenove"]
var PT_TENS = ["", "", "vinte", "trinta", "quarenta", "cinquenta", "sessenta", "setenta", "oitenta", "noventa"]
var PT_HUNDREDS = ["", "cento", "duzentos", "trezentos", "quatrocentos", "quinhentos", "seiscentos", "setecentos", "oitocentos", "novecentos"]
var PT_SCALES = [
  ["", ""],
  ["mil", "mil"],
  ["milhão", "milhões"],
  ["bilhão", "bilhões"],
  ["trilhão", "trilhões"]
]

function ptBelow1000(n) {
  if (n === 100) return "cem"
  var parts = []
  if (n >= 100) { parts.push(PT_HUNDREDS[Math.floor(n / 100)]); n %= 100 }
  if (n >= 20) {
    parts.push(PT_TENS[Math.floor(n / 10)])
    if (n % 10 > 0) parts.push(PT_UNITS[n % 10])
  } else if (n > 0) {
    parts.push(PT_UNITS[n])
  }
  return parts.join(" e ")
}

function numberWordsPt(n) {
  if (typeof n !== "number" || !isFinite(n) || Math.floor(n) !== n || Math.abs(n) >= 1e15) return ""
  if (n === 0) return "Zero"
  var neg = n < 0
  var a = Math.abs(n)
  var groups = []
  for (var s = 0; a > 0; s++) {
    var chunk = a % 1000
    if (chunk > 0) {
      var text = s === 1 && chunk === 1 ? "mil" : ptBelow1000(chunk) + (s > 0 ? " " + PT_SCALES[s][chunk === 1 ? 0 : 1] : "")
      groups.unshift({ chunk: chunk, scale: s, text: text })
    }
    a = Math.floor(a / 1000)
  }
  var out = groups[0].text
  for (var i = 1; i < groups.length; i++) {
    var g = groups[i]
    var useE = (g.scale === 0 && (g.chunk < 100 || g.chunk % 100 === 0)) || (groups.length === 2 && g.scale === 1)
    out += (useE ? " e " : " ") + g.text
  }
  if (neg) out = "menos " + out
  return out.charAt(0).toUpperCase() + out.slice(1)
}

function calcDate(text, t) {
  var s = String(text || "")
  // Full date: "Wednesday, 18 November 2026" or "... at 14:30"
  var full = s.match(/^(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday), (\d{1,2}) (January|February|March|April|May|June|July|August|September|October|November|December) (\d{4})(?: at (.+))?$/)
  if (full) {
    var datePart = format(t("calc.dateFormat", "%1, %2 %3 %4"), [
      t("weekday." + full[1], full[1]),
      full[2],
      t("month." + full[3], full[3]),
      full[4]
    ])
    return full[5] ? datePart + t("calc.at", " at ") + full[5] : datePart
  }
  // Short date (optionally followed by " · Zone (UTC...)" in time-zone captions)
  var short = s.match(/^(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday), (\d{1,2}) (January|February|March|April|May|June|July|August|September|October|November|December)( · .*)?$/)
  if (short) {
    var head = format(t("calc.shortDateFormat", "%1, %2 %3"), [
      t("weekday." + short[1], short[1]),
      short[2],
      t("month." + short[3], short[3])
    ])
    return head + (short[4] || "")
  }
  return s
}

function calcDayShift(text, t, tn) {
  return String(text || "").replace(/\(([+-]\d+) days?\)$/, function(_, signed) {
    return format(tn("calc.dayShift", Math.abs(Number(signed)), "(%1 day)"), [signed])
  })
}

function candidate(c, t, tn, lang) {
  if (!c) return c
  var out = Object.assign({}, c)
  if (out.typeLabel) out.typeLabel = typeLabel(out.typeLabel, t, tn)
  var b = BUILTIN_KEYS[out.id]
  if (b) {
    var origTitle = out.title
    out.title = t(b.title, origTitle)
    out.subtitle = t(b.subtitle, out.subtitle)
    var kw = Array.isArray(out.keywords) ? out.keywords.slice() : []
    if (origTitle && kw.indexOf(origTitle) < 0) kw.push(origTitle)
    out.keywords = kw
    if (out.arguments && out.arguments.length) {
      out.arguments = out.arguments.map(function(arg) {
        if (arg.placeholder === "Query") return Object.assign({}, arg, { placeholder: t("placeholder.argument", arg.placeholder) })
        return arg
      })
    }
    if (out.run && out.run.push && b.pushTitle) {
      out.run = Object.assign({}, out.run, {
        push: Object.assign({}, out.run.push, { title: t(b.pushTitle, out.run.push.title) })
      })
    }
  }
  var fk = FALLBACK_KEYS[out.id]
  if (fk) out.title = t(fk, out.title)
  if (out.kind === "clipboard") {
    var filesMatch = String(out.title || "").match(/^(\d+) Files$/)
    if (filesMatch) out.title = format(tn("clipboard.filesCount", Number(filesMatch[1]), "%1 Files"), [filesMatch[1]])
  }
  if (out.kind === "calculator") {
    if (out.calcKind === "date") {
      out.title = calcDate(out.title, t)
      out.calcResult = out.title
    } else if (out.calcKind === "time") {
      out.title = calcDayShift(out.title, t, tn)
      out.calcResult = out.title
    }
    out.calcInputCaption = calcCaption(out.calcInputCaption, t, tn, lang)
    var translatedResultCaption = calcCaption(out.calcResultCaption, t, tn, lang)
    if (translatedResultCaption === out.calcResultCaption && (out.calcKind === "math" || out.calcKind === "percentage")
        && lang && String(lang).indexOf("pt") === 0 && typeof out.calcValue === "number") {
      var ptWords = numberWordsPt(out.calcValue)
      if (ptWords) translatedResultCaption = ptWords
    }
    out.calcResultCaption = translatedResultCaption
  }
  return out
}

function sectionTitle(title, viewKind, t) {
  if (!title) return title
  if (SECTION_KEYS[title]) return t(SECTION_KEYS[title], title)
  if (viewKind === "emoji") {
    var group = t("emojiGroup." + title, "")
    if (group) return group
  }
  var useMatch = title.match(/^Use “([\s\S]*)” with…$/)
  if (useMatch) return format(t("section.useWith", title), [useMatch[1]])
  return title
}

function section(s, viewKind, t, tn, lang) {
  if (!s) return s
  return Object.assign({}, s, {
    title: sectionTitle(s.title, viewKind, t),
    rows: (s.rows || []).map(function(r) { return candidate(r, t, tn, lang) })
  })
}

function action(a, t) {
  if (!a) return a
  var title = a.title
  if (title === "Paste to Active App") {
    title = t("action.Paste to Active App", title)
  } else if (title.indexOf("Paste to ") === 0) {
    title = format(t("action.Paste to App", title), [title.slice("Paste to ".length)])
  } else if (title.indexOf("Skin Tone: ") === 0) {
    var rawTone = title.slice("Skin Tone: ".length)
    var tone = t("tone." + rawTone, rawTone)
    title = format(t("action.skinTone", title), [tone])
  } else {
    var mapped = t("action." + title, "")
    if (mapped) title = mapped
    else if (title === "Search Google") title = t("builtin.google.title", title)
    else if (title === "Search DuckDuckGo") title = t("builtin.duckduckgo.title", title)
  }
  return Object.assign({}, a, { title: title })
}

function infoRows(rows, t, tn) {
  return (rows || []).map(function(row) {
    var label = t("info." + row.label, row.label)
    var value = row.value
    if (row.label === "Type" || row.label === "Content type") {
      value = typeLabel(value, t, tn)
      if (value === row.value) value = calcCaption(value, t, tn)
    } else if (row.label === "Last Opened" || row.label === "Saved") {
      value = relativeTime(value, t, tn)
    } else if (row.label === "Arguments") {
      value = String(value || "").split(" (optional)").join(t("placeholder.optionalSuffix", " (optional)"))
    } else if (row.label === "Status" && value === "Current theme") {
      value = t("infoValue.Current theme", value)
    }
    return { label: label, value: value }
  })
}

function filterOptions(list, viewKind, t) {
  return (list || []).map(function(f) {
    var key = f.id === "all" && viewKind === "clipboard" ? "filter.allTypes" : FILTER_KEYS[f.id]
    return Object.assign({}, f, { title: key ? t(key, f.title) : f.title })
  })
}

var CONFIRM_BY_TITLE = {
  "Shut Down": { title: "confirm.shutdown.title", message: "confirm.shutdown.message", primary: "confirm.shutdown.primary" },
  "Restart": { title: "confirm.restart.title", message: "confirm.restart.message", primary: "confirm.restart.primary" },
  "Log Out": { title: "confirm.logout.title", message: "confirm.logout.message", primary: "confirm.logout.primary" },
  "Clear Recently Used": { title: "confirm.clearEmoji.title", message: "confirm.clearEmoji.message", primary: "confirm.clearEmoji.primary" }
}

function confirmation(c, t) {
  if (!c) return c
  var k = CONFIRM_BY_TITLE[c.title]
  if (k) {
    return Object.assign({}, c, {
      title: t(k.title, c.title),
      message: t(k.message, c.message),
      primary: t(k.primary, c.primary)
    })
  }
  if (c.title === "Delete All Entries") {
    var calc = String(c.message || "").indexOf("Calculator") >= 0
    var prefix = calc ? "confirm.deleteCalc." : "confirm.deleteClip."
    return Object.assign({}, c, {
      title: t(prefix + "title", c.title),
      message: t(prefix + "message", c.message),
      primary: t(prefix + "primary", c.primary)
    })
  }
  if (c.message === "Are you sure you want to run this script?") {
    return Object.assign({}, c, {
      message: t("confirm.script.message", c.message),
      primary: t("confirm.script.primary", c.primary)
    })
  }
  return c
}

if (typeof module !== "undefined") {
  module.exports = {
    format: format,
    relativeTime: relativeTime,
    typeLabel: typeLabel,
    calcCaption: calcCaption,
    calcDate: calcDate,
    numberWordsPt: numberWordsPt,
    candidate: candidate,
    sectionTitle: sectionTitle,
    section: section,
    action: action,
    infoRows: infoRows,
    filterOptions: filterOptions,
    confirmation: confirmation
  }
}
