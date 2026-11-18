const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const Localize = require("../core/Localize.js")
const OmarchyMenu = require("../core/OmarchyMenu.js")

const root = path.join(__dirname, "..")
const en = JSON.parse(fs.readFileSync(path.join(root, "i18n/en.json"), "utf8"))
const ptBR = JSON.parse(fs.readFileSync(path.join(root, "i18n/pt-BR.json"), "utf8"))

function makeTranslator(catalog) {
  function pickPlural(entry, count) {
    if (typeof entry === "string") return entry
    if (!entry || typeof entry !== "object") return ""
    const n = Math.abs(Math.trunc(Number(count) || 0))
    if (n <= 1 && typeof entry.one === "string") return entry.one
    if (n !== 0 && n % 1000000 === 0 && typeof entry.many === "string") return entry.many
    return typeof entry.other === "string" ? entry.other : ""
  }
  const t = (key, fallback, args) => {
    const v = catalog[key] !== undefined ? catalog[key] : en[key]
    const s = typeof v === "string" ? v : (v && typeof v === "object" ? v.other : fallback)
    return Localize.format(s !== undefined ? s : fallback, args)
  }
  const tn = (key, count, fallback, args) => {
    const v = catalog[key] !== undefined ? catalog[key] : en[key]
    const s = pickPlural(v, count) || fallback
    return Localize.format(s, args)
  }
  return { t, tn }
}

test("i18n catalogs have matching keys, valid plural forms and matching placeholders", () => {
  const enKeys = Object.keys(en).sort()
  const ptKeys = Object.keys(ptBR).sort()
  assert.deepEqual(ptKeys, enKeys)
  for (const k of enKeys) {
    const a = en[k]
    const b = ptBR[k]
    if (typeof a === "string") {
      assert.equal(typeof b, "string", k)
      assert.ok(b.length > 0, `${k} must not be empty`)
      assert.equal(a.includes("%1"), b.includes("%1"), `${k} %1 placeholder mismatch`)
      assert.equal(a.includes("%2"), b.includes("%2"), `${k} %2 placeholder mismatch`)
    } else {
      assert.equal(typeof a, "object", k)
      assert.equal(typeof b, "object", k)
      assert.equal(typeof a.one, "string", `${k}.one`)
      assert.equal(typeof a.other, "string", `${k}.other`)
      assert.equal(typeof b.one, "string", `${k}.one in pt-BR`)
      assert.equal(typeof b.other, "string", `${k}.other in pt-BR`)
    }
  }
})

test("Localize translates candidates to pt-BR while keeping English keywords searchable", () => {
  const { t, tn } = makeTranslator(ptBR)
  const cand = Localize.candidate({
    id: "builtin:clipboard-history",
    title: "Clipboard History",
    subtitle: "Clipboard History",
    typeLabel: "Command",
    keywords: ["clipboard", "history"],
    run: { push: { kind: "clipboard", title: "Clipboard History" } }
  }, t, tn)
  assert.equal(cand.title, "Histórico da Área de Transferência")
  assert.equal(cand.subtitle, "Área de transferência")
  assert.equal(cand.typeLabel, "Comando")
  assert.equal(cand.run.push.title, "Histórico da Área de Transferência")
  assert.ok(cand.keywords.includes("Clipboard History"))
})

test("Localize translates sections, relative times, actions, info rows, filters and confirmations", () => {
  const { t, tn } = makeTranslator(ptBR)
  assert.equal(Localize.sectionTitle("Favorites", "root", t), "Favoritos")
  assert.equal(Localize.sectionTitle("Use “firefox” with…", "root", t), "Usar “firefox” com…")
  assert.equal(Localize.sectionTitle("Smileys & Emotion", "emoji", t), "Rostos e emoções")

  assert.equal(Localize.relativeTime("Just now", t, tn), "Agora mesmo")
  assert.equal(Localize.relativeTime("5 min ago", t, tn), "Há 5 min")
  assert.equal(Localize.relativeTime("2 h ago", t, tn), "Há 2 h")
  assert.equal(Localize.relativeTime("1 days ago", t, tn), "Há 1 dia")
  assert.equal(Localize.relativeTime("3 days ago", t, tn), "Há 3 dias")
  assert.equal(Localize.candidate({ id: "clipboard:1", kind: "clipboard", title: "3 Files", typeLabel: "5 min ago" }, t, tn).title, "3 arquivos")
  assert.equal(Localize.candidate({ id: "clipboard:1", kind: "clipboard", title: "3 Files", typeLabel: "5 min ago" }, t, tn).typeLabel, "Há 5 min")

  assert.equal(Localize.action({ id: "copy", title: "Copy to Clipboard" }, t).title, "Copiar para a área de transferência")
  assert.equal(Localize.action({ id: "paste", title: "Paste to Firefox" }, t).title, "Colar em Firefox")
  assert.equal(Localize.action({ id: "tone:medium", title: "Skin Tone: Medium" }, t).title, "Tom de pele: Médio")

  const rows = Localize.infoRows([
    { label: "Content type", value: "Image" },
    { label: "Status", value: "Current theme" },
    { label: "Last Opened", value: "Yesterday" }
  ], t, tn)
  assert.deepEqual(rows, [
    { label: "Tipo de conteúdo", value: "Imagem" },
    { label: "Status", value: "Tema atual" },
    { label: "Última abertura", value: "Ontem" }
  ])

  const filters = Localize.filterOptions([{ id: "all", title: "All Types" }, { id: "image", title: "Images" }], "clipboard", t)
  assert.deepEqual(filters.map((f) => f.title), ["Todos os tipos", "Imagens"])

  const confirm = Localize.confirmation({ title: "Shut Down", message: "Are you sure you want to shut down?", primary: "Shut Down", destructive: true }, t)
  assert.equal(confirm.title, "Desligar")
  assert.equal(confirm.primary, "Desligar")
})

