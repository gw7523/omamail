#!/usr/bin/env python3
"""Build a label profile for one mailbox: what has gone under each label.

    label-brain.py build            the spec is the job's message file
                                    ($OMAMAIL_MESSAGE_FILE) or stdin
    label-brain.py tokens           the tokens of the text on stdin, as JSON
    label-brain.py stopwords        the words the tokeniser drops, as JSON

The build reads every label the spec names through himalaya — the newest
`sample.envelopes` messages of each for their sender, recipients and subject,
and the newest `sample.bodies` of those for the words of their text — and
counts, per label, how often each address, domain, recipient and word was
seen. That file is what `account/LabelBrain.js` scores a message against when
the move-to picker opens, and what a choice made there is added to. Nothing
here is a model: it is counts, and the counting rule (`tokens`) is the same
one the window applies, which `tests/test_label_brain.js` holds it to.

The spec:

    { "accountId": "imap:ada@example.com", "account": "ada@example.com",
      "provider": "imap",
      "out": "/home/ada/.local/share/omamail/labels/account-imap_3aada_40example.com.json",
      "labels": [{ "id": "Receipts", "folder": "Receipts", "name": "Receipts" }],
      "sample": { "envelopes": 2000, "bodies": 150, "chars": 4000 },
      "himalayaAccount": "" }

Progress goes to stdout one line per label; the last line is the summary the
window shows. The file is written once, whole, at the end, mode 0600, and
only inside the labels directory; the journal of picker choices beside it
(`<out>.choices`) is removed, since the archive just read holds them. A label that cannot be listed keeps the
counts the previous file held for it, so one bad folder on a rebuild does
not forget a label.
"""

import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time

VERSION = 1
PAGE = 500
DEFAULT_SAMPLE = {"envelopes": 2000, "bodies": 150, "chars": 4000}
TOKEN_CAP = 5000
BODY_TOKENS = 300
CALL_TIMEOUT = 180

# Kept in step with STOP in account/LabelBrain.js: the test compares them.
STOPWORDS = """
about above after again against all also and any are aren because been before
being below between both but can cannot could couldn did didn does doesn doing
don down during each few for from further had hadn has hasn have haven having
her here hers herself him himself his how into isn its itself just let more
most mustn myself nor not now off once only other our ours ourselves out over
own same shan she should shouldn some such than that the their theirs them
themselves then there these they this those through too under until very was
wasn were weren what when where which while who whom why will with won would
wouldn you your yours yourself yourselves
one two three four five six seven eight nine ten first last next new
get got make made take took use used using see saw know
please thanks thank regards best dear hello hey sincerely
email mail message sent subject fwd forwarded reply
http https www com net org html htm mailto utm href amp nbsp
""".split()

STOP = set(STOPWORDS)
WORD = re.compile(r"[a-zà-öø-ÿ]+")


def tokens(text):
    out = []
    for word in WORD.findall(str(text or "").lower()):
        if len(word) < 3 or len(word) > 24 or word in STOP:
            continue
        out.append(word)
    return out


def unique(words):
    """Each word once, in the order it was first seen: the start of a
    message says more about it than its end, so the cut keeps the start."""
    seen = set()
    out = []
    for word in words:
        if word in seen:
            continue
        seen.add(word)
        out.append(word)
    return out


def address(value):
    if isinstance(value, dict):
        return str(value.get("email") or value.get("addr") or "").strip().lower()
    return str(value or "").strip().lower()


def addresses(value):
    if isinstance(value, list):
        return [a for a in (address(v) for v in value) if a != ""]
    one = address(value)
    return [one] if one != "" else []


def domain_of(addr):
    at = addr.rfind("@")
    return addr[at + 1:] if at >= 0 else ""


def strip_html(markup):
    text = re.sub(r"(?is)<(script|style)[^>]*>.*?</\1>", " ", str(markup or ""))
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    return html.unescape(text)


def bump(counts, key, weight=1):
    if key == "":
        return
    counts[key] = counts.get(key, 0) + weight


