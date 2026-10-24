"""Copy Postal2.exe and make the copy import a hook DLL instead of COMDLG32.dll.

The DLL name is patched in place (the new name is no longer), so nothing else in the exe moves.
Usage: python -I patchexe.py <Postal2.exe> <out exe> <hook dll name, at most 12 chars>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pe import PE  # noqa: E402

OLD = b"COMDLG32.dll"


def main(src, dst, hook):
    new = hook.encode("ascii")
    if len(new) > len(OLD):
        sys.exit("hook DLL name %s is longer than %s" % (hook, OLD.decode()))
    pe = PE(src)
    names = [s[0].rstrip(b"\0") for s in pe.secs]
    if b".bind" in names:
        sys.exit("%s is wrapped by SteamStub (.bind section); unwrap it first" % src)
    o = pe.import_dll_name_offset(OLD.decode())
    if o is None:
        sys.exit("COMDLG32.dll import not found in %s" % src)
    d = bytearray(pe.d)
    assert d[o:o + len(OLD) + 1] == OLD + b"\0"
    d[o:o + len(OLD) + 1] = new.ljust(len(OLD) + 1, b"\0")
    with open(dst, "wb") as f:
        f.write(d)
    print("patched import name at file offset 0x%x -> %s imports %s" % (o, dst, hook))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:4])