test("LauncherWindow wires translucent outer scrim to Commons.Color.menu.scrim", () => {
  const src = fs.readFileSync(path.join(root, "ui/LauncherWindow.qml"), "utf8")
  assert.match(src, /scrim:\s*Commons\.Color\.menu\.scrim/)
  assert.match(src, /id:\s*scrim[\s\S]*color:\s*window\.look\.scrim/)
})

test("OmarchyMenu.applyTranslations translates menu labels and preserves English aliases", () => {
  const parsed = OmarchyMenu.parse(JSON.stringify({
    appearance: { label: "Appearance" },
    "appearance.theme": { label: "Theme", action: "omarchy-menu theme" }
  }))
  const translated = OmarchyMenu.applyTranslations(parsed.items, {
    appearance: { label: "Aparência" },
    "appearance.theme": { label: "Tema" }
  })
  const tree = OmarchyMenu.buildTree(translated, [])
  assert.equal(tree.items.appearance.label, "Aparência")
  assert.equal(tree.items["appearance.theme"].label, "Tema")
  assert.ok(tree.items.appearance.aliases.includes("Appearance"))
  assert.deepEqual(OmarchyMenu.breadcrumb(tree, "appearance.theme"), ["Aparência"])
})

test("Localize translates calculator number words, dates, day shifts and optional arguments", () => {
  const { t, tn } = makeTranslator(ptBR)
  assert.equal(Localize.numberWordsPt(4), "Quatro")
  assert.equal(Localize.numberWordsPt(1234), "Mil duzentos e trinta e quatro")
  assert.equal(Localize.numberWordsPt(-42), "Menos quarenta e dois")
  assert.equal(Localize.numberWordsPt(1000000), "Um milhão")

  const math = Localize.candidate({
    id: "calculator:result", kind: "calculator", calcKind: "math", calcValue: 4,
    title: "4", calcResult: "4", calcInputCaption: "Expression", calcResultCaption: "Four"
  }, t, tn, "pt-BR")
  assert.equal(math.calcInputCaption, "Expressão")
  assert.equal(math.calcResultCaption, "Quatro")

  const pctNum = Localize.candidate({
    id: "calculator:result", kind: "calculator", calcKind: "percentage", calcValue: 20,
    title: "20", calcResult: "20", calcInputCaption: "Percentage", calcResultCaption: "Twenty"
  }, t, tn, "pt-BR")
  assert.equal(pctNum.calcInputCaption, "Porcentagem")
  assert.equal(pctNum.calcResultCaption, "Vinte")

  const date = Localize.candidate({
    id: "calculator:result", kind: "calculator", calcKind: "date",
    title: "Friday, 20 November 2026 at 14:30", calcResult: "Friday, 20 November 2026 at 14:30",
    calcInputCaption: "Date", calcResultCaption: "In 3 days"
  }, t, tn, "pt-BR")
  assert.equal(date.title, "Sexta-feira, 20 de Novembro de 2026 às 14:30")
  assert.equal(date.calcResultCaption, "Em 3 dias")

  const tz = Localize.candidate({
    id: "calculator:result", kind: "calculator", calcKind: "time",
    title: "10:56 (+1 day)", calcResult: "10:56 (+1 day)",
    calcInputCaption: "Current Time", calcResultCaption: "Wednesday, 18 November · Tokyo (UTC+9)"
  }, t, tn, "pt-BR")
  assert.equal(tz.title, "10:56 (+1 dia)")
  assert.equal(tz.calcInputCaption, "Hora atual")
  assert.equal(tz.calcResultCaption, "Quarta-feira, 18 de Novembro · Tokyo (UTC+9)")

  const about = Localize.infoRows([{ label: "Arguments", value: "query (optional)" }], t, tn)
  assert.deepEqual(about, [{ label: "Argumentos", value: "query (opcional)" }])

  const unit = Localize.candidate({
    id: "calculator:result", kind: "calculator", calcKind: "conversion",
    title: "1.524 m", calcResult: "1.524 m", calcInputCaption: "Feet", calcResultCaption: "Meters"
  }, t, tn, "pt-BR")
  assert.equal(unit.calcInputCaption, "Pés")
  assert.equal(unit.calcResultCaption, "Metros")

  const currency = Localize.candidate({
    id: "calculator:result", kind: "calculator", calcKind: "currency",
    title: "570.53 BRL", calcResult: "570.53 BRL", calcInputCaption: "US Dollar (USD)", calcResultCaption: "Brazilian Real (BRL)"
  }, t, tn, "pt-BR")
  assert.equal(currency.calcInputCaption, "Dólar Americano (USD)")
  assert.equal(currency.calcResultCaption, "Real Brasileiro (BRL)")
})
