# AudioControl

Menu-bar app for per-app audio routing and volume, and for restoring default devices.

On launch and on every wake from sleep:

- If the configured output device is connected, it becomes the default output and the sound effects output. With Target Output Volume set to a level, its volume is set to that level and unmuted; with "Don't Change" (default), volume and mute are left as they are.
- If the configured input device is connected, it becomes the default input. Target Input Volume works the same way, also defaulting to "Don't Change".

A target that is not connected is left alone. Retries for 20 s to catch Bluetooth devices that reconnect late.

### Per-app settings

The Apps section lists every running app that uses audio. Each app has:

- **Volume** - 0-100% slider, applied only to that app.
- **Output** - device the app's audio plays on, or System Default.
- **Input** - device made the system default input while the app is capturing, or System Default.

Volume and Output use Core Audio process taps: the app's audio is muted at the source and replayed on the chosen device at the chosen volume. Quitting AudioControl returns every app to normal. Requires the System Audio Recording permission (System Settings > Privacy & Security > Screen & System Audio Recording); without it, routed apps are silent.

Music is the exception for Volume: its slider works like Music's own volume slider, over AppleScript. While Music plays to AirPlay (which bypasses Core Audio) it sets the selected receivers' volume, otherwise Music's player volume. Receivers that ignore AirPlay volume but accept Denon/Marantz network control (TCP port 23) are set directly, with 100% at the receiver's volume limit; this needs the Local Network permission. Requires the Automation permission for Music; reset restores the volume Music had before the first change.

macOS has no per-app input selection, so Input switches the system default input while the app captures. The most recently started capture wins. When no app with an Input setting is capturing, the default input returns to Target Input Device, or to the device it was before. Apps that pick their own microphone instead of following the system default are not affected.

## Build / install

```sh
./build.sh            # builds build/AudioControl.app
./build.sh --install  # also copies it to /Applications
```

## Use

1. Open `/Applications/AudioControl.app` (speaker icon in the menu bar).
2. Target Output Device / Target Input Device -> pick the devices; Target Output Volume / Target Input Volume -> pick the levels.
3. Apps -> pick an app -> set Volume, Output, Input.
4. Enable Launch at Login.

Logs: `log stream --predicate 'subsystem == "com.morrishoresh.AudioControl"'`

Devices without software volume (most HDMI/DisplayPort outputs) are switched to, but volume is left unchanged.

The menu-bar icon shows a warning badge when the current output or input is not the configured target.

Requires macOS 14.4 or later.
