#!/usr/bin/env python3
"""Compila localmente, mantém atual/anterior e abre uma única instância."""
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.0.0.32"
RELEASES = ROOT / "releases"
CURRENT = RELEASES / "PainelCli.app"
PREVIOUS = RELEASES / "PainelCli-anterior.app"

def pids(bundle):
    executable = str(bundle / "Contents/MacOS/PainelCli")
    rows = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    return [int(parts[0]) for row in rows.splitlines()
            if len(parts := row.strip().split(None, 1)) == 2 and parts[1] == executable]

def stop(bundle):
    for pid in pids(bundle):
        os.kill(pid, signal.SIGTERM)
    for _ in range(50):
        if not pids(bundle):
            return
        time.sleep(.1)
    raise RuntimeError(f"A instância exata não encerrou: {bundle}")

def launch(bundle):
    subprocess.run(["open", str(bundle)], check=True)
    time.sleep(2)
    if not pids(bundle):
        raise RuntimeError(f"Processo não observado após abertura: {bundle}")

RELEASES.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix=".build-", dir=ROOT) as temporary:
    binary = Path(temporary) / "PainelCli"
    subprocess.run(["xcrun", "swiftc", str(ROOT / "Sources/CLIEntryStore.swift"),
                    str(ROOT / "Sources/CLIInstaller.swift"), str(ROOT / "Sources/main.swift"),
                    "-o", str(binary), "-framework", "AppKit"], check=True)
    print("Compilação concluída", flush=True)
    stop(CURRENT)
    stop(PREVIOUS)
    if CURRENT.exists():
        if PREVIOUS.exists():
            shutil.rmtree(PREVIOUS)
        CURRENT.rename(PREVIOUS)
    try:
        contents = CURRENT / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        shutil.copy2(binary, contents / "MacOS/PainelCli")
        (contents / "Resources").mkdir()
        shutil.copy2(ROOT / "Resources/AppIcon.icns", contents / "Resources/AppIcon.icns")
        with (contents / "Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleExecutable": "PainelCli", "CFBundleName": "PainelCli",
                "CFBundleIdentifier": "app.painelcli.desktop", "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": VERSION, "CFBundleVersion": VERSION,
                "CFBundleIconFile": "AppIcon.icns",
                "NSHighResolutionCapable": True}, output)
        subprocess.run(["codesign", "--force", "--sign", "-", str(CURRENT)], check=True)
        launch(CURRENT)
        print(f"Aberto: {CURRENT}; PIDs: {pids(CURRENT)}", flush=True)
    except Exception:
        stop(CURRENT)
        if CURRENT.exists():
            shutil.rmtree(CURRENT)
        if PREVIOUS.exists():
            PREVIOUS.rename(CURRENT)
            launch(CURRENT)
            print("Versão anterior reaberta após falha verificável.", flush=True)
        raise
