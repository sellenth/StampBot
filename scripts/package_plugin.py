#!/usr/bin/env python3
"""Build a deterministic plugin ZIP from an explicit, credential-free file list."""
import argparse
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, default=root / "tmp/stampbot-plugin.zip")
args = parser.parse_args()
source = root / "plugins/stampbot"
manifest = json.loads((source / "plugin.json").read_text())
mcp = json.loads((source / "mcp.json").read_text())
interface = manifest["extensions"]["com.openai"]["interface"]
assert len(interface["displayName"]) <= 30
assert len(interface["shortDescription"]) <= 30
assert len(interface["longDescription"]) <= 4000
assert mcp["mcpServers"]["stampbot"]["url"] == "https://stamp-bot.com/mcp"
files = ["plugin.json", "mcp.json", "assets/icon.png", "assets/logo.png"]
args.output.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(args.output, "w", compression=ZIP_DEFLATED) as archive:
    for name in files:
        info = ZipInfo(name, date_time=(2026, 9, 30, 0, 0, 0))
        info.compress_type = ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        archive.writestr(info, (source / name).read_bytes())
print(args.output.resolve())
