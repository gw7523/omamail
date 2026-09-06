.pragma library

.import "ImapProtocol.js" as Protocol

// What an IMAP mailbox is, as far as the panel is concerned.
//
// The protocol itself is `ImapProtocol.js` and the transport is
// `ImapClient.qml`. This file answers the same four questions `Registry.js`
// asks of every provider, and the answers differ from Gmail's in ways the
// panel has to respect rather than paper over.

var ID = "imap"
var NAME = "IMAP"
var SUMMARY = "Any standard mailbox — Fastmail, iCloud, Outlook, Zoho, your own server."
var AUTH = "password"

var CAPABILITIES = {
  // No labels: a message is in one folder. The reader hides the label strip
  // rather than showing an empty one.
  labels: false,
  // One folder per message is what makes a move the plain thing to do here:
  // `labels: false` is about the strip the reader draws, not about whether a
  // message can be put somewhere else.
  move: true,
  manageLabels: true,
  // No server-side conversation id. Threading falls back to References, which
  // is what every other IMAP client does.
  threads: false,
  // Only if the server has somewhere to put it, which the client decides per
  // account from what LIST reported; this is the ceiling, not the guarantee.
  archive: true,
  // Deliberately off. IMAP can move a message to a Junk folder, but that
  // teaches the server nothing, and a "Report spam" button that quietly means
  // "move to a folder" is a promise the provider cannot keep.
  spam: false,
  star: true,
  batch: true,
  search: true,
  send: true,
  // No web UI this plugin could know the address of.
  web: false
}

// Folders, not queries. The `folder:` DSL is read by `ImapProtocol.parseQuery`
// and by nothing else — everywhere above, these strings are opaque, handed
// back to the client that produced them and used as a cache key.
//
// The names here are fallbacks. A server that advertises SPECIAL-USE (RFC 6154)
// names its own Sent, Trash and Archive, and `ImapProtocol.resolveFolder`
// replaces the placeholder with whatever the server actually said.
var MAILBOXES = [
  { key: "inbox", label: "Inbox", icon: "inbox", query: "folder:INBOX" },
  { key: "unread", label: "Unread", icon: "unread", query: "folder:INBOX UNSEEN" },
  { key: "starred", label: "Flagged", icon: "star", query: "folder:INBOX FLAGGED" },
  { key: "sent", label: "Sent", icon: "sent", query: "folder:\\Sent" },
  { key: "drafts", label: "Drafts", icon: "compose", query: "folder:\\Drafts" },
  { key: "archive", label: "Archive", icon: "archive", query: "folder:\\Archive", optional: true },
  { key: "spam", label: "Junk", icon: "spam", query: "folder:\\Junk", optional: true },
  { key: "trash", label: "Trash", icon: "trash", query: "folder:\\Trash", optional: true }
]

// IMAP SEARCH has no free-text operator that means what a user means by typing
// words into a search box, so plain words become a TEXT criterion — headers and
// body, the closest standard equivalent. The three operators people bring from
// webmail, from: to: and subject:, become the IMAP criteria of the same name;
// a space after the colon is allowed because that is how they get typed. IMAP
// matches a criterion as a substring, so a `*` wildcard is dropped rather than
// searched for. JSON.stringify is used for the quoting because it escapes
// exactly the two characters IMAP escapes.
function searchQuery(text) {
  var value = String(text === undefined || text === null ? "" : text).trim()
  if (value === "") return ""
  var tokens = value.split(/\s+/)
  var words = []
  var parts = []
  for (var i = 0; i < tokens.length; i++) {
    var match = tokens[i].match(/^(from|to|subject):(.*)$/i)
    if (!match) {
      words.push(tokens[i])
      continue
    }
    var term = match[2]
    if (term === "" && i + 1 < tokens.length) term = tokens[++i]
    term = term.replace(/\*/g, "")
    if (term !== "") parts.push(match[1].toUpperCase() + " " + JSON.stringify(term))
  }
  if (words.length > 0) parts.push("TEXT " + JSON.stringify(words.join(" ")))
  return parts.length === 0 ? "" : "folder:INBOX " + parts.join(" ")
}

// Standard IMAP SEARCH has one selected folder. A typed search selects INBOX,
// so a cached Sent, Trash or user-folder row cannot be an early result however
// well its subject happens to match.
function cachedSummaryInSearch(sourceQuery, summary) {
  return Protocol.parseQuery(sourceQuery).folder.toUpperCase() === "INBOX"
}

// Selecting a folder in the sidebar. This cannot go through `searchQuery`: a
// folder wrapped in a TEXT search would look for the folder's own name inside
// the inbox rather than opening it.
// Mail from, or to, one address, in the inbox: IMAP's FROM and TO criteria
// match the header as a substring, which is what an address search wants.
function addressQuery(field, address) {
  var value = String(address === undefined || address === null ? "" : address).trim()
  if (value === "") return ""
  return "folder:INBOX " + (field === "to" ? "TO " : "FROM ") + JSON.stringify(value)
}

function labelQuery(name) {
  var value = String(name === undefined || name === null ? "" : name).trim()
  return value === "" ? "" : "folder:" + JSON.stringify(value)
}
