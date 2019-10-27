# fish_apple_terminal.fish

Save/restore fish state for macOS, inspired by `/etc/bashrc_Apple_Terminal`

## The Problem

Z shell (`zsh`) becomes the default shell program for Terminal.app since macOS Catalina (10.15). After playing around with it for a while, I found it didn't work for me:

- The default configuration of `zsh` is just another `bash`. If you need fancy autocomplete, autosuggestion, etc. You need to install plugins to achieve them, like [zsh-completions](https://github.com/zsh-users/zsh-completions), [zsh-autosuggestions](https://github.com/zsh-users/zsh-autosuggestions), and [oh-my-zsh](https://github.com/robbyrussell/oh-my-zsh). But after installing all these plugins, your shell will become unstable. Mine got 100% CPU usage for some long-running stdout processes with default oh-my-zsh configurations.
- Apple doesn't provide a session save/restore mechanism for `zsh`, which was available for `bash`. It is one of my favorite features of macOS Terminal.app. It can save your `bash` history per tab/window and restore them even after you restart the system.

Then, I tried `fish`. It's incredible, it just works out-of-the-box and performant. But I still miss the session save/restore feature. So I wrote one based on Apple's implementation in `/etc/bashrc_Apple_Terminal`. It has a simpler logic:

- When there's no history file for the current session:
  - Create one for each tab/window based on `$TERM_SESSION_ID`
  - Copy existing history from the shared history, which is the default history (typically `~/.local/share/fish/fish_history`).
- Save the history since you start the session back to the shared history.

The current version does not have the expiration check feature. I'll try to add it when I have time. PRs are also welcome.

## Install

Download and put the script in `~/.config/fish/conf.d/`. Or just run:

```bash
wget -P ~/.config/fish/conf.d/ https://github.com/sparanoid/fish_apple_terminal/raw/master/fish_apple_terminal.fish
```

## License

MIT
