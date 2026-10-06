# Sonos for Omarchy

A fast Sonos bar widget for the Omarchy shell. A speaker icon in the bar opens a compact popup with every room or group: what's playing, play/pause/skip, volume and mute, shuffle and repeat, TV and line-in, room grouping and Spotify search. Media keys control Sonos too.

![The Sonos popup: rooms with playback controls, a grouped room expanded to shuffle, repeat, TV and line-in, per-speaker volume and room chips](preview.png)

## Built for speed

The official Sonos apps feel sluggish. This widget is built to be the opposite:

- **Instant feedback:** every press updates the popup immediately and the speakers confirm in the background, typically within 0.3 s.
- **No cloud:** it talks straight to the speakers on your network, never through Sonos' servers.
- **Always running:** the helper stays alive next to the shell, so a click never waits for anything to start.
- **No one-second stalls:** speakers on Wi-Fi sometimes drop the first packet of a connection and TCP waits a full second to retry. The helper races a fresh attempt every 150 ms instead.
- **Live state:** while the popup is open it reads every speaker once a second, so changes from the Sonos app, other people or the buttons on a speaker show up within a second.
- **Fast search:** the Spotify connection is opened when the popup opens and reused, so results arrive as you type.

## Install

```sh
omarchy plugin add https://github.com/freber/omarchy-sonos.git --enable
```

Needs `python3` (standard library only). Speakers are found automatically.

## Remove

```sh
omarchy plugin remove freber.sonos
rm -rf ~/.config/omasonos ~/.cache/omasonos.json ~/.cache/omasonos-inputs.json ~/.cache/omasonos-spotify-token.json
```

The second line removes the Spotify login and the cached speaker addresses and inputs. Nothing else on the system is changed.

## Use

- **Bar icon:** left click opens the popup. Middle click plays/pauses. Scroll changes the volume of the room that's playing.
- **Rooms:** each group shows an animated spectrum while playing. Long room names and song titles roll so they can be read in full. Click a room's name to make it the one search and media keys control.
- **Mute:** tap the volume number. It turns into a mute icon until you tap it again.
- **More per room:** the ⋯ button on a room (the 🔗 badge on a group) expands a room to shuffle and repeat, TV and line-in inputs where the speakers have them, one volume slider per speaker and chips for every room. Tap a room chip to add or remove that room; it pulses until Sonos confirms.
- **Group all / Ungroup all:** under the rooms. Group all joins every room into the highlighted one.
- **Media keys:** play/pause, next and previous control the highlighted room through Omarchy's media controls. This needs `python-gobject`, which Omarchy ships.
- **Errors:** if a speaker refuses something (shuffle on TV input, say) the room shows why for a few seconds in red.
- **Search:** type in the search field, pick where it plays with the "Play in" chips, then `enter` or click a result. `esc` clears, then closes.

## Spotify search

Sonos keeps your Spotify login on the speakers but doesn't expose search on the local network. Search uses Spotify's Web API instead. Playback still goes through the Spotify account linked in Sonos.

The popup shows a login card until Spotify is connected:

1. Once: create an app on the [Spotify dashboard](https://developer.spotify.com/dashboard) with redirect URI `http://127.0.0.1:8888/callback` (the card has a copy button) and Web API ticked. Paste its Client ID.
2. Click **Log in with Spotify** and approve in the browser.

The login uses OAuth with PKCE (no client secret). A refresh token is kept in `~/.config/omasonos/spotify.json` (readable only by you), so you log in once. The button next to the search field logs out.

The Spotify region (Europe or US) is read from your speakers. If playing from search ever fails, set it by hand in that file: `"sonos_service": 2311` for Europe or `3079` for the US.

## Troubleshooting

- **No speakers found:** discovery uses SSDP with a subnet scan as fallback. If your speakers are on another VLAN, set their IP on the widget's entry in `~/.config/omarchy/shell.json`: `{ "id": "freber.sonos", "hosts": "192.168.1.20" }`.
- **`redirect_uri: Not matching configuration`:** the redirect URI in your Spotify app must be exactly `http://127.0.0.1:8888/callback`. Save the app settings after adding it.

## How it works

`sonos` is a small Python helper (standard library only) that speaks UPnP to the speakers. The widget runs it as `sonos serve`, a long-running process that takes commands and returns status as JSON lines; it exits with the shell. Speaker addresses are cached in `~/.cache/omasonos.json`, so a full status update is one parallel round trip to every speaker. Volume changes go out one at a time per speaker with the newest value, so dragging a slider never lands out of order.

`serve` also shows the highlighted room as a desktop media player (MPRIS) named "Sonos · room".

The same helper works from a terminal: `sonos status`, `sonos play <ip>`, `sonos volume <ip> 30` and so on. Run `sonos help` for the full list.

## Development

`tests/` has a fake Sonos household: speakers on 127.0.0.x that remember their state and can refuse actions or answer slowly. The tests drive the real helper against it, so they never touch your speakers:

```sh
python3 -m unittest discover tests
```

`python3 tests/fake_sonos.py` serves the same fake household on port 1400 for trying the widget or taking screenshots.

## License

MIT
