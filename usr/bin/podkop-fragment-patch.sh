#!/bin/sh

. /lib/functions.sh

config_load podkop-fragment
config_get ENABLED settings enabled 1
config_get FRAGMENT settings fragment false
config_get RECORD_FRAGMENT settings record_fragment true
config_get FALLBACK_DELAY settings fragment_fallback_delay '500ms'
config_get SINGBOX_CONFIG settings singbox_config '/etc/sing-box/config.json'
config_get LOG_FILE settings log_file '/var/log/podkop-fragment.log'
config_get LOG_MAX_LINES settings log_max_lines 200

log_msg() {
	local msg
	msg="$(date '+%H:%M:%S %d.%m.%Y') $1"
	printf '%s\n' "$msg" >> "$LOG_FILE"
}

truncate_log() {
	if [ -f "$LOG_FILE" ]; then
		local lines
		case "$LOG_MAX_LINES" in ''|*[!0-9]*) return 1 ;; esac
		lines="$(wc -l < "$LOG_FILE")" || return 1
		if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
			LOG_TMP="$(mktemp "${LOG_FILE}.pt-fragment.XXXXXX")" || return 1
			tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$LOG_TMP" || return 1
			mv -f "$LOG_TMP" "$LOG_FILE" || return 1
			LOG_TMP=''
		fi
	fi
}

# Only this process may remove its lock and its uniquely allocated files. A stale
# lock is an error for administrator inspection, never a reason to steal it.
LOCK_DIR='/var/lock/podkop-fragment.lock'
LOCK_HELD=0
SOURCE_TMP=''
CANDIDATE_TMP=''
BACKUP_TMP=''
LOG_TMP=''
cleanup() {
	[ -z "$SOURCE_TMP" ] || rm -f "$SOURCE_TMP"
	[ -z "$CANDIDATE_TMP" ] || rm -f "$CANDIDATE_TMP"
	[ -z "$BACKUP_TMP" ] || rm -f "$BACKUP_TMP"
	[ -z "$LOG_TMP" ] || rm -f "$LOG_TMP"
	if [ "$LOCK_HELD" = 1 ]; then
		rmdir "$LOCK_DIR"
	fi
}

file_hash() {
	local value
	value="$(sha256sum < "$1")" || return 1
	value="${value%% *}"
	case "$value" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
	[ "${#value}" = 64 ] || return 1
	printf '%s\n' "$value"
}

same_file() {
	local left right
	if command -v cmp >/dev/null 2>&1; then
		cmp -s "$1" "$2"
	else
		left="$(file_hash "$1")" && right="$(file_hash "$2")" && [ "$left" = "$right" ]
	fi
}

valid_json() {
	[ -s "$1" ] && jq -e -s 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null 2>&1
}

if [ "$ENABLED" = "0" ]; then
	exit 0
fi

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077
if mkdir "$LOCK_DIR" 2>/dev/null; then
	LOCK_HELD=1
else
	log_msg "ERROR: fragment patch lock busy or unavailable: $LOCK_DIR"
	exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
	log_msg "ERROR: sha256sum is required to guard config publication"
	exit 1
fi
if [ ! -f "$SINGBOX_CONFIG" ] || [ ! -s "$SINGBOX_CONFIG" ] || [ -L "$SINGBOX_CONFIG" ]; then
	log_msg "ERROR: config must be a nonempty regular file: $SINGBOX_CONFIG"
	exit 1
fi

WAIT=0
MAX_WAIT=30
while [ $WAIT -lt $MAX_WAIT ]; do
	if pidof sing-box >/dev/null 2>&1; then
		break
	fi
	WAIT=$((WAIT + 1))
	sleep 1
done

if [ $WAIT -eq $MAX_WAIT ]; then
	log_msg "ERROR: sing-box not started after ${MAX_WAIT}s, aborting"
	exit 1
fi

SOURCE_TMP="$(mktemp "${SINGBOX_CONFIG}.pt-fragment-source.XXXXXX")" || exit 1
if ! cp -p "$SINGBOX_CONFIG" "$SOURCE_TMP" || ! valid_json "$SOURCE_TMP" || ! same_file "$SINGBOX_CONFIG" "$SOURCE_TMP"; then
	log_msg "ERROR: config snapshot failed, is invalid JSON or changed while reading"
	exit 1
fi
if ! sing-box check -c "$SOURCE_TMP" </dev/null >/dev/null 2>&1; then
	log_msg "ERROR: source config failed sing-box check; live config and previous backup kept"
	exit 1
fi

if [ "$FRAGMENT" = "true" ] && [ "$RECORD_FRAGMENT" = "true" ]; then
	PATCHED_FILTER='[.outbounds[] | select(.tls.enabled == true and .tls.fragment == true and .tls.record_fragment == true)] | length > 0'
elif [ "$FRAGMENT" = "true" ]; then
	PATCHED_FILTER='[.outbounds[] | select(.tls.enabled == true and .tls.fragment == true)] | length > 0'
elif [ "$RECORD_FRAGMENT" = "true" ]; then
	PATCHED_FILTER='[.outbounds[] | select(.tls.enabled == true and .tls.record_fragment == true and .tls.fragment != true)] | length > 0'
else
	log_msg "INFO: both fragment and record_fragment disabled, skipping"
	exit 0
fi

