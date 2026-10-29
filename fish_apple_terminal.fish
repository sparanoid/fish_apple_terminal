# Save/restore fish state for macOS
# Inspired by /etc/bashrc_Apple_Terminal
# Sparanoid <t@sparanoid.com>
# https://github.com/sparanoid/fish_apple_terminal

# Terminal session ID, which the terminal hands back to the new shell when it restores a tab/pane
# after a relaunch:
# - Apple Terminal: `TERM_SESSION_ID`
# - Orca: `ORCA_PANE_KEY` (`<tab-id>:<pane-id>`), saved with the pane layout
# - VS Code: has none, but revives a terminal with the launch options it saved, so its shell
#   integration nonce `VSCODE_NONCE` stays the same. VS Code hides the nonce from child processes
#   and `fish_history` is exported, so use a hash of it (fed via stdin to keep it out of `ps`)
# Pick by `TERM_PROGRAM`, which each terminal sets for its own shells, since the other variables can
# be inherited from wherever the terminal app itself was launched.
set -l fish_session_key
switch "$TERM_PROGRAM"
    case Orca
        set fish_session_key $ORCA_PANE_KEY
    case vscode
        test -n "$VSCODE_NONCE"; and set fish_session_key vscode_(printf %s $VSCODE_NONCE | /sbin/md5 -q)
    case '*'
        set fish_session_key $TERM_SESSION_ID
end

# An empty `fish_history` means history isn't saved at all (`fish --private` sets it, too), so
# leave such shells alone
set -q fish_history; and test -z "$fish_history"; and set fish_session_key

# Ensure:
# - Terminal session ID exists, this can be absent when running fish from outside the Terminals
# - fish is interactive: https://github.com/fish-shell/fish-shell/issues/5058
if test -n "$fish_session_key"; and status is-interactive

    # Only alphanumerics and underscores are valid in a fish history session name, replace the
    # rest (dashes, and the colon in Orca's key) with underscores
    set fish_session_id (string replace -ra '[^A-Za-z0-9_]' _ $fish_session_key)

    # Set fish history based on Terminal session ID. In Orca this also replaces the per-worktree
    # `orca_<hash>` history that Orca assigns to new panes
    set -x fish_history $fish_session_id

    # Check if session history available
    # Latest `fish_history` does not support changing the location of history file while the old
    # `FISH_HISTFILE` does, so just stick with it and store then under `XDG_DATA_HOME/fish/`
    # (typically `~/.local/share/fish/`).
    # Ref: https://github.com/fish-shell/fish-shell/issues/102
    set fish_session_timestamp (date +%s)
    set fish_session_base "$HOME/.local/share/fish"
    set fish_session_history "$fish_session_base/$fish_session_id"_history
    set fish_session_history_shared "$fish_session_base/fish_history"
    set fish_session_store "$fish_session_base/$fish_session_id"_session

    # How long to keep per-session `*_history`/`*_session` files before pruning
    # them. Uses `find -mtime` syntax: `d` = days, `w` = weeks (note that `m`
    # means MINUTES, not months). 26w is roughly half a year. Set this variable
    # before sourcing this file to override the default.
    set -q fish_session_expiration_age; or set fish_session_expiration_age +26w
    set fish_session_expiration_check "$fish_session_base/_expiration_check_timestamp"
    set fish_session_expiration_lock "$fish_session_base/_expiration_lockfile"

    function fish_session_start --on-event fish_prompt
        if test ! -s "$fish_session_store"
            echo Session start $fish_session_timestamp
            umask 077
            echo $fish_session_timestamp >$fish_session_store
            echo Set session start time to $fish_session_timestamp (date -r $fish_session_timestamp)
        end
    end

    # If session file exists, load it, otherwise merge from shared history
    if test -s "$fish_session_history"
        echo Restoring session history from $fish_session_id
    else
        echo Merging shared history to $fish_session_id
        umask 077
        # Clone (APFS copy-on-write) instead of copying, so a new session doesn't take up another
        # full copy of the shared history until fish rewrites the file (about every 25 commands;
        # it appends otherwise). This matters in Orca, where every agent tab is a new session
        /bin/cp -c $fish_session_history_shared $fish_session_history
    end

    function fish_session_merge
        # Debug
        # echo Searching from $fish_session_timestamp
        # echo Searching file $fish_session_history

        # Select all history since session start
        # https://stackoverflow.com/a/39367026/412385
        set fish_session_history_slice_find (awk -F '  when: ' -v from="$fish_session_timestamp" '{if ($2 > from) seen=1} seen {print NR; exit}' < $fish_session_history | string trim)

        if test -n "$fish_session_history_slice_find"
            echo Got history slice from line $fish_session_history_slice_find
            set fish_session_history_slice_from (math $fish_session_history_slice_find - 1)

            if test -n "$fish_session_history_slice_from"
                echo Writing history from $fish_session_history to $fish_session_history_shared
                # https://fishshell.com/docs/current/commands.html#string-split0
                set fish_session_history_slice (tail -n +$fish_session_history_slice_from $fish_session_history | string split0 )
                umask 077
                echo $fish_session_history_slice >>$fish_session_history_shared
            end
        end
    end

    # Delete old session files, but not more than once a day.
    # Ported from `shell_session_delete_expired` in /etc/zshrc_Apple_Terminal.
    # Note: zsh keeps its session files in a dedicated `~/.zsh_sessions/`, but ours
    # live next to the shared `fish_history`, so the find is scoped to the per-
    # session `*_history`/`*_session` files and explicitly spares `fish_history`.
    # Absolute paths are used because PATH (or a `find`->`bfs` alias) may differ
    # by the time this runs at shell exit.
    function fish_session_delete_expired
        # Throttle: skip if we already checked within the last day.
        set fish_session_expiration_recent (/usr/bin/find "$fish_session_expiration_check" -mtime -1d 2>/dev/null)
        if test -e "$fish_session_expiration_check"; and test -n "$fish_session_expiration_recent"
            return
        end

        # Take a PID-aware lock so concurrent shell exits don't collide.
        if /usr/bin/shlock -f "$fish_session_expiration_lock" -p $fish_pid
            echo -n 'Deleting expired sessions...'

            # Enumerate the expired per-session files once so we can size them before
            # deleting (macOS `find` has no GNU `-printf`, so measure with `du`).
            set fish_session_expired (/usr/bin/find "$fish_session_base" -type f '(' -name '*_history' -o -name '*_session' ')' '!' -name 'fish_history' -mtime $fish_session_expiration_age)
            set fish_session_expired_count (count $fish_session_expired)

            if test $fish_session_expired_count -gt 0
                set fish_session_expired_size (/usr/bin/du -ch $fish_session_expired | /usr/bin/tail -1 | awk '{print $1}')
                /bin/rm -f $fish_session_expired
                set fish_session_kept_count (/usr/bin/find "$fish_session_base" -type f '(' -name '*_history' -o -name '*_session' ')' '!' -name 'fish_history' | /usr/bin/wc -l | string trim)
                echo "$fish_session_expired_count removed ($fish_session_expired_size freed), $fish_session_kept_count kept."
            else
                echo 'none found.'
            end
            umask 077
            /usr/bin/touch "$fish_session_expiration_check"
            /bin/rm "$fish_session_expiration_lock"
        end
    end

    # Update saved session state when exiting
    function fish_session_update
        fish_session_merge
        fish_session_delete_expired
    end
    trap fish_session_update EXIT
end
