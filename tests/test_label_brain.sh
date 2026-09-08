#!/usr/bin/env bash
# The label build, driven against a himalaya that is a shell script: the
# spec names the labels, the newest envelopes of each are listed page by
# page, the newest few are read for their words, and one file comes out with
# the counts — private, whole, and summarised on the last line. Nothing here
# touches a real mailbox.
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/omamail-label-brain-test.XXXXXX)
trap 'rm -rf "$work"' EXIT
script="$project_dir/scripts/label-brain.py"

fail() { echo "test_label_brain.sh: $1" >&2; exit 1; }

mkdir -p "$work/bin"
cat > "$work/bin/himalaya" <<'EOF'
#!/usr/bin/env bash
# himalaya --json -a ACCOUNT envelope list -m FOLDER -s N -p P
# himalaya --json -a ACCOUNT message read -m FOLDER ID
echo "$*" >> "$FAKE_LOG"
[ "$1" = "--json" ] || { echo "no --json" >&2; exit 9; }
[ "$3" = "test" ] || { echo "unknown account $3" >&2; exit 9; }
verb="$4 $5"; folder="$7"
if [ "$verb" = "envelope list" ]; then
  page="${11}"
  case "$folder" in
    Broken) echo "error: no such mailbox" >&2; exit 1;;
    # Twelve hundred envelopes, paged by the size and page asked for.
    Big)
      size="$9"; start=$(( (page - 1) * size + 1 )); end=$(( page * size )); [ "$end" -gt 1200 ] && end=1200
      rows=""; i=$start
      while [ "$i" -le "$end" ]; do rows="$rows,{\"id\":\"$i\",\"from\":[{\"email\":\"big$i@example.com\"}],\"to\":[],\"subject\":\"Big $i\"}"; i=$((i + 1)); done
      echo "{\"envelopes\":[${rows#,}]}";;
    # Page two of this one fails: what page one gave is kept, and said short.
    Flaky)
      if [ "$page" = "1" ]; then
        rows=""; i=1
        while [ "$i" -le 500 ]; do rows="$rows,{\"id\":\"$i\",\"from\":[{\"email\":\"f@example.com\"}],\"to\":[],\"subject\":\"Flaky $i\"}"; i=$((i + 1)); done
        echo "{\"envelopes\":[${rows#,}]}"
      else echo "error: connection reset" >&2; exit 1; fi;;
    Receipts)
      if [ "$page" = "1" ]; then
        printf '{"envelopes":[%s,%s,%s]}\n' \
          '{"id":"31","from":[{"name":"ACME","email":"Bills@ACME.com"}],"to":[{"name":null,"email":"ada@example.com"}],"subject":"Invoice 31"}' \
          '{"id":"30","from":[{"name":"ACME","email":"bills@acme.com"}],"to":[{"email":"ada@example.com"}],"subject":"Re: Invoice 30"}' \
          '{"id":"29","from":[{"email":"shop@store.example"}],"to":[],"subject":"Your order shipped"}'
      else echo '{"envelopes":[]}'; fi;;
    Travel)
      if [ "$page" = "1" ]; then
        printf '{"envelopes":[%s,%s]}\n' \
          '{"id":"12","from":[{"email":"noreply@delta.com"}],"to":[{"email":"ada@example.com"}],"subject":"Your flight to SFO"}' \
          '{"id":"11","from":[{"email":"hotel@marriott.com"}],"to":[{"email":"ada@example.com"}],"subject":"Reservation confirmed"}'
      else echo '{"envelopes":[]}'; fi;;
    *) echo '{"envelopes":[]}';;
  esac
  exit 0
fi
if [ "$verb" = "message read" ]; then
  id="$9"
  case "$id" in
    31|30) echo '{"text_body":[1],"html_body":[],"attachments":[],"parts":[{"body":{"Multipart":[1]}},{"body":{"Text":"Please find the invoice attached. Total due 40 EUR."}}]}';;
    29) echo '{"text_body":[],"html_body":[1],"attachments":[],"parts":[{"body":{"Multipart":[1]}},{"body":{"Html":"<html><style>p{}</style><body><p>Your <b>order</b> has shipped &amp; is on its way</p><script>x()</script></body></html>"}}]}';;
    12) echo '{"text_body":[1],"html_body":[],"attachments":[],"parts":[{"body":{"Multipart":[1]}},{"body":{"Text":"Boarding pass for your flight"}}]}';;
    *) echo "unreadable" >&2; exit 1;;
  esac
  exit 0
