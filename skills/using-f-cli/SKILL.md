---
name: using-f-cli
description: Use when navigating between repositories, switching branches, finding local workspaces, reading code in other repos, or researching across multiple codebases. Also use when the user references repos by owner/repo/branch patterns.
---

# Using the `f` CLI for Codebase Navigation

## Overview

`f` is a git worktree workspace manager. All repos live under `$HOME/code/<domain>/<owner>/<repo>/<branch>/`. For AI agents, the key capability is **resolving workspace paths and listing available repos/branches without interactive prompts or tmux side effects**.

## Critical: Agent-Safe Commands

**NEVER use `f -l` or bare `f <args>` from an agent** -- these create/attach tmux sessions or launch interactive fzf, which will hang or fail in non-interactive contexts.

**Use these agent-safe approaches instead:**

| Command | Purpose |
|---------|---------|
| `f -L` | List ALL workspace paths to stdout |
| `f -p <owner/repo/branch>` | Print resolved path to stdout, no tmux |

### Version Fallback

The `-L` and `-p` flags require a recent build of `f`. If they are not available (`f -L` prints usage/help instead of paths), use the underlying directory convention directly:

```bash
# Equivalent to f -L
find "$HOME/code" -mindepth 4 -maxdepth 4 -type d

# Equivalent to f -p owner/repo/branch
echo "$HOME/code/github.com/owner/repo/branch"
```

**Always try `f -L` first.** If it returns help text instead of paths, fall back to `find`.

## Quick Reference

```bash
# List all local workspaces (one absolute path per line)
f -L

# Get the path to a specific workspace
f -p owner/repo/branch

# Read a file in another repo
cat "$(f -p owner/repo/branch)/README.md"

# Find all repos for a specific owner
f -L | grep "/owner/"

# Find all branches of a specific repo
f -L | grep "/repo-name/"

# Search across all workspaces
f -L | xargs -I{} grep -rl "pattern" {} --include="*.ts" 2>/dev/null
```

## Directory Structure

All workspaces follow this exact layout:
```
$HOME/code/github.com/<owner>/<repo>/<branch>/
```

Given a path, extract components:
- **Branch**: `basename "$path"`
- **Repo**: `basename "$(dirname "$path")"`
- **Owner**: `basename "$(dirname "$(dirname "$path")")"`

## Common Agent Workflows

### Find what repos/branches exist locally
```bash
f -L
# Returns paths like: /Users/you/code/github.com/acme/api/main
```

### Read a file in another repo without switching context
```bash
cat "$(f -p acme/api/main)/src/index.ts"
# Fallback: cat "$HOME/code/github.com/acme/api/main/src/index.ts"
```

### Search for code across all local workspaces
```bash
f -L | xargs -I{} rg "pattern" {} --type ts 2>/dev/null
```

### Check if a repo/branch is available locally
```bash
f -L | grep "repo-name/branch-name"
# Empty output = not checked out locally
```

### Clone a new repo (interactive -- use with caution)
Only use when the user explicitly asks. This creates tmux sessions:
```bash
f owner/repo/branch
```

### Housekeeping (user-facing, not agent-initiated)
```bash
f gc           # List stale worktrees (30+ days untouched)
f gc 14        # Custom threshold
f clean 60     # Remove old worktrees (interactive confirmation)
```

## Flags Reference

| Flag | Agent-safe? | Description |
|------|------------|-------------|
| `-L` | Yes | List all workspace paths to stdout |
| `-p` | Yes | Print resolved path only, no tmux |
| `-h` | Yes | Show usage |
| `-r <dir>` | Yes | Override root directory (default: `$HOME/code`) |
| `-g <domain>` | Yes | Override git domain (default: `github.com`) |
| `-l` | **No** | Interactive fzf picker -- will hang |
| `-d` | **No** | Interactive delete -- will hang |

## Gotchas

- **`-p` output goes to stdout; all status messages go to stderr.** When capturing `f -p`, only stdout matters.
- **`f -L` can return hundreds of paths.** Always filter with `grep` before processing.
- **The installed `f` may be older than the source.** If `-L`/`-p` print help text, use the `find` fallback above or ask the user to rebuild (`nix build` / `nix run`).