def empty_label(name):
    return {"name": name, "docs": 0, "bodies": 0,
            "from": {}, "domain": {}, "to": {}, "subject": {}, "body": {}}


def cap(counts, limit=TOKEN_CAP):
    if len(counts) <= limit:
        return counts
    kept = sorted(counts.items(), key=lambda item: (-item[1], item[0]))[:limit]
    return dict(kept)


def himalaya(args, account):
    command = ["himalaya", "--json", "-a", account] + args
    try:
        done = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                              errors="replace", timeout=CALL_TIMEOUT, stdin=subprocess.DEVNULL)
    except OSError as error:
        return None, "himalaya could not run: %s" % error
    except subprocess.TimeoutExpired:
        return None, "himalaya took longer than %d seconds" % CALL_TIMEOUT
    if done.returncode != 0:
        tail = (done.stderr or done.stdout or "").strip().splitlines()
        return None, (tail[-1] if tail else "himalaya exited with status %d" % done.returncode)
    try:
        return json.loads(done.stdout), ""
    except ValueError:
        return None, "himalaya did not answer with JSON"


def envelopes_of(folder, account, wanted):
    """The newest `wanted` envelopes of a folder, newest first: (rows, error,
    note). `error` is the folder failing outright; `note` is a later page
    failing, with what was read kept and the label told it is short."""
    out = []
    page = 1
    # Every page the same size: a page number means `(page - 1) * size`,
    # so a smaller last page would start in the middle of the one before.
    while len(out) < wanted:
        data, error = himalaya(["envelope", "list", "-m", folder, "-s", str(PAGE), "-p", str(page)], account)
        if data is None:
            if page == 1:
                return out, error, ""
            return out[:wanted], "", "short: page %d failed (%s)" % (page, error)
        rows = data.get("envelopes") if isinstance(data, dict) else data
        rows = [r for r in rows if isinstance(r, dict)] if isinstance(rows, list) else []
        if not rows:
            break
        out.extend(rows)
        if len(rows) < PAGE:
            break
        page += 1
    return out[:wanted], "", ""


def body_text(folder, message_id, account, chars):
    data, error = himalaya(["message", "read", "-m", folder, "--", str(message_id)], account)
    if not isinstance(data, dict):
        return "", error
    parts = data.get("parts") if isinstance(data.get("parts"), list) else []

    def part_text(index, key):
        if not isinstance(index, int) or index < 0 or index >= len(parts):
            return ""
        body = parts[index].get("body") if isinstance(parts[index], dict) else None
        value = body.get(key) if isinstance(body, dict) else None
        return value if isinstance(value, str) else ""

    text = " ".join(part_text(i, "Text") for i in (data.get("text_body") or []))
    if text.strip() == "":
        text = strip_html(" ".join(part_text(i, "Html") for i in (data.get("html_body") or [])))
    return text[:chars], ""


def himalaya_accounts_for(email, config_path=None):
    """The himalaya accounts whose `email` is the address, from its config."""
    wanted = str(email or "").strip().lower()
    if wanted == "":
        return []
    path = config_path or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"),
        "himalaya", "config.toml")
    try:
        import tomllib
        with open(path, "rb") as handle:
            config = tomllib.load(handle)
    except (OSError, ValueError, ImportError):
        return []
    accounts = config.get("accounts") if isinstance(config, dict) else None
    if not isinstance(accounts, dict):
        return []
    return [str(name) for name, entry in accounts.items()
            if isinstance(entry, dict) and str(entry.get("email") or "").strip().lower() == wanted]


def labels_dir():
    data_home = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(data_home, "omamail", "labels")


FILE_NAME = re.compile(r"^account-[A-Za-z0-9._-]+\.json$")


