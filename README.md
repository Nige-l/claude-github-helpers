# claude-github-helpers

Open-source GitHub issue management and local git plugin for Claude Code agents.

List, create, close, reopen, view, comment on, search, and batch-close GitHub issues — plus structured local git operations (status, diff, log, stage, commit, push) — all returning parseable JSON. Gives Claude Code agents reliable access to GitHub and git without shelling out raw `gh` or `git` commands.

## Requirements

- **[gh CLI](https://cli.github.com)** — installed and authenticated (`gh auth status`)
- **[Bun](https://bun.sh)** — the MCP server runs on Bun

## Quick Start

**1. Install and authenticate the gh CLI** (if not already done):

```sh
sudo apt install -y gh        # Debian/Ubuntu
gh auth login
```

**2. Install the plugin.**

Add the GitHub repo as a marketplace, then install:

```sh
claude plugin marketplace add https://github.com/Nige-l/claude-github-helpers
claude plugin install github-helpers
```

**3. Use the tools.** Ask Claude to list issues, create a bug report, close an issue after a commit, or search for duplicates. The tools are available automatically once the plugin is installed.

### Alternative: local install from a clone

```sh
git clone https://github.com/Nige-l/claude-github-helpers.git
claude --plugin-dir ./claude-github-helpers
```

This loads the plugin for a single session without installing it globally.

## Tools

### GitHub issue tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `list_issues` | List and filter issues | `repo`, `state` (open/closed/all), `labels`, `assignee`, `milestone`, `limit` |
| `create_issue` | Create a new issue | `repo`, `title`, `body`, `labels`, `assignee` |
| `close_issue` | Close an issue | `repo`, `number`, `comment` (optional) |
| `reopen_issue` | Reopen a closed issue | `repo`, `number`, `comment` (optional) |
| `view_issue` | View full issue + comments | `repo`, `number` |
| `add_comment` | Comment on an issue | `repo`, `number`, `body` |
| `search_issues` | Search by keyword | `repo`, `query`, `state`, `limit` |
| `batch_close` | Close multiple issues at once | `repo`, `numbers` (comma-separated, e.g. `"1,2,3"`), `comment` (optional) |

The `repo` parameter takes `owner/repo` format (e.g. `Nige-l/WorldOfFantasyWarStuff`). `labels` and `numbers` are comma-separated strings, not JSON arrays.

### Local git tools

| Tool | Description | Key Parameters |
|------|-------------|----------------|
| `git_status` | Branch, clean flag, staged/modified/untracked files, ahead/behind | `repo_path` (optional, defaults to cwd) |
| `git_diff` | Per-file stats and optional full diff text | `repo_path`, `staged` (bool), `stat_only` (bool) |
| `git_log` | Recent commits as JSON (hash, author, date, message) | `repo_path`, `limit`, `since` |
| `stage_files` | Stage specific files with `git add` | `files` (comma-separated), `repo_path` |
| `create_commit` | Commit with `Co-Authored-By` trailer appended automatically | `message`, `repo_path`, `co_author` |
| `git_push` | Push to remote (force push always refused) | `repo_path`, `remote`, `branch` |

All tools return structured JSON.

## Skills

| Skill | Description |
|-------|-------------|
| `/github-helpers:setup` | Check and install `gh` CLI, authenticate, verify access |

## Examples

**List open bugs:**
```
list_issues(repo: "owner/repo", state: "open", labels: ["bug"])
```

**Create a bug report:**
```
create_issue(repo: "owner/repo", title: "[Bug] movement rubber-banding at high latency", body: "Steps to reproduce...", labels: ["bug"])
```

**Close after a commit:**
```
close_issue(repo: "owner/repo", number: 42, comment: "Fixed in commit abc1234")
```

**Search for duplicates before filing:**
```
search_issues(repo: "owner/repo", query: "rubber-banding movement", state: "all")
```

**Add investigation notes:**
```
add_comment(repo: "owner/repo", number: 42, body: "Traced to PacketHandler.cs:87 — stale ref after entity Add")
```

**Close a batch of stale issues:**
```
batch_close(repo: "owner/repo", numbers: "101,102,103", comment: "Superseded by #120")
```

**Stage, commit, and push in one flow:**
```
stage_files(files: "src/foo.ts,src/bar.ts")
create_commit(message: "[fix] handle null case in foo")
git_push()
```

## Contributing

Contributions are welcome. Open an issue or submit a pull request.

## License

[MIT](LICENSE)