fi
echo "unexpected $*" >&2; exit 9
EOF
chmod +x "$work/bin/himalaya"
export PATH="$work/bin:$PATH"
export FAKE_LOG="$work/calls.log"
: > "$FAKE_LOG"
# The file may only land inside the labels directory of the data home.
export XDG_DATA_HOME="$work/data"

out="$work/data/omamail/labels/account-test.json"
cat > "$work/spec.json" <<EOF
{"accountId":"imap:ada@example.com","account":"ada@example.com","out":"$out",
 "labels":[{"id":"Receipts","folder":"Receipts","name":"Receipts"},{"id":"Travel","folder":"Travel","name":"Travel"},
           {"id":"Broken","folder":"Broken","name":"Broken"}],
 "sample":{"envelopes":10,"bodies":2,"chars":4000},"himalayaAccount":"test"}
EOF

(umask 077; mkdir -p "$work/data/omamail/labels") && printf '{"k":"learn"}\n' > "$out.choices"
OMAMAIL_MESSAGE_FILE="$work/spec.json" python3 "$script" build > "$work/build.log" 2>"$work/build.err" \
  || fail "the build exits clean: $(cat "$work/build.err")"
[ ! -e "$out.choices" ] || fail "the journal of choices beside the profile is folded in and removed"
cp "$FAKE_LOG" "$work/calls1.log"
[ -f "$out" ] || fail "the profile is written"
[ "$(stat -c %a "$out")" = "600" ] || fail "the profile is private"
[ "$(stat -c %a "$work/data/omamail/labels")" = "700" ] || fail "and so is its directory"
[ "$(tail -n 1 "$work/build.log")" = "Built 2 labels from 5 messages, 1 skipped" ] || fail "the last line is the summary: $(tail -n 1 "$work/build.log")"
grep -q "Label 3/3 Broken: skipped (error: no such mailbox)" "$work/build.log" || fail "a folder that fails is skipped and said so"
grep -q "Label 1/3 Receipts: 3 messages, 2 bodies" "$work/build.log" || fail "each label reports its counts: $(cat "$work/build.log")"

field() { python3 -c 'import json,sys
p=json.load(open(sys.argv[1]))
v=p
for k in sys.argv[2].split("|"):
    v=v[k] if isinstance(v,dict) else v[int(k)]
print(v)' "$out" "$1"; }
[ "$(field "version")" = "1" ] || fail "the file carries its version"
python3 -c 'import json,sys,time; p=json.load(open(sys.argv[1])); now=time.time(); sys.exit(0 if abs(p["builtMs"]/1000 - p["built"]) < 1.001 and p["built"] <= now and p["builtMs"] > 1e12 else 1)' "$out" || fail "and when it began, to the second and to the millisecond"
[ "$(field "accountId")" = "imap:ada@example.com" ] || fail "and whose it is"
[ "$(field "docs")" = "5" ] || fail "and how many messages it read"
[ "$(field "movedSince")" = "0" ] || fail "nothing has moved out yet"
[ "$(field "labels|Receipts|docs")" = "3" ] || fail "Receipts held three"
[ "$(field "labels|Receipts|bodies")" = "2" ] || fail "two of them were read for words, the newest two"
[ "$(field "labels|Receipts|from|bills@acme.com")" = "2" ] || fail "the sender is counted, lower-cased"
[ "$(field "labels|Receipts|domain|acme.com")" = "2" ] || fail "and its domain"
[ "$(field "labels|Receipts|to|ada@example.com")" = "2" ] || fail "and the recipient"
[ "$(field "labels|Receipts|subject|invoice")" = "2" ] || fail "subject words once per message"
[ "$(field "labels|Receipts|body|invoice")" = "2" ] || fail "body words once per message"
[ "$(field "labels|Travel|body|boarding")" = "1" ] || fail "Travel's one body was read"
[ "$(field "labels|Travel|bodies")" = "1" ] || fail "a body that cannot be read is not a body"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); sys.exit(0 if "Broken" not in p["labels"] else 1)' "$out" || fail "a skipped label has no entry"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); sys.exit(0 if "shipped" in p["labels"]["Receipts"]["body"] or "order" in p["labels"]["Receipts"]["body"] else 1)' "$out" \
  && fail "the third message was not one of the two bodies asked for"
