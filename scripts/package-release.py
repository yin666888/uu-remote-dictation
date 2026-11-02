#!/usr/bin/env python3
"""Package explicit public sources and built apps, without local configuration."""
from pathlib import Path
import hashlib
import plistlib
import shutil
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CORE = ("Sources", "Resources", "Package.swift", "LICENSE")
APPS = ("远控听写.app", "远控直输接收端.app")
version = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
out = ROOT / "dist/release"
if out.exists():
    raise SystemExit("dist/release already exists; move it aside before packaging again")
for name in APPS:
    app = ROOT / "dist" / name
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != version:
        raise SystemExit("Rebuild both applications before packaging")
out.mkdir(parents=True)

def copy(source, target):
    if source.is_dir():
        shutil.copytree(source, target, ignore=shutil.ignore_patterns(".DS_Store", "__pycache__"))
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

def bundle(source, target):
    with zipfile.ZipFile(target, "x", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(source.rglob("*")):
            if path.is_symlink():
                raise RuntimeError("Unexpected symlink in release")
            archive.write(path, Path(source.name) / path.relative_to(source))

with tempfile.TemporaryDirectory(prefix="remote-dictation-release-") as temporary:
    stage = Path(temporary)
    skill = stage / "uu-remote-dictation"
    copy(ROOT / "packaging/skill", skill)
    for name in CORE:
        copy(ROOT / name, skill / "assets/source" / name)
    copy(ROOT / "scripts/build-app.sh", skill / "assets/source/scripts/build-app.sh")
    for name in APPS:
        copy(ROOT / "dist" / name, skill / "assets/apps" / name)
    skill_zip = out / f"uu-remote-dictation-skill-v{version}.zip"
    bundle(skill, skill_zip)
    share = stage / f"remote-dictation-v{version}"
    share.mkdir()
    for name in APPS:
        copy(ROOT / "dist" / name, share / name)
    copy(ROOT / "docs/安装说明.md", share / "安装说明.md")
    copy(ROOT / "LICENSE", share / "LICENSE")
    copy(skill_zip, share / "uu-remote-dictation.zip")
    records = []
    for path in sorted(share.rglob("*")):
        if path.is_file():
            records.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(share)}")
    (share / "SHA256SUMS.txt").write_text("\n".join(records) + "\n")
    bundle(share, out / f"remote-dictation-v{version}.zip")
records = [f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}" for p in sorted(out.glob("*.zip"))]
(out / "SHA256SUMS.txt").write_text("\n".join(records) + "\n")
print(f"Release assets: {out}")
