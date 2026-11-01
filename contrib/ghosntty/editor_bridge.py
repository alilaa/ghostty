#!/usr/bin/env python3
"""Persistent JSON-lines/GIO bridge for Neovim's editor-control adapter."""
import json
import os
import sys

from gi.repository import Gio, GLib

PATH = "/com/ghosntty/GhosnTTy/EditorControl"
INTERFACE = "com.ghosntty.GhosnTTy.EditorControl1"


class Client:
    def __init__(self):
        self.destination = os.environ["GHOSTTY_CONTROL_BUS"]
        self.surface = int(os.environ["GHOSTTY_SURFACE_ID"], 0)
        self.connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def execute(self, operation, value="", amount=0):
        result = self.connection.call_sync(
            self.destination,
            PATH,
            INTERFACE,
            "Execute",
            GLib.Variant("(tssu)", (self.surface, operation, value, amount)),
            GLib.VariantType.new("(b)"),
            Gio.DBusCallFlags.NO_AUTO_START,
            150,
            None,
        )
        return result.unpack()[0]


def serve(client, source=sys.stdin, sink=sys.stdout):
    try:
        for line in source:
            request = {}
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ValueError("Expected a request object")
                performed = client.execute(
                    request["operation"], request.get("value", ""), request.get("amount", 0)
                )
                response = {"id": request.get("id"), "performed": performed}
            except (GLib.Error, ValueError, TypeError, KeyError, OverflowError) as error:
                response = {
                    "id": request.get("id") if isinstance(request, dict) else None,
                    "performed": False,
                    "error": str(error),
                }
            sink.write(json.dumps(response, ensure_ascii=False) + "\n")
            sink.flush()
    finally:
        # The editor's pipe closes on a crash as well as on normal exit.
        try:
            client.execute("editor", "off")
        except GLib.Error:
            pass


if __name__ == "__main__":
    try:
        serve(Client())
    except (GLib.Error, KeyError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
