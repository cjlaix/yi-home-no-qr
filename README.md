# yi-home-no-qr

Run a **China-region Yi Home 1080p** camera with [yi-hack-v5](https://github.com/alienatedsec/yi-hack-v5) **completely cloud-free**, and stop it asking for a QR code after every reboot.

After a power cycle it rejoins Wi-Fi and starts its video and RTSP stream on its own, ready for Frigate, motionEye, Home Assistant or any NVR.

## The problem

On China-region units (the device ID in the logs starts with `TNPCHNA-`), pairing with the international Yi Home app never fully completes. With yi-hack-v5 and the cloud disabled:

- the camera works after you scan the QR code, **but**
- after every reboot or power cut it says *"waiting to connect"* and wants the QR code again, and
- getting it back on Wi-Fi some other way doesn't help, because **no video is produced** until a QR scan happens.

This is a [long-standing issue](https://github.com/alienatedsec/yi-hack-v5/discussions/315), and the workarounds usually involve proxying the camera to China and pairing it with the Chinese app.

## What is actually happening

The fix came from tracing what a QR scan does inside the stock firmware:

1. The video process `rmm` decodes the QR code with zbar and decrypts it.
2. It sends **one 176-byte message** to the manager process `dispatch`, over the POSIX message queue `/ipc_dispatch`:

   ```
   01 00 00 00  02 00 00 00  70 00 70 00  00 00 00 00   header: to dispatch(1), from rmm(2), type 0x70
   [64 bytes]   SSID
   [64 bytes]   Wi-Fi password
   [32 bytes]   bind code from the app
   ```

3. `dispatch` then starts its own `wpa_supplicant`, gets an IP address, and switches the camera from QR mode to normal mode, which starts the H.264 encoder.

On a cold boot, nothing sends that message, so the camera waits for a QR code indefinitely. Nothing persistent marks the camera as "set up". The flash flags, the config partitions and the files in `/home` all looked identical before and after a scan. The switch happens only in RAM.

## The fix

`wifi_join.sh` runs from the SD card at the end of every boot and:

1. **Learns** the message once. yi-hack-v5 already wraps `dispatch` with `ipc_multiplex.so`, which copies every message `dispatch` receives to `/ipc_dispatch_1..9`. The script listens on queue 9 with yi-hack's `ipc_read`. When you scan the QR code, it saves that one message to `wifi_join/qr_msg.bin`.
2. **Replays** it on every later boot with yi-hack's `ipc_cmd -f qr_msg.bin`. `dispatch` behaves exactly as if you had just scanned: Wi-Fi, video and RTSP all come up with no scan.
3. **Backs it up.** If the camera is still offline 60 s after the replay, the script joins Wi-Fi itself with `wpa_supplicant` and `udhcpc`, so the camera stays reachable.

It never writes to the camera's flash and never reboots anything. To undo it, delete two files.

A live status page is included at `http://<camera-ip>/cgi-bin/diag.sh`. It shows Wi-Fi, key settings, which processes are running, the logs and the kernel messages, and refreshes every 10 s.

## Tested on

| | |
|---|---|
| Camera | Yi Home 1080p, China region (`yi_home`, Hi3518EV200, Realtek RTL871X Wi-Fi) |
| Hack | yi-hack-v5 0.4.1 |
| Settings | Disable cloud = yes, RTSP = yes |

Other Hi3518 Yi models running yi-hack-v5 probably behave the same way, but they haven't been tested. If you try one, please open an issue with your result.

## Install

You need yi-hack-v5 already installed and working, which means the camera works after a QR scan.

1. Copy the contents of [`sd-card/`](sd-card) to the root of the SD card, merging with the existing `yi-hack-v5` folder:
   ```
   yi-hack-v5/startup.sh                 runs the script at every boot
   yi-hack-v5/script/wifi_join.sh        the script
   yi-hack-v5/etc/wifi_join.conf         optional overrides (leave empty)
   yi-hack-v5/www/cgi-bin/diag.sh        status page
   ```
   If you already have a `startup.sh`, add this line to it instead:
   `sh /tmp/sd/yi-hack-v5/script/wifi_join.sh`
2. In the yi-hack web UI, set **Disable cloud = yes** and **RTSP = yes**.
3. **Teach it once:**
   1. Power on.
   2. Wait **2 minutes**, because yi-hack's boot scripts finish late and the listener isn't running before then.
   3. Scan the QR code from the Yi app as usual.
   4. `wifi_join/log.txt` should now say `learn: QR message saved (176 bytes)`.
4. Power-cycle and don't scan. Within about a minute the log should show:
   ```
   replay: sent QR message to dispatch
   video: running
   ```

**If you change your Wi-Fi:** delete `wifi_join/qr_msg.bin`, then repeat step 3.

### Use with Frigate / go2rtc

```yaml
go2rtc:
  streams:
    yi_cam: rtsp://<camera-ip>:554/ch0_0.h264      # 1080p
    yi_cam_sub: rtsp://<camera-ip>:554/ch0_1.h264  # 640x360 (needs RTSP stream = both)
```

The camera only produces **H.264**: the Hi3518EV200 has no H.265 encoder. If your other cameras are on H.265 with a global H.265 `hwaccel_args` preset, override it for this camera with an H.264 preset.

## Security notes

- `wifi_join/qr_msg.bin` contains your **Wi-Fi password and pairing code**, the same information the camera's flash already holds. Treat the SD card as private.
- **Set a username and password in yi-hack.** Its web UI has none by default, and its upload function can write files to the SD card.
- Block the camera's internet access at your router. It doesn't need it.

## Troubleshooting

| Log says | Meaning |
|---|---|
| `learn: no QR scan seen in 10 min` | The scan came too early or never happened. Reboot, wait 2 min, then scan. |
| `replay: sent …` but no `video: running` | The firmware didn't accept the message. Delete `qr_msg.bin` and re-learn. Please also open an issue with your model and firmware. |
| `not connected … attempt N` | The replay didn't bring Wi-Fi up, so the backup join is being used. Check your 2.4 GHz WPA2 network. |

## Credits

- [yi-hack-v5](https://github.com/alienatedsec/yi-hack-v5) by alienatedsec, and its predecessors yi-hack-v4 and yi-hack-v3 by TheCrypt0 and shadow-1. This fix relies on yi-hack's `ipc_multiplex`, `ipc_read` and `ipc_cmd` from [libipc](https://github.com/TheCrypt0/libipc) by roleo.

## License

GPL-3.0, the same licence as yi-hack-v5. Use at your own risk. This isn't affiliated with Yi or Kami.
