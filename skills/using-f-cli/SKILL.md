---
name: using-f-cli
description: Use when navigating between repositories, switching or creating branches, cloning repositories into the local workspace tree, finding local workspaces, reading code in other repos, or researching across multiple codebases. Also use when the user references repos by owner/repo/branch patterns.
---

# Using the `f` CLI for Codebase Navigation

## Overview

`f` is a git worktree workspace manager. All repos live under `$HOME/code/<domain>/<owner>/<repo>/<branch>/`.

For AI agents, `f` is useful for three jobs:
- **Resolve existing workspace paths** without interactive prompts.
- **Inspect what repos/branches already exist locally**.
- **Create missing workspaces by cloning repos and creating branches** (only when explicitly requested, because this can create tmux sessions).

## Critical: Agent-Safe Commands

**NEVER use `f -l` or bare `f <args>` from an agent** -- these create/attach tmux sessions or launch interactive fzf, which will hang or fail in non-interactive contexts.

**Use these agent-safe approaches instead:**

| Command | Purpose |
|---------|---------|
| `f -L` | List ALL workspace paths to stdout |
| `f -p <owner/repo/branch>` | Print resolved path to stdout, no tmux |
| `f -e <owner/repo/branch>` | Ensure workspace exists, print path, never tmux |

Command selection:
- Use `f -e` when the workspace might not exist yet.
- Use `f -p` when you expect the workspace already exists and only need its path.

### Version Fallback

The `-L`, `-p`, and `-e` flags require a recent build of `f`. If they are not available (`f -L` prints usage/help instead of paths), use the underlying directory convention directly:

```bash
# Equivalent to f -L
find "$HOME/code" -mindepth 4 -maxdepth 4 -type d

# Equivalent to f -p owner/repo/branch
echo "$HOME/code/github.com/owner/repo/branch"
```

**Always try `f -L` first.** If it returns help text instead of paths, fall back to `find`.

For `-e` on older builds:
- There is no non-tmux equivalent in old `f` versions.
- If creation is required and explicitly requested, use `f owner/repo/branch` (interactive; may start tmux).
- Otherwise use direct path resolution only (`f -p` equivalent) and report that creation was not performed.

## Quick Reference

```bash
# List all local workspaces (one absolute path per line)
f -L

# Get the path to a specific workspace
f -p owner/repo/branch

# Ensure a workspace exists (clone/create branch if needed), then print path
f -e owner/repo/branch

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

Prefer `owner/repo/branch` patterns in automation to avoid ambiguity when multiple owners have repos with the same name.

### Clone a new repo (interactive -- use with caution)
Use when the user explicitly asks to clone/open a repo that is not present locally. This can create tmux sessions:
```bash
f owner/repo/branch
```

Examples:
```bash
# Clone repo and open/create the main workspace
f acme/api/main

# Clone repo and create/open a feature branch workspace
f acme/api/feature-add-auth
```

Note: current `f` argument parsing expects exactly `owner/repo/branch` (single-segment branch names in this form).

### Create a new branch workspace (interactive -- use with caution)
Use when the repository already exists locally but the requested branch does not. This can create tmux sessions:
```bash
f owner/repo/new-branch
```

Behavior notes:
- If `owner/repo` is missing locally, `f` clones it first.
- If `new-branch` is missing, `f` creates a new worktree for it.
- This is the preferred `f`-native way to create branch workspaces.

### Agent-safe workspace creation (no tmux)
Use this when agents need to create/resolve workspaces non-interactively:
```bash
f -e owner/repo/branch
```

Behavior notes:
- Ensures the workspace exists (clone if needed, create branch worktree if needed).
- Prints the resolved workspace path to stdout.
- Never creates, attaches, or switches tmux sessions.

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
| `-e` | Yes | Ensure workspace exists, print path, no tmux |
| `-h` | Yes | Show usage |
| `-r <dir>` | Yes | Override root directory (default: `$HOME/code`) |
| `-g <domain>` | Yes | Override git domain (default: `github.com`) |
| `-l` | **No** | Interactive fzf picker -- will hang |
| `-d` | **No** | Interactive delete -- will hang |

## Gotchas

- **`-p` output goes to stdout; all status messages go to stderr.** When capturing `f -p`, only stdout matters.
- **`-e` output contract:** resolved path on stdout, status/progress on stderr, non-zero exit code on failure.
- **`f -L` can return hundreds of paths.** Always filter with `grep` before processing.
- **The installed `f` may be older than the source.** If `-L`/`-p`/`-e` print help text, use the fallback above or ask the user to rebuild (`nix build` / `nix run`).
- **Clone transport is SSH (`git@<domain>:owner/repo.git`).** Agent environments need SSH keys configured for clone/create flows.