def out_path_ok(out):
    """Whether `out` is the labels directory itself, absolute and not
    reached through any link, plus a file name of the shape the window
    gives a profile. The window names it so; a spec that says otherwise is
    not obeyed."""
    if not os.path.isabs(out):
        return False
    normal = os.path.normpath(out)
    directory = os.path.dirname(normal)
    name = os.path.basename(normal)
    if not FILE_NAME.match(name):
        return False
    home = os.path.normpath(labels_dir())
    if directory != home:
        return False
    try:
        # Neither the directory, nor anything on the way to it, nor the file
        # may be a link: a link is somewhere else wearing this name.
        walk = home
        while walk not in ("", os.sep):
            if os.path.islink(walk):
                return False
            walk = os.path.dirname(walk)
        if os.path.islink(normal):
            return False
    except OSError:
        return False
    return True


def clean_counts(value):
    out = {}
    if not isinstance(value, dict):
        return out
    for key, raw in value.items():
        try:
            n = int(raw)
        except (TypeError, ValueError):
            continue
        if n > 0 and isinstance(key, str) and key != "":
            out[key] = min(n, 1000000000)
    return cap(out)


def clean_label(value, name):
    """A label's entry as the previous file held it, made whole: the same
    shape and bounds as a fresh one, whatever the file said."""
    entry = empty_label(name)
    if not isinstance(value, dict):
        return entry
    entry["name"] = str(value.get("name") or name)
    for key in ("docs", "bodies"):
        try:
            entry[key] = max(0, min(int(value.get(key) or 0), 1000000000))
        except (TypeError, ValueError):
            entry[key] = 0
    for key in ("from", "domain", "to", "subject", "body"):
        entry[key] = clean_counts(value.get(key))
    return entry


