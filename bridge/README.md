# Volante Bridge

A small HTTP server that lets the Volante app hand longer tasks to
[Claude Code](https://docs.anthropic.com/en/docs/claude-code) running on your
Mac. Quick questions are answered on the phone through the API; work that needs
your repositories or the MCP integrations you already have connected to Claude
Code goes here and runs asynchronously.

Python 3, standard library only.

## How it works

1. The app's assistant calls the `manda_al_mac` tool with a self-contained
   request and an optional project name.
2. The bridge resolves the project name to a directory (fuzzy match, because car
   transcription gets names wrong) and runs `claude -p --output-format json
   --permission-mode <mode>` there in a background thread.
3. The prompt asks Claude Code to end with a line starting `VOCE:` — one sentence
   to be read aloud. The app polls the task, pauses the podcast when it finishes,
   speaks that sentence, and stores the full result in the notes.

## Run

```sh
python3 bridge/volante_bridge.py            # serves on 0.0.0.0:8787
python3 bridge/volante_bridge.py --token    # print the token for the app
```

State lives in `~/.volante/`:

- `bridge-token` — random bearer token (delete the file to regenerate)
- `projects.json` — `name → path` map. On first run it is pre-filled with every
  git repo found in `~/Code`, `~/progetti`, `~/esp`. Edit it by hand: fewer
  entries means fewer transcription mistakes.
- `tasks/*.json` — task history

Environment variables: `VOLANTE_CLAUDE_BIN` (path to `claude`, default
`claude`), `VOLANTE_PERMISSION_MODE` (default `auto`), `VOLANTE_TIMEOUT`
(seconds, default 900).

## API

| | |
|---|---|
| `GET /health` | no token — status and project names |
| `POST /task` | `{"prompt": "...", "project": "my-repo"}` → `{"id": "...", "project": "..."}` |
| `GET /task/<id>` | status, full `result`, `voice` (the sentence to speak) |
| `GET /tasks` | last 30 tasks |
| `GET /context` | your `~/.claude/CLAUDE.md` and `~/.claude/projects/*/memory/MEMORY.md`, concatenated |

Everything except `/health` requires `Authorization: Bearer <token>`.

`/context` lets the app cache what your Claude Code already knows about you, so
the in-car assistant has the same background even when the Mac is off. Be aware
that it serves those files to anyone holding the token.

```sh
TOK=$(python3 bridge/volante_bridge.py --token)
curl -s -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  -d '{"prompt":"Summarise the state of this repo in two lines.","project":"volante"}' \
  http://127.0.0.1:8787/task
```

## Reaching it from the car

Use [Tailscale](https://tailscale.com) (or another private network) on both the
Mac and the iPhone, and put `http://<tailscale-ip>:8787` in the app.

**Do not expose this port to the internet.** The bridge runs Claude Code with
write access to your machine, over plain HTTP.

The Mac must be awake. If it sleeps, the app says it cannot reach the Mac and
everything else keeps working through the API.

## Start at login (launchd)

Save as `~/Library/LaunchAgents/local.volante-bridge.plist` and load it with
`launchctl load -w <file>`. Replace `/path/to/volante` with your checkout.

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

The `PATH` entry matters: without it launchd cannot find `claude` and every task
fails with "not found".
