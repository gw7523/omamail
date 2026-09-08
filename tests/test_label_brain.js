"use strict"

// The label brain: the tokeniser the window and the build script share, the
// scoring that names which labels a message looks like, and what a choice
// teaches it. The build itself is tests/test_label_brain.sh.

const assert = require("assert")
const path = require("path")
const { execFileSync } = require("child_process")
const { load } = require("./load")

const brain = load("account/LabelBrain.js")
// Arrays from the loaded script come from another realm, so they are compared by shape.
const deepEqual = (a, b, msg) => assert.strictEqual(JSON.stringify(a), JSON.stringify(b), msg)
const script = path.join(__dirname, "..", "scripts", "label-brain.py")

function python(verb, input) {
  return JSON.parse(execFileSync("python3", [script, verb], { input: input || "", encoding: "utf8" }))
}

// ------------------------------------------------------------ tokens
deepEqual(brain.tokens("Re: Your invoice #1234 from ACME, Inc."), ["invoice", "acme", "inc"])
deepEqual(brain.tokens("the a an and of"), [], "stop words and short words go")
deepEqual(brain.tokens("Café menu — naïve résumé"), ["café", "menu", "naïve", "résumé"], "Latin letters are letters")
deepEqual(brain.tokens("x".repeat(25) + " " + "y".repeat(24)), ["y".repeat(24)], "a run past 24 letters is noise")
deepEqual(brain.tokens("https://www.example.com/path?utm_source=x"), ["example", "path", "source"], "URL furniture is dropped")
deepEqual(brain.tokens(null), [])

// The Python side tokenises the archive; it must agree on every string.
const samples = ["Re: Your invoice #1234 from ACME, Inc.", "Café menu — naïve résumé; THE quick brown fox",
  "Flight DL 1234 to SFO, seat 12A\nBoarding pass attached", "x".repeat(25) + " ok " + "y".repeat(24)]
for (const sample of samples) {
  assert.strictEqual(JSON.stringify(python("tokens", sample)), JSON.stringify(brain.tokens(sample)), "python and js tokenise alike: " + sample)
}
assert.strictEqual(JSON.stringify(python("stopwords")), JSON.stringify(brain.STOPWORDS.slice().sort()), "the two stop lists are one list")

deepEqual(brain.unique(["b", "a", "b", "c", "a"]), ["b", "a", "c"], "first seen, in order")

// ------------------------------------------------------------ features
const summary = { id: "1", from: { name: "Bob", email: "Bob@ACME.com" }, to: [{ email: "ada@example.com" }],
  cc: [{ email: "Eve@example.com" }], subject: "Invoice invoice for March" }
const feats = brain.features(summary, "Please find the invoice attached. Total due: 40 EUR. invoice")
deepEqual(feats.from, ["bob@acme.com"])
deepEqual(feats.domain, ["acme.com"])
deepEqual(feats.to, ["ada@example.com", "eve@example.com"])
deepEqual(brain.features({ to: [{ email: "ada@example.com" }], cc: [{ email: "ADA@example.com" }] }, "").to, ["ada@example.com"], "a recipient on To and Cc is one recipient")
deepEqual(feats.subject, ["invoice", "march"], "subject words once each")
deepEqual(feats.body, ["find", "invoice", "attached", "total", "due", "eur"])
deepEqual(brain.features({ from: "carol@x.org" }, "").from, ["carol@x.org"], "a bare address is an address")
deepEqual(brain.features(null, null).body, [])
{
  const long = []
  for (let i = 0; i < 400; i++) long.push("word" + i.toString(26).replace(/[0-9]/g, d => "qrstuvwxyz"[Number(d)]))
  assert.strictEqual(brain.features({}, long.join(" ")).body.length, 300, "a body is read to its 300th word")
}

// ------------------------------------------------------------ learning and suggesting
const labels = [
  { id: "Receipts", name: "Receipts" },
  { id: "Travel", name: "Travel" },
  { id: "INBOX", name: "Inbox", system: true },
  { id: "Empty", name: "Empty" }]
let profile = brain.emptyProfile("imap:ada@example.com")
deepEqual(brain.suggest(profile, labels, "", summary, ""), [], "nothing learnt, nothing suggested")

