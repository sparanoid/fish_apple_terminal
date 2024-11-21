# Save/restore fish state for macOS
# Inspired by /etc/bashrc_Apple_Terminal
# Sparanoid <t@sparanoid.com>
# https://github.com/sparanoid/fish_apple_terminal

# Ensure:
# - Terminal session ID exists, this can be absent when running fish from outside the Terminals
# - fish is interactive: https://github.com/fish-shell/fish-shell/issues/5058
if test -n "$TERM_SESSION_ID"; and status is-interactive

    # Dashes are invaid characters for fish history file, replace them with underscores
    set fish_session_id (string replace -a '-' _ $TERM_SESSION_ID)

    # Set fish history based on Terminal session ID
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
        cat $fish_session_history_shared >$fish_session_history
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

    # Update saved session state when exiting
    function fish_session_update
        fish_session_merge
    end
    trap fish_session_update EXIT
end
