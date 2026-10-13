# DeejMac

A macOS menu bar app for a [deej](https://github.com/omriharel/deej) slider/potentiometer box (Arduino sending `v1|v2|...|vN\r\n`, values 0–1023, 9600 baud).

## Build & run

```sh
./build.sh
open build/DeejMac.app
```

Requires macOS 14.2+ and the Xcode Command Line Tools. To start it at login, add `build/DeejMac.app` under System Settings → General → Login Items.

## Assigning sliders

Click the slider icon in the menu bar and choose one or more targets per slider:

| Target          | Effect                                                     | Config value          |
|-----------------|------------------------------------------------------------|-----------------------|
| Master volume   | Volume of the current output device                        | `master`              |
| Microphone      | Input volume of the current input device                   | `mic`                 |
| Everything else | All audio not assigned to another slider                   | `unmapped`            |
| An app          | That app, including its helper processes                   | bundle ID, e.g. `com.spotify.client` |

The config lives in `~/Library/Application Support/DeejMac/config.json` (also editable by hand; restart the app afterwards):

```json
{
  "port": null,
  "baudRate": 9600,
  "invertSliders": false,
  "sliders": [["master"], ["com.spotify.client"], ["com.google.Chrome", "com.hnc.Discord"], ["unmapped"], ["mic"]]
}
```

`port: null` auto-detects `/dev/cu.usbserial*` / `cu.wchusbserial*` / `cu.usbmodem*`.

## How per-app volume works

macOS has no per-app volume API. DeejMac uses Core Audio *process taps* (macOS 14.2+): the tap mutes the
app's normal output and hands DeejMac the audio, which it plays to the current output device scaled by the slider.
On first use macOS asks for **System Audio Recording** permission (System Settings → Privacy & Security →
Screen & System Audio Recording). If you deny it, assigned apps may play silence.
Quitting DeejMac removes the taps, and the apps play normally again.

Notes:
- Safari plays audio through the shared `com.apple.WebKit.GPU` process, so a Safari slider also affects other WebKit apps (Mail, etc.).
- Moving a slider overrides the volume set with the keyboard; the slider position wins the next time it moves.
