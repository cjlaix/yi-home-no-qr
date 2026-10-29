#!/bin/sh
#
# wifi_join.sh - join Wi-Fi ourselves on every boot (yi-hack-v5, Hi3518)
#
# On a cold boot this camera (China-region Yi Home 1080p, cloud disabled) waits
# for a QR code and starts no video. After a real scan, the QR reader (rmm)
# sends dispatch one message (type 0x70: ssid, password, bind code); dispatch
# then connects Wi-Fi and starts video. This script:
#   1. learns that message once (scan the QR code once; saved to qr_msg.bin)
#   2. replays it on every boot, so the camera sets itself up with no QR scan
#   3. as a backup, joins Wi-Fi itself if the camera is still offline after 60 s
# Never writes to the camera's flash, never reboots.
# qr_msg.bin contains your Wi-Fi password: keep the SD card private.

SD="${WJ_SD:-/tmp/sd}"
MTD="${WJ_MTD:-/dev/mtdblock2}"
CONF="$SD/yi-hack-v5/etc/wifi_join.conf"
DIR="$SD/wifi_join"
LOG="$DIR/log.txt"
WPA_CONF=/tmp/wifi_join_wpa.conf
CTRL=/var/run/wpa_supplicant
CHECK_EVERY="${WJ_CHECK_EVERY:-30}"

export PATH=/tmp/sd/yi-hack-v5/bin:/tmp/sd/yi-hack-v5/sbin:/tmp/sd/yi-hack-v5/usr/bin:/tmp/sd/yi-hack-v5/usr/sbin:/home/base/tools:/home/app/localbin:$PATH:/bin:/sbin:/usr/bin:/usr/sbin
mkdir -p "$DIR"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

read_field() { dd if="$MTD" bs=1 skip="$1" count=64 2>/dev/null | tr -d '\000'; }

conf() {
    [ -f "$CONF" ] || return
    tr -d '\r\000' < "$CONF" | grep -i "^[[:space:]]*$1[[:space:]]*=" | sed -n 1p | cut -d '=' -f 2-
}

wlan_ip() { ifconfig wlan0 2>/dev/null | grep -o 'inet addr:[0-9.]*' | cut -d ':' -f 2; }
wlan_essid() { iwconfig wlan0 2>/dev/null | grep -o 'ESSID:"[^"]*"' | cut -d '"' -f 2; }

start_dhcp() {
    killall udhcpc 2>/dev/null
    HN=$(cat "$SD/yi-hack-v5/etc/hostname" 2>/dev/null); HN=${HN:-yi-hack-v5}
    SCRIPT=/home/app/script/default.script
    [ -f "$SCRIPT" ] || SCRIPT=/usr/share/udhcpc/default.script
    udhcpc -i wlan0 -b -s "$SCRIPT" -x hostname:"$HN" >/dev/null 2>&1
}

connect() {
    log "connect: joining '$SSID' ourselves"
    log "connect: before - processes: $(ps 2>/dev/null | grep -E 'wpa_supplicant|udhcpc|hostapd' | grep -v grep | awk '{print $NF}' | tr '\n' ' ')"

    killall wpa_supplicant 2>/dev/null
    killall hostapd 2>/dev/null
    sleep 1
    ifconfig wlan0 up

    mkdir -p "$CTRL"
    {
        echo "ctrl_interface=$CTRL"
        echo "ap_scan=1"
        if command -v wpa_passphrase >/dev/null 2>&1; then
            wpa_passphrase "$SSID" "$PSK" | grep -v '#psk='
        else
            printf 'network={\n\tssid="%s"\n\tpsk="%s"\n}\n' "$SSID" "$PSK"
        fi
    } > "$WPA_CONF"
    # add scan_ssid for hidden networks
    sed -i 's/^}$/\tscan_ssid=1\n}/' "$WPA_CONF"
    chmod 600 "$WPA_CONF"

    for DRV in wext nl80211; do
        wpa_supplicant -B -i wlan0 -D $DRV -c "$WPA_CONF" >/dev/null 2>&1 && { log "connect: wpa_supplicant started (driver $DRV)"; break; }
        log "connect: wpa_supplicant failed with driver $DRV"
    done

    # wait up to 30 s for association
    n=0
    while [ $n -lt 15 ] && [ "$(wlan_essid)" != "$SSID" ]; do sleep 2; n=$((n + 1)); done
    log "connect: associated essid='$(wlan_essid)' after $((n * 2))s"

    start_dhcp
    n=0
    while [ $n -lt 10 ] && [ -z "$(wlan_ip)" ]; do sleep 2; n=$((n + 1)); done
    log "connect: ip='$(wlan_ip)'"
}

