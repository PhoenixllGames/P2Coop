"""Minimal PE reader: import and export names of a 32-bit DLL/EXE (stdlib only)."""
import struct


class PE:
    def __init__(self, path):
        self.d = d = open(path, "rb").read()
        pe = struct.unpack_from("<I", d, 0x3C)[0]
        nsec = struct.unpack_from("<H", d, pe + 6)[0]
        optsize = struct.unpack_from("<H", d, pe + 20)[0]
        opt = pe + 24
        magic = struct.unpack_from("<H", d, opt)[0]
        self.dd = opt + (96 if magic == 0x10B else 112)
        self.secs = [struct.unpack_from("<8sIIII", d, opt + optsize + i * 40) for i in range(nsec)]

    def off(self, rva):
        for _, vs, va, rs, ro in self.secs:
            if va <= rva < va + max(vs, rs):
                return rva - va + ro
        raise ValueError(hex(rva))

    def cstr(self, o):
        return self.d[o:self.d.index(b"\0", o)].decode("ascii")

    def imports(self):
        """{dll: [(name, int_entry_file_offset, iat_entry_file_offset)]}; name is '#n' for ordinals."""
        out = {}
        o = self.off(struct.unpack_from("<I", self.d, self.dd + 8)[0])
        while True:
            oft, _, _, name, ft = struct.unpack_from("<IIIII", self.d, o)
            if name == 0:
                break
            dll = self.cstr(self.off(name))
            t, i = self.off(oft or ft), self.off(ft)
            fns = []
            while True:
                v = struct.unpack_from("<I", self.d, t)[0]
                if v == 0:
                    break
                fns.append(("#%d" % (v & 0xFFFF) if v & 0x80000000 else self.cstr(self.off(v) + 2), t, i))
                t += 4
                i += 4
            out[dll] = fns
            o += 20
        return out

    def import_dll_name_offset(self, dll):
        o = self.off(struct.unpack_from("<I", self.d, self.dd + 8)[0])
        while True:
            name = struct.unpack_from("<I", self.d, o + 12)[0]
            if name == 0:
                return None
            if self.cstr(self.off(name)).lower() == dll.lower():
                return self.off(name)
            o += 20

    def exports(self):
        e = struct.unpack_from("<I", self.d, self.dd)[0]
        if not e:
            return set()
        o = self.off(e)
        n = struct.unpack_from("<I", self.d, o + 24)[0]
        names = self.off(struct.unpack_from("<I", self.d, o + 32)[0])
        return {self.cstr(self.off(struct.unpack_from("<I", self.d, names + 4 * i)[0])) for i in range(n)}

    def export_ordinals(self):
        """{name: ordinal} for named exports."""
        e = struct.unpack_from("<I", self.d, self.dd)[0]
        if not e:
            return {}
        o = self.off(e)
        base, _, n, _, names, ords = struct.unpack_from("<IIIIII", self.d, o + 16)
        names, ords = self.off(names), self.off(ords)
        return {self.cstr(self.off(struct.unpack_from("<I", self.d, names + 4 * i)[0])):
                base + struct.unpack_from("<H", self.d, ords + 2 * i)[0] for i in range(n)}
