# tmux

tmux is a terminal multiplexer: it lets you keep long‑running shells alive on servers, even if your SSH drops, and split your terminal into panes and windows inside one session. Perfect for managing multiple VPS tasks.

## Core use case
- Start work on a VPS inside a tmux session; if your network drops, the session keeps running, so builds/backups don’t die. You just reattach later.
- Organize work: one tmux session per server or project, with multiple windows (tabs) and panes (splits).

## What to install
- Debian/Ubuntu (on your VPS): `sudo apt update && sudo apt install tmux`[1]
- Fedora (local): `sudo dnf install tmux`[2][1]
- macOS (local via Homebrew): `brew install tmux`[3][1]
- Verify: `tmux -V`

If you prefer latest versions beyond distro repos, see the tmux wiki or build from source (needs libevent and ncurses).[1]

## First session (remote VPS)
1) SSH in: `ssh user@vps`
2) Create a named session: `tmux new -s work`
3) Do your tasks. Detach (leave it running): press Ctrl+b then d.
4) Reattach later: `tmux attach -t work` (or list with `tmux ls`).[4]

Try this now: create `work`, run `htop` or a build, detach, logout, SSH back, reattach—notice your program kept running.

## Windows and panes
- New window (like a tab): Ctrl+b c
- Next/prev window: Ctrl+b n / Ctrl+b p
- Split vertical: Ctrl+b %
- Split horizontal: Ctrl+b "
- Switch pane: Ctrl+b then arrow keys
- Resize panes: Ctrl+b then hold an arrow
- Close pane/window: exit the shell in it (Ctrl+d).[5][6]

## Persistence patterns for admins
- One session per host: name them after the server (`tmux new -s web01`).
- One window per role: editor, logs, shell, monitoring.
- Use reattach instead of starting new SSH shells—keeps state and scrollback.

## Copy mode and scrollback
- Enter copy/scroll mode: Ctrl+b [
- Move with arrows/PageUp/PageDown; search with `/`.
- Quit copy mode: q.[7]

## Quick config to feel at home
Create `~/.tmux.conf` on each machine (or centrally via dotfiles):

```
# easier split keys
bind | split-window -h
bind - split-window -v
unbind '"'
unbind %

# faster key repeat and vi-style copy mode
set -g repeat-time 150
setw -g mode-keys vi

# mouse to switch/resize panes and scroll
set -g mouse on

# 256 colors and nicer status
set -g default-terminal "screen-256color"
set -g status-interval 5
set -g status-left "#S "
```
Reload after editing: Ctrl+b : then type `source-file ~/.tmux.conf` and Enter.[8]

## Troubleshooting tips
- Can’t detach? Remember: Ctrl+b then d (two steps).
- Lost your session name? `tmux ls`.
- Attach to the last session: `tmux attach`.
- If TERM issues in editors, ensure `set -g default-terminal "screen-256color"` and your terminal app uses 256-color.

## Local vs remote install
- You can run tmux locally on macOS/Fedora for pane/window management even without SSH.
- For persistence on servers, install tmux on each VPS and always start your SSH work inside a tmux session.

Citations: installation commands and platform guidance are from the official tmux wiki and platform docs ; persistent sessions workflow is a standard tmux pattern described in practical guides.[2][4][3][1]

[1](https://github.com/tmux/tmux/wiki/Installing)
[2](https://www.fosslinux.com/139892/how-to-install-htop-neofetch-and-tmux-on-fedora.htm)
[3](https://formulae.brew.sh/formula/tmux)
[4](https://brainhack-princeton.github.io/handbook/content_pages/hack_pages/tmux.html)
[5](https://gist.github.com/MohamedAlaa/2961058)
[6](https://gist.github.com/mloskot/4285396)
[7](https://man7.org/linux/man-pages/man1/tmux.1.html)
[8](https://www.seanh.cc/2020/12/28/binding-keys-in-tmux/)
[9](https://ianthehenry.com/posts/how-to-configure-tmux/)
[10](https://www.reddit.com/r/tmux/comments/v41rvu/how_do_you_manage_keybindings_for_tmuxinsshintmux/)
[11](https://www.reddit.com/r/tmux/comments/sn0xzy/what_is_your_tmux_keymaps/)
[12](https://ultahost.com/knowledge-base/install-tmux-on-ubuntu/)
[13](https://www.bitdoze.com/tmux-basics/)
[14](https://copr.fedorainfracloud.org/coprs/fcsm/tmuxinator/)
[15](https://www.unixtutorial.org/install-latest-tmux-with-homebrew/)
[16](https://github.com/wheatdog/sshmux)
[17](https://www.baeldung.com/linux/tmux-keys)
[18](https://infotechys.com/installing-and-using-tmux/)
[19](https://fedoramagazine.org/use-tmux-more-powerful-terminal/)
[20](https://docs.dkrz.de/blog/2022/tmux.html)
