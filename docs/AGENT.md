# AI beside your mail

Omamail uses the default AI already selected in Omarchy. There is no Omamail
AI configuration, command preset, or separate agent page. An older saved
`agentCommand` setting is ignored.

Choose **Ask AI...** from a message's right-click menu or its AI button.
`Alt+G` opens the same assistance from the list, reader, or composer. If the
clicked message belongs to the current selection, the request covers that
selection; otherwise it covers just that message. Select at most 20 messages
from one mailbox per request.

The editable prompt offers common scenarios: summary, explanation, action items,
reply drafting, and translation. Drafts offer review, rewrite, shortening, tone
changes, and writing from notes. Selecting one fills the prompt without starting
AI. Edit it freely, then use **Ask AI...** beside the prompt or press Return.
The × button closes the dock. Copy and draft insertion actions stay below the result.

The dock keeps the request visible while Omamail reads the message bodies and
opens the system AI terminal. Startup and reading errors appear in that right-side dock,
so a failed request can be retried without typing it again. If no system default
exists, Omarchy's own picker opens; choose an AI there, then retry the request.
The picker does not carry the request forward itself.

AI reads the supplied mail or draft and writes its answer back into the right-side dock.
You can select and copy the full plain-text result. In the composer, **Insert at
cursor** and **Replace body** apply it explicitly; neither sends mail. Changes
remain text edits that can be undone. Replacement removes the old body and
inserts the new one, so undoing it can take two text undo steps. Results belong
to both the account and the particular draft, including a draft restored after
Undo send. A notice identifies a draft edited since the AI request.

Continue a conversation in the system AI terminal. AI can revise its saved
suggestion while that terminal remains open, and Omamail polls for the result.
The breathing attention indicator remains until the result has been viewed.

## The bridge

`AgentContext.qml` obtains actual message bodies through the owning provider's
normal message-read interface. Reading for AI does not change the selected
message or mark mail read. No mailbox command-line client or credentials are
handed to AI. `Agent.js` builds the contextual payload and matches results to
accounts, messages and drafts; `AgentRunner.qml` starts and polls the bridge.

`scripts/agent-job.py` accepts a bounded JSON line on stdin, stores it privately
under `$XDG_STATE_HOME/omamail/assistant/<session-id>/context.json`, and launches
an interactive session with `omarchy-launch-tui`. Inside that terminal,
`omarchy-agent --inline` selects the system's configured AI and its launch flags.
The command line contains fixed instructions only. Mail, addresses, draft text,
and the user's request do not enter process arguments.

The AI is instructed to write its answer atomically to `response.txt` as private
UTF-8 plain text. The bridge imports only a regular, single-link, owner-private
file within 64 KiB; symbolic links, special files, invalid UTF-8 and unsupported
control characters are refused. Job directories are 0700 and files are 0600.
Input is limited to 1 MiB, with at most four active sessions and 32 retained
sessions. The oldest completed sessions are removed to make room. Legacy agent
jobs in the old `agent` directory are neither executed nor imported.

The bridge gives terminal startup 30 seconds and its interactive wrapper one
hour. **Close session** stops that terminal interaction and its process group.
It cannot stop tools that detached into their own session or work already
submitted to an external daemon; those may continue. Closing the right-side dock alone
keeps the AI session running.

This bridge is not a sandbox for the system AI. It retains the same permissions
and provider configuration as a normal Omarchy AI session. Instructions to treat
mail as untrusted data and avoid mailbox access are guidance, not a technical
restriction on the AI's tools. Supplied content may be sent to the AI provider
configured in the system. Omamail never automatically applies generated text or
sends a message because of an AI result.

## Verification

`tests/test_agent_bridge.py` uses synthetic system helpers, real process argument
inspection and a Linux pseudo-terminal. It checks private files, import bounds,
launch failures, retention, cancellation identity and terminal input. The QML
tests exercise mouse and Return submission, visible errors, full results,
account/draft ownership, body loading and concurrent result reads. They do not
call an AI provider or use real mailbox credentials.
