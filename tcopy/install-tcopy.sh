#!/bin/sh
# install-tcopy.sh - install or atomically replace /usr/local/bin/tcopy
# Usage: sudo sh install-tcopy.sh
set -eu

# Runs as root: never trust the caller's PATH, locale or shell startup vars,
# regardless of whether sudo is configured with secure_path.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
unset CDPATH ENV BASH_ENV
IFS='
	 '

DEST=/usr/local/bin/tcopy
DIR=${DEST%/*}

die() { printf 'install-tcopy: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -d "$DIR" ] || mkdir -p "$DIR"
# -d follows symlinks: refuse a directory or a link to one, since mv would
# move the new file into it instead of replacing it.
[ ! -d "$DEST" ] || die "$DEST is a directory or a link to one"

# Build the new file in the destination directory so the final mv is a
# same-filesystem rename(2): the old tcopy stays intact until that moment.
umask 077
TMP=$(mktemp "$DIR/.tcopy.XXXXXX")
trap 'rm -f "$TMP"' EXIT
trap 'exit 1' HUP INT TERM

cat > "$TMP" <<'TCOPY_EOF'
#!/bin/sh
# tcopy - send a file or stdin to the local terminal clipboard via OSC 52
#
# Usage: tcopy [--no-limit] [--] [file]     (no file: read stdin)
#
#   TCOPY_MAX=N   limit in base64-encoded bytes (default 65536, max 1048576)
#   --no-limit    lift the 1 MiB hard cap; without TCOPY_MAX, no limit at all
set -eu

# Trusted environment: tools come only from system directories (this also
# matters under "sudo tcopy"), and pattern/character handling is byte-wise.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL
unset CDPATH ENV BASH_ENV

DEFAULT_MAX=65536    # default limit, in base64-encoded bytes
HARD_MAX=1048576     # 1 MiB encoded; OSC 52 is not meant for more than this

die() { printf 'tcopy: %s\n' "$1" >&2; exit 1; }
usage() { printf 'Usage: tcopy [--no-limit] [--] [file]   (no file: read stdin)\n' >&2; exit 1; }

NO_LIMIT=0
while [ "$#" -gt 0 ]; do
    case $1 in
        --no-limit) NO_LIMIT=1; shift ;;
        --)         shift; break ;;
        -?*)        usage ;;
        *)          break ;;
    esac
done
[ "$#" -le 1 ] || usage

# MAX is empty when there is no limit at all.
if [ -n "${TCOPY_MAX:-}" ]; then
    MAX=$TCOPY_MAX
elif [ "$NO_LIMIT" -eq 1 ]; then
    MAX=
else
    MAX=$DEFAULT_MAX
fi

if [ -n "$MAX" ]; then
    case $MAX in
        *[!0123456789]*) die "TCOPY_MAX must be a positive integer" ;;
        0*)              die "TCOPY_MAX must not start with 0" ;;
    esac
    if [ "$NO_LIMIT" -eq 1 ]; then
        # At most 9 digits keeps every value and RAW_MAX+1 below 2^31,
        # so it is safe even where shell arithmetic is only 32-bit.
        [ "${#MAX}" -le 9 ] || die "TCOPY_MAX must be at most 999999999"
    else
        { [ "${#MAX}" -le 7 ] && [ "$MAX" -le "$HARD_MAX" ]; } ||
            die "TCOPY_MAX must be at most $HARD_MAX (use --no-limit to lift this cap)"
    fi
    [ "$MAX" -ge 4 ] || die "TCOPY_MAX must be at least 4"
    # Largest raw input whose padded base64 encoding fits within MAX.
    RAW_MAX=$(( MAX / 4 * 3 ))
fi

# Read at most $1 bytes from stdin.
# head -c reads in large blocks and never stops early on a pipe.
# dd bs=1 is the strict-POSIX fallback. A larger dd block size is not safe:
# short reads on a pipe would silently truncate the data.
if head -c 1 </dev/null >/dev/null 2>&1; then
    bounded_read() { head -c "$1"; }
else
    bounded_read() { dd bs=1 count="$1" 2>/dev/null; }
fi

# File names are never printed: they may contain terminal control bytes.
if [ "$#" -eq 1 ]; then
    [ -f "$1" ] || die "not found or not a regular file"
    # Open once; everything below reads from this descriptor only.
    { command exec 3< "$1"; } 2>/dev/null || die "cannot read file"
else
    [ -t 0 ] && usage
    exec 3<&0
fi

if [ -n "$MAX" ]; then
    read_input() { bounded_read $(( RAW_MAX + 1 )) <&3; }
else
    read_input() { cat <&3; }
fi

# POSIX sh has no pipefail, so every stage reports its own failure.
# A failing stage writes '!' straight to the command substitution (fd 4).
# '!' is not in the base64 alphabet, so it can never be mistaken for data,
# and wherever it lands in the output the result is rejected.
DATA=$(
    {
        { read_input || printf '!' >&4; } |
        { base64     || printf '!' >&4; } |
        { tr -d '\n' || printf '!' >&4; }
    } 4>&1
)
exec 3<&-

case $DATA in
    *'!'*) die "reading or encoding the input failed, nothing sent" ;;
esac
LEN=${#DATA}

[ "$LEN" -gt 0 ] || die "empty input, nothing sent"
if [ -n "$MAX" ] && [ "$LEN" -gt "$MAX" ]; then
    die "input too large (limit $RAW_MAX bytes; TCOPY_MAX=$MAX encoded)"
fi

if ! { printf '\033]52;c;%s\a' "$DATA" > /dev/tty; } 2>/dev/null; then
    die "cannot write to /dev/tty"
fi

printf 'tcopy: OSC 52 sequence sent (%s encoded bytes); clipboard update depends on the terminal\n' \
    "$LEN" >&2
TCOPY_EOF

sh -n "$TMP" || die "embedded script has a syntax error"
chown 0:0 "$TMP"
chmod 0755 "$TMP"

if [ -e "$DEST" ] || [ -L "$DEST" ]; then ACTION=Replaced; else ACTION=Installed; fi

# rename(2) replaces an existing file or symlink itself, never its target.
mv -f "$TMP" "$DEST"
trap - EXIT

printf 'install-tcopy: %s %s\n' "$ACTION" "$DEST"
