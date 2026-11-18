#!/usr/bin/env python3
"""Guard the inspection logic against false-positive ABI/codegen results."""
import importlib.util
from pathlib import Path
import struct
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "probe_engine_abi.py"
SPEC = importlib.util.spec_from_file_location("probe_engine_abi", SCRIPT)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


def assembly(store8="strb", store16="strh", prefix=""):
    return f"""
.globl _bo1_probe_store8
_bo1_probe_store8: // @bo1_probe_store8
.cfi_startproc
  {prefix}
  mov w8, w0
  {store8} w1, [x8]
  ret
.cfi_endproc
.globl _bo1_probe_store16
_bo1_probe_store16:
.cfi_startproc
  mov w8, w0
  {store16} w1, [x8]
  ret
.cfi_endproc
"""


def image(pagezero_size=1 << 32, flags=0x200000, platform=2):
    def segment(name, address, size, maxprot, initprot):
        return struct.pack("<II16sQQQQiiII", 0x19, 72, name, address, size,
                           0, 0, maxprot, initprot, 0, 0)
    commands = (segment(b"__PAGEZERO", 0, pagezero_size, 0, 0) +
                segment(b"__TEXT", 1 << 32, 16384, 5, 5) +
                segment(b"__DATA", (1 << 32) + 16384, 2 << 30, 3, 3) +
                struct.pack("<6I", 0x32, 24, platform, 0x100000, 0x120000, 0))
    return struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 4, len(commands), flags, 0) + commands


class InspectorTests(unittest.TestCase):
    def test_correct_narrow_stores(self):
        self.assertEqual(PROBE.inspect_narrow_stores(assembly())["bo1_probe_store8"]["store_opcode"], "strb")

    def test_widened_byte_store_is_rejected(self):
        with self.assertRaises(ValueError):
            PROBE.inspect_narrow_stores(assembly(store8="str"))

    def test_widened_halfword_store_is_rejected(self):
        with self.assertRaises(ValueError):
            PROBE.inspect_narrow_stores(assembly(store16="str"))

    def test_stack_spill_does_not_hide_wider_destination(self):
        with self.assertRaises(ValueError):
            PROBE.inspect_narrow_stores(assembly(store8="str", prefix="strb w1, [sp, #1]"))

    def test_function_must_exist(self):
        with self.assertRaises(ValueError):
            PROBE.inspect_narrow_stores("strb w1, [x0]\nstrh w1, [x0]\n")

    def test_ordinary_arm64_ios_image(self):
        result = PROBE.inspect_macho(image())
        self.assertTrue(result["hard_pagezero_4gib"])
        self.assertTrue(result["ios_target"])
        self.assertTrue(result["pie"])
        self.assertTrue(result["image_fits_relative32"])
        self.assertEqual(result["image_span_bytes"], (2 << 30) + 16384)

    def test_changed_link_properties_are_not_reported_as_normal(self):
        result = PROBE.inspect_macho(image(pagezero_size=16384, flags=0, platform=7))
        self.assertFalse(result["hard_pagezero_4gib"])
        self.assertFalse(result["pie"])
        self.assertFalse(result["ios_target"])

    def test_truncated_commands_are_rejected(self):
        with self.assertRaises(ValueError):
            PROBE.inspect_macho(image()[:-1])

    def test_invalid_command_length_is_rejected(self):
        data = bytearray(image())
        struct.pack_into("<I", data, 36, 0xFFFFFFF8)
        with self.assertRaises(ValueError):
            PROBE.inspect_macho(data)

    def test_non_arm64_is_rejected(self):
        data = bytearray(image())
        struct.pack_into("<I", data, 4, 0x01000007)
        with self.assertRaises(ValueError):
            PROBE.inspect_macho(data)


if __name__ == "__main__":
    unittest.main()