# The words of an HTML-only message come through without its markup.
cat > "$work/spec2.json" <<EOF
{"accountId":"imap:ada@example.com","account":"ada@example.com","out":"$out",
 "labels":[{"id":"Receipts","folder":"Receipts","name":"Receipts"}],"sample":{"envelopes":10,"bodies":3},"himalayaAccount":"test"}
EOF
OMAMAIL_MESSAGE_FILE="$work/spec2.json" python3 "$script" build > "$work/build2.log" 2>&1 || fail "a second build exits clean"
[ "$(field "labels|Receipts|body|shipped")" = "1" ] || fail "an HTML body is read as words"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); b=p["labels"]["Receipts"]["body"]; sys.exit(1 if "style" in b or "script" in b or "html" in b else 0)' "$out" \
  || fail "markup, style and script are not words"
[ "$(field "sample|bodies")" = "3" ] || fail "the caps are recorded"
[ "$(field "sample|chars")" = "4000" ] || fail "a cap left out is the default"

# The listing pages by 500 at most and asks for no more than the cap.
grep -q -- "envelope list -m Receipts -s 500 -p 1" "$work/calls1.log" || fail "the first page is a full page whatever the cap: $(cat "$work/calls1.log")"
grep -q -- "message read -m Receipts -- 31" "$work/calls1.log" || fail "the newest message is read, its id after a --"
grep -q -- "message read -m Receipts -- 29" "$work/calls1.log" && fail "the third is not, with bodies capped at two"

# A rebuild that cannot list a label keeps what the last file held for it,
# and one that can replaces it. The choices made since ride along in the
# old entry, so a bad folder on a rebuild does not forget a label.
python3 - "$out" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["labels"]["Broken"] = {"name": "Broken", "docs": 7, "bodies": 1, "from": {"old@example.com": 7}, "domain": {}, "to": {}, "subject": {"old": 7}, "body": {}}
p["labels"]["Receipts"]["from"]["chosen@example.com"] = 2
p["movedSince"] = 30
json.dump(p, open(sys.argv[1], "w"))
PY
cat > "$work/spec3.json" <<SPEC
{"accountId":"imap:ada@example.com","account":"ada@example.com","out":"$out",
 "labels":[{"id":"Receipts","folder":"Receipts"},{"id":"Broken","folder":"Broken"}],"sample":{"envelopes":10,"bodies":0},"himalayaAccount":"test"}
SPEC
OMAMAIL_MESSAGE_FILE="$work/spec3.json" python3 "$script" build > "$work/build3.log" 2>&1 || fail "a rebuild with one bad folder still exits clean: $(cat "$work/build3.log")"
[ "$(field "labels|Broken|docs")" = "7" ] || fail "the label that could not be listed keeps its counts from before"
[ "$(field "labels|Broken|from|old@example.com")" = "7" ] || fail "all of them"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); sys.exit(1 if "chosen@example.com" in p["labels"]["Receipts"]["from"] else 0)' "$out" \
  || fail "a label that was listed is replaced whole"
[ "$(field "movedSince")" = "0" ] || fail "a rebuild starts the departures again"
[ "$(field "docs")" = "10" ] || fail "the kept counts are counted: $(field docs)"
grep -q "Label 2/2 Broken: could not be listed (error: no such mailbox); kept the counts from before" "$work/build3.log" || fail "and the line says so: $(cat "$work/build3.log")"
[ "$(tail -n 1 "$work/build3.log")" = "Built 2 labels from 10 messages, 1 kept from before" ] || fail "as does the summary: $(tail -n 1 "$work/build3.log")"

# Paging: every page the same size, so a cap that is not a multiple of the
# page still reads the newest `cap` and no page starts inside another.
: > "$FAKE_LOG"
cat > "$work/spec4.json" <<SPEC
{"accountId":"imap:ada@example.com","account":"ada@example.com","out":"$out",
 "labels":[{"id":"Big","folder":"Big"},{"id":"Flaky","folder":"Flaky"}],"sample":{"envelopes":600,"bodies":0},"himalayaAccount":"test"}
