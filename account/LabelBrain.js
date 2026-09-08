.pragma library

// What the mailbox already holds under each label, and which labels a
// message therefore looks like: the counts `scripts/label-brain.py` builds
// from the archive, read back here and scored against the message in the
// picker. Nothing in it is a model. Per label there is a count of every
// sender, sender domain, recipient, subject word and body word seen under
// it; a message's own senders and words are looked up in each label's
// counts and the labels are ranked by how much likelier each makes the
// message than the mailbox as a whole does — a naive Bayes over five kinds
// of token, read as lift, which is what mail filters have been since the
// nineties, because who sent a message and what list it came from settle
// most of where it goes. Each kind counts once whatever its length, so a
// long body cannot outvote the sender, and a word no label has ever seen
// says nothing about any of them.
//
// The tokeniser is the one rule the two sides must share, and
// `tests/test_label_brain.js` runs the Python one over the same strings.

var VERSION = 1
var TOKEN_CAP = 5000
var TOKEN_PRUNE_AT = 6000
var BODY_TOKENS = 300
var ALPHA = 0.5
// How far one token may move a kind's mean, either way: a sender seen once
// under a label of one message is strong evidence, not the only evidence.
var LIFT_CAP = 3
var SUGGESTIONS = 3
var REBUILD_AFTER = 25
var MAX_LABELS = 1000
var FEATURES = ["from", "domain", "to", "subject", "body"]
var WEIGHTS = { from: 3, domain: 2, to: 1, subject: 1.5, body: 1 }

// Count maps carry no prototype: a subject that says "constructor" must
// look up nothing but its own count.
function counts() { return Object.create(null) }
function has(map, key) { return !!map && Object.prototype.hasOwnProperty.call(map, key) }
function countOf(map, key) { return has(map, key) ? map[key] : 0 }

// Kept in step with STOPWORDS in scripts/label-brain.py: the test compares them.
var STOPWORDS = ("about above after again against all also and any are aren because been before "
  + "being below between both but can cannot could couldn did didn does doesn doing "
  + "don down during each few for from further had hadn has hasn have haven having "
  + "her here hers herself him himself his how into isn its itself just let more "
  + "most mustn myself nor not now off once only other our ours ourselves out over "
  + "own same shan she should shouldn some such than that the their theirs them "
  + "themselves then there these they this those through too under until very was "
  + "wasn were weren what when where which while who whom why will with won would "
  + "wouldn you your yours yourself yourselves "
  + "one two three four five six seven eight nine ten first last next new "
  + "get got make made take took use used using see saw know "
  + "please thanks thank regards best dear hello hey sincerely "
  + "email mail message sent subject fwd forwarded reply "
  + "http https www com net org html htm mailto utm href amp nbsp").split(" ")
var STOP = {}
for (var s = 0; s < STOPWORDS.length; s++) STOP[STOPWORDS[s]] = true

var WORD = /[a-zà-öø-ÿ]+/g

function tokens(text) {
  var words = String(text || "").toLowerCase().match(WORD) || []
  var out = []
  for (var i = 0; i < words.length; i++) {
    var word = words[i]
    if (word.length < 3 || word.length > 24 || STOP[word] === true) continue
    out.push(word)
  }
  return out
}

// Each word once, in the order first seen: the start of a message says more
// about it than its end, so the cut keeps the start.
function unique(words) {
  var seen = {}
  var out = []
  for (var i = 0; i < words.length; i++) {
    if (seen[words[i]] === true) continue
    seen[words[i]] = true
    out.push(words[i])
  }
  return out
}

function addressOf(value) {
  if (value && typeof value === "object") return String(value.email || value.addr || "").trim().toLowerCase()
  return String(value || "").trim().toLowerCase()
}

function addressesOf(value) {
  var list = Array.isArray(value) ? value : (value ? [value] : [])
  var out = []
  for (var i = 0; i < list.length; i++) {
    var one = addressOf(list[i])
    if (one !== "") out.push(one)
  }
  return out
}

function domainOf(address) {
  var at = String(address || "").lastIndexOf("@")
  return at >= 0 ? String(address).slice(at + 1) : ""
}

