# wifi_scan
wifi_scan

# OpenWrt Wi-Fi Spectrum Scanner (`wifi_scan.sh`)

A lightweight, dependency-free `ash` + `awk` script for OpenWrt routers that periodically scans both **2.4 GHz** and **5 GHz** (plus 6 GHz) wireless spectrums without disconnecting active Wi-Fi clients, and logs sorted network details into rotating files in `/tmp`.

## Features

* **Non-Disruptive Scanning:** Dynamically creates and tears down temporary virtual `station` interfaces (`scan_phy0`, `scan_phy1`) so active client connections are not interrupted during scans.
* **Zero External Dependencies:** Uses only standard OpenWrt tools (`iw`, `ip`, and BusyBox `ash`/`awk`/`sort`).
* **Unified RSSI Sorting:** Aggregates 2.4 GHz and 5 GHz scan results into a single table sorted from strongest to weakest signal (`dBm`).
* **`wpa_supplicant`-Style Capabilities:** Parses RSN, WPA, WPS, and management frame protection flags into familiar bracketed strings (e.g., `[WPA2-PSK+SAE-CCMP-128][RSN-PSK+SAE-CCMP-128][ESS][MFPC]`).
* **Distance Estimation:** Calculates approximate line-of-sight distance using the Free-Space Path Loss (FSPL) formula based on frequency and RSSI.
* **Flexible Filtering:** Supports excluding networks by exact SSID, SSID regex mask, or case-insensitive MAC address mask.
* **RAM-Safe Log Rotation:** Automatically rotates logs at `1 MB` per file, keeping up to `15` files (`~15 MB` max footprint in `/tmp`).

## Output Example

```text
2026-11-22 15:10:01 scanning result
SSID                             MAC               Channel Bandwidth  Approx.distance  RSSI     Capabilities
ORANGE                           5c:1d:c7:eb:f6:cc 36      80 MHz     ~0.7 m           -45 dBm  [WPA2-PSK-CCMP-128][RSN-PSK-CCMP-128][ESS][MFPC]
Guest1                           6e:ae:db:41:b6:35 6       20 MHz     ~5.0 m           -61 dBm  [WPA2-PSK-CCMP-128][RSN-PSK-CCMP-128][ESS]
<hidden>                         52:ee:20:ff:f7:28 7       40 MHz     ~308.9 m         -90 dBm  [WPA2-PSK+SAE-CCMP-128][RSN-PSK+SAE-CCMP-128][ESS][MFPC]
