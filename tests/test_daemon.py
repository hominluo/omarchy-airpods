"""Tests for the watchdog's pure logic.

`bin/bt-call-daemon` has no `.py` suffix because it is an executable, so it is
loaded through SourceFileLoader. The parts worth testing are the ones that
decide whether a call is happening and where playback returns afterwards;
they only need a `pw-dump` shaped list, so no hardware is involved.
"""

import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(os.path.dirname(HERE), "bin", "bt-call-daemon")

_loader = importlib.machinery.SourceFileLoader("bt_call_daemon", DAEMON)
_spec = importlib.util.spec_from_loader("bt_call_daemon", _loader)
daemon = importlib.util.module_from_spec(_spec)
_loader.exec_module(daemon)

CARD = "bluez_card.68_CA_C4_C4_57_7C"
BT_SOURCE = "bluez_input.68:CA:C4:C4:57:7C"


def node(node_id, name, media_class=None, app=None):
    props = {"node.name": name}
    if media_class is not None:
        props["media.class"] = media_class
    if app is not None:
        props["application.name"] = app
    return {"id": node_id, "type": "PipeWire:Interface:Node", "info": {"props": props}}


def link(input_id, output_id):
    return {"id": 100 + input_id,
            "type": "PipeWire:Interface:Link",
            "info": {"props": {"link.input.node": input_id,
                               "link.output.node": output_id}}}


class MicUsersTest(unittest.TestCase):
    def test_counts_only_streams_linked_to_the_headset(self):
        dump = [
            node(1, "bluez_input.68:CA:C4:C4:57:7C", "Audio/Source"),
            node(2, "alsa_input.pci-0000_00_1f.3.analog-stereo", "Audio/Source"),
            node(10, "discord", "Stream/Input/Audio", "Discord"),
            node(11, "obs", "Stream/Input/Audio", "OBS"),
            link(10, 1),
            link(11, 2),
        ]
        self.assertEqual(daemon.mic_users(dump, CARD), ["Discord"])

    def test_ignores_level_meters_and_internal_streams(self):
        dump = [
            node(1, BT_SOURCE, "Audio/Source"),
            node(10, "peak-detect", "Stream/Input/Audio", "Peak Detect"),
            node(11, "internal", "Stream/Input/Audio/Internal", "WirePlumber"),
            link(10, 1),
            link(11, 1),
        ]
        self.assertEqual(daemon.mic_users(dump, CARD), [])

    def test_underscore_and_colon_source_names_both_match(self):
        self.assertTrue(daemon.is_bt_source({"node.name": BT_SOURCE}, CARD))
        self.assertTrue(daemon.is_bt_source({"node.name": "bluez_input.68_CA_C4_C4_57_7C"}, CARD))
        self.assertFalse(daemon.is_bt_source({"node.name": "bluez_output.68_CA_C4_C4_57_7C.a2dp-sink"}, CARD))


class A2dpHomeTest(unittest.TestCase):
    """Where playback goes after a call: pre-call profile, then the picked one,
    then a bare a2dp-sink."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.pick = os.path.join(self.tmp.name, "a2dp-68_CA_C4_C4_57_7C")
        patcher = mock.patch.object(daemon, "PICK_DIR", self.tmp.name)
        patcher.start()
        self.addCleanup(patcher.stop)
        offers = mock.patch.object(
            daemon, "offered",
            return_value={"a2dp-sink", "a2dp-sink-sbc", "a2dp-sink-sbc_xq"})
        offers.start()
        self.addCleanup(offers.stop)

    def test_pre_call_profile_wins(self):
        with open(self.pick, "w") as f:
            f.write("a2dp-sink-sbc_xq")
        self.assertEqual(daemon.a2dp_home(CARD, "a2dp-sink-sbc"), "a2dp-sink-sbc")

    def test_pick_wins_when_there_was_no_call(self):
        with open(self.pick, "w") as f:
            f.write("a2dp-sink-sbc_xq")
        self.assertEqual(daemon.a2dp_home(CARD, None), "a2dp-sink-sbc_xq")

    def test_vanished_pick_falls_back_to_a2dp_sink(self):
        with open(self.pick, "w") as f:
            f.write("a2dp-sink-aptx")
        self.assertEqual(daemon.a2dp_home(CARD, None), "a2dp-sink")


if __name__ == "__main__":
    unittest.main()
