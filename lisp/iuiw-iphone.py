#!/usr/bin/env python3
"""Build an Xcode project and install it on the iPhone, over Tailscale if no cable is in.

  iuiw-iphone.py capture            save the iPhone's pairing record; needs the cable
  iuiw-iphone.py deploy PROJECT     build PROJECT, install it and launch it

CoreDevice finds an iPhone through Bonjour, which Tailscale does not carry, so `relay`
publishes the iPhone's record with this Mac's address and forwards its ports to the tailnet.
"""
import asyncio
import json
import plistlib
import re
import resource
import signal
import subprocess
import sys
import time
from pathlib import Path

CONFIG = Path.home() / ".config/iuiw/iphone.json"
CACHE = Path.home() / "Library/Caches/iuiw-iphone"
TAILSCALE = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
SERVICE = "_remotepairing._tcp"
# The iPhone counts tunnel ports up from here. The rest of macOS's ephemeral range,
# 49152-65535, must stay free or this Mac can no longer open outbound connections.
PORTS = [49152, *range(54000, 56001)]


def fail(message):
    sys.exit(f"iuiw-iphone: {message}")


def output(*command):
    return subprocess.run(command, capture_output=True, text=True).stdout


def briefly(*command, seconds=3):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
    time.sleep(seconds)
    process.terminate()
    return process.communicate()[0]


def capture():
    browsed = briefly("dns-sd", "-B", SERVICE, "local.")
    instances = re.findall(r"\bAdd\b.*?([0-9A-F-]{36})", browsed)
    if not instances:
        fail("no pairing record found; connect the iPhone by cable and unlock it")
    instance = instances[-1]
    record = briefly("dns-sd", "-L", instance, SERVICE, "local.")
    host = re.search(r"can be reached at (\S+?)\.?:\d+", record)
    tag = re.search(r"authTag=(\S+)", record)
    version = re.search(r"\bver=(\d+)", record)
    if not (host and tag and version):
        fail("the pairing record is incomplete")
    settings = load() if CONFIG.exists() else {}
    settings.update(instance=instance, host=host[1], version=version[1],
                    tag=tag[1].replace("\\", ""))
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.touch(mode=0o600)
    CONFIG.write_text(json.dumps(settings, indent=2))
    print(f"saved {CONFIG}")


def load():
    if not CONFIG.exists():
        fail(f"{CONFIG} is missing; run capture with the cable in")
    return json.loads(CONFIG.read_text())


def addresses():
    mac = output("ipconfig", "getifaddr", "en0").strip()
    peers = json.loads(output(TAILSCALE, "status", "--json") or "{}").get("Peer", {})
    phones = [peer for peer in peers.values() if peer.get("OS") == "iOS" and peer.get("Online")]
    if not mac:
        fail("this Mac has no address on en0")
    if not phones:
        fail("the iPhone is not online on Tailscale")
    return mac, phones[0]["TailscaleIPs"][0]


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except OSError:
        pass
    finally:
        writer.close()


def forward(mac, phone, port):
    async def handle(reader, writer):
        # These ports are open to the LAN; only this Mac may reach the iPhone through them.
        if writer.get_extra_info("peername")[0] != mac:
            writer.close()
            return
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(phone, port)
        except OSError:
            writer.close()
            return
        await asyncio.gather(pipe(reader, upstream_writer), pipe(upstream_reader, writer))
    return handle


async def serve(mac, phone):
    for port in PORTS:
        try:
            await asyncio.start_server(forward(mac, phone, port), mac, port, reuse_address=True)
        except OSError:
            pass
    await asyncio.Event().wait()


def relay():
    settings = load()
    mac, phone = addresses()
    resource.setrlimit(resource.RLIMIT_NOFILE,
                       (8192, resource.getrlimit(resource.RLIMIT_NOFILE)[1]))
    record = subprocess.Popen(
        ["dns-sd", "-P", settings["instance"], SERVICE, "local", "49152",
         settings["host"], mac, f"identifier={settings['instance']}",
         f"authTag={settings['tag']}", f"ver={settings['version']}", "minVer=8", "flags=0"],
        stdout=subprocess.DEVNULL)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        asyncio.run(serve(mac, phone))
    finally:
        record.terminate()


def device_state(udid):
    for line in output("xcrun", "devicectl", "list", "devices").splitlines():
        if udid in line:
            return "unavailable" if "unavailable" in line else "available"
    return "missing"


def wait_available(udid, seconds=60):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if device_state(udid) == "available":
            return True
        time.sleep(2)
    return False


def build(project, settings):
    name = project.stem
    data = CACHE / name
    build_log = data.with_suffix(".log")
    data.parent.mkdir(parents=True, exist_ok=True)
    print(f"building {name}", flush=True)
    with build_log.open("w") as log:
        result = subprocess.run(
            ["xcodebuild", "build", "-project", str(project), "-scheme", name,
             "-configuration", "Debug", "-destination", "generic/platform=iOS",
             "-derivedDataPath", str(data), "-allowProvisioningUpdates",
             f"DEVELOPMENT_TEAM={settings['team']}", "CODE_SIGN_STYLE=Automatic"],
            stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        errors = [line for line in build_log.read_text().splitlines() if "error:" in line]
        fail("build failed\n" + "\n".join(errors[-5:]) + f"\nfull log: {build_log}")
    return next((data / "Build/Products/Debug-iphoneos").glob("*.app"))


def install(udid, app):
    attempts = 3
    for attempt in range(1, attempts + 1):
        print("installing", flush=True)
        result = subprocess.run(
            ["xcrun", "devicectl", "device", "install", "app", "--device", udid, str(app)],
            capture_output=True, text=True)
        if result.returncode == 0:
            return
        if attempt < attempts:
            wait_available(udid, 20)
    fail("install failed\n" + result.stdout + result.stderr)


def launch(udid, app):
    bundle = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", udid,
                    "--terminate-existing", bundle], capture_output=True)


def deploy(project):
    settings = load()
    udid = settings["udid"]
    app = build(Path(project).expanduser().resolve(), settings)
    forwarding = None
    try:
        if device_state(udid) != "available":
            print("relaying over Tailscale", flush=True)
            addresses()
            forwarding = subprocess.Popen([sys.executable, "-I", __file__, "relay"])
            if not wait_available(udid):
                fail("the iPhone did not appear; is it on Wi-Fi with Tailscale on?")
        install(udid, app)
        launch(udid, app)
    finally:
        if forwarding:
            forwarding.terminate()
            forwarding.wait()
    print("installed", flush=True)


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["capture"]:
            capture()
        case ["relay"]:
            relay()
        case ["deploy", project]:
            deploy(project)
        case _:
            sys.exit(__doc__)
