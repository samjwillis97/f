# `f` - shell navigation of projects with git worktrees

This is an interprestation of [h](https://github.com/zimbatm/h) with slight modifications to accomodate git worktrees and suit my workflow better

## Usage

### Main `f` commands

`f <owner>/<repo>`

`f <owner>/<repo>/<branch>`

`f <git-url>`

`f -l`

`f -d <workspace>`


### Usage in .tmux.conf

Assuming `f` is on `$PATH`
Binds prefix (by default `Ctrl + b`) + `f` to open `f` in list mode, allowing you to select or create new workspaces

```
bind-key -r f run-shell "tmux neww f -l"
```


### Usage in .zshrc

Assuming `f` is on `$PATH`
Binds `Ctrl + f` to open `f` in list mode, allowing you to select or create new workspaces

```

bindkey -s ^f "f -l\n\n"

```

### Run using Nix

`nix run .#`