const receipt = (n) => ({ from: { email: "bills@acme.com" }, to: [{ email: "ada@example.com" }], subject: "Invoice " + n })
const trip = (n) => ({ from: { email: "noreply@delta.com" }, to: [{ email: "ada@example.com" }], subject: "Your flight " + n })
for (let i = 0; i < 5; i++) profile = brain.learn(profile, "Receipts", "Receipts", receipt(i), "Invoice attached, total due", 1)
for (let i = 0; i < 5; i++) profile = brain.learn(profile, "Travel", "Travel", trip(i), "Boarding pass for your flight", 1)
profile = brain.learn(profile, "Travel", "Travel", { from: { email: "hotel@marriott.com" }, subject: "Reservation" }, "", 1)
assert.strictEqual(profile.docs, 11)
assert.strictEqual(profile.labels.Receipts.docs, 5)
assert.strictEqual(profile.labels.Receipts.bodies, 5)
assert.strictEqual(profile.labels.Travel.bodies, 5, "a message without a body is not a body")
assert.strictEqual(profile.labels.Receipts.from["bills@acme.com"], 5)
assert.strictEqual(profile.labels.Receipts.subject.invoice, 5)
assert.strictEqual(profile.labels.Receipts.body.invoice, 5)
assert.strictEqual(profile.labels.Receipts.domain["acme.com"], 5)

{
  const got = brain.suggest(profile, labels, "", { from: { email: "bills@acme.com" }, subject: "Invoice 99" }, "")
  assert.strictEqual(got[0].id, "Receipts", "the sender names the label")
  assert.strictEqual(got[0].name, "Receipts")
  assert.ok(got[0].because.indexOf("bills@acme.com") >= 0, "and says so: " + JSON.stringify(got[0].because))
  assert.ok(got.length <= 3)
  for (const row of got) assert.notStrictEqual(row.id, "INBOX", "a system label is never suggested")
  for (const row of got) assert.notStrictEqual(row.id, "Empty", "a label with no counts is never suggested")
}
{
  const got = brain.suggest(profile, labels, "", { from: { email: "someone@else.net" }, subject: "flight change" }, "boarding pass")
  assert.strictEqual(got[0].id, "Travel", "the words name the label when the sender is new")
  assert.ok(got[0].because.length > 0 && got[0].because[0].indexOf("“") === 0, "a word reason is quoted: " + got[0].because)
}
deepEqual(brain.suggest(profile, labels, "", { from: { email: "nobody@nowhere.io" }, subject: "zzz" }, ""), [],
  "no token ever seen under a label is no suggestion")
assert.strictEqual(brain.suggest(profile, labels, "Receipts", { from: { email: "bills@acme.com" }, subject: "Invoice" }, "")
  .map(r => r.id).indexOf("Receipts"), -1, "the label on screen is not a destination")
deepEqual(brain.suggest(profile, [{ id: "Gone", name: "Gone" }], "", receipt(1), ""), [],
  "only labels the account still has")
deepEqual(brain.suggest(profile, labels, "", receipt(1), "", 1).length, 1, "the limit holds")
deepEqual(brain.suggest(null, labels, "", receipt(1), ""), [])

// The sender outvotes a long body: each kind counts once whatever its
// length, so three hundred words that name Travel do not move a message
// bills@acme.com sent away from Receipts.
{
  const travelWords = []
  for (let i = 0; i < 300; i++) travelWords.push("flight boarding pass gate seat".split(" ")[i % 5] + " ")
  const got = brain.suggest(profile, labels, "", { from: { email: "bills@acme.com" }, subject: "" }, travelWords.join(" ").repeat(3))
  assert.strictEqual(got[0].id, "Receipts", "the sender names the label over a body full of another's words: " + JSON.stringify(got))
  // And a body of words no label has seen says nothing at all.
  const noise = []
  for (let i = 0; i < 300; i++) noise.push("zq" + i.toString(26).replace(/[0-9]/g, d => "qrstuvwxyz"[Number(d)]))
  const plain = brain.suggest(profile, labels, "", receipt(1), "")
  const noisy = brain.suggest(profile, labels, "", receipt(1), noise.join(" "))
  assert.strictEqual(noisy[0].id, plain[0].id)
  assert.ok(Math.abs(noisy[0].score - plain[0].score) < 1e-9, "unseen words do not change the score")
}

