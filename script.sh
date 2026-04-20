#!/usr/bin/env bash
# ============================================================
# mysql_clone_local - download a remote MySQL database and
# import it into a local MySQL database.
# ============================================================

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

SSH_HOST="${SSH_HOST:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_USER="${SSH_USER:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"

REMOTE_DB_HOST="${REMOTE_DB_HOST:-127.0.0.1}"
REMOTE_DB_PORT="${REMOTE_DB_PORT:-3306}"
REMOTE_DB_USER="${REMOTE_DB_USER:-}"
REMOTE_DB_PASS="${REMOTE_DB_PASS:-}"
REMOTE_DB_NAME="${REMOTE_DB_NAME:-}"

LOCAL_DB_HOST="${LOCAL_DB_HOST:-127.0.0.1}"
LOCAL_DB_PORT="${LOCAL_DB_PORT:-3306}"
LOCAL_DB_USER="${LOCAL_DB_USER:-}"
LOCAL_DB_PASS="${LOCAL_DB_PASS:-}"
LOCAL_DB_NAME="${LOCAL_DB_NAME:-}"

MODE="${MODE:-ssh-dump}"
TUNNEL_LOCAL_PORT="${TUNNEL_LOCAL_PORT:-3307}"
DUMP_DIR="${DUMP_DIR:-/tmp}"
KEEP_DUMP="${KEEP_DUMP:-false}"
YES="${YES:-false}"
INTERACTIVE="${INTERACTIVE:-auto}"
DROP_LOCAL_DB="${DROP_LOCAL_DB:-false}"

TUNNEL_PID=""
DUMP_FILE=""
MYSQL_DEFAULTS_FILE=""
TMP_FILES=()

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME [options]

Downloads a remote MySQL database over SSH and imports it locally.

Connection:
  --ssh-host HOST              SSH server host
  --ssh-port PORT              SSH port (default: 22)
  --ssh-user USER              SSH user
  --ssh-key PATH               SSH private key path
  --ssh-password PASSWORD      SSH password. Prefer prompt or SSH_PASSWORD env

Remote database:
  --remote-host HOST           Remote MySQL host as seen from SSH server (default: 127.0.0.1)
  --remote-port PORT           Remote MySQL port (default: 3306)
  --remote-user USER           Remote MySQL user
  --remote-password PASSWORD   Remote MySQL password. Prefer prompt or REMOTE_DB_PASS env
  --remote-db DB               Remote database name

Local database:
  --local-host HOST            Local MySQL host (default: 127.0.0.1)
  --local-port PORT            Local MySQL port (default: 3306)
  --local-user USER            Local MySQL user
  --local-password PASSWORD    Local MySQL password. Prefer prompt or LOCAL_DB_PASS env
  --local-db DB                Local database name

Behavior:
  --mode ssh-dump|tunnel       ssh-dump runs mysqldump on the remote server (default).
                               tunnel runs local mysqldump through an SSH tunnel.
  --tunnel-port PORT           Local tunnel port for --mode tunnel (default: 3307)
  --drop-local-db              Drop and recreate the local database before import
  --dump-dir DIR               Directory for temporary dumps (default: /tmp)
  --keep-dump                  Keep the compressed dump after import
  --yes                        Do not ask for destructive confirmation
  --interactive                Ask for missing values (default when attached to a TTY)
  --no-interactive             Fail if required values are missing
  -h, --help                   Show this help

Environment variables use the same uppercase names, for example SSH_HOST,
REMOTE_DB_NAME, LOCAL_DB_USER, MODE, KEEP_DUMP.

Examples:
  $SCRIPT_NAME --interactive
  SSH_HOST=example.com SSH_USER=deploy REMOTE_DB_NAME=app \\
    REMOTE_DB_USER=app REMOTE_DB_PASS=secret LOCAL_DB_NAME=app_local \\
    LOCAL_DB_USER=root LOCAL_DB_PASS=root $SCRIPT_NAME
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-host) SSH_HOST="${2:-}"; shift 2 ;;
        --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
        --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
        --ssh-key) SSH_KEY="${2:-}"; shift 2 ;;
        --ssh-password) SSH_PASSWORD="${2:-}"; shift 2 ;;
        --remote-host) REMOTE_DB_HOST="${2:-}"; shift 2 ;;
        --remote-port) REMOTE_DB_PORT="${2:-}"; shift 2 ;;
        --remote-user) REMOTE_DB_USER="${2:-}"; shift 2 ;;
        --remote-password) REMOTE_DB_PASS="${2:-}"; shift 2 ;;
        --remote-db) REMOTE_DB_NAME="${2:-}"; shift 2 ;;
        --local-host) LOCAL_DB_HOST="${2:-}"; shift 2 ;;
        --local-port) LOCAL_DB_PORT="${2:-}"; shift 2 ;;
        --local-user) LOCAL_DB_USER="${2:-}"; shift 2 ;;
        --local-password) LOCAL_DB_PASS="${2:-}"; shift 2 ;;
        --local-db) LOCAL_DB_NAME="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}"; shift 2 ;;
        --tunnel-port) TUNNEL_LOCAL_PORT="${2:-}"; shift 2 ;;
        --dump-dir) DUMP_DIR="${2:-}"; shift 2 ;;
        --keep-dump) KEEP_DUMP=true; shift ;;
        --drop-local-db) DROP_LOCAL_DB=true; shift ;;
        --yes|-y) YES=true; shift ;;
        --interactive) INTERACTIVE=true; shift ;;
        --no-interactive) INTERACTIVE=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1. Use --help." ;;
    esac
