#!/usr/bin/env python3
"""Build metadata, package and verify a Universal macOS release using system tools."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "dist/release"
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def validate_tag(version: str, tag: str) -> str:
    if not re.fullmatch(VERSION, version):
        raise ValueError("CFBundleShortVersionString must use MAJOR.MINOR.PATCH.")
    tag = tag or f"v{version}"
    match = re.fullmatch(rf"v({VERSION})(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?", tag)
    if not match or match.group(1) != version:
        raise ValueError(f"Tag {tag!r} must match the app version v{version}.")
    if match.group(2):
        for part in match.group(2).split("."):
            if part.isdigit() and len(part) > 1 and part.startswith("0"):
                raise ValueError("Numeric prerelease identifiers cannot have leading zeroes.")
    return tag


def changelog_section(text: str, version: str) -> str:
    match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not match or not match.group(1).strip():
        raise ValueError(f"CHANGELOG.md needs a nonempty [{version}] section.")
    return match.group(1).strip()


def release_info(tag: str) -> dict:
    with (ROOT / "packaging/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = info["CFBundleShortVersionString"]
    validated_tag = validate_tag(version, tag)
    if not re.fullmatch(r"[1-9][0-9]*", info["CFBundleVersion"]):
        raise ValueError("CFBundleVersion must be a positive integer.")
    notes = changelog_section((ROOT / "CHANGELOG.md").read_text(), version)
    if tag:
        tagged_commit = run("git", "rev-parse", "--verify", f"refs/tags/{validated_tag}^{{commit}}")
        if tagged_commit != run("git", "rev-parse", "HEAD"):
            raise ValueError("The release tag must point at the checked-out commit.")
        if run("git", "status", "--porcelain"):
            raise ValueError("A tagged release requires a clean working tree.")
    return {"tag": validated_tag, "version": version, "build": info["CFBundleVersion"],
            "minimum_macos": info["LSMinimumSystemVersion"], "notes": notes,
            "prerelease": version.startswith("0.") or "-" in validated_tag}


def signature_info(text: str) -> dict:
    if "Signature=adhoc" in text:
        return {"signing": "ad-hoc", "team_id": None}
    team = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", text, re.M)
    if (not team or "Authority=Developer ID Application:" not in text
            or "(runtime)" not in text or "Timestamp=" not in text):
        raise ValueError("Developer ID signatures require a Team ID, hardened runtime and secure timestamp.")
    return {"signing": "developer-id", "team_id": team.group(1)}


def inspect_app(app: Path, info: dict) -> dict:
    with (app / "Contents/Info.plist").open("rb") as stream:
        bundle = plistlib.load(stream)
    expected = {"CFBundleIdentifier": "app.jotlet.mac", "CFBundleExecutable": "Jotlet",
                "CFBundleShortVersionString": info["version"], "CFBundleVersion": info["build"],
                "LSMinimumSystemVersion": info["minimum_macos"]}
    for key, value in expected.items():
        if bundle.get(key) != value:
            raise ValueError(f"App bundle {key} does not match release metadata.")
    binary = app / "Contents/MacOS/Jotlet"
    if not os.access(binary, os.X_OK):
        raise ValueError("The app executable lost its executable permission.")
    if set(run("lipo", "-archs", str(binary)).split()) != {"arm64", "x86_64"}:
        raise ValueError("Release binaries must contain both arm64 and x86_64.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app)], check=True)
    signatures = []
    for arch in ["arm64", "x86_64"]:
        displayed = subprocess.run(["codesign", "--display", "--verbose=4", "--architecture", arch, str(app)],
                                   capture_output=True, text=True, check=True)
        signatures.append(signature_info(displayed.stderr))
    if signatures[0] != signatures[1]:
        raise ValueError("Both architectures must use the same signing identity.")
    signing = signatures[0]
    signing["notarized"] = False
    if signing["signing"] == "developer-id":
        ticket = subprocess.run(["xcrun", "stapler", "validate", str(app)], capture_output=True, text=True)
        signing["notarized"] = ticket.returncode == 0
        if signing["notarized"]:
            subprocess.run(["spctl", "--assess", "--type", "execute", str(app)], check=True)
    for key, value in signing.items():
        if key in info and info[key] != value:
            raise ValueError(f"Actual {key} differs from release metadata.")
    return signing


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_distribution(signing: dict, expected_team: str) -> None:
    if (not re.fullmatch(r"[A-Z0-9]{10}", expected_team)
            or signing != {"signing": "developer-id", "team_id": expected_team, "notarized": True}):
        raise ValueError("Distribution requires notarization and a Developer ID signature from the expected team.")


def package(tag: str, require_notarized: bool = False, expected_team: str = "") -> None:
    info = release_info(tag)
    app = ROOT / "dist/Jotlet.app"
    signing = inspect_app(app, info)
    if require_notarized:
        require_distribution(signing, expected_team)
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    OUTPUT.mkdir(parents=True)
    archive = f"Jotlet-{info['tag']}-universal.zip"
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(OUTPUT / archive)], check=True)
    metadata = {key: value for key, value in info.items() if key != "notes"}
    metadata.update({"schema_version": 1, "architectures": ["arm64", "x86_64"],
                     "source_commit": run("git", "rev-parse", "HEAD"),
                     "source_dirty": bool(run("git", "status", "--porcelain")),
                     "archive": archive, "archive_sha256": digest(OUTPUT / archive), **signing})
    (OUTPUT / "release.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    (OUTPUT / "SHA256SUMS").write_text("".join(f"{digest(OUTPUT / name)}  {name}\n" for name in [archive, "release.json"]))
    signing_note = ("本包已使用 Developer ID 签名并通过 Apple 公证，应用内附带公证票据。\n\n"
                    if signing["notarized"] else
                    "本包尚未完成 Developer ID 签名和 Apple 公证，仅供开发验证。"
                    "请参阅 [Apple 的应用打开说明](https://support.apple.com/en-us/102445)。\n\n")
    notes = (f"{info['notes']}\n\n"
             f"### 下载与安装\n\n"
             f"支持 macOS {info['minimum_macos']} 及以上，下载 `{archive}`，解压后将 `Jotlet.app` 放入应用程序目录。"
             "同一个包包含 Apple Silicon 和 Intel 两种架构。更新前请正常退出旧版，已有便签保存在用户资料库中。\n\n"
             f"{signing_note}"
             "`SHA256SUMS` 可用于核对下载文件，`release.json` 记录版本、构建号、架构和源码提交。\n")
    (OUTPUT / "release-notes.md").write_text(notes)
    print(f"Packaged {OUTPUT / archive}")


def verify(require_notarized: bool = False, expected_team: str = "") -> None:
    info = json.loads((OUTPUT / "release.json").read_text())
    validate_tag(info["version"], info["tag"])
    expected_name = f"Jotlet-{info['tag']}-universal.zip"
    if info["archive"] != expected_name or digest(OUTPUT / expected_name) != info["archive_sha256"]:
        raise ValueError("Release archive name or SHA-256 does not match metadata.")
    expected_sums = "".join(f"{digest(OUTPUT / name)}  {name}\n" for name in [expected_name, "release.json"])
    if (OUTPUT / "SHA256SUMS").read_text() != expected_sums:
        raise ValueError("SHA256SUMS does not match the release files.")
    with tempfile.TemporaryDirectory(prefix="jotlet-release-check-") as folder:
        subprocess.run(["ditto", "-x", "-k", str(OUTPUT / expected_name), folder], check=True)
        signing = inspect_app(Path(folder) / "Jotlet.app", info)
        if require_notarized:
            require_distribution(signing, expected_team)
    print("Verified archive extraction, metadata, both architectures, permissions and code signature.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "package", "verify"])
    parser.add_argument("--tag", default="")
    parser.add_argument("--require-notarized", action="store_true")
    parser.add_argument("--team-id", default="")
    args = parser.parse_args()
    if args.command == "check":
        print(json.dumps(release_info(args.tag), ensure_ascii=False, indent=2))
    elif args.command == "package":
        package(args.tag, args.require_notarized, args.team_id)
    else:
        verify(args.require_notarized, args.team_id)


if __name__ == "__main__":
    main()