def previous_profile(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("version") != VERSION or not isinstance(data.get("labels"), dict):
        return None
    return data


def read_spec():
    source = os.environ.get("OMAMAIL_MESSAGE_FILE", "")
    try:
        if source:
            with open(source, "r", encoding="utf-8") as handle:
                raw = handle.read()
        else:
            raw = sys.stdin.read()
        spec = json.loads(raw)
    except (OSError, ValueError):
        return None
    return spec if isinstance(spec, dict) else None


def write_profile(path, profile):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".label-brain-", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(profile, handle, ensure_ascii=False, separators=(",", ":"))
        os.chmod(temp, 0o600)
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise


def command_build():
    os.umask(0o077)
    spec = read_spec()
    if spec is None:
        sys.stderr.write("label-brain.py build: expected a JSON spec\n")
        return 2
    out = str(spec.get("out") or "").strip()
    email = str(spec.get("account") or "").strip()
    account_id = str(spec.get("accountId") or "").strip()
    provider = str(spec.get("provider") or "").strip().lower()
    labels = [l for l in (spec.get("labels") or []) if isinstance(l, dict)]
    if out == "" or account_id == "" or not labels:
        sys.stderr.write("label-brain.py build: out, accountId and labels are required\n")
        return 2
    if not out_path_ok(out):
        sys.stderr.write("label-brain.py build: out must be a file inside %s\n" % labels_dir())
        return 2
    if provider == "hey":
        sys.stderr.write("A HEY mailbox has no folders himalaya can open\n")
        return 1
    sample = dict(DEFAULT_SAMPLE)
    given = spec.get("sample") if isinstance(spec.get("sample"), dict) else {}
    for key in sample:
        try:
            sample[key] = max(0, int(given.get(key, sample[key])))
        except (TypeError, ValueError):
            pass
    account = str(spec.get("himalayaAccount") or "").strip()
    if account == "":
        candidates = himalaya_accounts_for(email)
        if len(candidates) > 1:
            sys.stderr.write("Several himalaya accounts have the address %s (%s); name one as himalayaAccount\n"
                             % (email, ", ".join(candidates)))
            return 1
        account = candidates[0] if candidates else ""
    if account == "":
        sys.stderr.write("himalaya has no account whose email is %s; name one as himalayaAccount\n" % (email or "(unset)"))
        return 1
    print("Reading %d labels of %s through himalaya account %s" % (len(labels), email, account), flush=True)

    # What the last build (and the choices since) knew: a label that cannot
    # be listed today keeps its counts from there rather than vanishing.
    previous = previous_profile(out)
    kept_from_before = previous["labels"] if previous is not None else {}
    # When the build began, to the second for the page and to the millisecond
    # for the journal's watermark: a choice from before this moved a message
    # into the archive read below.
    started = time.time()
    profile = {"version": VERSION, "built": int(started), "builtMs": int(started * 1000), "accountId": account_id,
               "account": email, "docs": 0, "movedSince": 0, "sample": sample, "labels": {}}
    failed = 0
    kept = 0
    done = set()
    for index, label in enumerate(labels, start=1):
        label_id = str(label.get("id") or "").strip()
        folder = str(label.get("folder") or label.get("name") or label_id).strip()
        name = str(label.get("name") or folder).strip()
        if label_id == "" or folder == "" or label_id in done:
            continue
        done.add(label_id)
        entry = empty_label(name)
        rows, error, note = envelopes_of(folder, account, sample["envelopes"])
        if error:
            failed += 1
            before = kept_from_before.get(label_id)
            if isinstance(before, dict):
                kept += 1
                before = clean_label(before, name)
                profile["labels"][label_id] = before
                profile["docs"] += before["docs"]
                print("Label %d/%d %s: could not be listed (%s); kept the counts from before"
                      % (index, len(labels), name, error), flush=True)
            else:
                print("Label %d/%d %s: skipped (%s)" % (index, len(labels), name, error), flush=True)
            continue
        for row in rows:
            senders = addresses(row.get("from"))
            sender = senders[0] if senders else ""
            bump(entry["from"], sender)
            bump(entry["domain"], domain_of(sender))
            for recipient in addresses(row.get("to")):
                bump(entry["to"], recipient)
            for word in unique(tokens(row.get("subject"))):
                bump(entry["subject"], word)
            entry["docs"] += 1
        bodies = 0
        for row in rows[:sample["bodies"]]:
            text, error = body_text(folder, row.get("id"), account, sample["chars"])
            if text.strip() == "":
                continue
            bodies += 1
            for word in unique(tokens(text))[:BODY_TOKENS]:
                bump(entry["body"], word)
        entry["bodies"] = bodies
        for key in ("from", "domain", "to", "subject", "body"):
            entry[key] = cap(entry[key])
        profile["labels"][label_id] = entry
        profile["docs"] += entry["docs"]
        print("Label %d/%d %s: %d messages, %d bodies%s"
              % (index, len(labels), name, entry["docs"], bodies, (" (" + note + ")") if note else ""), flush=True)

    if not profile["labels"]:
        sys.stderr.write("No label could be read\n")
        return 1
    try:
        write_profile(out, profile)
    except OSError as error:
        sys.stderr.write("Could not write %s: %s\n" % (out, error))
        return 1
    # The choices made in the picker since the last build moved messages
    # into the folders this build has just read: folded in, so their journal
    # goes. The window does not write while a build runs; a line that lands
    # regardless is dated, and the window reads only the ones after `builtMs`.
    try:
        os.unlink(out + ".choices")
    except FileNotFoundError:
        pass
    except OSError as error:
        # A journal left behind would be counted on top of the archive that
        # holds it: the build is not done until it is gone.
        sys.stderr.write("Could not remove the journal %s.choices: %s\n" % (out, error))
        return 1
    skipped = ""
    if failed:
        skipped = ", %d kept from before" % kept if kept == failed else (
            ", %d skipped" % failed if kept == 0 else ", %d kept from before, %d skipped" % (kept, failed - kept))
    print("Built %d labels from %d messages%s" % (len(profile["labels"]), profile["docs"], skipped), flush=True)
    return 0


def main(argv):
    verb = argv[1] if len(argv) > 1 else ""
    if verb == "build":
        return command_build()
    if verb == "tokens":
        sys.stdout.write(json.dumps(tokens(sys.stdin.read())) + "\n")
        return 0
    if verb == "stopwords":
        sys.stdout.write(json.dumps(sorted(STOP)) + "\n")
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