// The five kinds of token a message carries, from its summary and its text.
function features(summary, bodyText) {
  var row = summary || {}
  var sender = addressOf(row.from)
  var domain = domainOf(sender)
  return {
    from: sender !== "" ? [sender] : [],
    domain: domain !== "" ? [domain] : [],
    to: unique(addressesOf(row.to).concat(addressesOf(row.cc))),
    subject: unique(tokens(row.subject)),
    body: unique(tokens(bodyText)).slice(0, BODY_TOKENS)
  }
}

function emptyProfile(accountId) {
  return { version: VERSION, built: 0, builtMs: 0, accountId: String(accountId || ""), account: "",
    docs: 0, movedSince: 0, sample: null, labels: {} }
}

// When the build began, in milliseconds: a choice from before it moved a
// message into the archive the build read, and is not to be counted twice.
// An older file says only the second.
function builtMsOf(profile) {
  if (!profile) return 0
  var ms = count(profile.builtMs)
  return ms > 0 ? ms : count(profile.built) * 1000
}

function count(value) {
  var n = Math.floor(Number(value))
  return isFinite(n) && n > 0 ? n : 0
}

function emptyEntry(name) {
  return { name: String(name || ""), docs: 0, bodies: 0,
    from: counts(), domain: counts(), to: counts(), subject: counts(), body: counts() }
}

// The counts of a map as read from a file: whole, positive, its own keys
// only, and no more of them than a map is allowed to hold.
function cleanCounts(value) {
  var out = counts()
  if (!value || typeof value !== "object" || Array.isArray(value)) return out
  var keys = Object.keys(value)
  for (var i = 0; i < keys.length; i++) {
    var n = count(value[keys[i]])
    if (n > 0) out[keys[i]] = n
  }
  return keys.length > TOKEN_CAP ? capCounts(out, TOKEN_CAP) : out
}

// A profile from the file's text, or null for anything that is not one: a
// version this code does not read, a shape it does not know.
function load(text) {
  var parsed = null
  try { parsed = JSON.parse(String(text || "")) } catch (e) { parsed = null }
  if (!parsed || typeof parsed !== "object" || parsed.version !== VERSION) return null
  if (!parsed.labels || typeof parsed.labels !== "object" || Array.isArray(parsed.labels)) return null
  var profile = emptyProfile(parsed.accountId)
  profile.account = String(parsed.account || "")
  profile.built = count(parsed.built)
  profile.builtMs = count(parsed.builtMs)
  profile.movedSince = count(parsed.movedSince)
  profile.sample = parsed.sample && typeof parsed.sample === "object" ? parsed.sample : null
  var docs = 0
  var ids = Object.keys(parsed.labels).slice(0, MAX_LABELS)
  for (var i = 0; i < ids.length; i++) {
    var id = ids[i]
    var raw = parsed.labels[id]
    if (!raw || typeof raw !== "object" || String(id) === "") continue
    var entry = emptyEntry(raw.name)
    entry.docs = count(raw.docs)
    entry.bodies = count(raw.bodies)
    for (var f = 0; f < FEATURES.length; f++) entry[FEATURES[f]] = cleanCounts(raw[FEATURES[f]])
    profile.labels[id] = entry
    docs += entry.docs
  }
  profile.docs = docs
  return profile
}

function serialize(profile) {
  return JSON.stringify(prune(profile))
}

// The `limit` most frequent counts, ties by key, so a map cannot grow
// without bound as choices are added.
function capCounts(map, limit) {
  var keys = Object.keys(map || {})
  if (keys.length <= limit) return map
  keys.sort(function(a, b) { return map[b] - map[a] || (a < b ? -1 : a > b ? 1 : 0) })
  var out = counts()
  for (var i = 0; i < limit; i++) out[keys[i]] = map[keys[i]]
  return out
}

function prune(profile) {
  if (!profile || !profile.labels) return profile
  for (var id in profile.labels) {
    var entry = profile.labels[id]
    for (var f = 0; f < FEATURES.length; f++) {
      var kind = FEATURES[f]
      if (Object.keys(entry[kind] || {}).length > TOKEN_PRUNE_AT) entry[kind] = capCounts(entry[kind], TOKEN_CAP)
    }
  }
  return profile
}

