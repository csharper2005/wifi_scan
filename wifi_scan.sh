#!/bin/sh
# ==============================================================================
# Script:      wifi_scan.sh
# Description: Non-disruptive 2.4 GHz & 5 GHz Wi-Fi scanner for OpenWrt (ash)
#              Logs sorted AP details with wpa_supplicant-style capabilities
#              and rotates up to 15 x 1 MB log files in /tmp.
# Authors:     Mikhail Zhilkin & Gemini
# License:     MIT
# ==============================================================================

LOG_BASE="/tmp/wifi_scan.log"
# List of physical wireless devices (verify via: iw phy)
PHYS="phy0 phy1"
# Max size per log file in bytes (1 MB = 1048576 bytes)
MAX_SIZE=1048576
# Total number of log files to keep (wifi_scan.log + wifi_scan.log.1 .. .14)
MAX_FILES=15

# --- Exclusion Filters ---
# Pipe-separated (|) exact SSIDs to ignore (e.g., "MyHomeWiFi|Guest1")
EXCLUDE_SSIDS=""
# Pipe-separated (|) regex patterns for SSIDs (e.g., "^DIRECT-|^HP-Print-|<hidden>")
EXCLUDE_SSID_PATTERNS=""
# Pipe-separated (|) regex patterns for MAC addresses, case-insensitive (e.g., "^52:ff:20:|^00:11:22:")
EXCLUDE_MAC_PATTERNS=""

# --- Log Rotation (15 files x 1 MB) ---
if [ -f "$LOG_BASE" ]; then
    CUR_SIZE=$(wc -c < "$LOG_BASE" 2>/dev/null || echo 0)
    if [ "$CUR_SIZE" -ge "$MAX_SIZE" ]; then
        i=$((MAX_FILES - 1))
        # Remove the oldest archive if it exists
        [ -f "${LOG_BASE}.${i}" ] && rm -f "${LOG_BASE}.${i}"
        # Shift existing archives: .13 -> .14, ..., .1 -> .2
        while [ "$i" -gt 1 ]; do
            prev=$((i - 1))
            [ -f "${LOG_BASE}.${prev}" ] && mv "${LOG_BASE}.${prev}" "${LOG_BASE}.${i}"
            i=$prev
        done
        # Move current active log to .1
        mv "$LOG_BASE" "${LOG_BASE}.1"
    fi
fi

# Write scan timestamp and table header
echo "$(date '+%Y-%m-%d %H:%M:%S') scanning result" >> "$LOG_BASE"
printf "%-32s %-17s %-7s %-10s %-16s %-8s %s\n" \
    "SSID" "MAC" "Channel" "Bandwidth" "Approx.distance" "RSSI" "Capabilities" >> "$LOG_BASE"

