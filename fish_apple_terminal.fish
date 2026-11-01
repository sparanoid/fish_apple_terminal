# Save/restore fish state for macOS
# Inspired by /etc/bashrc_Apple_Terminal
# Sparanoid <t@sparanoid.com>
# https://github.com/sparanoid/fish_apple_terminal

# Ensure fish is interactive: https://github.com/fish-shell/fish-shell/issues/5058
status is-interactive; or return 0

# Leave shells alone when history isn't saved:
# - `fish --private` (`fish_private_mode`, even if an exported `fish_history` was inherited)
# - an explicitly empty `fish_history`
# - VS Code AI/task terminals (`VSCODE_PREVENT_SHELL_HISTORY=1`, which `shellIntegration.fish`
#   converts to `fish_private_mode` only in `--init-command`, after `conf.d` has already run)
test -n "$fish_private_mode"; and return 0
set -q fish_history; and test -z "$fish_history"; and return 0
test "$VSCODE_PREVENT_SHELL_HISTORY" = 1; and return 0

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

# `fish` is the shared history's own session name, so it can't name a session of its own
test "$fish_session_key" = fish; and set fish_session_key

# Ensure terminal session ID exists (absent when running fish outside supported terminals)
if test -n "$fish_session_key"

    # Only alphanumerics and underscores are valid in a fish history session name, replace the
    # rest (dashes, and the colon in Orca's key) with underscores
    set -g fish_session_id (string replace -ra '[^A-Za-z0-9_]' _ $fish_session_key)

    # Set fish history based on Terminal session ID. In Orca this also replaces the per-worktree
    # `orca_<hash>` history that Orca assigns to new panes
    set -gx fish_history $fish_session_id

    # Check if session history available
    # Latest `fish_history` does not support changing the location of history file while the old
    # `FISH_HISTFILE` does, so just stick with it and store then under `XDG_DATA_HOME/fish/`
    # (typically `~/.local/share/fish/`).
    # Ref: https://github.com/fish-shell/fish-shell/issues/102
    set -g fish_session_timestamp (/bin/date +%s)
    set -g fish_session_base "$HOME/.local/share/fish"
    set -g fish_session_history "$fish_session_base/$fish_session_id"_history
    set -g fish_session_history_shared "$fish_session_base/fish_history"
    set -g fish_session_history_lock "$fish_session_base/_history_lockfile"
    set -g fish_session_store "$fish_session_base/$fish_session_id"_session
    set -g fish_session_dirty 0

    # How long to keep per-session `*_history`/`*_session` files before pruning
    # them. Uses `find -mtime` syntax: `d` = days, `w` = weeks (note that `m`
    # means MINUTES, not months). 26w is roughly half a year. Set this variable
    # before sourcing this file to override the default.
    set -q fish_session_expiration_age; or set -g fish_session_expiration_age +26w
    set -g fish_session_expiration_check "$fish_session_base/_expiration_check_timestamp"
    set -g fish_session_expiration_lock "$fish_session_base/_expiration_lockfile"

    function fish_session_start --on-event fish_prompt
        functions -e fish_session_start
        if test ! -s "$fish_session_store"
            echo Session start $fish_session_timestamp
            umask 077
            echo $fish_session_timestamp >"$fish_session_store"
            echo Set session start time to $fish_session_timestamp (/bin/date -r $fish_session_timestamp)
        end
    end

    # Track whether any non-private command actually executed in this shell so
    # zero-command sessions exit immediately without scanning or locking history.
    function fish_session_mark_dirty --on-event fish_preexec
        test -n "$fish_private_mode"; and return
        set -g fish_session_dirty 1
        functions -e fish_session_mark_dirty
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
        if test -e "$fish_session_history_shared"
            /bin/cp -c "$fish_session_history_shared" "$fish_session_history" 2>/dev/null
            or /bin/cp "$fish_session_history_shared" "$fish_session_history"
        end
        # Mark the session as ours right away (`fish_session_start` fills it in at the first
        # prompt), so expiry can tell it apart from other named histories even without a prompt
        /usr/bin/touch "$fish_session_store"
    end

    # Acquire/release a PID-aware lock around `fish_history` reads/writes so concurrent
    # exiting tabs never interleave lines or race with compaction. Retries >1s so
    # `shlock` can also break a stale lock left behind in the previous second.
    function fish_session_lock_history
        set -l tries 0
        while test $tries -lt 25
            /usr/bin/shlock -f "$fish_session_history_lock" -p $fish_pid; and return 0
            set tries (math $tries + 1)
            /bin/sleep 0.05
        end
        return 1
    end

    function fish_session_unlock_history
        /bin/rm -f "$fish_session_history_lock"
    end

    # Stream validated `- cmd:` blocks from `$argv[1]` starting at timestamp `$argv[2]`.
    # When `$argv[3]` is 1, deduplicate by command (preserving earliest `added_when` and
    # latest `paths`). Never loads history text into a fish variable or `echo` (which
    # triggers O(N^2) buffer shifting on large strings in fish).
    function fish_session_scan_history
        set -l file $argv[1]
        set -l from $argv[2]
        set -l dedup $argv[3]
        set -l until (math (/bin/date +%s) + 60)

        /usr/bin/awk -v min_ts=946684800 -v from="$from" -v until="$until" -v dedup="$dedup" '
            BEGIN {
                min_ts += 0
                from += 0
                until += 0
                dedup += 0
                low = (from > min_ts) ? from : min_ts
            }
            function emit_block(c, w_num, w_str, fw_num, fw_str, p_str) {
                printf "%s\n  when: %s\n", c, w_str
                if (fw_num < w_num) {
                    printf "  added_when: %s\n", fw_str
                }
                if (p_str != "") {
                    printf "%s", p_str
                }
            }
            function finish_block() {
                if (!in_block || !valid || (in_paths && !has_path) || when < low || when > until) return
                earliest = (added_when >= min_ts && added_when < when) ? added_when : when
                earliest_str = (added_when >= min_ts && added_when < when) ? added_when_str : when_str
                p_out = in_paths ? paths : ""
                if (!dedup) {
                    emit_block(cmd, when, when_str, earliest, earliest_str, p_out)
                    return
                }
                if (!(cmd in best_idx)) {
                    n++
                    cmds[n] = cmd
                    best_idx[cmd] = n
                    best_when[cmd] = when
                    best_when_str[cmd] = when_str
                    first_when[cmd] = earliest
                    first_when_str[cmd] = earliest_str
                    best_paths[cmd] = p_out
                } else {
                    if (earliest < first_when[cmd]) {
                        first_when[cmd] = earliest
                        first_when_str[cmd] = earliest_str
                    }
                    if (when >= best_when[cmd]) {
                        delete cmds[best_idx[cmd]]
                        n++
                        cmds[n] = cmd
                        best_idx[cmd] = n
                        best_when[cmd] = when
                        best_when_str[cmd] = when_str
                        best_paths[cmd] = p_out
                    }
                }
            }
            /^- cmd: / {
                finish_block()
                in_block = 1
                cmd = $0
                when = -1
                when_str = ""
                added_when = -1
                added_when_str = ""
                paths = ""
                in_paths = 0
                has_path = 0
                valid = 1
                next
            }
            !in_block || $0 == "" { next }
            /^  when: [0-9]+$/ && !in_paths && when < 0 {
                when_str = substr($0, 9)
                when = when_str + 0
                if (when < low || when > until) {
                    in_block = 0
                }
                next
            }
            /^  added_when: [0-9]+$/ && !in_paths && added_when < 0 {
                added_when_str = substr($0, 15)
                added_when = added_when_str + 0
                next
            }
            /^  paths:$/ && !in_paths && paths == "" {
                in_paths = 1
                paths = $0 "\n"
                next
            }
            /^    - / && in_paths {
                has_path = 1
                paths = paths $0 "\n"
                next
            }
            {
                valid = 0
                in_block = 0
            }
            END {
                finish_block()
                if (dedup) {
                    for (i = 1; i <= n; i++) {
                        if (i in cmds) {
                            c = cmds[i]
                            emit_block(c, best_when[c], best_when_str[c], first_when[c], first_when_str[c], best_paths[c])
                        }
                    }
                }
            }
        ' "$file"
    end

    function fish_session_merge
        test "$fish_session_dirty" = 1; or return
        test -n "$fish_private_mode"; and return
        test -s "$fish_session_history"; or return

        umask 077
        set -l tmp (/usr/bin/mktemp "$fish_session_base/.fish_history_merge.XXXXXX"); or return

        fish_session_scan_history "$fish_session_history" "$fish_session_timestamp" 0 >"$tmp"

        if test $status -eq 0; and test -s "$tmp"
            if fish_session_lock_history
                echo Writing history from $fish_session_history to $fish_session_history_shared
                umask 077
                if test -s "$fish_session_history_shared"
                    if not /usr/bin/tail -c 1 "$fish_session_history_shared" | builtin count >/dev/null
                        printf '\n' >>"$fish_session_history_shared"
                    end
                end
                /bin/cat "$tmp" >>"$fish_session_history_shared"
                fish_session_unlock_history
            end
        end
        /bin/rm -f "$tmp"
    end

    # Deduplicate and sanitize the shared `fish_history` file. Because interactive
    # sessions point `fish_history` at per-session files, fish itself rarely
    # compacts the shared `fish_history`.
    function fish_session_compact_shared
        test -s "$fish_session_history_shared"; or return

        umask 077
        set -l tmp (/usr/bin/mktemp "$fish_session_base/.fish_history_compact.XXXXXX"); or return

        if fish_session_lock_history
            if fish_session_scan_history "$fish_session_history_shared" 0 1 >"$tmp"
                if test -s "$tmp"; and not /usr/bin/cmp -s "$tmp" "$fish_session_history_shared"
                    /bin/mv "$tmp" "$fish_session_history_shared"
                end
            end
            fish_session_unlock_history
        end
        /bin/rm -f "$tmp"
    end

    # Delete old sessions, and compact `fish_history`, at most once a day.
    # Ported from `shell_session_delete_expired` in /etc/zshrc_Apple_Terminal.
    # Note: zsh keeps its session files in a dedicated `~/.zsh_sessions/`, but ours
    # live next to the shared `fish_history` and other named histories (like Orca's
    # `orca_<hash>_history`). Only this script writes `*_session` files, so only
    # sessions that have one are ours to delete, and `fish_history` is always spared.
    # Absolute paths are used because PATH (or a `find`->`bfs` alias) may differ
    # by the time this runs at shell exit.
    function fish_session_delete_expired
        # Throttle: skip if we already checked within the last day.
        set -l check_age (builtin path mtime -R "$fish_session_expiration_check" 2>/dev/null)
        if test -n "$check_age"; and test "$check_age" -lt 86400
            return
        end

        # Take a PID-aware lock so concurrent shell exits don't collide.
        if /usr/bin/shlock -f "$fish_session_expiration_lock" -p $fish_pid
            echo -n 'Deleting expired sessions...'

            # Enumerate the expired sessions once so we can size them before deleting
            # (macOS `find` has no GNU `-printf`, so measure with `du`). A session has
            # expired once its marker and its history, if it still has one, are both old.
            set -l fish_session_old (/usr/bin/find "$fish_session_base" -maxdepth 1 -type f '(' -name '*_history' -o -name '*_session' ')' '!' -name 'fish_history' -mtime $fish_session_expiration_age)
            set -l fish_session_expired
            set -l fish_session_expired_count 0
            for fish_session_old_store in $fish_session_old
                string match -q -- '*_session' $fish_session_old_store; or continue
                set -l fish_session_old_history (string replace -r -- '_session$' _history $fish_session_old_store)
                if contains -- $fish_session_old_history $fish_session_old; or not test -e $fish_session_old_history
                    set -a fish_session_expired $fish_session_old_store
                    test -e $fish_session_old_history; and set -a fish_session_expired $fish_session_old_history
                    set fish_session_expired_count (math $fish_session_expired_count + 1)
                end
            end

            if test $fish_session_expired_count -gt 0
                set -l fish_session_expired_size (/usr/bin/du -ch $fish_session_expired | /usr/bin/tail -1 | /usr/bin/awk '{print $1}')
                /bin/rm -f $fish_session_expired
                set -l fish_session_kept "$fish_session_base"/*_session
                set -l fish_session_kept_count (builtin path filter -f -- $fish_session_kept | builtin count)
                echo "$fish_session_expired_count removed ($fish_session_expired_size freed), $fish_session_kept_count kept."
            else
                echo 'none found.'
            end

            fish_session_compact_shared

            umask 077
            /usr/bin/touch "$fish_session_expiration_check"
            /bin/rm -f "$fish_session_expiration_lock"
        end
    end

    # Update saved session state when exiting
    function fish_session_update
        fish_session_merge
        fish_session_delete_expired
    end
    trap fish_session_update EXIT
end