function totalsOf(entry) {
  var out = {}
  for (var f = 0; f < FEATURES.length; f++) {
    var kind = FEATURES[f]
    var sum = 0
    for (var key in entry[kind]) sum += entry[kind][key]
    out[kind] = sum
  }
  return out
}

// Every label's counts folded together, per kind: the vocabulary each kind
// has, and how common each token is across the whole mailbox — what a
// label's own count is compared against to say why it was suggested.
function backgroundOf(profile) {
  var seen = {}
  var totals = {}
  var f
  for (f = 0; f < FEATURES.length; f++) { seen[FEATURES[f]] = counts(); totals[FEATURES[f]] = 0 }
  for (var id in profile.labels) {
    var entry = profile.labels[id]
    for (f = 0; f < FEATURES.length; f++) {
      var kind = FEATURES[f]
      for (var key in entry[kind]) {
        seen[kind][key] = countOf(seen[kind], key) + entry[kind][key]
        totals[kind] += entry[kind][key]
      }
    }
  }
  var sizes = {}
  for (f = 0; f < FEATURES.length; f++) sizes[FEATURES[f]] = Object.keys(seen[FEATURES[f]]).length
  return { counts: seen, totals: totals, sizes: sizes }
}

function reasonText(kind, token) {
  if (kind === "from") return token
  if (kind === "domain") return "@" + token
  if (kind === "to") return "to " + token
  return "“" + token + "”"
}

// The labels the message most looks like, best first, at most `limit`:
// only labels the account still has (`labels`, less the one on screen and
// the system ones), and only where at least one of the message's tokens
// has been seen under the label — a label with no evidence for it is not
// suggested however few messages it holds. Each carries the two tokens
// that told most, in words the picker can show.
//
// The score is the label's prior plus, per kind of token, the mean lift
// the message's tokens of that kind give the label — how much likelier
// the token is under the label than across the mailbox, each capped so
// one rare token cannot own the kind — weighted by kind. Only tokens some
// label has seen count: one seen nowhere would score by the labels' sizes
// alone. A token seen elsewhere but not here counts against, as it should.
function suggest(profile, labels, currentLabelId, summary, bodyText, limit) {
  if (!profile || !profile.labels) return []
  var allowed = {}
  var list = Array.isArray(labels) ? labels : []
  var current = String(currentLabelId || "")
  var candidates = 0
  for (var i = 0; i < list.length; i++) {
    var label = list[i]
    if (!label || label.system === true) continue
    var id = String(label.id || "")
    if (id === "" || id === current || !profile.labels[id]) continue
    allowed[id] = label
    candidates++
  }
  if (candidates === 0) return []
  var feats = features(summary, bodyText)
  var background = backgroundOf(profile)
  var labelCount = Object.keys(profile.labels).length
  var docsAll = Math.max(profile.docs, 1)
  var out = []
  for (var candidate in allowed) {
    var entry = profile.labels[candidate]
    var totals = totalsOf(entry)
    var score = Math.log((entry.docs + 1) / (docsAll + labelCount))
    var matched = 0
    var reasons = []
    for (var f = 0; f < FEATURES.length; f++) {
      var kind = FEATURES[f]
      var size = background.sizes[kind]
      if (size === 0) continue
      var own = entry[kind]
      var denominator = totals[kind] + ALPHA * size
      var allDenominator = background.totals[kind] + ALPHA * size
      var lift = 0
      var informative = 0
      for (var t = 0; t < feats[kind].length; t++) {
        var token = feats[kind][t]
        var everywhere = countOf(background.counts[kind], token)
        if (everywhere === 0) continue
        var c = countOf(own, token)
        var p = (c + ALPHA) / denominator
        var q = (everywhere + ALPHA) / allDenominator
        lift += Math.max(-LIFT_CAP, Math.min(LIFT_CAP, Math.log(p / q)))
        informative++
        if (c === 0) continue
        matched++
        reasons.push({ ratio: p / q, text: reasonText(kind, token) })
      }
      if (informative > 0) score += WEIGHTS[kind] * lift / informative
    }
    if (matched === 0) continue
    reasons.sort(function(a, b) { return b.ratio - a.ratio })
    var because = []
    for (var r = 0; r < reasons.length && because.length < 2; r++) {
      if (reasons[r].ratio > 1 && because.indexOf(reasons[r].text) < 0) because.push(reasons[r].text)
    }
    out.push({ id: candidate, name: String(allowed[candidate].name || entry.name || candidate),
      score: score, because: because })
  }
  out.sort(function(a, b) { return b.score - a.score || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0) })
  return out.slice(0, Math.max(1, Math.floor(Number(limit)) || SUGGESTIONS))
}

