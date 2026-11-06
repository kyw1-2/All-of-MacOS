# Pointer and hardware controls

Implementation follows the AGY Telegram REA brief delivered in
`/data/agent-channels-gemini/telegram/delivered/reply-tg144496762.json`,
with API details checked against the extracted AlDente helper and current
[LinearMouse PointerKit](https://github.com/linearmouse/linearmouse/tree/main/Modules/PointerKit)
and [batt PowerUI/SMC interfaces](https://github.com/charlie0129/batt/tree/master/pkg).
These are independent Swift implementations of the interfaces, not embedded
third-party executables.

## Available controls

- Settings → Automation: independent wheel reversal, opt-in 120 ms wheel
  smoothing, and per-service external-mouse linear acceleration. Continuous
  touch scrolling and AOM-generated events pass through. Wheel transformation
  requires Accessibility permission. Acceleration uses the IOFixed value -65536,
  verifies readback, and restores owned settings on disable/quit. Recorded
  same-boot registry IDs permit recovery after AOM restarts. Other utilities'
  changed values are not overwritten. Linear acceleration is not a guarantee of
  one screen pixel per mouse sensor count; DPI and display scaling still apply.
- System Tools → Battery & Hardware: available SMC temperature/power channels,
  fan RPM and battery temperature/current. Unsupported channels stay absent.
  SMC keys and their interpretation vary across Mac models; labels identify
  individual sensors, not an asserted calibrated die/package temperature.
- Charging: native PowerUI MCL 80% limit when the class, selectors, ABI, and
  capability query match, with state readback. A macOS version number alone
  does not establish support. Native limits remain configured after AOM exits.
  An error from a present native interface is surfaced, not silently bypassed.
- Optional helper: legacy 80/75% hysteresis and bypass using paired CH0B/CH0C
  (0x02), or CHTE only when the pair is absent. Bypass inhibits charging while
  retaining AC power; it does not electrically disconnect the battery or force
  discharge. At/below 20%, ordinary charging resumes. Above 35 °C charging is
  held until below 33 °C; unavailable temperature also holds charging.
- Fans: Auto releases AOM's overrides; Quiet requests verified minimum RPM;
  Max requests verified maximum RPM. Quiet requires both supported CPU/GPU
  readings, releases to Auto at 75 °C, missing readings, or serious/critical
  thermal pressure, and resumes only below 65 °C. Fanless Macs expose no fan
  controls. No guessed limits or unbounded fan targets are written.

## Runtime and helper lifecycle

All controls default off/Auto. Sensor sampling runs every 3 seconds only while
the card is visible, on a utility queue, and publishes changed samples.
Pointer hotplug handling uses callbacks, not polling. Smoothing's 120 Hz timer
exists only during a wheel burst. The helper's 5-second policy timer and the
app's 10-second lease renewal exist only while a policy is active (or recovery
needs retry). Hardware metadata and the SMC connection are reused.

The helper is bundled by SwiftPM packaging and the Xcode build phase. It is
registered only by the explicit **Enable Hardware Helper** action through
SMAppService; macOS may require approval in Login Items. Ad-hoc builds cannot
enable hardware writes. App and daemon require the same signing certificate
and exact peer bundle identifier via NSXPCConnection's signing requirement;
only the current console UID may hold the single control lease.

RPC accepts typed battery/fan presets only. No arbitrary key, command or file
path can be supplied. Readback, ownership checks and a root-owned write-ahead
journal cover partial writes and helper restarts. Fan manual mode must be
confirmed released before restoring its old target. Failed recovery remains
journaled for retry. Disconnect, 30-second lease expiry, user switching,
sleep and ordinary exit restore owned settings. Legacy policies must be
selected again after sleep; native MCL remains managed by macOS. No wake
auto-reapply, launch auto-enable, SMC battery-disconnect, or firmware-update
path is provided.

## Validation and remaining device checks

`bash scripts/test-hardware-core.sh` runs the production policy, codec, wheel,
controller and recovery tests with fake hardware on Swift 5.9+.

At implementation time, portable tests and macOS 15.2 SDK arm64 type checks
were run on the server. The full helper uses real macOS imports; app-module
checks use small stand-ins for unrelated existing app dependencies.
This is not a signed full-app build or hardware validation: the Mac host was
offline. Before distributing, verify a certificate-signed bundle on a Mac:

1. Confirm helper approval, peer authentication, reconnect, sleep, app kill
   and helper kill recovery; also test refusal with mismatched certificates.
2. Verify USB/Bluetooth mouse reconnect, trackpad preservation, acceleration
   readback and restoration, and Accessibility revocation.
3. Verify native MCL on a supported Mac; unsupported/denied SMC writes must
   report an error. Check both battery threshold crossings on AC.
4. Verify fan min/max, Auto restoration and thermal fallback on a fan-equipped
   Mac, and absence of fan controls on a fanless Mac.

No release, installation, helper registration, or physical hardware writes
were performed as part of this server-side implementation.
