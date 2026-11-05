#!/usr/bin/env python3
"""Run either installed native package under xvfb-run + dbus-run-session."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from gi.repository import Gio, GLib


with tempfile.TemporaryDirectory(prefix="ghosntty-smoke-") as temporary:
    root = Path(temporary)
    ready = root / "first.json"
    second = root / "second.json"
    child = (
        "import json,os,sys,time; "
        "json.dump({k:os.environ[k] for k in "
        "['GHOSTTY_CONTROL_BUS','GHOSTTY_SURFACE_ID','GHOSTTY_NVIM_RUNTIME']},"
        "open(sys.argv[1],'w')); time.sleep(90)"
    )
    log = (root / "desktop.log").open("w+")
    # `-e` forces gtk-single-instance=false, which would leave +new-tab with no
    # primary instance to talk to, so the first child is run via `command`.
    script = root / "child.py"
    script.write_text(child)
    process = subprocess.Popen(
        ["ghosntty", "--config-default-files=false",
         "--config-file=/usr/share/ghosntty/profile/config.ghostty",
         "--gtk-single-instance=true", "--gtk-editor-control-spawn=true", "--window-show-tab-bar=always",
         f"--command=/usr/bin/python3 {script} {ready}"],
        env={**os.environ, "GDK_BACKEND": "x11", "LIBGL_ALWAYS_SOFTWARE": "1"},
        stdout=log, stderr=log,
    )

    def wait_child(path):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"GhosnTTy exited: {process.returncode}")
            try:
                return json.loads(path.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(0.1)
        raise TimeoutError(f"Terminal child did not start: {path}")

    try:
        environment = wait_child(ready)
        assert Path(environment["GHOSTTY_NVIM_RUNTIME"], "lua/ghostty_control.lua").is_file()
        connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)

        def execute(surface, operation, value="", amount=0):
            return connection.call_sync(
                environment["GHOSTTY_CONTROL_BUS"],
                "/com/ghosntty/GhosnTTy/EditorControl",
                "com.ghosntty.GhosnTTy.EditorControl1", "Execute",
                GLib.Variant("(tssu)", (surface, operation, value, amount)),
                GLib.VariantType.new("(b)"), Gio.DBusCallFlags.NO_AUTO_START,
                3000, None,
            ).unpack()[0]

        surface = int(environment["GHOSTTY_SURFACE_ID"], 0)
        assert execute(surface, "project", "GhosnTTy smoke å")
        assert not execute(0, "project", "invalid pane")
        assert not execute(surface, "project", "invalid\nidentity")
        # This uses the default branded application ID and object path.
        subprocess.run(
            ["ghosntty", "+new-tab", f"--surface-id={surface}",
             "-e", "/usr/bin/python3", "-c", child, str(second)],
            check=True, timeout=15,
        )
        other = wait_child(second)
        assert other["GHOSTTY_SURFACE_ID"] != environment["GHOSTTY_SURFACE_ID"]
        assert other["GHOSTTY_CONTROL_BUS"] == environment["GHOSTTY_CONTROL_BUS"]
        assert execute(surface, "project", "Background tab")

        def control(method, args, reply):
            return connection.call_sync(
                environment["GHOSTTY_CONTROL_BUS"],
                "/com/ghosntty/GhosnTTy/EditorControl",
                "com.ghosntty.GhosnTTy.EditorControl1", method, args,
                GLib.VariantType.new(reply), Gio.DBusCallFlags.NO_AUTO_START,
                5000, None,
            ).unpack()[0]

        third = root / "third.json"
        split = control("Split", GLib.Variant(
            "(tssas)", (surface, "left", temporary,
                        ["/usr/bin/python3", str(script), str(third)])), "(t)")
        assert int(wait_child(third)["GHOSTTY_SURFACE_ID"], 16) == split
        panes = {pane[0]: pane for pane in control("ListSurfaces", None, "(a(tsssb))")}
        assert {surface, split} <= panes.keys()
        assert panes[surface][3] == panes[split][3] and panes[split][4]
        for bad in [(surface, "diagonal", "", []), (surface, "left", "rel", [])]:
            try:
                control("Split", GLib.Variant("(tssas)", bad), "(t)")
                raise AssertionError(f"Split accepted {bad}")
            except GLib.Error:
                pass
        assert control("Focus", GLib.Variant("(t)", (surface,)), "(b)")
        assert not control("Focus", GLib.Variant("(t)", (1,)), "(b)")
        print("Installed GTK package, new-tab IPC, and editor-control D-Bus: passed")
    except BaseException:
        log.flush()
        log.seek(0)
        print(log.read())
        raise
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()