// A choice made in the picker: the message's tokens are added to the label
// chosen, `weight` times over. A label the brain did not suggest is the
// stronger signal — it was wrong, or knew nothing — so the caller doubles it.
function learn(profile, labelId, labelName, summary, bodyText, weight) {
  return learnFeatures(profile, labelId, labelName, features(summary, bodyText), weight)
}

// The same, from tokens read earlier: a lesson taken before a move and
// learnt after it carries its tokens, not a row the list may have changed.
function learnFeatures(profile, labelId, labelName, feats, weight) {
  var id = String(labelId || "")
  if (id === "" || !feats || typeof feats !== "object") return profile
  var target = profile || emptyProfile("")
  if (!target.labels) target.labels = {}
  var entry = target.labels[id]
  if (!entry) {
    entry = emptyEntry(labelName)
    target.labels[id] = entry
  } else if (String(labelName || "") !== "") {
    entry.name = String(labelName)
  }
  var w = Math.max(1, Math.floor(Number(weight)) || 1)
  for (var f = 0; f < FEATURES.length; f++) {
    var kind = FEATURES[f]
    var list = Array.isArray(feats[kind]) ? feats[kind] : []
    for (var t = 0; t < list.length; t++) {
      var token = String(list[t])
      entry[kind][token] = countOf(entry[kind], token) + w
    }
    if (Object.keys(entry[kind]).length > TOKEN_PRUNE_AT) entry[kind] = capCounts(entry[kind], TOKEN_CAP)
  }
  entry.docs += 1
  if (Array.isArray(feats.body) && feats.body.length > 0) entry.bodies += 1
  target.docs = count(target.docs) + 1
  return target
}

// A message taken out of a label is not taken out of the counts — the
// build is what corrects them — but it is counted, and past a point the
// settings say a rebuild is due.
function noteDeparture(profile) {
  if (!profile) return profile
  profile.movedSince = count(profile.movedSince) + 1
  return profile
}

function rebuildRecommended(profile) {
  return !!profile && count(profile.built) > 0 && count(profile.movedSince) >= REBUILD_AFTER
}

// What the settings page says about a profile.
function status(profile) {
  if (!profile) return { built: 0, docs: 0, labels: 0, bodies: 0, movedSince: 0, recommended: false }
  var labels = 0
  var bodies = 0
  for (var id in profile.labels) {
    labels++
    bodies += count(profile.labels[id].bodies)
  }
  return { built: count(profile.built), docs: count(profile.docs), labels: labels, bodies: bodies,
    movedSince: count(profile.movedSince), recommended: rebuildRecommended(profile) }
}

// What the build job is handed: every label the account files under, with
// the folder himalaya opens it by, and the caps.
function buildSpec(accountId, email, outPath, labels, sample) {
  var list = Array.isArray(labels) ? labels : []
  var rows = []
  for (var i = 0; i < list.length; i++) {
    var label = list[i]
    if (!label || label.system === true) continue
    var id = String(label.id || "")
    if (id === "") continue
    rows.push({ id: id, folder: String(label.rawName || label.name || id), name: String(label.name || id) })
  }
  var caps = { envelopes: 2000, bodies: 150, chars: 4000 }
  if (sample && typeof sample === "object") {
    for (var key in caps) if (count(sample[key]) > 0) caps[key] = count(sample[key])
  }
  return { accountId: String(accountId || ""), account: String(email || ""), out: String(outPath || ""),
    labels: rows, sample: caps }
}