# ------------------------------------------------------------------ main

if [ "$1" != "loop" ]; then
    # Detach so we survive the boot script exiting
    if command -v setsid >/dev/null 2>&1; then
        setsid sh "$0" loop </dev/null >/dev/null 2>&1 &
    else
        nohup sh "$0" loop </dev/null >/dev/null 2>&1 &
    fi
    exit 0
fi

SSID=$(conf wifi_ssid); PSK=$(conf wifi_psk)
SRC=conf
if [ -z "$SSID" ] || [ -z "$PSK" ]; then
    SSID=$(read_field 28); PSK=$(read_field 92); SRC=flash
fi

log "===== boot ====="

# --- Learn mode: no recorded QR message yet (first run, or after you changed
# Wi-Fi and deleted qr_msg.bin). Listen to dispatch's messages in RAM only,
# and when a QR scan happens, save that one message to qr_msg.bin.
QR_MSG="$DIR/qr_msg.bin"
if [ ! -f "$QR_MSG" ] && command -v ipc_read >/dev/null 2>&1; then
    log "learn: no qr_msg.bin - scan the QR code once and it will be saved"
    killall ipc_read 2>/dev/null
    nohup ipc_read -n 9 -d </dev/null >/dev/null 2>/tmp/wj_ipc.txt &
    ( n=0; while [ $n -lt 120 ]; do
          sleep 5; n=$((n + 1))
          HEX=$(awk '/^IPC message\. Len: 176/ {getline; getline; print; exit}' /tmp/wj_ipc.txt 2>/dev/null)
          case "$HEX" in "01 00 00 00 02 00 00 00 70 00 70 00"*)
              echo "$HEX" | awk '{ s=""; for (i=1;i<=NF;i++) { v=0; h=toupper($i); for (j=1;j<=2;j++) v=v*16+index("0123456789ABCDEF",substr(h,j,1))-1; s=s sprintf("\\%03o", v) } print s }' > /tmp/wj_esc.txt
              printf "$(cat /tmp/wj_esc.txt)" > "$QR_MSG"
              rm -f /tmp/wj_esc.txt /tmp/wj_ipc.txt; killall ipc_read 2>/dev/null
              log "learn: QR message saved ($(ls -l "$QR_MSG" | awk '{print $5}') bytes) - future boots need no QR scan"
              exit 0 ;;
          esac
      done
      killall ipc_read 2>/dev/null; rm -f /tmp/wj_ipc.txt; log "learn: no QR scan seen in 10 min" ) &
fi

log "wifi from $SRC: ssid='$SSID' key_len=${#PSK}"
if [ -z "$SSID" ] || [ -z "$PSK" ]; then
    log "no ssid/password found - scan the QR code once, or fill in etc/wifi_join.conf. Exiting."
    exit 0
fi

# Replay the message the camera's QR reader (rmm) sends to dispatch after a
# QR scan (captured once into qr_msg.bin). dispatch then connects Wi-Fi and
# starts video itself, exactly as after a real scan.
FIRST_WAIT=${WJ_FIRST_WAIT:-20}
if [ -f "$QR_MSG" ] && command -v ipc_cmd >/dev/null 2>&1; then
    sleep 3
    if [ -n "$(wlan_ip)" ]; then
        log "replay: camera already online - not needed"
    else
        ipc_cmd -f "$QR_MSG" && log "replay: sent QR message to dispatch" || log "replay: ipc_cmd failed"
        FIRST_WAIT=60   # give dispatch time to connect by itself before the fallback
    fi
fi

# Log once when video starts (h264grabber stays up)
( n=0; while [ $n -lt 40 ]; do
      sleep 15; n=$((n + 1))
      if ps | grep -v grep | grep -q h264grabber; then sleep 20
          ps | grep -v grep | grep -q h264grabber && { log "video: running (after ~$((n * 15 + 20))s of this script)"; exit 0; }
      fi
  done; log "video: not running after 10 min" ) &

# Give the firmware a chance first (e.g. right after a QR scan)
sleep "$FIRST_WAIT"

FAILS=0
while true; do
    if [ -n "$(wlan_ip)" ] && [ "$(wlan_essid)" = "$SSID" ]; then
        [ $FAILS -ne 0 ] && log "ok: on '$SSID' ip=$(wlan_ip)"
        FAILS=0
    else
        FAILS=$((FAILS + 1))
        log "not connected (essid='$(wlan_essid)' ip='$(wlan_ip)') - attempt $FAILS"
        connect
    fi
    [ -n "$WJ_ONCE" ] && exit 0
    # back off up to 5 min between failed attempts
    W=$CHECK_EVERY; [ $FAILS -gt 3 ] && W=300
    sleep $W
done
