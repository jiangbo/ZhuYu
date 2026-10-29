#!/usr/bin/env python3
"""从 Apple SDK 提取 Sokol 材料；仅维护时需要 Python、PyYAML 和 Zig。"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from functools import cache
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import tempfile
import textwrap

import yaml


def symbols(path):
    """读取 64 位 Mach-O 目标文件，区分外部定义和未定义符号。"""
    data = path.read_bytes()
    if struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError(f"expected a 64-bit Mach-O object: {path}")
    defined = set()
    undefined = set()
    pos = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, pos)
        # LC_SYMTAB 给出 nlist_64 数组和符号名称表的位置。
        if command == 2:
            offset, count, strings, _ = struct.unpack_from("<4I", data, pos + 8)
            for row in range(count):
                index, kind, _, _, value = struct.unpack_from(
                    "<IBBHQ", data, offset + row * 16
                )
                # 跳过调试符号和局部符号；未定义的公共符号值为零。
                if kind & 0xE0 or not kind & 1:
                    continue
                start = strings + index
                name = data[start:data.index(0, start)].decode()
                if kind & 0x0E or value:
                    defined.add(name)
                else:
                    undefined.add(name)
            return defined, undefined
        pos += size
    raise ValueError(f"missing Mach-O symbol table: {path}")


def compile_source(zig, sdk, source, target, fast, work):
    """按 Sokol 的 Metal 配置编译，同时收集实际包含的头文件。"""
    name = f"{target}-{int(fast)}-{source.stem}"
    obj = work / f"{name}.o"
    dep = work / f"{name}.d"
    result = subprocess.run([
        zig, "cc", "-target", target, "-x", "objective-c",
        "-DIMPL", "-DSOKOL_METAL", "-O3" if fast else "-O0",
        *(["-DNDEBUG"] if fast else []),
        # SDK 头文件优先于 Zig 内置版本，只忽略旧 SDK 自身的声明警告。
        "-Wno-deprecated-declarations", "-Wno-macro-redefined",
        "-I", str(sdk / "usr/include"),
        "-iframework", str(sdk / "System/Library/Frameworks"),
        "-MD", "-MF", str(dep), "-MT", "deps",
        "-c", str(source), "-o", str(obj),
    ], capture_output=True, text=True)
    # 旧 SDK 自身的声明警告很多，维护工具只在失败时报告编译器输出。
    if result.returncode:
        raise RuntimeError(result.stderr)
    paths = shlex.split(dep.read_text().replace("\\\n", " "))[1:]
    # 保留 pthread.h 等符号链接的入口名称，输出时复制成普通文件。
    headers = {Path(os.path.abspath(path)) for path in paths}
    return symbols(obj), {path for path in headers if path.is_relative_to(sdk)}


def exports(group):
    """将 TBD 的 Objective-C 分类展开成实际链接符号，用于覆盖检查。"""
    result = set(group.get("symbols", []))
    result.update(group.get("weak-def-symbols", []))
    result.update(group.get("thread-local-symbols", []))
    for name in group.get("objc-classes", []):
        result.add(f"_OBJC_CLASS_$_{name}")
        result.add(f"_OBJC_METACLASS_$_{name}")
    result.update(f"_OBJC_IVAR_$_{name}" for name in group.get("objc-ivars", []))
    result.update(f"_OBJC_EHTYPE_$_{name}" for name in group.get("objc-eh-types", []))
    return result


@cache
def read_library(path):
    """缓存原始 TBD，避免多个框架和架构重复解析同一份内容。"""
    return list(yaml.load_all(path.read_text(), Loader=yaml.BaseLoader))


def library_path(sdk, name):
    """将真实加载路径映射到 SDK 的 TBD，兼容展开后的 Framework 目录。"""
    relative = name.lstrip("/").removesuffix(".dylib")
    for relative in (relative, re.sub(r"/Versions/[^/]+/", "/", relative)):
        path = sdk / f"{relative}.tbd"
        if path.is_file():
            return path
    raise FileNotFoundError(f"missing reexported library in {sdk}: {name}")


def library_groups(sdk, source, target):
    """按真实重导出关系展开内嵌及外部 TBD，保持父框架的符号可见性。"""
    docs = read_library(source)
    libraries = {doc["install-name"]: doc for doc in docs}
    targets = {target}
    # 模拟器的系统接口经桥接库重导出到宿主 macOS，保留同架构接口。
    if docs[0]["install-name"] == "/usr/lib/libSystem.B.dylib" and \
            target.endswith("-ios-simulator"):
        targets.add(target.replace("-ios-simulator", "-macos"))
    pending = [docs[0]]
    seen = set()
    while pending:
        doc = pending.pop()
        if doc["install-name"] in seen:
            continue
        seen.add(doc["install-name"])
        for group in doc.get("exports", []) + doc.get("reexports", []):
            if targets.intersection(group["targets"]):
                yield group
        for group in doc.get("reexported-libraries", []):
            if targets.intersection(group["targets"]):
                for name in group["libraries"]:
                    if name not in libraries:
                        for child in read_library(library_path(sdk, name)):
                            libraries.setdefault(child["install-name"], child)
                    pending.append(libraries[name])


def write_library(sdk, source, dest, required):
    """保留真实加载路径和版本，按架构筛选导出，不引入无关重导出依赖。"""
    docs = read_library(source)
    data = {"tbd-version": 4, "targets": list(required)}
    for key in ("install-name", "current-version", "compatibility-version"):
        if key in docs[0]:
            data[key] = docs[0][key]
    groups = []
    provided = {target: set() for target in required}
    for target, names in required.items():
        selected = {}
        for group in library_groups(sdk, source, target):
            for key, values in group.items():
                if key == "targets":
                    continue
                for value in values:
                    if exports({key: [value]}) & names:
                        selected.setdefault(key, set()).add(value)
        group = {"targets": [target]}
        group.update({key: sorted(values) for key, values in selected.items()})
        groups.append(group)
        provided[target].update(exports(group))
    data["exports"] = groups
    dest.parent.mkdir(parents=True, exist_ok=True)
    # 使用 SDK 相同的块映射和行内数组，兼容 Zig 的 TBD 解析器。
    lines = ["--- !tapi-tbd\n", "tbd-version: 4\n",
             f"targets: {json.dumps(data['targets'])}\n",
             f"install-name: {json.dumps(data['install-name'])}\n"]
    for key in ("current-version", "compatibility-version"):
        if key in data:
            lines.append(f"{key}: {data[key]}\n")
    lines.append("exports:\n")
    for group in groups:
        for key, values in group.items():
            prefix = "  - " if key == "targets" else "    "
            lines.append(textwrap.fill(
                json.dumps(values), width=84, initial_indent=f"{prefix}{key}: ",
                subsequent_indent="                     ",
                break_long_words=False, break_on_hyphens=False,
            ) + "\n")
    dest.write_text("".join(lines) + "...\n")
    return provided


def extract(zig, sdk, sources, targets, frameworks, output, links):
    """收集各架构的编译材料，将精简链接描述与稳定 SDK 材料分开。"""
    headers = set()
    required = {}
    with tempfile.TemporaryDirectory(prefix="zhuyu-apple-") as work:
        with ThreadPoolExecutor(max_workers=4) as pool:
            for target, arch in targets:
                defined = set()
                undefined = set()
                for fast in (False, True):
                    jobs = [pool.submit(
                        compile_source, zig, sdk, source,
                        target, fast, Path(work),
                    ) for source in sources]
                    for job in jobs:
                        (defs, refs), paths = job.result()
                        defined.update(defs)
                        undefined.update(refs)
                        headers.update(paths)
                required[arch] = undefined - defined

    # 两类目录只存放生成材料，重新提取时清除旧版本留下的文件。
    for root in (output, links):
        for name in ("usr", "System"):
            if (root / name).exists():
                shutil.rmtree(root / name)
    records = []
    for path in sorted(headers):
        relative = path.relative_to(sdk).as_posix()
        if relative.startswith("usr/include/"):
            name = relative.removeprefix("usr/include/")
        else:
            match = re.search(
                r"/([^/]+)\.framework/(?:Versions/[^/]+/)?Headers/(.*)$",
                "/" + relative,
            )
            if match is None:
                raise ValueError(f"unsupported SDK header path: {relative}")
            name = f"{match[1]}/{match[2]}"
        dest = output / "usr/include" / name
        if dest.exists() and dest.read_bytes() != path.read_bytes():
            raise ValueError(f"conflicting SDK headers: {name}")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
        records.append(f"{relative} -> usr/include/{name}\n")

    provided = {target: set() for target in required}
    for name in (*frameworks, "objc"):
        if name == "objc":
            relative = Path("usr/lib/libobjc.tbd")
        else:
            relative = Path(f"System/Library/Frameworks/{name}.framework/{name}.tbd")
        dest = links / relative
        found = write_library(sdk, sdk / relative, dest, required)
        for target, names in found.items():
            provided[target].update(names)
        records.append(f"{relative} -> {os.path.relpath(dest, output)}\n")

    # Zig 标准库也使用系统接口，libSystem 保留完整的公开接口集合。
    (output / "usr/lib").mkdir(parents=True, exist_ok=True)
    path = sdk / "usr/lib/libSystem.tbd"
    system = {}
    for target in required:
        names = set()
        for group in library_groups(sdk, path, target):
            names.update(exports(group))
        system[target] = names
        provided[target].update(names)
    if any(target.endswith("-ios-simulator") for target in required):
        # 展平宿主桥接的重导出，最终程序仍只依赖公开的 libSystem。
        write_library(sdk, path, output / "usr/lib/libSystem.tbd", system)
    else:
        shutil.copyfile(path, output / "usr/lib/libSystem.tbd")
    records.append(f"usr/lib/libSystem.tbd -> usr/lib/libSystem.tbd\n")
    for target, names in required.items():
        missing = {name for name in names - provided[target]
                   if not name.startswith("___ubsan_") and
                   name != "___isPlatformVersionAtLeast"}
        if missing:
            raise ValueError(f"unresolved {target} symbols: {sorted(missing)}")
    settings = json.loads((sdk / "SDKSettings.json").read_text())
    # 部分模拟器 SDK 的展示名带有前缀，Zig 的链接器需要纯版本号。
    if settings["MinimalDisplayName"].startswith("Simulator - "):
        settings["MinimalDisplayName"] = settings["Version"]
    (output / "SDKSettings.json").write_text(json.dumps(settings) + "\n")
    records.append(f"SDKSettings.json -> SDKSettings.json\n")
    (output / "FILES.txt").write_text("".join(records))
    print(f"{output.name}: {len(headers)} headers, "
          f"{len(frameworks) + 2} TBD files", flush=True)


def main(platform, output):
    """平台入口只指定 SDK、编译目标和 Sokol 实际依赖的框架。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path, help="Apple SDK directory")
    if platform == "ios":
        parser.add_argument("simulator", type=Path, help="iOS Simulator SDK")
    parser.add_argument("sokol", type=Path, help="Sokol src/sokol/c directory")
    parser.add_argument("--zig", default="zig", help="Zig executable")
    args = parser.parse_args()
    sources = sorted(path for path in args.sokol.resolve().glob("*.c")
                     if "imgui" not in path.name)
    if not sources:
        raise ValueError("no Sokol C sources")
    # 裁剪范围随 Sokol 变化，精简 TBD 写入独立的版本控制目录。
    links = output.parent / "defs" / platform
    if platform == "macos":
        extract(args.zig, args.sdk.resolve(), sources, (
            ("aarch64-macos.14.0", "arm64-macos"),
            ("x86_64-macos.14.0", "x86_64-macos"),
        ), ("AppKit", "Metal", "QuartzCore", "AudioToolbox",
            "Foundation", "CoreGraphics", "CoreFoundation"), output, links)
    else:
        for name, sdk, targets in (
            ("device", args.sdk, (("aarch64-ios.15.0", "arm64-ios"),)),
            ("simulator", args.simulator, (
                ("aarch64-ios.15.0-simulator", "arm64-ios-simulator"),
                ("x86_64-ios.15.0-simulator", "x86_64-ios-simulator"),
            )),
        ):
            extract(args.zig, sdk.resolve(), sources, targets, (
                "UIKit", "Metal", "QuartzCore", "AudioToolbox", "AVFoundation",
                "AVFAudio", "Foundation", "CoreGraphics", "CoreFoundation",
            ), output / name, links / name)
