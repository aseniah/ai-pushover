# ai-pushover

Get phone notifications from your AI coding agent so you can step away while it works.

`pushover.sh` is a small zsh script that sends status pushes through [Pushover](https://pushover.net). You tell your agent you are stepping away, and it pings you when it finishes, when it needs your input, and occasionally while a long task is still running. The script handles the parts an agent should not have to think about: credentials, rate limits, message length, and screening out secrets before anything leaves your machine.

## Requirements

- macOS (zsh, curl, and the `security` CLI for Keychain access ship with it)
- [jq](https://jqlang.github.io/jq/) (`brew install jq`)
- [ripgrep](https://github.com/BurntSushi/ripgrep) (`brew install ripgrep`)
- A Pushover account with the app installed on your phone, plus an application token from [pushover.net/apps/build](https://pushover.net/apps/build)

## Install

Clone the repo and put the script somewhere stable. A symlink lets you update with `git pull`.

```sh
git clone https://github.com/aseniah/ai-pushover.git ~/projects/ai-pushover
mkdir -p ~/bin
ln -s ~/projects/ai-pushover/pushover.sh ~/bin/pushover.sh
```

Store your credentials in the login Keychain. Run this yourself in a terminal, not through an agent, so the keys never pass through a chat transcript.

```sh
~/bin/pushover.sh --setup
```

Check that the credentials work without sending a push, then send a real one.

```sh
~/bin/pushover.sh --test
~/bin/pushover.sh -t "Setup" "Nothing blocking. This is a test push."
```

## Usage

```sh
pushover.sh [-t LABEL] [-q] [-u URL] MESSAGE
```

- `-t LABEL` sets a short session label. The title arrives as `Agent: LABEL`, which lets you tell parallel sessions apart. The prefix is configurable.
- `-q` delivers silently (Pushover priority -1), for routine "still working" check-ins.
- `-u URL` attaches a link, such as a pull request.
- `--dry-run` runs every check and prints the payload without sending.
- `--help` prints usage plus the full set of limits, message rules, and exit codes. Agents should read it once before their first push.

Each successful send reports how many pushes are left in the current window, so the agent always knows where it stands.

## Guardrails

- **Credentials** live in the macOS login Keychain under the service name `pushover`. They are never written to a file.
- **Rate limit:** at least 3 seconds between pushes and at most 10 per 5 minutes, shared across every session on the machine. A throttled send exits with code 3 and says when the next send is allowed.
- **Length:** titles are capped at 40 characters and messages at 1,024 (Pushover's own maximum). Anything longer is rejected rather than truncated, so you never receive a partial message.
- **No code:** messages containing backticks are rejected.
- **Secret screening:** messages that look like AWS, GitHub, Slack, npm, or Anthropic keys, JWTs, private keys, or long password or token values are rejected. This is a best effort pattern check, not a guarantee, so your agent instructions should still forbid sensitive content.
- **Literal content:** every field is sent as a literal string, so a message like `@/etc/hosts` can never upload a local file.

## Configuring your agent

The script only enforces limits. Your agent also needs to know when to push and what is appropriate to send. Add instructions like these to your agent's global instructions file, such as `~/.claude/CLAUDE.md` for Claude Code or `AGENTS.md` for other tools. Replace the path with wherever you installed the script.

```markdown
## Push Notifications (`~/bin/pushover.sh`)

When I say in the current session that I'm stepping away, or ask to be pinged, send status pushes to my phone with `/Users/<you>/bin/pushover.sh`. Never send them otherwise.

- Run `/Users/<you>/bin/pushover.sh --help` once before the first push in a session and follow what it prints, including how to handle each exit code.
- Send as a standalone command with the absolute path, with no env var prefix and no `&&` chaining, so it matches the allow rule.
- On the first push, pick a `-t` label for the session: the ticket key, or a 1 to 3 word description of the work such as `-t "Search Feature"`. Reuse it on every push for the rest of the session unless I ask for a different one.
- The push service is a third party. Never include customer data, credentials, internal URLs, or anything confidential.
- Push at real milestones, when you need me, and once when the work is finished.
- Only the main session sends pushes. Do not give subagents the script or ask them to push; have them report back, and relay anything worth a push yourself.
- Never run `--setup`.
```

### Claude Code permissions

So a push never stalls waiting for you to approve it, allow the script in `~/.claude/settings.json`. Use the same absolute path your instructions use.

```json
{
  "permissions": {
    "allow": [
      "Bash(/Users/<you>/bin/pushover.sh *)"
    ]
  }
}
```

If your agent runs commands in a sandbox, it may also need network access to `api.pushover.net` and read access to the login Keychain. Running `--test` through the agent confirms both.

### Claude Code hooks (optional)

An agent cannot push while it is stuck waiting on you, such as at a permission prompt or a question. A Claude Code Notification hook can cover that gap, since Claude Code raises the same permission notification for both after about six seconds without a response. Once a session has sent its first push, the script treats that session as away, and the `--hook` entry point sends a "needs input" push using the session's label. The next prompt you type in that session runs `--back`, which turns this off until the agent pushes again. Sessions that never pushed are never notified.

Add these to the `hooks` section of `~/.claude/settings.json`, merging with any hooks you already have:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/Users/<you>/bin/pushover.sh --back >/dev/null 2>&1 || true" }] }
    ],
    "Notification": [
      {
        "matcher": "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
        "hooks": [{ "type": "command", "command": "/Users/<you>/bin/pushover.sh --hook >/dev/null 2>&1 || true", "async": true }]
      }
    ]
  }
}
```

Keep the `|| true`. A hook that exits with code 2 blocks the prompt it is attached to, and the script uses exit 2 for missing credentials. Hook pushes count toward the same rate limit as everything else.

## Configuration

Every setting below has a default in the script. To change one without editing the script, so `git pull` never conflicts, set it in `~/.config/pushover/config` (or `$XDG_CONFIG_HOME/pushover/config`). The file is sourced as zsh, so use plain `KEY=value` lines.

```sh
mkdir -p ~/.config/pushover
cat > ~/.config/pushover/config <<'CONF'
TITLE_PREFIX="Claude"
MAX_PER_WINDOW=20
CONF
```

Run `pushover.sh --help` afterward to confirm the values took effect.


| Variable | Default | Purpose |
| --- | --- | --- |
| `TITLE_PREFIX` | `Agent` | Prefix for every push title |
| `MAX_TITLE_CHARS` | `40` | Title length limit, prefix included |
| `MAX_MESSAGE_CHARS` | `1024` | Message length limit |
| `MIN_GAP_SECONDS` | `3` | Minimum time between pushes |
| `WINDOW_SECONDS` / `MAX_PER_WINDOW` | `300` / `10` | Rolling rate limit |

Throttle state lives in `~/.local/state/pushover/`. Set `PUSHOVER_STATE_DIR` to move it.

## Limitations

- macOS only, because credentials come from the Keychain.
- An agent can only push between its own steps. It cannot push while it is waiting on a long command. The optional hooks cover permission prompts and questions.
- Secret screening catches common token formats only. Treat it as a safety net behind your agent instructions, not a replacement for them.

## License

[MIT](LICENSE)