// One rare token cannot own a kind: a message full of Receipts' words with
// one word seen once under a label of one message is still a receipt, and
// so is one with a stray sender-less word and no sender at all.
{
  let p = brain.load(brain.serialize(profile))
  p = brain.learn(p, "Odd", "Odd", { from: { email: "once@odd.example" }, subject: "Odd one" }, "xyzzyonly plugh", 1)
  const withOdd = labels.concat([{ id: "Odd", name: "Odd" }])
  const got = brain.suggest(p, withOdd, "", { from: { email: "bills@acme.com" }, subject: "Invoice 7" }, "invoice attached total due xyzzyonly")
  assert.strictEqual(got[0].id, "Receipts", "the sender and the words outvote one rare word: " + JSON.stringify(got))
  const senderless = brain.suggest(p, withOdd, "", { from: { email: "nobody@nowhere.example" }, subject: "" }, "invoice attached total due xyzzyonly")
  assert.strictEqual(senderless[0].id, "Receipts", "four receipt words outvote one odd word: " + JSON.stringify(senderless))
  const odd = brain.suggest(p, withOdd, "", { from: { email: "once@odd.example" }, subject: "" }, "")
  assert.strictEqual(odd[0].id, "Odd", "and the rare sender alone still names its label")
}

// A lesson carries its tokens: learnt later, it teaches what was read then.
{
  let p = brain.emptyProfile("x")
  const feats = brain.features({ from: { email: "bills@acme.com" }, subject: "Invoice" }, "invoice attached")
  p = brain.learnFeatures(p, "Receipts", "Receipts", feats, 2)
  assert.strictEqual(p.labels.Receipts.from["bills@acme.com"], 2)
  assert.strictEqual(p.labels.Receipts.body.attached, 2)
  assert.strictEqual(p.labels.Receipts.bodies, 1)
  assert.strictEqual(brain.learnFeatures(p, "Receipts", "Receipts", null, 1), p, "no tokens, nothing learnt")
  assert.strictEqual(brain.learnFeatures(p, "Receipts", "Receipts", { from: "not a list" }, 1).labels.Receipts.docs, 2, "a malformed kind is skipped, not thrown")
}

// A word that names a property of every object is a word here, not a lookup.
{
  let p = brain.emptyProfile("x")
  p = brain.learn(p, "Receipts", "Receipts", { from: { email: "bills@acme.com" }, subject: "constructor prototype" }, "hasOwnProperty toString", 1)
  assert.strictEqual(p.labels.Receipts.subject.constructor, 1)
  assert.strictEqual(p.labels.Receipts.body.tostring, 1)
  const got = brain.suggest(p, labels, "", { from: { email: "other@else.net" }, subject: "constructor" }, "")
  assert.strictEqual(got.length, 1)
  assert.ok(isFinite(got[0].score), "a finite score: " + got[0].score)
  assert.deepEqual(brain.suggest(p, labels, "", { from: { email: "other@else.net" }, subject: "valueOf" }, ""), [],
    "a property name no label has seen is no evidence")
  const back = brain.load(brain.serialize(p))
  assert.strictEqual(back.labels.Receipts.subject.constructor, 1, "and it survives the file")
  assert.strictEqual(back.labels.Receipts.subject.valueOf, undefined, "with no prototype behind the counts")
}

// A choice the brain did not make counts double.
{
  let p = brain.emptyProfile("x")
  p = brain.learn(p, "Receipts", "Receipts", receipt(1), "", 2)
  assert.strictEqual(p.labels.Receipts.from["bills@acme.com"], 2)
  p = brain.learn(p, "Receipts", "", receipt(1), "", 0)
  assert.strictEqual(p.labels.Receipts.from["bills@acme.com"], 3, "a weight below one is one")
  assert.strictEqual(p.labels.Receipts.name, "Receipts", "an empty name does not unname the label")
  assert.strictEqual(brain.learn(p, "", "x", receipt(1), "", 1), p, "no label, nothing learnt")
}

