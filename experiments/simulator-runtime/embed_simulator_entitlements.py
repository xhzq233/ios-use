#!/usr/bin/env python3
"""Copy an arm64 Simulator executable and embed its supplied entitlement plist.

Uses existing zero padding in the Mach-O header and __TEXT segment. Code and
data offsets stay unchanged. The output requires ad-hoc signing before use.
"""
import argparse
import mmap
import os
from pathlib import Path
import plistlib
import shutil
import struct


def remap_symbol_sections(executable, symbol_table, text_last_section):
    if not symbol_table:
        return
    symbol_offset, symbol_count = symbol_table
    with mmap.mmap(executable.fileno(), 0) as data:
        for index in range(symbol_count):
            position = symbol_offset + index * 16 + 5  # nlist_64.n_sect
            section = data[position]
            if section > text_last_section:
                if section == 255:
                    raise ValueError("symbol section index cannot be incremented")
                data[position] = section + 1


def embed(source, entitlements, output):
    claims = plistlib.loads(entitlements.read_bytes())
    if not isinstance(claims, dict):
        raise ValueError("entitlements must be a plist dictionary")
    payload = plistlib.dumps(claims, fmt=plistlib.FMT_XML)
    with source.open("rb") as executable:
        header = bytearray(executable.read(32))
        magic, cpu, _, _, count, command_bytes, _, _ = struct.unpack("<8I", header)
        if magic != 0xFEEDFACF or cpu != 0x0100000C:
            raise ValueError("requires a thin little-endian arm64 Mach-O")
        commands = bytearray(executable.read(command_bytes))
        offset = 0
        text_segment = None
        first_section = None
        symbol_table = None
        section_count = 0
        text_last_section = 0
        simulator = False
        for _ in range(count):
            kind, size = struct.unpack_from("<II", commands, offset)
            if size < 8 or offset + size > len(commands):
                raise ValueError("invalid load command extent")
            if kind == 0x32:
                simulator = struct.unpack_from("<I", commands, offset + 8)[0] == 7
            if kind == 0x2:
                symbol_table = struct.unpack_from("<II", commands, offset + 8)
            if kind == 0xB and any(struct.unpack_from("<I", commands, offset + field)[0] for field in (68, 76)):
                raise ValueError("relocation tables require a relinker")
            if kind == 0x19:
                count_here = struct.unpack_from("<I", commands, offset + 64)[0]
                section_count += count_here
                if size != 72 + 80 * count_here:
                    raise ValueError("invalid segment section table")
                for index in range(count_here):
                    if struct.unpack_from("<I", commands, offset + 72 + index * 80 + 60)[0]:
                        raise ValueError("section relocations require a relinker")
            if kind == 0x19 and commands[offset + 8:offset + 24].rstrip(b"\0") == b"__TEXT":
                text_last_section = section_count
                vmaddr, _, fileoff, filesize = struct.unpack_from("<4Q", commands, offset + 24)
                sections = struct.unpack_from("<I", commands, offset + 64)[0]
                end = fileoff
                for index in range(sections):
                    section = offset + 72 + 80 * index
                    name = commands[section:section + 16].rstrip(b"\0")
                    if name in (b"__entitlements", b"__ents_der"):
                        raise ValueError("existing Simulator entitlement sections must be handled explicitly")
                    length, location = struct.unpack_from("<QI", commands, section + 40)
                    if location:
                        first_section = min(first_section or location, location)
                        end = max(end, location + length)
                text_segment = (offset, size, sections, vmaddr, fileoff, filesize, end)
            offset += size
        if not simulator or not text_segment:
            raise ValueError("requires an executable already targeting the iOS Simulator")
        if section_count >= 255:
            raise ValueError("no section ordinal available")
        position, size, sections, vmaddr, fileoff, filesize, end = text_segment
        header_end = 32 + command_bytes
        payload_offset = (end + 7) & ~7
        if not first_section or header_end + 80 > first_section or payload_offset + len(payload) > fileoff + filesize:
            raise ValueError("insufficient existing header or __TEXT padding; relinking is required")
        for start, length in ((header_end, 80), (payload_offset, len(payload))):
            executable.seek(start)
            if executable.read(length) != bytes(length):
                raise ValueError("selected padding is not entirely zero; refusing to overwrite data")
        record = struct.pack("<16s16sQQ8I", b"__entitlements", b"__TEXT",
            vmaddr + payload_offset - fileoff, len(payload), payload_offset, 3, 0, 0, 0, 0, 0, 0)
        commands[position + size:position + size] = record
        struct.pack_into("<I", commands, position + 4, size + 80)
        struct.pack_into("<I", commands, position + 64, sections + 1)
        struct.pack_into("<I", header, 20, command_bytes + 80)
        # Exclusive creation also prevents in-place edits of the source.
        with output.open("x+b") as destination:
            executable.seek(0)
            shutil.copyfileobj(executable, destination)
            destination.seek(0)
            destination.write(header + commands)
            destination.seek(payload_offset)
            destination.write(payload)
            destination.flush()
            # Inserting into __TEXT shifts later sections' nlist ordinals even
            # though their addresses and bytes do not move.
            remap_symbol_sections(destination, symbol_table, text_last_section)
    os.chmod(output, source.stat().st_mode & 0o777)
    print(f"Embedded Simulator entitlement XML ({len(payload)} bytes); ad-hoc sign the output before launching.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("entitlements", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    try:
        embed(arguments.source, arguments.entitlements, arguments.output)
    except (OSError, ValueError, struct.error) as error:
        parser.error(str(error))
