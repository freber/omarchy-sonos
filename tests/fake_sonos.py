#!/usr/bin/env python3
"""A fake Sonos household for the tests and the README preview.

Each speaker listens on its own loopback address (127.0.0.x) and answers the
UPnP calls the `sonos` helper makes, keeping state so a test can check what a
command did. Speakers can be told to refuse an action, answer slowly or the
household can report a different Spotify region.

    python3 tests/fake_sonos.py        serve the preview household on port 1400
"""
import html
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PREVIEW = [  # ip, name, inputs, volume, coordinator ip, (state, title, artist)
    ("127.0.0.1", "Kitchen", [], 32, "127.0.0.1", ("PLAYING", "Bohemian Rhapsody", "Queen")),
    ("127.0.0.2", "Living Room", ["tv"], 46, "127.0.0.2", ("PLAYING", "Teardrop", "Massive Attack")),
    ("127.0.0.3", "Patio", ["line-in"], 34, "127.0.0.2", None),
    ("127.0.0.4", "Office", ["line-in"], 18, "127.0.0.4", ("PAUSED_PLAYBACK", "Clair de Lune", "Claude Debussy")),
    ("127.0.0.5", "Bedroom", [], 12, "127.0.0.5", ("STOPPED", "", "")),
]


class Speaker:
    def __init__(self, ip, name, inputs=(), volume=20):
        self.ip, self.name, self.inputs, self.volume = ip, name, list(inputs), volume
        self.uuid = "RINCON_" + name.upper().replace(" ", "") + "01400"
        self.group = ip          # coordinator ip
        # Only meaningful on a coordinator:
        self.state, self.title, self.artist = "STOPPED", "", ""
        self.uri, self.play_mode, self.mute = "", "NORMAL", False
        self.queue = []


