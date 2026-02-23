````markdown
# Terminal Setup Script (Zsh + CLI Tools)

A simple interactive shell setup script for macOS/Linux that installs a modern terminal workflow and can revert its own changes.

I built this because I wanted a repeatable way to set up a better terminal on a new machine without manually installing everything one by one (and without messing up my existing config).

## What it does

The script walks you through an interactive setup and lets you choose what to install.

### Core shell setup
- Zsh (if not already installed)
- Oh My Zsh
- `zsh-autocomplete`
- `zsh-autosuggestions`
- `zsh-syntax-highlighting`

### CLI tools
- `fzf`
- `zoxide`
- `eza`
- `bat`
- `ripgrep`
- `fd`
- `jq`
- `direnv`
- `atuin`

### Prompt + session manager
- `starship` (optional, but recommended)
- `tmux` (optional)

## Why this script exists

Most terminal setup guides are either:
- too manual
- tied to someone’s full dotfiles repo
- hard to undo once you run them

This script is meant to be:
- **interactive**
- **safe**
- **easy to rerun**
- **easy to revert**

It adds a clearly marked managed block to `.zshrc` and keeps its own files under `~/.terminal-setup/`.

---

## Features

- Interactive install flow (pick what you want)
- Backs up your existing `.zshrc`
- Adds a managed `.zshrc` block (instead of replacing your whole file)
- Tracks changes in a manifest file
- Revert command to undo changes recorded by the script
- Status command to see what’s installed / managed

---

## Supported package managers

The script currently detects and uses:

- Homebrew (`brew`)
- APT (`apt-get`)
- DNF (`dnf`)
- Pacman (`pacman`)

---

## Usage

### 1) Make it executable

```bash
chmod +x main.sh
````

### 2) Install (interactive)

```bash
./main.sh install
```

### 3) Check status

```bash
./main.sh status
```

### 4) Revert

```bash
./main.sh revert
```

---

## Important notes

### 1) Revert behavior is intentionally conservative

The script only uninstalls packages/plugins that it knows it installed (tracked in the manifest).

That means if a package was already installed before running the script, `revert` will **not** remove it. This is on purpose, to avoid deleting tools you already use.

### 2) The script manages only a section of `.zshrc`

It adds/removes a block like this:

```zsh
# >>> terminal-setup managed block >>>
# ...
# <<< terminal-setup managed block <<<
```

Your existing `.zshrc` outside that block is left alone.

### 3) Oh My Zsh install is non-destructive

The script installs Oh My Zsh in unattended mode and preserves your `.zshrc` (`KEEP_ZSHRC=yes`).

---

## Where it stores things

The script uses:

* `~/.terminal-setup/`

  * `plugins/` → zsh plugins cloned by the script
  * `backups/` → config backups (like `.zshrc`)
  * `manifest.env` → tracks what was changed

---

## macOS note (Bash 3)

macOS ships with an older Bash version by default (`3.2`).

This script is written to be compatible with the default macOS Bash (no Bash 4-only syntax).

---

## What this script does not do (yet)

This is intentionally a focused v1. It does **not** include:

* terminal emulators (Ghostty, WezTerm, etc.)
* Neovim setup
* full dotfiles/stow management
* macOS UI customizations (Karabiner, Hammerspoon, SketchyBar, etc.)
* non-interactive flags (`--yes`, `--dry-run`) *(planned)*

---

## Planned improvements (v1.1+)

* `--yes` / non-interactive mode
* `--dry-run`
* `revert --force` (remove managed block + plugins even if manifest is missing)
* optional Starship config file (`starship.toml`)
* optional tmux config (`.tmux.conf`)
* improved package name mapping across distros

---

## Credits / References

Used these projects as the base inspiration for the shell setup:

* [Oh My Zsh](https://ohmyz.sh/)
* [zsh-autocomplete](https://github.com/marlonrichert/zsh-autocomplete)
* [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions)
* [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting)
* [Starship](https://starship.rs/)

Also took inspiration from the structure and tool choices in:

* [omerxx/dotfiles](https://github.com/omerxx/dotfiles)

---
