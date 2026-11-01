import importlib.util
import io
import json
from pathlib import Path
import unittest

from gi.repository import Gio, GLib

spec = importlib.util.spec_from_file_location("editor_bridge", Path(__file__).parents[1] / "editor_bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def test_pipe_eof_releases_editor_after_failed_and_successful_requests(self):
        class Client:
            calls = []

            def execute(self, *args):
                self.calls.append(args)
                return args[0] == "project"

        client = Client()
        source = io.StringIO('\n'.join([
            '{"id":1,"operation":"move","value":"left"}',
            '{"id":2,"operation":"project","value":"å repo;$(literal)"}',
            'invalid JSON',
            '[]',
        ]) + '\n')
        sink = io.StringIO()
        bridge.serve(client, source, sink)
        responses = [json.loads(line) for line in sink.getvalue().splitlines()]
        self.assertFalse(responses[0]["performed"])
        self.assertTrue(responses[1]["performed"])
        self.assertIn("error", responses[2])
        self.assertIn("error", responses[3])
        self.assertEqual(client.calls[-1], ("editor", "off"))
        self.assertEqual(client.calls[1], ("project", "å repo;$(literal)", 0))

    def test_client_preserves_full_surface_id_and_actual_performed_result(self):
        class Connection:
            args = None

            def call_sync(self, *args):
                self.args = args
                return GLib.Variant("(b)", (False,))

        client = bridge.Client.__new__(bridge.Client)
        client.destination = ":1.42"
        client.surface = 0xFEDCBA9876543210
        client.connection = Connection()
        self.assertFalse(client.execute("resize", "right", 3))
        args = client.connection.args
        self.assertEqual(args[4].unpack(), (client.surface, "resize", "right", 3))
        self.assertEqual(args[6], Gio.DBusCallFlags.NO_AUTO_START)
        self.assertEqual(args[7], 150)


if __name__ == "__main__":
    unittest.main()