jq -e "$PATCHED_FILTER" "$SOURCE_TMP" >/dev/null 2>&1
case "$?" in
	0) log_msg "INFO: config already patched, skipping"; exit 0 ;;
	1) : ;;
	*) log_msg "ERROR: jq could not inspect fragment settings"; exit 1 ;;
esac

log_msg "INFO: patching $SINGBOX_CONFIG (fragment=$FRAGMENT, record_fragment=$RECORD_FRAGMENT, fallback_delay=$FALLBACK_DELAY)"

CANDIDATE_TMP="$(mktemp "${SINGBOX_CONFIG}.pt-fragment-candidate.XXXXXX")" || exit 1
if ! cp -p "$SOURCE_TMP" "$CANDIDATE_TMP"; then
	log_msg "ERROR: could not prepare candidate permissions/content"
	exit 1
fi

if [ "$FRAGMENT" = "true" ]; then
	jq --arg f "$FRAGMENT" --arg rf "$RECORD_FRAGMENT" --arg fd "$FALLBACK_DELAY" \
		'(.outbounds[] | select(.tls.enabled == true) | .tls) |= . + {"fragment": ($f == "true"), "record_fragment": ($rf == "true"), "fragment_fallback_delay": $fd}' \
		"$SOURCE_TMP" > "$CANDIDATE_TMP"
else
	jq --arg f "$FRAGMENT" --arg rf "$RECORD_FRAGMENT" \
		'(.outbounds[] | select(.tls.enabled == true) | .tls) |= . + {"fragment": ($f == "true"), "record_fragment": ($rf == "true")} | (.outbounds[] | select(.tls.enabled == true) | .tls) |= del(.fragment_fallback_delay)' \
		"$SOURCE_TMP" > "$CANDIDATE_TMP"
fi
JQ_STATUS=$?

if [ "$JQ_STATUS" != 0 ] || ! valid_json "$CANDIDATE_TMP"; then
	log_msg "ERROR: jq failed or produced an empty/invalid candidate; live config kept"
	exit 1
fi
if ! sing-box check -c "$CANDIDATE_TMP" </dev/null >/dev/null 2>&1; then
	log_msg "ERROR: sing-box check failed for candidate; live config kept"
	exit 1
fi
PUBLISHED_HASH="$(file_hash "$CANDIDATE_TMP")" || exit 1
if ! same_file "$SINGBOX_CONFIG" "$SOURCE_TMP"; then
	log_msg "ERROR: config changed while preparing patch; live config kept"
	exit 1
fi

# Keep the previous config as a checked, atomic backup. Never touch the editor's
# .auto-backup, and never truncate either the live config or an existing .bak.
BACKUP="${SINGBOX_CONFIG}.bak"
if [ -L "$BACKUP" ] || { [ -e "$BACKUP" ] && [ ! -f "$BACKUP" ]; }; then
	log_msg "ERROR: backup destination is not a regular file: $BACKUP"
	exit 1
fi
BACKUP_TMP="$(mktemp "${SINGBOX_CONFIG}.pt-fragment-backup.XXXXXX")" || exit 1
if ! cp -p "$SOURCE_TMP" "$BACKUP_TMP" || ! same_file "$SOURCE_TMP" "$BACKUP_TMP" || ! mv -f "$BACKUP_TMP" "$BACKUP"; then
	log_msg "ERROR: atomic backup failed; live config kept"
	exit 1
fi
BACKUP_TMP=''
if ! same_file "$SINGBOX_CONFIG" "$SOURCE_TMP"; then
	log_msg "ERROR: config changed before publication; live config kept"
	exit 1
fi
if ! mv -f "$CANDIDATE_TMP" "$SINGBOX_CONFIG"; then
	log_msg "ERROR: atomic config publication failed; live config kept"
	exit 1
fi
CANDIDATE_TMP=''
LIVE_HASH="$(file_hash "$SINGBOX_CONFIG")" || exit 1
if [ "$LIVE_HASH" != "$PUBLISHED_HASH" ]; then
	log_msg "ERROR: config changed after publication; service restart skipped"
	exit 1
fi

if ! /etc/init.d/sing-box restart; then
	# Do not undo a concurrent writer's changes. Even a successful rollback says
	# nothing about service state after a failed restart; never report success.
	LIVE_HASH="$(file_hash "$SINGBOX_CONFIG")" || LIVE_HASH=''
	if [ "$LIVE_HASH" = "$PUBLISHED_HASH" ] && sing-box check -c "$SOURCE_TMP" </dev/null >/dev/null 2>&1; then
		LIVE_HASH="$(file_hash "$SINGBOX_CONFIG")" || LIVE_HASH=''
	else
		LIVE_HASH=''
	fi
	if [ "$LIVE_HASH" = "$PUBLISHED_HASH" ] && mv -f "$SOURCE_TMP" "$SINGBOX_CONFIG"; then
		SOURCE_TMP=''
		log_msg "ERROR: sing-box restart failed; previous config restored atomically; service state unverified"
	else
		log_msg "ERROR: sing-box restart failed; rollback unsafe or failed; inspect live config and $BACKUP; service state unverified"
	fi
	exit 1
fi
log_msg "INFO: patch applied, sing-box restart requested"
truncate_log || log_msg "ERROR: log truncation failed"

exit 0