// ------------------------------------------------------------ the file
{
  const text = brain.serialize(profile)
  const back = brain.load(text)
  assert.ok(back, "a profile reads back")
  assert.strictEqual(back.docs, 11)
  assert.strictEqual(back.accountId, "imap:ada@example.com")
  deepEqual(back.labels.Receipts.from, profile.labels.Receipts.from)
  assert.strictEqual(brain.load("nonsense"), null)
  assert.strictEqual(brain.load(JSON.stringify({ version: 99, labels: {} })), null, "a version this code does not read")
  assert.strictEqual(brain.load(JSON.stringify({ version: 1 })), null, "no labels is no profile")
  const dirty = brain.load(JSON.stringify({ version: 1, built: "x", labels: { A: { docs: -3, from: { a: "7", b: -1, c: 2.9 } }, "": { docs: 5 } } }))
  assert.strictEqual(dirty.built, 0)
  assert.strictEqual(dirty.labels.A.docs, 0, "a nonsense count is zero")
  deepEqual(dirty.labels.A.from, { a: 7, c: 2 }, "counts are whole and positive")
  assert.strictEqual(Object.keys(dirty.labels).length, 1, "a label with no id is dropped")
  assert.strictEqual(brain.load(JSON.stringify({ version: 1, labels: [] })), null, "an array of labels is not a map of them")
  assert.strictEqual(brain.builtMsOf(brain.load(JSON.stringify({ version: 1, built: 1700000000, builtMs: 1700000000123, labels: {} }))), 1700000000123, "the build's start, to the millisecond")
  assert.strictEqual(brain.builtMsOf(brain.load(JSON.stringify({ version: 1, built: 1700000000, labels: {} }))), 1700000000000, "or to the second from an older file")
  assert.strictEqual(brain.builtMsOf(null), 0)
  const big = { version: 1, labels: { A: { docs: 1, from: {} } } }
  for (let i = 0; i < 7000; i++) big.labels.A.from["a" + i] = i < 10 ? 9 : 1
  const bounded = brain.load(JSON.stringify(big))
  assert.strictEqual(Object.keys(bounded.labels.A.from).length, 5000, "a map is cut to its cap as it is read")
  assert.strictEqual(bounded.labels.A.from.a0, 9)
  const many = { version: 1, labels: {} }
  for (let i = 0; i < 1200; i++) many.labels["L" + i] = { docs: 1 }
  assert.strictEqual(Object.keys(brain.load(JSON.stringify(many)).labels).length, 1000, "and so is the number of labels")
}
{
  // A map past 6 000 tokens is cut back to the 5 000 most frequent.
  let p = brain.emptyProfile("x")
  const entry = { name: "Big", docs: 1, bodies: 0, from: {}, domain: {}, to: {}, subject: {}, body: {} }
  for (let i = 0; i < 6001; i++) entry.body["w" + i] = i < 100 ? 50 : 1
  p.labels.Big = entry
  const pruned = brain.load(brain.serialize(p))
  assert.strictEqual(Object.keys(pruned.labels.Big.body).length, 5000)
  assert.strictEqual(pruned.labels.Big.body.w0, 50, "the frequent ones stay")
  assert.strictEqual(brain.capCounts({ a: 1, b: 3, c: 2 }, 2).a, undefined)
}

// ------------------------------------------------------------ a rebuild is due
{
  let p = brain.load(brain.serialize(profile))
  p.built = 1700000000
  for (let i = 0; i < 24; i++) p = brain.noteDeparture(p)
  assert.strictEqual(brain.rebuildRecommended(p), false)
  p = brain.noteDeparture(p)
  assert.strictEqual(p.movedSince, 25)
  assert.strictEqual(brain.rebuildRecommended(p), true, "twenty-five messages moved out since the build")
  const status = brain.status(p)
  deepEqual(status, { built: 1700000000, docs: 11, labels: 2, bodies: 10, movedSince: 25, recommended: true })
  assert.strictEqual(brain.rebuildRecommended(brain.noteDeparture(brain.emptyProfile("x"))), false, "never built, nothing to rebuild")
  assert.strictEqual(brain.noteDeparture(null), null)
  deepEqual(brain.status(null), { built: 0, docs: 0, labels: 0, bodies: 0, movedSince: 0, recommended: false })
}

// ------------------------------------------------------------ the build's spec
{
  const spec = brain.buildSpec("imap:ada@example.com", "ada@example.com", "/tmp/out.json", [
    { id: "Receipts", name: "Receipts" },
    { id: "Label_9", name: "Work/Invoices", rawName: "Work/Invoices" },
    { id: "INBOX", name: "Inbox", system: true },
    { id: "", name: "nameless" }], { envelopes: 100, bodies: "7", chars: 0 })
  deepEqual(spec.labels, [
    { id: "Receipts", folder: "Receipts", name: "Receipts" },
    { id: "Label_9", folder: "Work/Invoices", name: "Work/Invoices" }])
  deepEqual(spec.sample, { envelopes: 100, bodies: 7, chars: 4000 }, "a cap of nothing is the default")
  assert.strictEqual(spec.out, "/tmp/out.json")
  assert.strictEqual(spec.account, "ada@example.com")
  deepEqual(brain.buildSpec("", "", "", null, null).labels, [])
}

console.log("test_label_brain.js ok")