done

is_tty() { [[ -t 0 && -t 1 ]]; }

if [[ "$INTERACTIVE" == "auto" ]]; then
    if is_tty; then
        INTERACTIVE=true
    else
        INTERACTIVE=false
    fi
fi

prompt_value() {
    local var_name="$1"
    local label="$2"
    local default_value="${3:-}"
    local secret="${4:-false}"
    local current="${!var_name:-}"

    [[ -n "$current" ]] && return 0
    if [[ "$INTERACTIVE" != "true" && -n "$default_value" ]]; then
        printf -v "$var_name" '%s' "$default_value"
        return 0
    fi

    [[ "$INTERACTIVE" == "true" ]] || die "$label is required. Pass it as an option or environment variable."

    local prompt="$label"
    if [[ -n "$default_value" ]]; then
        prompt="$prompt [$default_value]"
    fi
    prompt="$prompt: "

    if [[ "$secret" == "true" ]]; then
        read -rsp "$prompt" current
        printf '\n'
    else
        read -rp "$prompt" current
    fi

    if [[ -z "$current" && -n "$default_value" ]]; then
        current="$default_value"
    fi

    printf -v "$var_name" '%s' "$current"
}

confirm() {
    local question="$1"
    [[ "$YES" == "true" ]] && return 0
    [[ "$INTERACTIVE" == "true" ]] || die "$question Use --yes to confirm in non-interactive mode."

    local answer=""
    read -rp "$question [y/N]: " answer
    [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command '$1' was not found."
}

mysql_identifier() {
    printf '%s' "$1" | sed 's/`/``/g'
}

mysql_defaults_file() {
    local host="$1"
    local port="$2"
    local user="$3"
    local password="$4"
    local file

    file="$(mktemp)"
    chmod 600 "$file"
    cat > "$file" <<EOF
[client]
host=$host
port=$port
user=$user
password=$password
EOF
    MYSQL_DEFAULTS_FILE="$file"
    TMP_FILES+=("$file")
}

ssh_base_command() {
    local -n out_ref=$1

    out_ref=(ssh -p "$SSH_PORT" -o ExitOnForwardFailure=yes)

    if [[ -n "$SSH_KEY" ]]; then
        out_ref+=(-i "$SSH_KEY")
    fi

    if [[ -n "$SSH_PASSWORD" ]]; then
        require_command sshpass
        out_ref=(sshpass -p "$SSH_PASSWORD" "${out_ref[@]}")
    fi

    out_ref+=("${SSH_USER}@${SSH_HOST}")
}

cleanup() {
    local exit_code=$?

    if [[ -n "$TUNNEL_PID" ]]; then
        log "Closing SSH tunnel..."
        kill "$TUNNEL_PID" >/dev/null 2>&1 || true
    fi

    if [[ -n "$DUMP_FILE" && -f "$DUMP_FILE" && "$KEEP_DUMP" != "true" ]]; then
        rm -f "$DUMP_FILE"
    fi

    for file in "${TMP_FILES[@]}"; do
        [[ -n "$file" ]] && rm -f "$file"
    done

    exit "$exit_code"
}
trap cleanup EXIT

validate_config() {
    case "$MODE" in
        ssh-dump|tunnel) ;;
        *) die "--mode must be either 'ssh-dump' or 'tunnel'." ;;
    esac

    prompt_value SSH_HOST "SSH host"
    prompt_value SSH_USER "SSH user"
    prompt_value SSH_PORT "SSH port" "$SSH_PORT"

    if [[ -z "$SSH_KEY" && -z "$SSH_PASSWORD" && "$INTERACTIVE" == "true" && "$MODE" == "tunnel" ]]; then
        log "Tunnel mode with SSH password requires sshpass. Leave password empty to use key or ssh-agent."
    fi

    if [[ -z "$SSH_KEY" && "$INTERACTIVE" == "true" ]]; then
        prompt_value SSH_PASSWORD "SSH password (leave empty to use ssh-agent or system prompt)" "" true
    fi

    prompt_value REMOTE_DB_HOST "Remote MySQL host" "$REMOTE_DB_HOST"
    prompt_value REMOTE_DB_PORT "Remote MySQL port" "$REMOTE_DB_PORT"
    prompt_value REMOTE_DB_USER "Remote MySQL user"
    prompt_value REMOTE_DB_PASS "Remote MySQL password" "" true
    prompt_value REMOTE_DB_NAME "Remote database name"

    prompt_value LOCAL_DB_HOST "Local MySQL host" "$LOCAL_DB_HOST"
    prompt_value LOCAL_DB_PORT "Local MySQL port" "$LOCAL_DB_PORT"
    prompt_value LOCAL_DB_USER "Local MySQL user"
    prompt_value LOCAL_DB_PASS "Local MySQL password" "" true
    prompt_value LOCAL_DB_NAME "Local database name" "$REMOTE_DB_NAME"

    [[ -d "$DUMP_DIR" ]] || die "Dump directory does not exist: $DUMP_DIR"
}