{
    for PHY in $PHYS; do
        # Skip if physical radio interface does not exist
        [ -d "/sys/class/ieee80211/$PHY" ] || continue

        SCAN_IF="scan_${PHY}"
        CREATED_TMP=0
        SCAN_CMD="scan"

        # 1. Try creating a temporary virtual station interface
        if iw phy "$PHY" interface add "$SCAN_IF" type station 2>/dev/null && \
           ip link set "$SCAN_IF" up 2>/dev/null; then
            CREATED_TMP=1
        else
            # Clean up partial interface if creation succeeded but 'up' failed
            iw dev "$SCAN_IF" del 2>/dev/null

            # 2. Fallback: find an existing UP interface belonging to this PHY
            SCAN_IF=""
            for net_if in /sys/class/ieee80211/"$PHY"/device/net/*; do
                [ -e "$net_if" ] || continue
                if_name=$(basename "$net_if")
                # Check if interface is UP (flags bit 0x1)
                flags=$(cat "$net_if/flags" 2>/dev/null)
                if [ $((flags & 1)) -eq 1 ]; then
                    SCAN_IF="$if_name"
                    # 'ap-force' allows scanning on an active AP/STA interface
                    SCAN_CMD="scan ap-force"
                    break
                fi
            done
        fi

        # Skip PHY if no usable interface is available
        [ -z "$SCAN_IF" ] && continue

        # Perform scan and parse raw output using awk
        iw dev "$SCAN_IF" $SCAN_CMD 2>/dev/null | awk \
            -v ex_ssids="$EXCLUDE_SSIDS" \
            -v ex_ssid_re="$EXCLUDE_SSID_PATTERNS" \
            -v ex_mac_re="$EXCLUDE_MAC_PATTERNS" '
        BEGIN {
            n_exact = split(ex_ssids, exact_arr, "|")
            for (i = 1; i <= n_exact; i++) {
                if (exact_arr[i] != "") exact_map[exact_arr[i]] = 1
            }
            ex_mac_re = tolower(ex_mac_re)
        }

        function is_excluded(s, m) {
            if (s in exact_map) return 1
            if (ex_ssid_re != "" && s ~ ex_ssid_re) return 1
            if (ex_mac_re != "" && tolower(m) ~ ex_mac_re) return 1
            return 0
        }

        function freq_to_chan(f) {
            if (f == 2484) return 14
            if (f >= 2412 && f <= 2472) return int((f - 2407) / 5)
            if (f >= 5180 && f <= 5885) return int((f - 5000) / 5)
            if (f >= 5955 && f <= 7115) return int((f - 5950) / 5)
            return ""
        }

        function norm_cipher(c) {
            gsub(/ /, "+", c)
            gsub(/CCMP/, "CCMP-128", c)
            return c
        }

        function norm_auth(a) {
            gsub(/ /, "+", a)
            return a
        }

        function build_caps(    res, proto, a, c) {
            res = ""

            # Legacy WPA (WPA1)
            if (has_wpa) {
                a = (wpa_auth != "" ? wpa_auth : "PSK")
                c = (wpa_cipher != "" ? wpa_cipher : "TKIP")
                res = res "[WPA-" a "-" c "]"
            }

            # RSN (WPA2 / WPA3)
            if (has_rsn) {
                a = (rsn_auth != "" ? rsn_auth : "PSK")
                c = (rsn_cipher != "" ? rsn_cipher : "CCMP-128")
                proto = (a ~ /SAE/ && a !~ /PSK/ ? "WPA3" : "WPA2")
                res = res "[" proto "-" a "-" c "][RSN-" a "-" c "]"
            }

            # Open / WEP indicator when neither WPA nor RSN is present
            if (!has_wpa && !has_rsn) {
                res = res (is_priv ? "[WEP]" : "[OPEN]")
            }

            # ESS / IBSS flags
            if (is_ess) res = res "[ESS]"
            if (is_ibss) res = res "[IBSS]"

            # Management Frame Protection (802.11w)
            if (mfp != "") res = res "[" mfp "]"

            # WPS support
            if (has_wps) res = res "[WPS]"

            return res
        }

        function print_bss(    sort_key) {
            if (mac == "") return
            if (ssid == "") ssid = "<hidden>"
            if (is_excluded(ssid, mac)) return

            if (chan == "" && freq > 0) chan = freq_to_chan(freq)
            if (chan == "") chan = "?"
            if (bw == "") bw = "20 MHz"

            # Estimate distance using Free-Space Path Loss (FSPL) formula
            dist = "N/A"
            if (rssi != "" && freq > 0) {
                abs_rssi = (rssi < 0) ? -rssi : rssi
                log10_f = log(freq) / log(10)
                exp_val = (27.55 - (20 * log10_f) + abs_rssi) / 20
                d = 10 ^ exp_val
                dist = sprintf("~%.1f m", d)
            }

            rssi_str = (rssi != "" ? rssi " dBm" : "N/A")
            sort_key = (rssi != "" ? rssi : -999)

            # Prefix numeric RSSI + tab as sort key, stripped after sorting
            printf "%d\t%-32s %-17s %-7s %-10s %-16s %-8s %s\n", \
                sort_key, substr(ssid, 1, 32), mac, chan, bw, dist, rssi_str, build_caps()
        }

        /^BSS / {
            print_bss()
            # Reset variables for the next AP entry
            mac = substr($2, 1, 17)
            ssid = ""; chan = ""; bw = "20 MHz"; rssi = ""; freq = 0
            sec = ""; has_wpa = 0; has_rsn = 0; has_wps = 0
            wpa_auth = ""; wpa_cipher = ""; rsn_auth = ""; rsn_cipher = ""
            is_ess = 0; is_ibss = 0; is_priv = 0; mfp = ""; ht_check = 0
        }
        /^[ \t]+freq:/ {
            freq = int($2)
        }
        /^[ \t]+signal:/ {
            rssi = int($2)
        }
        /^[ \t]+capability:/ {
            if ($0 ~ /ESS/) is_ess = 1
            if ($0 ~ /IBSS/) is_ibss = 1
            if ($0 ~ /Privacy/) is_priv = 1
        }
        /^[ \t]+SSID:/ {
            sub(/^[ \t]+SSID: /, "")
            ssid = $0
        }
        /^[ \t]+DS Parameter set: channel/ {
            chan = $5
        }
        /^[ \t]+\* primary channel:/ {
            if (chan == "") chan = $4
        }
        /^[ \t]+\* channel width:/ {
            if ($4 == "1") bw = "80 MHz"
            else if ($4 == "2" || $4 == "3") bw = "160 MHz"
            else if ($0 ~ /320 MHz/) bw = "320 MHz"
        }
        /^[ \t]+HT operation:/ {
            if (bw == "20 MHz") ht_check = 1
        }
        /^[ \t]+\* secondary channel offset:/ {
            if (ht_check == 1 && $5 != "no") bw = "40 MHz"
            ht_check = 0
        }
        /^[ \t]+RSN:/ {
            sec = "RSN"; has_rsn = 1
        }
        /^[ \t]+WPA:/ {
            sec = "WPA"; has_wpa = 1
        }
        /^[ \t]+WPS:/ {
            sec = "WPS"; has_wps = 1
        }
        /^[ \t]+\* Pairwise ciphers:/ {
            val = $0
            sub(/^[ \t]+\* Pairwise ciphers:[ \t]*/, "", val)
            if (sec == "RSN") rsn_cipher = norm_cipher(val)
            else if (sec == "WPA") wpa_cipher = norm_cipher(val)
        }
        /^[ \t]+\* Authentication suites:/ {
            val = $0
            sub(/^[ \t]+\* Authentication suites:[ \t]*/, "", val)
            if (sec == "RSN") rsn_auth = norm_auth(val)
            else if (sec == "WPA") wpa_auth = norm_auth(val)
        }
        /^[ \t]+\* Capabilities:/ {
            if (sec == "RSN") {
                if ($0 ~ /MFP-required/) mfp = "MFPR"
                else if ($0 ~ /MFP-capable/) mfp = "MFPC"
            }
        }
        END {
            print_bss()
        }'

        # Tear down and remove temporary virtual interface ONLY if we created it
        if [ "$CREATED_TMP" -eq 1 ]; then
            ip link set "$SCAN_IF" down 2>/dev/null
            iw dev "$SCAN_IF" del 2>/dev/null
        fi
    done
} | sort -rn | cut -f2- >> "$LOG_BASE"

echo "" >> "$LOG_BASE"
