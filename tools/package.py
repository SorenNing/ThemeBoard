#!/usr/bin/env python3
"""Package already signed builds; never modify an App after codesign.

Usage: python3 tools/package.py --arch arm64 [--root ROOT] [--build-dir DIR]
Build input: build/ci/{arm64,arm64e}/ThemeBoard.app and engine/ThemeBoardEngine.dylib.
The repository postinst MUST contain @TB_PACKAGE_PREFIX@; substitute /var/jb
for ordinary rootless, or the empty string for RootHide. No marker guessing.
"""
import argparse
import gzip
import os
from pathlib import Path
import plistlib
import shutil
import tarfile

from mkdeb import pack

ARCHITECTURES = {"arm64": ("iphoneos-arm64", "/var/jb"),
                 "arm64e": ("iphoneos-arm64e", "")}
VERSION = "1.51"
ICONS = {"app": "usr/share/icons/com.ning.themeboard.png",
         "engine": "usr/share/icons/com.ning.themeboard.engine.png"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_control(path):
    fields = {}
    previous = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith((" ", "\t")) and previous:
            fields[previous] += "\n" + line
        elif line:
            key, separator, value = line.partition(":")
            require(separator and key not in fields, "Invalid control field: " + line)
            fields[key] = value.strip()
            previous = key
    return fields


def installed_size(directory):
    # Debian Installed-Size is KiB, rounding each regular payload file up.
    return sum((p.stat().st_size + 1023) // 1024
               for p in directory.rglob("*") if p.is_file())


def write_tar(directory, output, epoch):
    with output.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=epoch) as zipped:
            with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for path in sorted(directory.rglob("*")):
                    require(not path.is_symlink(), "Symlinks are not supported: " + str(path))
                    require(path.is_file() or path.is_dir(), "Unexpected payload type: " + str(path))
                    info = archive.gettarinfo(str(path), "./" + path.relative_to(directory).as_posix())
                    info.uid = info.gid = 0
                    info.uname = info.gname = "root"
                    info.mtime = epoch
                    info.pax_headers = {}
                    if path.is_file():
                        with path.open("rb") as stream:
                            archive.addfile(info, stream)
                    else:
                        archive.addfile(info)


def copy_file(source, destination):
    require(source.is_file(), "Missing package input: " + str(source))
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def package(root, build, arch, dist):
    deb_arch, prefix = ARCHITECTURES[arch]
    app = build / "ThemeBoard.app"
    engine = build / "engine/ThemeBoardEngine.dylib"
    require(app.is_dir() and engine.is_file(), "Both signed App and engine are required for " + arch)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    require(info.get("CFBundleShortVersionString") == VERSION, "App version must be " + VERSION)
    require((app / "Engine/ThemeBoardEngine.dylib").read_bytes() == engine.read_bytes(),
            "App must embed the identical, signed same-architecture engine")
    icon = root / "app/Resources/Icon-large.png"
    require(icon.is_file() and icon.stat().st_size > 0, "Missing original Sileo icon")
    postinst = (root / "postinst").read_text(encoding="utf-8")
    require("@TB_PACKAGE_PREFIX@" in postinst,
            "postinst template must contain @TB_PACKAGE_PREFIX@ (ordinary=/var/jb, RootHide=empty)")
    postinst = postinst.replace("@TB_PACKAGE_PREFIX@", prefix)
    require("@TB_PACKAGE_PREFIX@" not in postinst, "Unexpanded package prefix")
    work = build / "packages"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    dist.mkdir(parents=True, exist_ok=True)
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
    require(epoch >= 0, "SOURCE_DATE_EPOCH must be nonnegative")
    outputs = []
    for kind, source_control, identity in (
            ("app", "control", "com.ning.themeboard"),
            ("engine", "control.engine", "com.ning.themeboard.engine")):
        fields = read_control(root / source_control)
        require(fields.get("Package") == identity, "Unexpected package identity")
        require(fields.get("Version") == VERSION, source_control + " must have Version: " + VERSION)
        require(fields.get("Author") == "Ning" and fields.get("Maintainer") == "Ning",
                "Package Author/Maintainer must be Ning")
        require(fields.get("Depends"), "Existing Depends must be preserved")
        fields["Architecture"] = deb_arch
        package_icon = ICONS[kind]
        fields["Icon"] = "file://" + prefix + "/" + package_icon
        stage = work / kind
        data, control = stage / "data", stage / "control"
        data.mkdir(parents=True)
        control.mkdir()
        payload = data / prefix.lstrip("/") if prefix else data
        if kind == "app":
            destination = payload / "Applications/ThemeBoard.app"
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(app, destination, symlinks=True)
            demos = root / "demo-themes"
            if demos.is_dir():
                for theme in sorted(demos.glob("*.theme")):
                    target = payload / "Library/Themes" / theme.name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copytree(theme, target, symlinks=True)
            (control / "postinst").write_text(postinst, encoding="utf-8")
            copy_file(root / "postrm", control / "postrm")
        else:
            destination = payload / "Library/MobileSubstrate/DynamicLibraries"
            copy_file(engine, destination / engine.name)
            copy_file(root / "engine/ThemeBoardEngine.plist", destination / "ThemeBoardEngine.plist")
            (control / "postinst").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        copy_file(icon, payload / package_icon)
        fields["Installed-Size"] = str(installed_size(data))
        (control / "control").write_text(
            "".join(key + ": " + value + "\n" for key, value in fields.items()), encoding="utf-8")
        (control / "control").chmod(0o644)
        for script in ("postinst", "postrm"):
            if (control / script).exists():
                (control / script).chmod(0o755)
        write_tar(control, stage / "control.tar.gz", epoch)
        write_tar(data, stage / "data.tar.gz", epoch)
        (stage / "debian-binary").write_bytes(b"2.0\n")
        output = dist / (identity + "_" + VERSION + "_" + deb_arch + ".deb")
        pack(str(output), [(name, str(stage / name)) for name in
                           ("debian-binary", "control.tar.gz", "data.tar.gz")])
        outputs.append(output)
        print("packaged {} ({} KiB installed)".format(output, fields["Installed-Size"]))
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--arch", choices=ARCHITECTURES, required=True)
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--dist", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        package(root, (args.build_dir or root / "build/ci" / args.arch).resolve(),
                args.arch, (args.dist or root / "dist").resolve())
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as exc:
        parser.exit(1, "error: " + str(exc) + "\n")


if __name__ == "__main__":
    main()
