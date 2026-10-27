# Audio workspace UX and boost review

Scope: the Workspace and Audio views in AOM 3.0.12. The installed build was inspected on macOS; the observations below distinguish UI changes from algorithmic equivalence. References: [Apple Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [Apple Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), and [SoundSource Applications](https://rogueamoeba.com/support/manuals/soundsource/?page=application-adjustments).

## Changes made

The following are individual improvements, including accessibility and state clarity; they are not 40 independent page redesigns.

1. Workspace had no audio entry: add an Audio card.
2. Show whether app audio is on there.
3. Show output boost state and strength there.
4. Show master EQ state and preset there.
5. Add a Mixer navigation link.
6. Add a clearly named Open Audio action.
7. Explain when saved effects are paused by the engine.
8. Restore the audio page's visible scroll indicator.
9. Make the master EQ summary a link to its controls.
10. Honor Reduce Motion when navigating to EQ.
11. Move app commands below their heading to leave more horizontal space.
12. Trim whitespace before filtering app names and identifiers.
13. Show filtered versus total app counts.
14. Name the filter for assistive technology.
15. Label and explain the filter's clear button.
16. Offer Clear Filter directly in the empty result.
17. Label the audio engine switch.
18. Label the refresh control.
19. Track expanded EQ by stable row identity rather than a shared zero PID.
20. Name the output device picker.
21. Name and explain output mute.
22. Name output volume and report its value.
23. Explain when the output cannot adjust volume.
24. Name output balance and describe its value.
25. Explain when balance is unavailable.
26. Name the input device picker.
27. Name and explain microphone mute.
28. Name microphone gain and report its value.
29. Explain when input gain is unavailable.
30. Name and explain system alert mute.
31. Name system alert volume and report its value.
32. Keep alert mute state and last nonzero level consistent when its slider reaches zero.
33. Give each app's output picker a distinct name.
34. Give each app's boost button a distinct name and state.
35. Give each app's EQ button a distinct name and expanded state.
36. Give each reconnect action a distinct app name.
37. Give each volume slider a distinct app name.
38. Add an explicit 100% reset for each app volume.
39. Name app and master EQ preset pickers and clarify the master reset label.
40. Identify the frequency in each EQ band's decrement, increment and reset accessibility actions.

## Audio evidence and limits

The [SoundSource manual](https://rogueamoeba.com/support/manuals/soundsource/?page=built-in-effects) describes lookahead for Magic Boost and separates it from per-app Volume Overdrive. AOM uses its own stereo-linked compressor without lookahead and retains its 200% per-app gain range. The available Oracle Ghidra security report covers the installer and RemoteAUHost, not the Magic Boost algorithm; SSAudio evidence `ev_6b6c3fcec3067b9383bdb242743e3de3e28f9d43dd075439aba027bd13339c1a` is a DummyTapRunner procedure search. Neither establishes boost equivalence.

Previously AOM selected the maximum app/output boost setting inside each app stream. The output setting now processes the combined managed audio per output bus, while app boost processes its own stream first. A final linked limiter remains after summing and boost. Both boosts enabled can increase loudness. Native audio bypassed by the engine or AirPlay direct mode is outside this processing path. SoundSource's exact processing, timing, audio character, and full system-output coverage are not claimed.
