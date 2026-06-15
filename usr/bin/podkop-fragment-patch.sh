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
	echo "$msg" >> "$LOG_FILE"
}

truncate_log() {
	if [ -f "$LOG_FILE" ]; then
		local lines
		lines="$(wc -l < "$LOG_FILE")"
		if [ "$lines" -gt "$LOG_MAX_LINES" ]; then
			tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp"
			mv "${LOG_FILE}.tmp" "$LOG_FILE"
		fi
	fi
}

if [ "$ENABLED" = "0" ]; then
	exit 0
fi

if [ ! -f "$SINGBOX_CONFIG" ]; then
	log_msg "ERROR: config not found: $SINGBOX_CONFIG"
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

if [ "$FRAGMENT" = "true" ] && [ "$RECORD_FRAGMENT" = "true" ]; then
	ALREADY_PATCHED=$(jq -e '(.outbounds[] | select(.tls.enabled == true and .tls.fragment == true and .tls.record_fragment == true)) | limit(1; .)' "$SINGBOX_CONFIG" 2>/dev/null)
elif [ "$FRAGMENT" = "true" ]; then
	ALREADY_PATCHED=$(jq -e '(.outbounds[] | select(.tls.enabled == true and .tls.fragment == true)) | limit(1; .)' "$SINGBOX_CONFIG" 2>/dev/null)
elif [ "$RECORD_FRAGMENT" = "true" ]; then
	ALREADY_PATCHED=$(jq -e '(.outbounds[] | select(.tls.enabled == true and .tls.record_fragment == true and .tls.fragment != true)) | limit(1; .)' "$SINGBOX_CONFIG" 2>/dev/null)
else
	log_msg "INFO: both fragment and record_fragment disabled, skipping"
	exit 0
fi

if [ -n "$ALREADY_PATCHED" ]; then
	log_msg "INFO: config already patched, skipping"
	exit 0
fi

log_msg "INFO: patching $SINGBOX_CONFIG (fragment=$FRAGMENT, record_fragment=$RECORD_FRAGMENT, fallback_delay=$FALLBACK_DELAY)"

cp "$SINGBOX_CONFIG" "${SINGBOX_CONFIG}.bak"

if [ "$FRAGMENT" = "true" ]; then
	jq --arg f "$FRAGMENT" --arg rf "$RECORD_FRAGMENT" --arg fd "$FALLBACK_DELAY" \
		'(.outbounds[] | select(.tls.enabled == true) | .tls) |= . + {"fragment": ($f == "true"), "record_fragment": ($rf == "true"), "fragment_fallback_delay": $fd}' \
		"${SINGBOX_CONFIG}.bak" > "$SINGBOX_CONFIG"
else
	jq --arg f "$FRAGMENT" --arg rf "$RECORD_FRAGMENT" \
		'(.outbounds[] | select(.tls.enabled == true) | .tls) |= . + {"fragment": ($f == "true"), "record_fragment": ($rf == "true")} | (.outbounds[] | select(.tls.enabled == true) | .tls) |= del(.fragment_fallback_delay)' \
		"${SINGBOX_CONFIG}.bak" > "$SINGBOX_CONFIG"
fi

if ! sing-box check -c "$SINGBOX_CONFIG" >/dev/null 2>&1; then
	log_msg "ERROR: sing-box check failed after patch, rolling back"
	mv "${SINGBOX_CONFIG}.bak" "$SINGBOX_CONFIG"
	exit 1
fi

/etc/init.d/sing-box restart
log_msg "INFO: patch applied, sing-box restarted"

rm -f "${SINGBOX_CONFIG}.bak"
truncate_log

exit 0
