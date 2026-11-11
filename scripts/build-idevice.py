#!/usr/bin/env python3
"""Build the optional pinned backend. All downloaded/generated artifacts stay in tmp/."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--debug", action="store_true", help="Build without release optimizations")
parser.add_argument("--offline", action="store_true", help="Use previously fetched dependencies")
args = parser.parse_args()
local_cargo = root / "tmp/cargo-home/bin/cargo"
cargo = str(local_cargo) if local_cargo.is_file() else shutil.which("cargo")
if not cargo:
    sys.exit("Rust/Cargo is required to build the optional idevice backend. See docs/DEPENDENCIES.md.")
env = os.environ.copy()
env["CARGO_HOME"] = str(root / "tmp/cargo-home")
if (root / "tmp/rustup").is_dir():
    env["RUSTUP_HOME"] = str(root / "tmp/rustup")
command = [cargo, "build", "--locked", "--manifest-path", str(root / "Backends/IDevice/Cargo.toml"),
           "--target-dir", str(root / "tmp/idevice-build")]
if not args.debug:
    command.append("--release")
if args.offline:
    command.append("--offline")
subprocess.run(command, cwd=root, env=env, check=True)
destination = root / "tmp/bin/appledevices-idevice"
destination.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "tmp/idevice-build" / ("debug" if args.debug else "release") / "appledevices-idevice", destination)
print(f"Built {destination}; add {destination.parent} to PATH.")
