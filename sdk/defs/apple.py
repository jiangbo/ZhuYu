#!/usr/bin/env python3
"""按引擎调用生成精简 Apple TBD，不提取或修改 SDK 材料。"""

import argparse
from concurrent.futures import ThreadPoolExecutor
from functools import cache
import json
from pathlib import Path
import re
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
    """按 Sokol 的 Metal 配置编译，只收集目标文件的链接符号。"""
    name = f"{target}-{int(fast)}-{source.stem}"
    obj = work / f"{name}.o"
    result = subprocess.run([
        zig, "cc", "-target", target, "-x", "objective-c",
        "-DIMPL", "-DSOKOL_METAL", "-O3" if fast else "-O0",
        *(["-DNDEBUG"] if fast else []),
        # SDK 头文件优先于 Zig 内置版本，只忽略旧 SDK 自身的声明警告。
        "-Wno-deprecated-declarations", "-Wno-macro-redefined",
        "-I", str(sdk / "usr/include"),
        "-iframework", str(sdk / "System/Library/Frameworks"),
        "-c", str(source), "-o", str(obj),
    ], capture_output=True, text=True)
    # 旧 SDK 自身的声明警告很多，维护工具只在失败时报告编译器输出。
    if result.returncode:
        raise RuntimeError(result.stderr)
    return symbols(obj)


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


def generate(zig, sdk, sources, targets, frameworks, output):
    """合并 Sokol 和引擎直接调用的符号，只生成精简 Framework 和 objc。"""
    if output == sdk or output.is_relative_to(sdk):
        raise ValueError("output must be outside the input SDK")
    source = Path(__file__).resolve().parents[2] / "src/internal/apple.zig"
    font_symbols = {"_" + name for name in re.findall(
        r"extern (?:fn|var) (\w+)", source.read_text("utf-8")
    )}
    required = {}
    with tempfile.TemporaryDirectory(prefix="zhuyu-apple-defs-") as folder:
        work = Path(folder)
        with ThreadPoolExecutor(max_workers=4) as pool:
            for target, arch in targets:
                defined = set()
                undefined = set()
                for fast in (False, True):
                    jobs = [pool.submit(compile_source, zig, sdk, source,
                                        target, fast, work) for source in sources]
                    for job in jobs:
                        defs, refs = job.result()
                        defined.update(defs)
                        undefined.update(refs)
                required[arch] = (undefined - defined) | font_symbols
        stage = work / "output"
        provided = {target: set() for target in required}
        for name in (*frameworks, "objc"):
            relative = (Path("usr/lib/libobjc.tbd") if name == "objc" else
                        Path(f"System/Library/Frameworks/{name}.framework/{name}.tbd"))
            found = write_library(sdk, sdk / relative, stage / relative, required)
            for target, names in found.items():
                provided[target].update(names)
        # libSystem 使用 SDK 的完整公开接口，仅用于覆盖校验，不写入 defs。
        for target, names in required.items():
            for group in library_groups(sdk, sdk / "usr/lib/libSystem.tbd", target):
                provided[target].update(exports(group))
            missing = {name for name in names - provided[target]
                       if not name.startswith("___ubsan_") and
                       name != "___isPlatformVersionAtLeast"}
            if missing:
                raise ValueError(f"unresolved {target} symbols: {sorted(missing)}")
        # 全部生成并校验后写入，不删除输入 SDK 或已有符号文件。
        shutil.copytree(stage, output, dirs_exist_ok=True)
    print(f"generated {len(frameworks) + 1} TBD files in {output}", flush=True)


def main():
    """平台材料路径显式传入，输出默认位于本仓库的 sdk/defs。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("macos", "ios"))
    parser.add_argument("sdk", type=Path, help="Original Apple SDK directory")
    parser.add_argument("sokol", type=Path, help="Sokol src/sokol/c directory")
    parser.add_argument("--simulator", type=Path, help="Original iOS Simulator SDK")
    parser.add_argument("--zig", default="zig", help="Zig executable")
    parser.add_argument("--output", type=Path, help="Output platform defs directory")
    args = parser.parse_args()
    if args.platform == "ios" and args.simulator is None:
        parser.error("--simulator is required for ios")
    sources = sorted(path for path in args.sokol.resolve().glob("*.c")
                     if "imgui" not in path.name)
    if not sources:
        raise ValueError("no Sokol C sources")
    output = (args.output or Path(__file__).resolve().parent / args.platform).resolve()
    if args.platform == "macos":
        generate(args.zig, args.sdk.resolve(), sources, (
            ("aarch64-macos.14.0", "arm64-macos"),
            ("x86_64-macos.14.0", "x86_64-macos"),
        ), ("AppKit", "Metal", "QuartzCore", "AudioToolbox", "Foundation",
            "CoreGraphics", "CoreFoundation", "CoreText"), output)
    else:
        for name, sdk, targets in (
            ("device", args.sdk, (("aarch64-ios.15.0", "arm64-ios"),)),
            ("simulator", args.simulator, (
                ("aarch64-ios.15.0-simulator", "arm64-ios-simulator"),
                ("x86_64-ios.15.0-simulator", "x86_64-ios-simulator"),
            )),
        ):
            generate(args.zig, sdk.resolve(), sources, targets, (
                "UIKit", "Metal", "QuartzCore", "AudioToolbox", "AVFoundation",
                "AVFAudio", "Foundation", "CoreGraphics", "CoreFoundation",
                "CoreText",
            ), output / name)


if __name__ == "__main__":
    main()
