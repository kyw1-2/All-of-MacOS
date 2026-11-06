# Ulanzi Deck integration for AOM 3.4.17

AOM includes a plugin for Ulanzi Studio, the manufacturer companion app.
It does not claim that Ulanzi hardware is Elgato Stream Deck-compatible.

The signed AOM app contains Contents/Resources/Ulanzi/com.ulanzi.aom.ulanziPlugin.
Install the official Ulanzi Studio software, then run scripts/install-ulanzi-plugin.sh
or copy that folder manually to
~/Library/Application Support/Ulanzi/UlanziDeck/Plugins/com.ulanzi.aom.ulanziPlugin
Quit and reopen Ulanzi Studio, then drag an AOM Key action onto a physical key.

For AOM Key 01 ... AOM Key 16, create and enable matching AOM Named Triggers
named ulanzi-key-01 ... ulanzi-key-16. These 16 numbered slots do not
represent physical button counts on every Deck variant. For supported dials,
AOM Encoder 1 ... 3 maps to named triggers ulanzi-dial-01-left,
ulanzi-dial-01-right and ulanzi-dial-01-press, through encoder 03.

These Named Triggers can be assigned any AOM actions and scoped per app.
The plugin uses the official Ulanzi JavaScript SDK onRun/onDialDown/onDialRotate
and the existing AOM custom aom://trigger?name= route; no network listeners
or arbitrary shell commands. The copied official SDK JavaScript files use
Apache License 2.0 and ship their license text. A connected Ulanzi unit
was unavailable for hardware integration tests; the package and route can
be validated without it.
