"""Tests for the `sonos` helper against a fake household on loopback addresses.

    python3 -m unittest discover tests

Nothing here touches real speakers: every speaker is a fake on 127.0.0.x on a
free port; caches and config go to a temporary directory.
"""
import importlib.machinery
import importlib.util
import ipaddress
import json
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from fake_sonos import Household

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(ROOT, "sonos")
ROOMS = [  # ip, name, inputs, volume, coordinator ip, (state, title, artist)
    ("127.0.0.1", "Kitchen", [], 30, "127.0.0.1", ("PLAYING", "Song A", "Artist A")),
    ("127.0.0.2", "Living Room", ["tv"], 40, "127.0.0.2", ("PAUSED_PLAYBACK", "Song B", "Artist B")),
    ("127.0.0.3", "Patio", ["line-in"], 20, "127.0.0.2", None),
    ("127.0.0.4", "Office", [], 10, "127.0.0.4", ("STOPPED", "", "")),
]
DEAD = "127.0.0.250"  # nothing listens here


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class HelperTest(unittest.TestCase):
    """Starts a fresh household per test and loads the helper as a module."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.port = free_port()
        self.env = {**os.environ, "OMASONOS_PORT": str(self.port), "OMASONOS_MPRIS": "0",
                    "XDG_CACHE_HOME": os.path.join(self.tmp, "cache"),
                    "XDG_CONFIG_HOME": os.path.join(self.tmp, "config")}
        self.home = Household(self.port, ROOMS).start()
        saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)
        loader = importlib.machinery.SourceFileLoader("sonos_under_test", HELPER)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.sonos = importlib.util.module_from_spec(spec)
        loader.exec_module(self.sonos)
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def tearDown(self):
        self.home.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_helper(self, *args):
        out = subprocess.run([HELPER, "--hosts", "127.0.0.1", *args], env=self.env,
                             capture_output=True, text=True, timeout=20)
        return out.returncode, out.stdout

    def status(self):
        code, out = self.run_helper("status")
        self.assertEqual(code, 0, out)
        return json.loads(out)

    def group(self, data, name):
        return next(g for g in data["groups"] if name in g["name"])

    def room(self, data, name):
        return next(r for r in data["rooms"] if r["name"] == name)


class OneShotTest(HelperTest):
    def test_status_lists_groups_rooms_and_inputs(self):
        data = self.status()
        self.assertEqual([g["name"] for g in data["groups"]], ["Kitchen", "Living Room + Patio", "Office"])
        living = self.group(data, "Living")
        self.assertEqual((living["state"], living["title"], living["artist"]), ("PAUSED_PLAYBACK", "Song B", "Artist B"))
        self.assertEqual(living["volume"], 30)  # average of 40 and 20
        self.assertEqual(self.room(data, "Patio")["group"], "127.0.0.2")
        self.assertEqual(self.room(data, "Living Room")["inputs"], ["tv"])
        self.assertEqual(self.room(data, "Patio")["inputs"], ["line-in"])
        self.assertNotIn("error", data)

    def test_transport_controls(self):
        self.run_helper("pause", "127.0.0.1")
        self.assertEqual(self.home.speakers["127.0.0.1"].state, "PAUSED_PLAYBACK")
        self.run_helper("play", "127.0.0.1")
        self.assertEqual(self.home.speakers["127.0.0.1"].state, "PLAYING")
        self.run_helper("next", "127.0.0.1")
        self.assertEqual(self.group(self.status(), "Kitchen")["title"], "Next song")

    def test_group_volume_scales_speakers(self):
        self.run_helper("volume", "127.0.0.2", "60")
        self.assertEqual((self.home.speakers["127.0.0.2"].volume, self.home.speakers["127.0.0.3"].volume), (80, 40))
        self.run_helper("speaker-volume", "127.0.0.3", "150")
        self.assertEqual(self.home.speakers["127.0.0.3"].volume, 100)  # clamped

    def test_mute_and_play_mode(self):
        self.run_helper("mute", "127.0.0.1", "on")
        self.run_helper("play-mode", "127.0.0.1", "SHUFFLE")
        kitchen = self.group(self.status(), "Kitchen")
        self.assertEqual((kitchen["muted"], kitchen["playMode"]), (True, "SHUFFLE"))
        self.run_helper("mute", "127.0.0.1", "off")
        self.assertFalse(self.group(self.status(), "Kitchen")["muted"])

    def test_join_leave_and_hand_over(self):
        office = self.home.speakers["127.0.0.4"]
        self.run_helper("join", "127.0.0.4", self.home.speakers["127.0.0.1"].uuid)
        self.assertEqual(office.group, "127.0.0.1")
        self.run_helper("leave", "127.0.0.4")
        self.assertEqual(office.group, "127.0.0.4")
        # A coordinator leaving hands the group and its music to the heir.
        self.run_helper("leave", "127.0.0.2", self.home.speakers["127.0.0.3"].uuid)
        patio = self.home.speakers["127.0.0.3"]
        self.assertEqual((patio.group, patio.title), ("127.0.0.3", "Song B"))

    def test_sources(self):
        living = self.home.speakers["127.0.0.2"]
        self.run_helper("source", "127.0.0.2", "tv", living.uuid)
        self.assertEqual((living.uri, living.state), (f"x-sonos-htastream:{living.uuid}:spdif", "PLAYING"))
        self.assertEqual(self.group(self.status(), "Living")["source"], "tv")
        patio = self.home.speakers["127.0.0.3"]
        self.run_helper("source", "127.0.0.1", "line-in", patio.uuid)
        self.assertEqual(self.home.speakers["127.0.0.1"].uri, f"x-rincon-stream:{patio.uuid}")

    def test_refusal_is_explained(self):
        living = self.home.speakers["127.0.0.2"]
        self.run_helper("source", "127.0.0.2", "tv", living.uuid)
        code, out = self.run_helper("play-mode", "127.0.0.2", "SHUFFLE")
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(out)["error"], "not supported for this source")

    def test_unreachable_speaker_is_explained(self):
        with self.assertRaises(OSError) as caught:
            self.sonos.control("pause", DEAD)
        self.assertEqual(self.sonos.describe(caught.exception), "the speaker didn't answer")

    def test_spotify_region_is_detected(self):
        self.assertEqual(self.sonos.spotify_service("127.0.0.1"), 2311)  # Europe, Id 9
        self.home.spotify_id = 12
        self.assertEqual(self.sonos.spotify_service("127.0.0.1"), 3079)  # US
        os.makedirs(os.path.dirname(self.sonos.SPOTIFY_CONF))
        with open(self.sonos.SPOTIFY_CONF, "w") as f:
            json.dump({"client_id": "x", "sonos_service": 1234}, f)
        self.assertEqual(self.sonos.spotify_service("127.0.0.1"), 1234)  # manual setting wins

    def test_play_uri_replaces_queue(self):
        kitchen = self.home.speakers["127.0.0.1"]
        kitchen.queue = [("old", "")]
        self.run_helper("play-uri", "127.0.0.1", "spotify:album:abc", kitchen.uuid)
        self.assertEqual(len(kitchen.queue), 1)
        uri, meta = kitchen.queue[0]
        self.assertEqual(uri, "x-rincon-cpcontainer:1004206cspotify%3aalbum%3aabc")
        self.assertIn("SA_RINCON2311_X_#Svc2311-0-Token", meta)
        self.assertEqual(kitchen.state, "PLAYING")


class ConnectionTest(HelperTest):
    def test_dropped_spare_falls_back_to_new_connection(self):
        self.sonos.add_spare("127.0.0.1")
        sock, _ = self.sonos.spares["127.0.0.1"]
        sock.shutdown(socket.SHUT_RDWR)  # as if the speaker had dropped it
        self.sonos.control("pause", "127.0.0.1")
        self.assertEqual(self.home.speakers["127.0.0.1"].state, "PAUSED_PLAYBACK")
        self.assertEqual(len(self.home.actions("Pause")), 1)  # sent exactly once

    def test_no_network_and_other_networks(self):
        searches = []
        self.sonos.discover = lambda nets: searches.append(nets) or []
        self.sonos.save_hosts([{"members": [{"ip": "192.168.11.100"}]}])
        server = self.sonos.Server([])
        server.emit = lambda obj: None
        server.interval = 1

        self.sonos.local_networks = lambda: ()
        with self.assertRaisesRegex(RuntimeError, "No network"):
            server.find_groups()

        cafe = (ipaddress.ip_network("10.9.9.0/24"),)
        self.sonos.local_networks = lambda: cafe
        started = time.monotonic()
        for _ in range(5):
            self.assertEqual(server.find_groups(), [])
        self.assertLess(time.monotonic() - started, 0.5)  # home speakers are never waited on
        self.assertEqual(searches, [cafe])                # one search per network, not per poll


class ServeTest(HelperTest):
    """Drives `sonos serve` the way the widget does."""

    def setUp(self):
        super().setUp()
        self.proc = subprocess.Popen([HELPER, "--hosts", "127.0.0.1", "serve"], env=self.env, text=True,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=1)
        self.lines = queue.Queue()
        threading.Thread(target=lambda: [self.lines.put(json.loads(l)) for l in self.proc.stdout], daemon=True).start()

    def tearDown(self):
        self.proc.stdin.close()
        self.proc.wait(5)
        self.proc.stdout.close()
        super().tearDown()

    def send(self, **msg):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def next_of(self, kind, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            msg = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            if msg["type"] == kind:
                return msg

    def watch(self):
        self.send(cmd="watch", interval=1)
        return self.next_of("status")

    def test_status_then_quiet_when_nothing_changes(self):
        data = self.watch()
        self.assertEqual(len(data["groups"]), 3)
        self.assertNotIn("position", data["groups"][0])
        with self.assertRaises(queue.Empty):
            self.next_of("status", timeout=2.5)

    def test_control_is_confirmed_quickly(self):
        self.watch()
        sent = time.monotonic()
        self.send(cmd="pause", ip="127.0.0.1")
        while self.group(self.next_of("status"), "Kitchen")["state"] != "PAUSED_PLAYBACK":
            pass
        self.assertLess(time.monotonic() - sent, 1.0)

    def test_volume_drag_ends_on_the_last_level(self):
        self.watch()
        self.home.delay["127.0.0.1"] = 0.05
        for level in range(10, 60, 3):
            self.send(cmd="speaker-volume", ip="127.0.0.1", value=level)
        self.send(cmd="speaker-volume", ip="127.0.0.1", value=42)
        deadline = time.monotonic() + 5
        while self.home.speakers["127.0.0.1"].volume != 42 and time.monotonic() < deadline:
            time.sleep(0.05)
        time.sleep(0.3)
        self.assertEqual(self.home.speakers["127.0.0.1"].volume, 42)
        sent = [int(body.split("<DesiredVolume>")[1].split("<")[0]) for _, _, body in self.home.actions("SetVolume")]
        self.assertEqual(sent[-1], 42)
        self.assertLess(len(sent), 18)  # levels were combined, not all sent

    def test_failure_is_reported(self):
        self.watch()
        self.home.refuse[("127.0.0.1", "Next")] = 800
        self.send(cmd="next", ip="127.0.0.1")
        failed = self.next_of("failed")
        self.assertEqual((failed["ip"], failed["cmd"], failed["error"]), ("127.0.0.1", "next", "the speaker refused"))

    def test_group_all_and_ungroup_all(self):
        self.watch()
        self.send(cmd="group-all", ip="127.0.0.1")
        deadline = time.monotonic() + 5
        while len(self.home.members("127.0.0.1")) < 4 and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertEqual(len(self.home.members("127.0.0.1")), 4)
        while len(self.next_of("status")["groups"]) != 1:
            pass
        self.send(cmd="ungroup-all")
        deadline = time.monotonic() + 5
        while any(s.group != s.ip for s in self.home.speakers.values()) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(all(s.group == s.ip for s in self.home.speakers.values()))


@unittest.skipUnless(shutil.which("dbus-run-session") and shutil.which("gdbus"), "needs dbus-run-session and gdbus")
class MediaKeysTest(HelperTest):
    """Runs the helper on a private D-Bus session and presses media keys over MPRIS."""

    def test_media_keys_control_the_focused_group(self):
        script = f"""
            set -e
            {HELPER} --hosts 127.0.0.1 serve < <(echo '{{"cmd":"watch","interval":1}}'; echo '{{"cmd":"focus","ip":"127.0.0.1"}}'; sleep 6) > /dev/null &
            for i in $(seq 50); do
              gdbus call --session -d org.mpris.MediaPlayer2.sonos -o /org/mpris/MediaPlayer2 \\
                -m org.freedesktop.DBus.Properties.Get org.mpris.MediaPlayer2.Player PlaybackStatus 2>/dev/null | grep -q Playing && break
              sleep 0.1
            done
            gdbus call --session -d org.mpris.MediaPlayer2.sonos -o /org/mpris/MediaPlayer2 \\
              -m org.freedesktop.DBus.Properties.Get org.mpris.MediaPlayer2 Identity
            gdbus call --session -d org.mpris.MediaPlayer2.sonos -o /org/mpris/MediaPlayer2 \\
              -m org.mpris.MediaPlayer2.Player.PlayPause
            sleep 0.5
        """
        env = {**self.env, "OMASONOS_MPRIS": "1"}
        out = subprocess.run(["dbus-run-session", "--", "bash", "-c", script], env=env,
                             capture_output=True, text=True, timeout=30)
        self.assertIn("Sonos · Kitchen", out.stdout, out.stderr)
        self.assertEqual(self.home.speakers["127.0.0.1"].state, "PAUSED_PLAYBACK")


if __name__ == "__main__":
    unittest.main()
