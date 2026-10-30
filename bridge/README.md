# Volante bridge

A small HTTP server that lets the Volante app hand longer tasks to
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) on your Mac. Quick
questions are answered on the phone through the API; work that needs your
repositories or your Claude Code MCP integrations comes here and runs asynchronously.
Python 3, standard library only.

```sh
python3 bridge/volante_bridge.py            # serves on 0.0.0.0:8787
python3 bridge/volante_bridge.py --token    # print the token for the app
```

The app's assistant calls `manda_al_mac` with a request and an optional project name.
The bridge fuzzy-matches the name to a directory (car transcription gets names wrong)
and runs `claude -p --output-format json --permission-mode <mode>` there in a
background thread. The prompt asks Claude Code to end with a line starting `VOCE:`,
one sentence to read aloud. The app polls the task, pauses the podcast when it
finishes, speaks that sentence and stores the full result in the notes.

State lives in `~/.volante/`: `bridge-token` (delete it to regenerate),
`projects.json` (a `name` to `path` map, pre-filled on first run with every git repo
in `~/Code`, `~/progetti`, `~/esp`; prune it, fewer entries means fewer transcription
mistakes) and `tasks/*.json`. Environment: `VOLANTE_CLAUDE_BIN` (default `claude`),
`VOLANTE_PERMISSION_MODE` (default `auto`), `VOLANTE_TIMEOUT` (seconds, default 900).

## API

| | |
|---|---|
| `GET /health` | no token; status and project names |
| `POST /task` | `{"prompt": "...", "project": "my-repo"}` returns `{"id": "...", "project": "..."}` |
| `GET /task/<id>` | status, full `result`, `voice` (the sentence to speak) |
| `GET /tasks` | last 30 tasks |
| `GET /context` | your `~/.claude/CLAUDE.md` and `~/.claude/projects/*/memory/MEMORY.md`, concatenated |

Everything except `/health` needs `Authorization: Bearer <token>`. `/context` lets the
app cache what Claude Code knows about you so the in-car assistant has it when the Mac
is off; it serves those files to anyone holding the token.

```sh
TOK=$(python3 bridge/volante_bridge.py --token)
curl -s -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"prompt":"Summarise the state of this repo in two lines.","project":"volante"}' \
  http://127.0.0.1:8787/task
```

## Reaching it from the car

Put the Mac and the iPhone on [Tailscale](https://tailscale.com) (or another private
network) and enter `http://<tailscale-ip>:8787` in the app. Do not expose this port to
the internet: the bridge runs Claude Code with write access to your machine, over
plain HTTP. If the Mac is asleep the app says so and everything else keeps working
through the API.

To start it at login, save this as `~/Library/LaunchAgents/local.volante-bridge.plist`
(replace `/path/to/volante`) and run `launchctl load -w <file>`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.volante-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/path/to/volante/bridge/volante_bridge.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/volante-bridge.log</string>
  <key>StandardErrorPath</key><string>/tmp/volante-bridge.err</string>
</dict>
</plist>
```

Without the `PATH` entry launchd cannot find `claude` and every task fails with "not found".
