#!/usr/bin/env python3
"""
Build and run official riscv-tests (rv32ui/rv32mi) on the Wishbone testbench.
"""

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RISCV_TESTS = ROOT / "third_party" / "riscv-tests"
LINKER = ROOT / "scripts" / "riscv_tests_link.ld"
BUILD_DIR = ROOT / "build" / "riscv_tests"
SIM_EXE = ROOT / "build" / "sim" / "tb_riscv_tests_wb"
TB_FILE = ROOT / "tb" / "tb_riscv_tests_wb.v"
RTL_FILE = ROOT / "rtl" / "femtorv32_petitpipe.v"
SIM_MAIN = ROOT / "tb" / "sim_main.cpp"

INCLUDES = [
    RISCV_TESTS / "env" / "p",
    RISCV_TESTS / "env",
    RISCV_TESTS / "isa" / "macros" / "scalar",
    RISCV_TESTS / "isa" / "macros",
]

TOOLCHAIN_PREFIX = "riscv64-unknown-elf-"


def run(cmd, cwd=None):
    result = subprocess.run(cmd, cwd=cwd, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise RuntimeError(f"Command failed: {' '.join(cmd)}")
    return result.stdout


def ensure_sim():
    SIM_EXE.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "verilator",
        "--cc",
        "--exe",
        "--build",
        "--timing",
        "--trace-fst",
        "-Wall",
        "-Wno-fatal",
        "--top-module",
        "tb_riscv_tests_wb",
        "--Mdir",
        str(SIM_EXE.parent / "obj_tb_riscv_tests_wb"),
        "-CFLAGS",
        "-O2 -DVM_TOP=Vtb_riscv_tests_wb -DVM_TOP_HEADER=\\\"Vtb_riscv_tests_wb.h\\\"",
        f"-I{ROOT / 'tb'}",
        "-o",
        str(SIM_EXE),
        str(TB_FILE),
        str(RTL_FILE),
        str(SIM_MAIN),
    ]
    run(cmd)


def build_test(test_path, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    elf = out_dir / (test_path.stem + ".elf")
    hexfile = out_dir / (test_path.stem + ".hex")

    gcc = TOOLCHAIN_PREFIX + "gcc"
    objcopy = TOOLCHAIN_PREFIX + "objcopy"

    cmd = [
        gcc,
        "-march=rv32i_zicsr_zifencei",
        "-mabi=ilp32",
        "-nostdlib",
        "-nostartfiles",
        "-static",
        "-T",
        str(LINKER),
    ]
    for inc in INCLUDES:
        cmd.extend(["-I", str(inc)])
    cmd.extend(["-o", str(elf), str(test_path)])
    run(cmd)

    run([objcopy, "-O", "verilog", str(elf), str(hexfile)])
    return elf, hexfile


def get_signature_addrs(elf_path):
    readelf = TOOLCHAIN_PREFIX + "readelf"
    out = run([readelf, "-s", str(elf_path)])
    sig_start = None
    sig_end = None
    for line in out.splitlines():
        if " begin_signature" in line:
            sig_start = int(line.split()[1], 16)
        elif " end_signature" in line:
            sig_end = int(line.split()[1], 16)
    return sig_start, sig_end


def run_test(hexfile, sig_start, sig_end, sig_out, max_cycles):
    cmd = [
        str(SIM_EXE),
        f"+hex_file={hexfile}",
        f"+signature_file={sig_out}",
        f"+sig_start={sig_start:08x}",
        f"+sig_end={sig_end:08x}",
        f"+max_cycles={max_cycles}",
    ]
    result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    return result.returncode, result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--suites", default="rv32ui,rv32mi", help="Comma-separated suites")
    parser.add_argument("--max-cycles", type=int, default=2000000)
    parser.add_argument("--tests", default="", help="Optional comma-separated test names")
    args = parser.parse_args()

    if not RISCV_TESTS.exists():
        raise RuntimeError("riscv-tests repo not found. Clone it into third_party/riscv-tests")

    ensure_sim()

    suites = [s.strip() for s in args.suites.split(",") if s.strip()]
    only_tests = [t.strip() for t in args.tests.split(",") if t.strip()]

    results = []
    for suite in suites:
        suite_dir = RISCV_TESTS / "isa" / suite
        if not suite_dir.exists():
            print(f"[SKIP] Suite not found: {suite}")
            continue
        for test_path in sorted(suite_dir.glob("*.S")):
            if only_tests and test_path.stem not in only_tests:
                continue
            out_dir = BUILD_DIR / suite
            elf, hexfile = build_test(test_path, out_dir)
            sig_start, sig_end = get_signature_addrs(elf)
            if sig_start is None or sig_end is None:
                raise RuntimeError(f"Signature symbols not found in {elf}")
            sig_out = out_dir / (test_path.stem + ".signature")
            code, log = run_test(hexfile, sig_start, sig_end, sig_out, args.max_cycles)
            status = "PASS" if code == 0 else "FAIL"
            results.append((suite, test_path.stem, status, code))
            print(f"[{status}] {suite}/{test_path.stem}")
            if code != 0:
                sys.stderr.write(log)

    print("\nSummary")
    for suite, name, status, code in results:
        print(f"  {suite}/{name}: {status}")

    failed = [r for r in results if r[2] != "PASS"]
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