SPEC
OMAMAIL_MESSAGE_FILE="$work/spec4.json" python3 "$script" build > "$work/build4.log" 2>&1 || fail "a big folder builds: $(cat "$work/build4.log")"
[ "$(field "labels|Big|docs")" = "600" ] || fail "six hundred of twelve hundred: $(field "labels|Big|docs")"
[ "$(field "labels|Big|from|big600@example.com")" = "1" ] || fail "up to the six hundredth"
[ "$(field "labels|Big|from|big601@example.com" 2>/dev/null || echo none)" = "none" ] || fail "and not past it"
grep -q -- "envelope list -m Big -s 500 -p 1" "$FAKE_LOG" || fail "page one at the page size"
grep -q -- "envelope list -m Big -s 500 -p 2" "$FAKE_LOG" || fail "page two at the same size, not the remainder: $(grep Big "$FAKE_LOG")"
grep -q -- "envelope list -m Big -s 100" "$FAKE_LOG" && fail "no page shrinks"
[ "$(field "labels|Flaky|docs")" = "500" ] || fail "a later page failing keeps what was read"
grep -q "Label 2/2 Flaky: 500 messages, 0 bodies (short: page 2 failed (error: connection reset))" "$work/build4.log" || fail "and says the label is short: $(grep Flaky "$work/build4.log")"

# The file lands only inside the labels directory: a spec naming anywhere
# else, or a symlink there, is refused before anything is read.
: > "$FAKE_LOG"
printf '{"accountId":"x","account":"a","out":"%s","labels":[{"id":"Receipts"}],"himalayaAccount":"test"}\n' "$work/elsewhere.json" \
  | python3 "$script" build > "$work/elsewhere.log" 2>&1 && fail "a file outside the labels directory is refused"
grep -q "out must be a file inside" "$work/elsewhere.log" || fail "and said so: $(cat "$work/elsewhere.log")"
[ ! -s "$FAKE_LOG" ] || fail "and nothing was read first"
printf '{"accountId":"x","account":"a","out":"%s","labels":[{"id":"Receipts"}],"himalayaAccount":"test"}\n' "$work/data/omamail/labels/../../account-escape.json" \
  | python3 "$script" build > /dev/null 2>&1 && fail "nor a path that climbs out"
ln -s "$work/target.json" "$work/data/omamail/labels/account-link.json"
printf '{"accountId":"x","account":"a","out":"%s","labels":[{"id":"Receipts"}],"himalayaAccount":"test"}\n' "$work/data/omamail/labels/account-link.json" \
  | python3 "$script" build > /dev/null 2>&1 && fail "nor a symlink in the directory"
[ ! -f "$work/target.json" ] || fail "and the link's target is untouched"

# Nor a relative path, a name of another shape, or a directory reached
# through a link.
printf '{"accountId":"x","account":"a","out":"account-rel.json","labels":[{"id":"Receipts"}],"himalayaAccount":"test"}\n' \
  | (cd "$work/data/omamail/labels" && python3 "$script" build) > /dev/null 2>&1 && fail "a relative name is refused even from inside the directory"
printf '{"accountId":"x","account":"a","out":"%s","labels":[{"id":"Receipts"}],"himalayaAccount":"test"}\n' "$work/data/omamail/labels/evil.json" \
  | python3 "$script" build > /dev/null 2>&1 && fail "a name of another shape is refused"
mkdir -p "$work/other/omamail" && ln -s "$work/data/omamail/labels" "$work/other/omamail/labels"
printf '{"accountId":"x","account":"a","out":"%s","labels":[{"id":"Receipts"}],"himalayaAccount":"test"}\n' "$work/other/omamail/labels/account-viaLink.json" \
  | XDG_DATA_HOME="$work/other" python3 "$script" build > /dev/null 2>&1 && fail "a labels directory that is a link is refused"
[ ! -f "$work/data/omamail/labels/account-viaLink.json" ] || fail "and nothing landed through it"

# A previous file's entry is kept only in the shape a fresh one has:
# nonsense counts are dropped, huge ones bounded, and a count that is not a
# number does not stop the build.
python3 - "$out" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["labels"]["Broken"] = {"name": "Broken", "docs": "7x", "bodies": {}, "from": {"ok@example.com": 3, "bad@example.com": "many", "": 2, "huge@example.com": 10**15}, "subject": "not a map", "extra": True}
json.dump(p, open(sys.argv[1], "w"))
PY
OMAMAIL_MESSAGE_FILE="$work/spec3.json" python3 "$script" build > "$work/build5.log" 2>&1 || fail "a corrupt kept entry does not stop the build: $(cat "$work/build5.log")"
[ "$(field "labels|Broken|docs")" = "0" ] || fail "a count that is not a number is nothing"
[ "$(field "labels|Broken|from|ok@example.com")" = "3" ] || fail "a good count stays"
python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["labels"]["Broken"]; sys.exit(0 if "bad@example.com" not in e["from"] and "" not in e["from"] and e["from"]["huge@example.com"] == 1000000000 and e["subject"] == {} and "extra" not in e else 1)' "$out" \
  || fail "the kept entry is made whole: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["labels"]["Broken"])' "$out")"

