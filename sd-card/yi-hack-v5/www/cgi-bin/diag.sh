#!/bin/sh
# Live status page: http://<camera-ip>/cgi-bin/diag.sh
# Read-only. Refreshes every 10 seconds. Never shows the Wi-Fi password.
# Uses only tools present on the camera (no head/wc).
# Optional: diag.sh?a=4&b=5 compares state_4 with state_5.

export PATH=/tmp/sd/yi-hack-v5/bin:/tmp/sd/yi-hack-v5/sbin:/tmp/sd/yi-hack-v5/usr/bin:/tmp/sd/yi-hack-v5/usr/sbin:/home/base/tools:/home/app/localbin:$PATH:/bin:/sbin:/usr/bin:/usr/sbin
CONF=/tmp/sd/yi-hack-v5/etc/system.conf
WJ=/tmp/sd/wifi_join

esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
section() { echo; echo "===== $1 ====="; }
first() { sed -n "1,${1}p"; }
last() { awk -v n="$1" '{ l[NR]=$0 } END { s=NR-n+1; if (s<1) s=1; for (i=s;i<=NR;i++) print l[i] }'; }
count() { awk 'END { print NR }'; }
qs() { echo "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p"; }

printf 'Content-type: text/html\r\n\r\n'
echo '<html><head><meta http-equiv="refresh" content="10"><title>camera diag</title></head>'
echo '<body style="font-family:monospace;font-size:13px"><pre>'
{
    echo "Camera time: $(date '+%Y-%m-%d %H:%M:%S')   uptime: $(cut -d ' ' -f 1 /proc/uptime 2>/dev/null)s"

    section "Wi-Fi"
    iwconfig wlan0 2>/dev/null | grep -E 'ESSID|Quality|Bit Rate' | sed 's/  */ /g'
    echo "IP: $(ifconfig wlan0 2>/dev/null | grep -o 'inet addr:[0-9.]*' | cut -d ':' -f 2)"

    section "Key settings (system.conf)"
    grep -E '^(DISABLE_CLOUD|REC_WITHOUT_CLOUD|RTSP|RTSP_STREAM|RTSP_AUDIO|RTSP_PORT|SNAPSHOT|ONVIF)=' "$CONF" 2>/dev/null

    section "Processes that matter (missing = not running)"
    PS=$(ps 2>/dev/null)
    for P in dispatch rmm cloud mp4record h264grabber rRTSPServer wpa_supplicant udhcpc httpd wifi_join; do
        if echo "$PS" | grep -v grep | grep -q "$P"; then echo "  running  $P"; else echo "  MISSING  $P"; fi
    done

    section "wifi_join log (last 25 lines)"
    last 25 < $WJ/log.txt 2>/dev/null

    section "RTSP watchdog log (last 10 lines)"
    last 10 < /tmp/sd/wd_rtsp.log 2>/dev/null

    section "Stored state comparison"
    N=$(cat $WJ/boot_count 2>/dev/null)
    A=$(qs a); B=$(qs b); A=${A:-$((N - 1))}; B=${B:-$N}
    FA=$WJ/state_$A.txt; FB=$WJ/state_$B.txt
    echo "state files: $(ls $WJ 2>/dev/null | grep state_ | tr '\n' ' ')"
    for F in $FA $FB; do
        [ -f "$F" ] && echo "  ${F##*/}: $(count < "$F") lines, first: $(first 1 < "$F")"
    done
    if [ -f "$FA" ] && [ -f "$FB" ]; then
        echo "comparing state_$A -> state_$B  (lines only in one of them):"
        awk 'NR==FNR { a[$0]=1; next } { b[$0]=1 } END {
               for (k in a) if (!(k in b)) print "  before: " k;
               for (k in b) if (!(k in a)) print "  after:  " k }' "$FA" "$FB" | sort -k3 | first 80
        echo "(end of comparison)"
    fi

    section "Flash partitions (/proc/mtd)"
    cat /proc/mtd 2>/dev/null

    section "Kernel messages (last 15)"
    dmesg 2>/dev/null | last 15

    section "SD card"
    df -h /tmp/sd 2>/dev/null | last 1
} 2>&1 | esc
echo '</pre></body></html>'
