#!/usr/bin/env python3
"""Verify the four final debs on Linux; also verify signatures on macOS.

Reads ar/tar using only the Python standard library. Extraction never trusts
archive paths, symlinks or special files. Darwin codesign checks run against
newly extracted FINAL deb payloads, including every nested Mach-O.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import struct
import subprocess
import sys
import tarfile
import tempfile

from package import ARCHITECTURES, ICONS, VERSION, read_control

SUBTYPES = {"arm64": 0, "arm64e": 0x80000002}
REQUIRED_ENTITLEMENTS = (
    "platform-application", "com.apple.private.security.no-container",
    "com.apple.private.security.storage.MobileDocuments",
    "com.apple.private.security.storage.AppBundles",
    "com.apple.private.skip-library-validation", "com.apple.private.security.no-sandbox",
    "com.apple.private.security.storage.AppDataContainers", "get-task-allow")
MACH_MAGICS = (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe",
               b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
               b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_ar(path):
    members = {}
    with path.open("rb") as stream:
        require(stream.read(8) == b"!<arch>\n", "Invalid deb ar magic")
        while True:
            header = stream.read(60)
            if not header:
                break
            require(len(header) == 60 and header[58:] == b"`\n", "Invalid ar header")
            name = header[:16].decode("ascii").rstrip().rstrip("/")
            require(name in ("debian-binary", "control.tar.gz", "data.tar.gz")
                    and name not in members, "Unexpected/duplicate ar member: " + name)
            size = int(header[48:58].decode("ascii").strip())
            require(0 <= size <= path.stat().st_size, "Invalid ar member size")
            members[name] = stream.read(size)
            require(len(members[name]) == size, "Truncated ar member")
            if size % 2:
                require(stream.read(1) == b"\n", "Missing ar alignment byte")
    require(list(members) == ["debian-binary", "control.tar.gz", "data.tar.gz"],
            "deb must contain exactly debian-binary, control.tar.gz, data.tar.gz in order")
    require(members["debian-binary"] == b"2.0\n", "Unsupported Debian format")
    return members


def read_tar(raw):
    files, modes, directories = {}, {}, set()
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as archive:
        for entry in archive:
            name = entry.name
            require(not name.startswith("/") and "\\" not in name and "\x00" not in name,
                    "Unsafe tar path: " + repr(name))
            parts = PurePosixPath(name).parts
            require(parts and ".." not in parts, "Unsafe tar path: " + repr(name))
            clean = PurePosixPath(*parts).as_posix()
            require(clean not in files and clean not in directories, "Duplicate tar entry: " + clean)
            require(entry.isfile() or entry.isdir(), "Links/special tar files are forbidden: " + clean)
            require(not entry.mode & 0o7000, "Unexpected privileged mode: " + clean)
            if entry.isdir():
                directories.add(clean)
            else:
                require(0 <= entry.size <= 256 * 1024 * 1024, "Oversized payload file: " + clean)
                stream = archive.extractfile(entry)
                require(stream is not None, "Unreadable tar file: " + clean)
                files[clean] = stream.read()
                require(len(files[clean]) == entry.size, "Truncated tar file: " + clean)
                modes[clean] = entry.mode & 0o777
    for path in list(files) + list(directories):
        require(not any(parent.as_posix() in files for parent in PurePosixPath(path).parents),
                "File used as parent directory: " + path)
    return files, modes, directories


def entitlements(blob):
    require(len(blob) >= 12, "Truncated Mach-O code signature")
    magic, size, count = struct.unpack_from(">III", blob)
    require(magic == 0xfade0cc0 and size <= len(blob) and 12 + count * 8 <= size,
            "Invalid Mach-O embedded signature")
    for index in range(count):
        kind, offset = struct.unpack_from(">II", blob, 12 + index * 8)
        require(offset + 8 <= size, "Invalid signature slot")
        submagic, length = struct.unpack_from(">II", blob, offset)
        require(length >= 8 and offset + length <= size, "Invalid signature blob length")
        if kind == 5:
            require(submagic == 0xfade7171, "Invalid XML entitlement magic")
            return plistlib.loads(blob[offset + 8:offset + length])
    return {}


def macho(raw, arch, name):
    require(len(raw) >= 32 and raw[:4] == b"\xcf\xfa\xed\xfe",
            name + ": expected a thin little-endian 64-bit Mach-O")
    _, cpu, subtype, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", raw)
    require(cpu == 0x0100000c and subtype == SUBTYPES[arch],
            "{}: expected {} subtype {:#010x}, got CPU {:#x} subtype {:#010x}".format(
                name, arch, SUBTYPES[arch], cpu, subtype))
    require(filetype in (2, 6), name + ": unexpected Mach-O file type")
    require(32 + sizeofcmds <= len(raw), name + ": truncated load commands")
    offset, versions, signature = 32, [], None
    for _ in range(ncmds):
        require(offset + 8 <= 32 + sizeofcmds, name + ": truncated load command")
        cmd, size = struct.unpack_from("<II", raw, offset)
        require(size >= 8 and size % 8 == 0 and offset + size <= 32 + sizeofcmds,
                name + ": invalid load command size")
        if cmd == 0x32:  # LC_BUILD_VERSION, PLATFORM_IOS
            require(size >= 24, name + ": truncated LC_BUILD_VERSION")
            platform, minimum = struct.unpack_from("<II", raw, offset + 8)
            require(platform == 2, name + ": platform is not iOS device")
            versions.append(minimum)
        elif cmd == 0x25:  # LC_VERSION_MIN_IPHONEOS
            require(size >= 16, name + ": truncated iOS deployment command")
            versions.append(struct.unpack_from("<I", raw, offset + 8)[0])
        elif cmd == 0x1d:  # LC_CODE_SIGNATURE
            require(size >= 16 and signature is None, name + ": invalid signature command")
            start, length = struct.unpack_from("<II", raw, offset + 8)
            require(length > 0 and start >= 32 + sizeofcmds and start + length <= len(raw),
                    name + ": missing/truncated signature")
            signature = raw[start:start + length]
        offset += size
    require(offset == 32 + sizeofcmds, name + ": load-command count mismatch")
    require(versions and all(0 < version <= 15 << 16 for version in versions),
            name + ": minimum iOS must be <= 15.0")
    require(signature is not None, name + ": Mach-O must already be signed")
    return {"path": name, "subtype": "0x{:08x}".format(subtype),
            "minimum_ios": ["{}.{}.{}".format(v >> 16, (v >> 8) & 255, v & 255) for v in versions],
            "entitlements": entitlements(signature)}


def verify_signatures(files, modes, app_name, code_names, expected):
    with tempfile.TemporaryDirectory(prefix="themeboard-final-deb-") as temporary:
        directory = Path(temporary)
        for name, raw in files.items():
            path = directory.joinpath(*PurePosixPath(name).parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
            path.chmod(modes[name])
        for name in code_names + ([app_name] if app_name else []):
            subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2",
                            str(directory / name)], check=True)
        # verify_package already parses and compares the embedded signed
        # entitlement blob. The checks above validate that signature itself;
        # never treat codesign's human-readable [Dict] output as a plist.


def verify_package(path, root, arch, kind, signatures):
    members = read_ar(path)
    control, cmodes, cdirs = read_tar(members["control.tar.gz"])
    files, modes, directories = read_tar(members["data.tar.gz"])
    require(set(control) == ({"control", "postinst", "postrm"} if kind == "app"
                             else {"control", "postinst"}) and not cdirs,
            "Unexpected control archive contents")
    with tempfile.TemporaryDirectory(prefix="themeboard-control-") as temp:
        metadata = Path(temp) / "control"
        metadata.write_bytes(control["control"])
        fields = read_control(metadata)
    original = read_control(root / ("control" if kind == "app" else "control.engine"))
    deb_arch, prefix = ARCHITECTURES[arch]
    identity = "com.ning.themeboard" + (".engine" if kind == "engine" else "")
    for key, value in {"Package": identity, "Version": VERSION, "Architecture": deb_arch,
                       "Author": "Ning", "Maintainer": "Ning",
                       "Icon": "file://" + prefix + "/" + ICONS[kind]}.items():
        require(fields.get(key) == value, "Invalid " + key + " in " + path.name)
    require(original.get("Version") == VERSION, "Source control version must be " + VERSION)
    require(fields.get("Depends") == original.get("Depends") and fields.get("Depends"),
            "Depends changed from repository control")
    require(("firmware (>= 15.0)" if kind == "app" else "mobilesubstrate") in fields["Depends"],
            "Required package dependency missing")
    require(int(fields.get("Installed-Size", "-1")) ==
            sum((len(raw) + 1023) // 1024 for raw in files.values()), "Installed-Size mismatch")
    for script in set(control) - {"control"}:
        require(cmodes[script] == 0o755 and control[script].startswith(b"#!/bin/sh\n"),
                "Invalid maintainer script mode/interpreter")
    require(b"@TB_PACKAGE_PREFIX@" not in control["postinst"], "Unexpanded postinst token")
    if kind == "app":
        template = (root / "postinst").read_bytes()
        require(b"@TB_PACKAGE_PREFIX@" in template, "Missing source postinst prefix token")
        require(control["postinst"] == template.replace(b"@TB_PACKAGE_PREFIX@", prefix.encode()),
                "postinst differs from architecture-substituted source template")
        require(control["postrm"] == (root / "postrm").read_bytes(), "postrm differs from source")
    base = prefix.lstrip("/") + "/" if prefix else ""
    if prefix:
        require(all(name.startswith(base) for name in files), "Ordinary rootless files escape /var/jb")
        require(all(name in ("var", "var/jb") or name.startswith(base) for name in directories),
                "Ordinary rootless directories escape /var/jb")
    else:
        require(all(name.split("/")[0] in ("Applications", "Library", "usr")
                    for name in set(files) | directories), "RootHide payload has unexpected install roots")
    icon = base + ICONS[kind]
    require(files.get(icon) == (root / "app/Resources/Icon-large.png").read_bytes(),
            "Package icon must be the original Icon-large.png")
    app = base + "Applications/ThemeBoard.app" if kind == "app" else None
    engine = (app + "/Engine/ThemeBoardEngine.dylib" if app else
              base + "Library/MobileSubstrate/DynamicLibraries/ThemeBoardEngine.dylib")
    require(engine in files, "Missing same-architecture engine")
    engine_plist = engine.removesuffix(".dylib") + ".plist" if hasattr(str, "removesuffix") else engine[:-6] + ".plist"
    require(files.get(engine_plist) == (root / "engine/ThemeBoardEngine.plist").read_bytes(),
            "Engine filter differs from source")
    checks = []
    for name, raw in files.items():
        if raw[:4] in MACH_MAGICS:
            checks.append(macho(raw, arch, name))
    code = {entry["path"]: entry for entry in checks}
    require(engine in code, "Engine is not a signed Mach-O")
    if app:
        executable = app + "/ThemeBoard"
        require(executable in code, "App is not a signed Mach-O")
        require(modes[executable] & 0o111, "App executable has no execute permission")
        info = plistlib.loads(files.get(app + "/Info.plist", b""))
        require(info.get("CFBundleIdentifier") == "com.ning.themeboard" and
                info.get("CFBundleExecutable") == "ThemeBoard" and
                info.get("CFBundleShortVersionString") == VERSION, "Invalid App identity/version")
        require(tuple(map(int, info.get("MinimumOSVersion", "99").split("."))) <= (15, 0),
                "App MinimumOSVersion is greater than 15.0")
        bundle = app + "/Theseus_Theseus.bundle/"
        require(len(files.get(bundle + "default.metallib", b"")) > 0,
                "Missing/empty original Theseus Metal resource bundle")
        plistlib.loads(files.get(bundle + "Info.plist", b""))
        require(files.get(app + "/Engine/version.txt", b"").strip() == VERSION.encode(),
                "Embedded engine version mismatch")
        expected = plistlib.loads((root / "tools/entitlements.plist").read_bytes())
        require(all(expected.get(key) is True for key in REQUIRED_ENTITLEMENTS),
                "Source entitlements omit a required capability")
        require(expected.get("com.apple.security.exception.files.absolute-path.read-write") == ["/"],
                "Source entitlements omit absolute-path access")
        require(code[executable]["entitlements"] == expected, "Embedded App entitlements differ from source")
        require(all(name in code for name in files if name.startswith(app + "/Frameworks/")
                    and name.endswith(".dylib")), "Swift runtime contains non-Mach-O dylib")
    else:
        expected = {}
        require(set(files) == {engine, engine_plist, icon}, "Unexpected engine package payload")
    if signatures:
        verify_signatures(files, modes, app, list(code), expected)
    return {"package": path.name, "architecture": arch, "kind": kind,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "installed_size_kib": int(fields["Installed-Size"]),
            "signatures": "codesign --deep --strict passed" if signatures else "not run (non-Darwin)",
            "mach_o": [{k: v for k, v in entry.items() if k != "entitlements"} for entry in checks],
            "engine_sha256": hashlib.sha256(files[engine]).hexdigest()}


def verify_all(root, dist, arch_filter="both"):
    require(arch_filter in ("both", "arm64", "arm64e"), "Invalid architecture selection")
    signatures = sys.platform == "darwin"
    results = []
    expected = set()
    for arch, (deb_arch, _) in ARCHITECTURES.items():
        if arch_filter != "both" and arch != arch_filter:
            continue
        pair = []
        owned_files, owned_directories = set(), set()
        for kind in ("app", "engine"):
            identity = "com.ning.themeboard" + (".engine" if kind == "engine" else "")
            name = identity + "_" + VERSION + "_" + deb_arch + ".deb"
            expected.add(name)
            members = read_ar(dist / name)
            files, _, directories = read_tar(members["data.tar.gz"])
            collisions = (owned_files & set(files)) | (owned_files & directories) | (owned_directories & set(files))
            require(not collisions, arch + ": co-install file ownership collision: " + ", ".join(sorted(collisions)))
            owned_files.update(files)
            owned_directories.update(directories)
            result = verify_package(dist / name, root, arch, kind, signatures)
            results.append(result)
            pair.append(result["engine_sha256"])
        require(pair[0] == pair[1], arch + ": embedded engine differs from engine deb")
    require({p.name for p in dist.glob("*.deb")} == expected,
            "dist must contain exactly the packages for selected architecture")
    return {"passed": True, "version": VERSION, "selected_architecture": arch_filter,
            "codesign_verified": signatures, "packages": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--dist", type=Path)
    parser.add_argument("--arch", choices=("both", "arm64", "arm64e"), default="both")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        result = verify_all(root, (args.dist or root / "dist").resolve(), args.arch)
        rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(rendered, encoding="utf-8")
        print(rendered, end="")
    except (OSError, ValueError, KeyError, struct.error, tarfile.TarError,
            plistlib.InvalidFileException, subprocess.CalledProcessError) as exc:
        parser.exit(1, "error: " + str(exc) + "\n")


if __name__ == "__main__":
    main()
