# actvt-privacy-scan

[![As seen on Open Source Alternatives](https://www.opensourcealternatives.to/badge-osa.svg)](https://www.opensourcealternatives.to)

`privacy-scan` checks the AI coding-agent sessions on your machine for secrets and personal data
that ended up in them: API keys pasted into a prompt, a token printed by a tool, an email address
in a reply.

It reads Claude Code, Codex and Pi sessions: prompts, replies, thinking, tool calls and tool
output, the subagents' as well as the session's own. **Nothing is sent anywhere, and no detected
value is ever printed.** Each finding names the agent, the session, where in it, the category and the project, with a masked preview too short to use.

It is the same scanner that [Actvt](https://actvt.io), the macOS menu-bar app, runs on-device.

## What it finds

| Category | Examples |
|---|---|
| `secret` | PEM private keys, JWTs, AWS access key IDs, prefixed tokens (OpenAI `sk-`, Stripe, GitHub, GitLab, Slack, Google, Hugging Face, npm), API keys, passwords and bearer tokens in assignments and headers, passwords in URLs |
| `privateEmail` | email addresses |
| `creditCard` | card numbers that pass the Luhn check |
| `bankAccount` | IBANs that pass the mod-97 check |
| `nationalID` | US SSNs and ITINs, UK National Insurance numbers |

Placeholder values in key, password and token assignments (`your-api-key`, `changeme`, `xxxx`) are not reported. The CLI uses pattern rules only.
The Actvt app adds an on-device AI detector for names and addresses, which isn't part of this repo.

## Usage

```
privacy-scan [--json] [path ...]
```

- With no path, it scans the agents' own folders on this machine, archived Codex sessions
  included, and prints the findings and a summary.
- With paths, it scans those files and folders instead. It reads every `.jsonl` (or Codex's
  compressed `.jsonl.zst`) in them written by Claude Code, Codex or Pi, told apart by its records,
  so you can check a copy or an export before you share it.
- `--json` prints one JSON object per finding on stdout, and the summary on stderr.

This checks a folder of traces before you upload it to the Hugging Face Hub.

```sh
privacy-scan ~/exports/my-traces
```

Exit status: `0` nothing found, `1` something found, `2` an error. That makes it usable in a
script or a hook:

```sh
privacy-scan >/dev/null 2>&1 || echo "check your agent sessions"
```

## Build

Requires Swift 6.0 or later, on macOS 15+ or Linux.

```sh
cd Packages/ActvtPrivacyScan
swift build -c release
swift test
.build/release/privacy-scan
```

Both packages use Foundation only, with no package dependencies and no networking code. The only
third-party code in the tree is zstd's decoder (BSD), vendored as `CZstd` to read the `.jsonl.zst`
files Codex compresses old sessions into.

## Layout

```
Packages/
  ActvtPrivacyScan/      the scanner library (ActvtPrivacyScan) and the privacy-scan CLI
  ActvtSessionParsers/   session discovery and transcript parsers for Claude Code, Codex and Pi
```

## Contributing

This repository is synced from the Actvt app at each Actvt release. The sync replaces
`Packages/` and this README, and leaves the rest alone. Issues and pull requests are welcome here. An accepted
change is applied in Actvt and comes back with the next release's sync.

## License

MIT. See [LICENSE](LICENSE).
