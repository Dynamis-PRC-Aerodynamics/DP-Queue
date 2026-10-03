#!/bin/bash
# Sets dpq up on this machine, from the folder this script is in.
#
#   bash install.sh
#
# It creates dpq.conf from dpq.conf.example (never overwrites an existing one),
# picks a random ntfy topic for the notifications and adds the "dpq" command
# to ~/.bashrc. Safe to run again after a git pull.

DPQ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$DPQ_DIR/dpq.conf"
BASHRC="$HOME/.bashrc"
ALIAS_LINE="alias dpq='bash \"$DPQ_DIR/dpq\"'"

is_wsl() { grep -qi microsoft /proc/version 2> /dev/null; }

echo "dpq folder: $DPQ_DIR"
echo

# ------------------------------ checks ----------------------------------
missing=""
for tool in flock setsid pgrep lscpu curl awk sed; do
    command -v "$tool" > /dev/null || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    echo "Missing commands:$missing"
    echo "Install them and run this script again (on Ubuntu: sudo apt install util-linux procps curl)."
    exit 1
fi
if grep -q $'\r' "$DPQ_DIR/dpq"; then
    echo "dpq has Windows line endings (CRLF). Convert it with: dos2unix \"$DPQ_DIR/dpq\""
    exit 1
fi

# --------------------------- configuration ------------------------------
if [ -f "$CONF" ]; then
    echo "Configuration: $CONF already exists, left as it is."
else
    cp "$DPQ_DIR/dpq.conf.example" "$CONF" || exit 1
    chmod 600 "$CONF"
    topic="dpq-$(hostname | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')-$(head -c 32 /dev/urandom | base32 | tr -d '=' | tr 'A-Z' 'a-z' | head -c 12)"
    sed -i "s|^NTFY_TOPIC=\"\"|NTFY_TOPIC=\"$topic\"|" "$CONF"
    if is_wsl; then
        sed -i 's|^NOTIFY_DESKTOP=1|NOTIFY_DESKTOP=0|' "$CONF"
    fi
    echo "Configuration: created $CONF"
fi

source "$CONF"

# ----------------------------- command ----------------------------------
if grep -Fqx "$ALIAS_LINE" "$BASHRC" 2> /dev/null; then
    echo "Command:       'dpq' is already in $BASHRC"
else
    if grep -q "^alias dpq=" "$BASHRC" 2> /dev/null; then
        sed -i '/^alias dpq=/d' "$BASHRC"
    fi
    echo "$ALIAS_LINE" >> "$BASHRC"
    echo "Command:       'dpq' added to $BASHRC (open a new terminal to use it)"
fi

# ------------------------------ summary ---------------------------------
echo
if [ -f "$FOAM_BASHRC" ]; then
    echo "OpenFOAM:      $FOAM_BASHRC"
else
    echo "OpenFOAM:      NOT FOUND at $FOAM_BASHRC"
    echo "               set FOAM_BASHRC in $CONF"
fi
if [ -d "$RUN_DIR" ]; then
    echo "Run folder:    $RUN_DIR"
else
    echo "Run folder:    NOT FOUND at $RUN_DIR"
    echo "               set RUN_DIR in $CONF"
fi
if [ -n "$NTFY_TOPIC" ]; then
    echo "ntfy topic:    $NTFY_TOPIC"
    echo
    echo "To receive the notifications: install the ntfy app on the phone,"
    echo "subscribe to the topic above, then run:  dpq test-notify"
else
    echo "ntfy topic:    none (set NTFY_TOPIC in $CONF to get push notifications)"
fi
is_wsl && echo && echo "WSL: keep one terminal open while the queue runs, and see the WSL notes in README.md."
exit 0