class Household:
    def __init__(self, port, rooms=PREVIEW, spotify_id=9):
        self.port = port
        self.spotify_id = spotify_id
        self.speakers = {}
        self.lock = threading.Lock()
        self.log = []            # (ip, action, args) in arrival order
        self.refuse = {}         # (ip, action) -> UPnP error code
        self.delay = {}          # ip -> seconds before answering
        self.servers = []
        for ip, name, inputs, volume, coord, playing in rooms:
            sp = Speaker(ip, name, inputs, volume)
            sp.group = coord
            if playing:
                sp.state, sp.title, sp.artist = playing
            self.speakers[ip] = sp

    # ---- running
    def start(self):
        for ip in self.speakers:
            server = ThreadingHTTPServer((ip, self.port), self.handler(ip))
            server.daemon_threads = True
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.servers.append(server)
        return self

    def stop(self):
        for server in self.servers:
            server.shutdown()
            server.server_close()

    # ---- helpers for tests
    def by_uuid(self, uuid):
        return next(s for s in self.speakers.values() if s.uuid == uuid)

    def members(self, coord):
        return [s for s in self.speakers.values() if s.group == coord]

    def actions(self, action):
        return [entry for entry in self.log if entry[1] == action]

    # ---- the speaker side
    def topology(self):
        out = "<ZoneGroupState><ZoneGroups>"
        for coord in sorted({s.group for s in self.speakers.values()}):
            out += f'<ZoneGroup Coordinator="{self.speakers[coord].uuid}" ID="{coord}:1">'
            for s in self.members(coord):
                out += f'<ZoneGroupMember UUID="{s.uuid}" Location="http://{s.ip}:{self.port}/xml/device_description.xml" ZoneName="{s.name}"/>'
            out += "</ZoneGroup>"
        return out + "</ZoneGroups></ZoneGroupState>"

    def leave(self, sp):
        """Take a speaker out of its group; a coordinator leaves its members behind."""
        if sp.group == sp.ip:
            rest = [s for s in self.members(sp.ip) if s is not sp]
            if rest:
                heir = rest[0]
                for s in rest:
                    s.group = heir.ip
                heir.state, heir.title, heir.artist, heir.uri = sp.state, sp.title, sp.artist, sp.uri
        sp.group = sp.ip
        sp.state = "STOPPED"

    def act(self, ip, action, body):
        sp = self.speakers[ip]
        arg = lambda tag: html.unescape(m.group(1)) if (m := re.search(f"<{tag}>(.*?)</{tag}>", body, re.S)) else ""
        if action == "GetZoneGroupState":
            return {"ZoneGroupState": self.topology()}
        if action == "GetTransportInfo":
            return {"CurrentTransportState": sp.state}
        if action == "GetTransportSettings":
            return {"PlayMode": sp.play_mode}
        if action == "GetPositionInfo":
            meta = ('<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
                    'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">'
                    f"<item><dc:title>{html.escape(sp.title)}</dc:title><dc:creator>{html.escape(sp.artist)}</dc:creator>"
                    "<upnp:album>Album</upnp:album></item></DIDL-Lite>") if sp.title else ""
            return {"TrackURI": sp.uri or ("x-sonos-spotify:x" if sp.title else ""), "TrackMetaData": meta,
                    "RelTime": "0:01:05", "TrackDuration": "0:04:00" if sp.title else ""}
        if action == "GetVolume":
            return {"CurrentVolume": sp.volume}
        if action == "SetVolume":
            sp.volume = int(arg("DesiredVolume"))
            return {}
        if action == "GetGroupVolume":
            vols = [s.volume for s in self.members(ip)]
            return {"CurrentVolume": round(sum(vols) / len(vols))}
        if action == "SetGroupVolume":
            target = int(arg("DesiredVolume"))
            members = self.members(ip)
            avg = sum(s.volume for s in members) / len(members)
            for s in members:
                s.volume = max(0, min(100, round(s.volume * target / avg) if avg else target))
            return {}
        if action == "GetGroupMute":
            return {"CurrentMute": "1" if sp.mute else "0"}
        if action == "SetGroupMute":
            sp.mute = arg("DesiredMute") == "1"
            return {}
        if action in ("Play", "Pause"):
            sp.state = "PLAYING" if action == "Play" else "PAUSED_PLAYBACK"
            return {}
        if action in ("Next", "Previous"):
            if sp.uri.startswith(("x-sonos-htastream", "x-rincon-stream")):
                raise Refused(711)
            sp.title = ("Next " if action == "Next" else "Previous ") + "song"
            return {}
        if action == "SetPlayMode":
            if sp.uri.startswith(("x-sonos-htastream", "x-rincon-stream")):
                raise Refused(712)
            sp.play_mode = arg("NewPlayMode")
            return {}
        if action == "SetAVTransportURI":
            uri = arg("CurrentURI")
            if uri.startswith("x-rincon:"):
                coord = self.by_uuid(uri[len("x-rincon:"):])
                self.leave(sp)
                sp.group = coord.ip
            else:
                sp.uri = uri
                if uri.startswith("x-sonos-htastream"):
                    sp.title, sp.artist = "TV", ""
                elif uri.startswith("x-rincon-stream"):
                    sp.title, sp.artist = "Line-in", ""
            return {}
        if action == "BecomeCoordinatorOfStandaloneGroup":
            self.leave(sp)
            return {}
        if action == "DelegateGroupCoordinationTo":
            heir = self.by_uuid(arg("NewCoordinator"))
            for s in self.members(ip):
                s.group = heir.ip
            heir.state, heir.title, heir.artist, heir.uri = sp.state, sp.title, sp.artist, sp.uri
            sp.group, sp.state = sp.ip, "STOPPED"
            return {}
        if action == "RemoveAllTracksFromQueue":
            sp.queue = []
            return {}
        if action == "AddURIToQueue":
            sp.queue.append((arg("EnqueuedURI"), arg("EnqueuedURIMetaData")))
            return {"FirstTrackNumberEnqueued": 1}
        if action == "ListAvailableServices":
            return {"AvailableServiceDescriptorList":
                    '<Services><Service Id="254" Name="TuneIn" Version="1.1"/>'
                    f'<Service Id="{self.spotify_id}" Name="Spotify" Version="1.1" Uri="https://example"/></Services>'}
        raise Refused(401)

    def description(self, ip):
        sp = self.speakers[ip]
        services = ["AVTransport", "RenderingControl", "GroupRenderingControl"]
        services += ["HTControl"] if "tv" in sp.inputs else []
        services += ["AudioIn"] if "line-in" in sp.inputs else []
        return "<root><device><modelName>Fake</modelName><serviceList>" + "".join(
            f"<service><serviceType>urn:schemas-upnp-org:service:{s}:1</serviceType></service>" for s in services
        ) + "</serviceList></device></root>"

    def handler(self, ip):
        household = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                body = household.description(ip).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"])).decode()
                action = self.headers["SOAPACTION"].split("#")[1].strip('"')
                time.sleep(household.delay.get(ip, 0))
                with household.lock:
                    household.log.append((ip, action, body))
                    try:
                        if (ip, action) in household.refuse:
                            raise Refused(household.refuse[(ip, action)])
                        out = household.act(ip, action, body)
                        inner = "".join(f"<{k}>{html.escape(str(v))}</{k}>" for k, v in out.items())
                        xml = (f'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
                               f'<u:{action}Response xmlns:u="x">{inner}</u:{action}Response></s:Body></s:Envelope>')
                        code = 200
                    except Refused as e:
                        xml = ('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault>'
                               '<faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>'
                               f'<UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>{e.code}</errorCode>'
                               '</UPnPError></detail></s:Fault></s:Body></s:Envelope>')
                        code = 500
                data = xml.encode()
                self.send_response(code)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        return Handler


class Refused(Exception):
    def __init__(self, code):
        self.code = code


if __name__ == "__main__":
    Household(1400).start()
    print("Fake Sonos household on 127.0.0.1-5:1400. Point the widget at it with "
          'echo \'["127.0.0.1"]\' > ~/.cache/omasonos.json, then ctrl+c to stop.')
    threading.Event().wait()
