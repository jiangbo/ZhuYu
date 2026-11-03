#!/usr/bin/env python3
"""根据 Sokol 的实际引用生成 Linux 库清单；仅维护时需要 Python 和 readelf。"""

import argparse
from pathlib import Path
import subprocess


def references(paths):
    """合并目标文件或静态库的未定义符号，排除 Sokol 自己提供的实现。"""
    undefined = set()
    defined = set()
    for path in paths:
        output = subprocess.check_output(
            ["readelf", "--syms", "--wide", str(path)], text=True
        )
        for line in output.splitlines():
            fields = line.split()
            if len(fields) < 8 or not fields[0].endswith(":"):
                continue
            if fields[4] not in ("GLOBAL", "WEAK"):
                continue
            name = fields[7].split("@")[0]
            if fields[6] == "UND":
                undefined.add(name)
            else:
                defined.add(name)
    return undefined - defined


def symbols(path, required):
    """只保留 Sokol 引用的默认导出，排除历史版本别名。"""
    output = subprocess.check_output(
        ["readelf", "--dyn-syms", "--wide", str(path)], text=True
    )
    result = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 8 or not fields[0].endswith(":"):
            continue
        size, kind, bind, visible, section, name = fields[2:8]
        if bind not in ("GLOBAL", "WEAK"):
            continue
        if visible not in ("DEFAULT", "PROTECTED") or section in ("UND", "ABS"):
            continue
        # 链接器生成的段边界不是库接口。
        if kind == "NOTYPE" and name in (
            "_end", "_edata", "__bss_start", "__bss_start__", "_bss_end__",
            "__bss_end__", "__end__",
        ):
            continue
        if "@" in name and "@@" not in name:
            continue
        # 默认版本也是 ABI 的一部分，保留 @@ 后的版本供链接器使用。
        base = name.split("@")[0]
        if base not in required:
            continue
        if kind in ("FUNC", "IFUNC"):
            result[base] = name
        elif kind == "OBJECT":
            if int(size) == 0:
                raise ValueError(f"zero-sized data symbol: {name}")
            result[base] = f"{name} data {size}"
        else:
            raise ValueError(f"unsupported symbol: {name} ({kind})")
    return "".join(result[name] + "\n" for name in sorted(result))


def main():
    """合并 GLX、GLES 的 Debug 和 ReleaseFast 产物，更新指定 ABI 清单。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("abi", choices=("gnu", "musl"), help="Linux libc ABI")
    parser.add_argument("libraries", type=Path, help="Directory of Linux .so files")
    parser.add_argument("sokol", type=Path, nargs="+", help="Sokol .a or .o files")
    args = parser.parse_args()
    required = references(args.sokol)
    if not required:
        raise ValueError("no undefined symbols in Sokol inputs")
    # 清单写入脚本旁的 ABI 目录，与引擎构建代码一起维护。
    output = Path(__file__).resolve().parent / args.abi
    output.mkdir(parents=True, exist_ok=True)
    for name, soname in (
        ("asound", "libasound.so.2"),
        ("pulse", "libpulse.so.0"),
        ("pulse-simple", "libpulse-simple.so.0"),
        ("GL", "libGL.so.1"),
        ("GLESv2", "libGLESv2.so.2"),
        ("EGL", "libEGL.so.1"),
        ("X11", "libX11.so.6"),
        ("Xi", "libXi.so.6"),
        ("Xcursor", "libXcursor.so.1"),
    ):
        # 当前后端未引用 ALSA 时保留已有清单，材料仍可供使用方选择。
        if name == "asound" and not any(
            symbol.startswith("snd_") for symbol in required
        ):
            continue
        path = args.libraries / soname
        content = symbols(path, required)
        (output / f"{name}.def").write_text(content)
        print(f"generated {name}.def: {len(content.splitlines())} symbols")


if __name__ == "__main__":
    main()