dump_via_ssh() {
    require_command ssh
    require_command gzip

    local ssh_cmd
    local remote_mysql
    ssh_base_command ssh_cmd

    remote_mysql="$(printf 'MYSQL_PWD=%q mysqldump -h %q -P %q -u %q --single-transaction --quick --lock-tables=false --routines --triggers %q' \
        "$REMOTE_DB_PASS" "$REMOTE_DB_HOST" "$REMOTE_DB_PORT" "$REMOTE_DB_USER" "$REMOTE_DB_NAME")"

    log "Downloading remote dump '${REMOTE_DB_NAME}' from ${SSH_HOST}..."
    "${ssh_cmd[@]}" "$remote_mysql" | gzip > "$DUMP_FILE"
}

dump_via_tunnel() {
    require_command ssh
    require_command mysqldump
    require_command gzip

    local ssh_cmd
    local remote_defaults
    ssh_base_command ssh_cmd

    log "Opening SSH tunnel ${TUNNEL_LOCAL_PORT} -> ${SSH_HOST}:${REMOTE_DB_HOST}:${REMOTE_DB_PORT}..."
    "${ssh_cmd[@]}" -L "${TUNNEL_LOCAL_PORT}:${REMOTE_DB_HOST}:${REMOTE_DB_PORT}" -N &
    TUNNEL_PID=$!
    sleep 2

    if ! kill -0 "$TUNNEL_PID" >/dev/null 2>&1; then
        die "SSH tunnel failed to start."
    fi

    mysql_defaults_file 127.0.0.1 "$TUNNEL_LOCAL_PORT" "$REMOTE_DB_USER" "$REMOTE_DB_PASS"
    remote_defaults="$MYSQL_DEFAULTS_FILE"
    log "Downloading remote dump '${REMOTE_DB_NAME}' through tunnel..."
    mysqldump \
        --defaults-extra-file="$remote_defaults" \
        --single-transaction \
        --quick \
        --lock-tables=false \
        --routines \
        --triggers \
        "$REMOTE_DB_NAME" | gzip > "$DUMP_FILE"
    rm -f "$remote_defaults"
}

prepare_local_db() {
    require_command mysql

    local local_defaults
    local local_db_sql
    local_db_sql="$(mysql_identifier "$LOCAL_DB_NAME")"
    mysql_defaults_file "$LOCAL_DB_HOST" "$LOCAL_DB_PORT" "$LOCAL_DB_USER" "$LOCAL_DB_PASS"
    local_defaults="$MYSQL_DEFAULTS_FILE"

    if [[ "$DROP_LOCAL_DB" == "true" ]]; then
        confirm "Drop and recreate local database '${LOCAL_DB_NAME}'?" || die "Canceled."
        log "Dropping local database '${LOCAL_DB_NAME}'..."
        mysql --defaults-extra-file="$local_defaults" \
            -e "DROP DATABASE IF EXISTS \`${local_db_sql}\`;"
    fi

    log "Creating local database '${LOCAL_DB_NAME}' if needed..."
    mysql --defaults-extra-file="$local_defaults" \
        -e "CREATE DATABASE IF NOT EXISTS \`${local_db_sql}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

    rm -f "$local_defaults"
}

import_local_dump() {
    require_command mysql
    require_command gzip

    local local_defaults
    mysql_defaults_file "$LOCAL_DB_HOST" "$LOCAL_DB_PORT" "$LOCAL_DB_USER" "$LOCAL_DB_PASS"
    local_defaults="$MYSQL_DEFAULTS_FILE"

    log "Importing dump into local database '${LOCAL_DB_NAME}'..."
    gzip -dc "$DUMP_FILE" | mysql --defaults-extra-file="$local_defaults" "$LOCAL_DB_NAME"

    rm -f "$local_defaults"
}

main() {
    validate_config

    local safe_name
    safe_name="$(printf '%s' "$REMOTE_DB_NAME" | tr -c '[:alnum:]_.-' '_')"
    DUMP_FILE="${DUMP_DIR}/${safe_name}_$(date +%Y%m%d_%H%M%S).sql.gz"

    if [[ "$MODE" == "ssh-dump" ]]; then
        dump_via_ssh
    else
        dump_via_tunnel
    fi

    [[ -s "$DUMP_FILE" ]] || die "Dump was not created or is empty: $DUMP_FILE"
    log "Dump saved: $DUMP_FILE ($(du -sh "$DUMP_FILE" | cut -f1))"

    prepare_local_db
    import_local_dump

    if [[ "$KEEP_DUMP" == "true" ]]; then
        log "Kept dump: $DUMP_FILE"
    fi

    log "Done. Local database '${LOCAL_DB_NAME}' has been updated."
}

main "$@"
