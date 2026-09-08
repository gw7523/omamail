# Suggested labels

What the move-to picker leads with, where it comes from, and what it is not.

## What it is

Per label, counts: how often each sender address, sender domain, recipient,
subject word and body word has been seen under it, and how many messages
that was. When the picker opens on a message, its own addresses and words are
looked up in every label's counts and the labels are ranked by how much
likelier each makes the message than the mailbox as a whole does — a
multinomial naive Bayes over five kinds of token, read as lift. Each kind
counts once whatever its length (the mean lift of its tokens, each capped so
one rare token cannot own the kind), weighted so that who sent a message
counts for more than a word in it and a long body cannot outvote the sender;
a word no label has ever seen says nothing about any of them, and one seen
elsewhere but not here counts against. The top
three with any evidence at all are the suggestions; a label none of the
message's tokens has ever been seen under is not offered however small it
is. Each suggestion carries the two tokens that told most, which is what
the picker prints under it. The count maps carry no prototype, so a subject
that says "constructor" is a word and not a lookup.

`account/LabelBrain.js` holds the rule set: the tokeniser, the features, the
scoring, learning, the file's shape. `account/LabelBrain.qml` holds the
files, one profile per account under `$XDG_DATA_HOME/omamail/labels/`, named
as the cache names its own so the name cannot leave the directory, and a
journal of choices beside it (`….json.choices`). `scripts/label-brain.py`
builds the profile.

## Where the counts come from

Two places, and both add to the same file.

**The build.** Settings → Mailboxes → **Build now**. A job of the agent
runner's — `scripts/agent-job.py` with `labels: true`, kind `labels`, a
transient systemd user unit like an ask — whose command is
`scripts/label-brain.py build` and whose spec (which labels, which folders
himalaya opens them by, the caps, where to write) is the job's message file.
The script finds the himalaya account whose `email` is the mailbox's address
in himalaya's own config, lists the newest 2000 envelopes of each label
(`envelope list`, 500 a page), reads the newest 150 of those for their text
(`message read --json`, text parts first, HTML stripped of tags when that is
all there is, the first 4000 characters), and writes the file once, whole,
mode 0600, in a directory it made 0700 — and only there: the name must be
absolute, of the shape the window gives a profile (`account-….json`), in
that directory itself, and neither the file nor any directory on the way
to it may be a link. Every
page is the same size, so a cap that is not a multiple of 500 still reads
the newest `cap` and no page starts inside another; a later page failing
keeps what was read and says the label is short. A label that cannot be
listed keeps the counts the previous file held for it — the choices made
since ride along in that entry, read back in the shape a fresh one has,
whatever the file said — so one bad folder on a rebuild does not forget a
label; every label failing is a failure and writes nothing. Two
himalaya accounts with the mailbox's address is a question, not a guess,
and a HEY mailbox has no folders himalaya opens. Progress is one line per
label on the job's output, which the settings page shows while it runs; the
last line is the summary. No agent, no model, no network beyond himalaya's
own.

**Choices.** A label chosen in the picker for one message adds that
message's tokens to the label, twice over when the label was not among the
suggestions — the brain was wrong or knew nothing, and that is the stronger
lesson. What there is to learn is read before the move, while the row is
still listed — its tokens, not the row — and learnt after it, once the move
has been sent: a refused move teaches nothing. A ticked batch teaches
nothing at all: it was offered no suggestions, and one label for many
messages is a filing, not a lesson.

The window never rewrites the profile. Each choice is one line appended to
the journal beside it, by one command that makes the directory 0700 and
appends the line, 0600 if the file is new — and each message that leaves
its label is a line too. The commands run one at a time in the order they
were asked for, each carrying the paths it is for, so an account switch
cannot misfile one; Forget removes the profile and its journal after the
append in hand and drops the ones waiting; a read of the files waits for
the queue to drain and the queue for the read, so neither sees half of the
other; a command that does not finish in ten seconds is told to stop, and
one that never started is let go. Reading is the profile's counts plus the
journal's lines newer than the build; the build reads the archive those
choices moved messages into, and removes the journal it has folded in.
Nothing is written while a build runs. A profile that was never built still
learns from choices, and the settings page says that is all it knows.

## What it does not do

- It does not unlearn. A message moved out of a label stays in the counts;
  the move is counted instead — one per message, a batch counting each of
  its rows still listed; a move elsewhere, trash, delete, and on a provider
  that files by folder archive and spam; none while a build runs, since a
  build starts the count again — and at twenty-five since the build the
  settings page recommends a rebuild. The build is what corrects the
  counts.
- It does not file anything. Suggestions sit at the top of the picker and
  are taken by Return or a click like any row; the tree is still there
  under them, and typing keeps a suggestion only while the letters name it.
- It does not read a merged list, or suggest for a ticked batch: a
  suggestion is about one message on one account.
- It does not send anything anywhere. The setting's text says what is read
  and where it is kept, and **Forget** deletes the file.

## Why counts and not a model

Mail routing is overwhelmingly decided by who sent a message, what list it
came from and a handful of subject words. That is exactly what per-label
token counts capture, it is what every classic mail classifier did, and it
satisfies every constraint here: offline, local, incremental, rebuildable,
explainable, and cheap enough to score a message the moment the picker opens
— thirty labels by five thousand tokens is nothing. An embedding or an LLM
could be blended in later as a second signal without changing the file or
the picker; nothing in the first slice needs one.

## Tests

`tests/test_label_brain.js` — the tokeniser (and that the Python one agrees on
the same strings and the same stop list), features, scoring, learning, the
file's shape, pruning, the rebuild rule, the spec. `tests/test_label_brain.sh`
— the build against a himalaya that is a shell script. `tests/test_agent_job.sh`
— the `labels` kind. `tests/test_model.js` — the picker's rows.
`tests/qml/tst_label_suggestions.qml` — the picker with suggestions and the
file-holding object. `tests/qml/tst_move_to_label.qml` — the picker in the
window with the setting on.
