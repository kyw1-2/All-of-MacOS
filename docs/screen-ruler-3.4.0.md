# Screen Ruler (3.4.0)

Measure anything on screen, in any app, PixelSnap style: the distance between elements, the size of a button
or card, and the colour under the pointer, in points or pixels.

## Start measuring

- Press **⇧⌘7** (Settings › Shortcuts › Productivity › Measure Screen; change it there).
- Or choose **Measure Screen** in the menu bar menu (Productivity section), or **Measure Now** on the Capture
  page.

Every display is captured once when measuring starts and shown as a still while you measure, so what you see is
exactly what is measured. Windows of All of MacOS itself are left out of that still (its menu bar icon stays).
Nothing underneath is clicked while measuring. Press the shortcut again, Esc or right-click to stop; the app you
were using gets the keyboard back.

Measuring needs **Screen & System Audio Recording** permission (System Settings › Privacy & Security). Without
it, the shortcut asks for it and says where to allow it; the Capture page shows the same notice.

## While measuring

| Do this | What happens |
|---|---|
| Move the pointer | Crosshair lines run left, right, up and down to the first edge (the first pixel whose colour differs from the one under the pointer by more than the tolerance). W and H labels give the distances. |
| Drag | Measures the box you drag (W × H). When you let go it shrinks to the object inside it. |
| Hold ⌥ while you let go | Keeps the box as drawn instead of shrinking it. |
| ⇧ | Keeps the current measurement on screen, so you can add more. |
| ⌫ | Removes the newest kept measurement. |
| ⌘C | Copies the box you just measured, otherwise the distances at the pointer, in the copy format you chose. |
| Space | Switches between points and pixels. |
| Arrow keys | Move the pointer by one pixel (⌥ for ten). |
| Esc, right-click, or the shortcut again | Ends measuring. |

A box keeps to the display it started on. Displays with different scales each measure in their own pixels.

## Options (Capture page › Screen ruler, Measuring)

- **Units**: points (what layouts and CSS use) or the display's pixels. **Show pixels with points** adds the
  other unit on Retina displays ("120 pt · 240 px").
- **Copy format**: "120 × 44", "120x44" or CSS "width: 120px; height: 44px;". CSS is always in points, because
  a CSS pixel is a point on a Mac.
- **Edge tolerance** (0–50 %, default 10 %): how different a colour must be to count as an edge. Higher looks past
  gradients and shadows; lower finds faint borders.
- **Snap areas to content** (on): a dragged box shrinks to what is inside it.
- **Guide color**: the lines and labels; label text switches between white and black to stay readable.
- **Show color under pointer**: the sRGB hex value next to the pointer.
- **Hide cursor while measuring**: only the guides mark the pointer.

## How it works

- One ScreenCaptureKit screenshot per display at its native scale, then every pointer move is answered from
  those pixels in memory (about 0.6 ms per move on a 3840 × 2160 display in a debug build); nothing is captured
  again until the next session.
- Drawing uses a few small Core Animation layers per display, so moving the pointer only moves layers and
  changes two labels.
- Nothing runs while you are not measuring: no timer, no monitor and no image is kept. The stills are released
  when measuring ends. Nothing is written to disk.
- Settings are stored under `AOMScreenRuler…` keys; Settings › Data › Reset Preferences resets them.

## Not included

- Guides you place and keep across sessions, measuring screenshots exported as images, and moving a box with
  Space (Space switches units here) are not part of 3.4.0.
