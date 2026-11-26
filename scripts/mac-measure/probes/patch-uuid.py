# Copies the LC_UUID of one Mach-O (thin, 64-bit) into another, in place: measurement M10's forger, a different program
# that carries another's UUID. Run with python3 -I. Usage: patch-uuid.py FROM TO
import struct
import sys


def uuid_offset(data):
    if struct.unpack_from('<I', data, 0)[0] != 0xFEEDFACF:
        sys.exit('not a thin 64-bit Mach-O')
    commands, offset = struct.unpack_from('<I', data, 16)[0], 32
    for _ in range(commands):
        command, size = struct.unpack_from('<II', data, offset)
        if command == 0x1B:
            return offset + 8
        offset += size
    sys.exit('no LC_UUID')


source = open(sys.argv[1], 'rb').read()
target = bytearray(open(sys.argv[2], 'rb').read())
at, to = uuid_offset(source), uuid_offset(target)
target[to:to + 16] = source[at:at + 16]
open(sys.argv[2], 'wb').write(target)
print('LC_UUID set to', source[at:at + 16].hex())