# A HEY mailbox has no folders himalaya opens.
printf '{"accountId":"hey:a","account":"a","provider":"hey","out":"%s","labels":[{"id":"Receipts"}],"himalayaAccount":"test"}\n' "$work/data/omamail/labels/account-hey.json" \
  | python3 "$script" build > "$work/hey.log" 2>&1 && fail "a HEY mailbox is refused"
grep -q "HEY mailbox" "$work/hey.log" || fail "and told why"

# No himalaya account for the address is a clear failure, not a guess.
printf '{"accountId":"x","account":"nobody@nowhere.example","out":"%s","labels":[{"id":"A"}]}\n' "$work/data/omamail/labels/account-none.json" \
  | XDG_CONFIG_HOME="$work/noconfig" python3 "$script" build > "$work/none.log" 2>&1 && fail "an unknown address fails"
grep -q "himalaya has no account whose email is nobody@nowhere.example" "$work/none.log" || fail "and says which: $(cat "$work/none.log")"
[ ! -f "$work/data/omamail/labels/account-none.json" ] || fail "and writes nothing"

# The address is matched to a himalaya account through its config.
mkdir -p "$work/config/himalaya"
printf '[accounts.test]\nemail = "Ada@Example.com"\n[accounts.other]\nemail = "bob@example.com"\n' > "$work/config/himalaya/config.toml"
: > "$FAKE_LOG"
printf '{"accountId":"imap:ada@example.com","account":"ada@example.com","out":"%s","labels":[{"id":"Travel"}],"sample":{"bodies":0}}\n' "$work/data/omamail/labels/account-byconfig.json" \
  | XDG_CONFIG_HOME="$work/config" python3 "$script" build > "$work/byconfig.log" 2>&1 || fail "the config names the account: $(cat "$work/byconfig.log")"
grep -q -- "-a test envelope list -m Travel" "$FAKE_LOG" || fail "and it is the one used"
grep -q -- "message read" "$FAKE_LOG" && fail "no bodies asked for, none read"
[ "$(tail -n 1 "$work/byconfig.log")" = "Built 1 labels from 2 messages" ] || fail "a label with only its id is read by that id"
# Two himalaya accounts with the address is a question, not a guess.
printf '[accounts.test]\nemail = "ada@example.com"\n[accounts.twin]\nemail = "ada@example.com"\n' > "$work/config/himalaya/config.toml"
printf '{"accountId":"imap:ada@example.com","account":"ada@example.com","out":"%s","labels":[{"id":"Travel"}]}\n' "$work/data/omamail/labels/account-twins.json" \
  | XDG_CONFIG_HOME="$work/config" python3 "$script" build > "$work/twins.log" 2>&1 && fail "two accounts with one address is refused"
grep -q "Several himalaya accounts have the address ada@example.com (test, twin)" "$work/twins.log" || fail "and names them: $(cat "$work/twins.log")"

# A spec with nothing to read is refused before anything runs.
printf '{"accountId":"x","out":"%s"}\n' "$work/data/omamail/labels/account-nothing.json" | python3 "$script" build > /dev/null 2>&1 && fail "no labels is a usage error"
printf 'not json' | python3 "$script" build > /dev/null 2>&1 && fail "so is no spec"
# Every folder failing is a failure, not an empty file.
printf '{"accountId":"x","account":"a","out":"%s","labels":[{"id":"Broken"}],"himalayaAccount":"test"}\n' "$work/data/omamail/labels/account-allbroken.json" \
  | python3 "$script" build > "$work/allbroken.log" 2>&1 && fail "every label failing fails"
[ ! -f "$work/data/omamail/labels/account-allbroken.json" ] || fail "and writes nothing"

# The tokeniser at the command line, for the window's test to compare with.
[ "$(printf 'Re: Your invoice #1234 from ACME, Inc.' | python3 "$script" tokens)" = '["invoice", "acme", "inc"]' ] || fail "tokens on stdin"

echo "test_label_brain.sh ok"
