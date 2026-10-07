#!/usr/bin/env python3
"""Convert the CC0-derived bilateral MRI pial mesh into the offline Gyrus reference.

No Python dependencies. Networking is confined to this development tool.
"""
import hashlib
import json
import math
from pathlib import Path
import struct
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "https://raw.githubusercontent.com/StarKnightt/brain-explorer/d778b990dac88c2442ae67b83134537c0883db17/public/models/brain-atlas.glb"
SHA256 = "ce761741d866e32d7a5b7638f4cacd5ec03e2b582e72c8218aba483ac28125e8"


def main():
    cache = Path("/tmp/gyrus-atlas.glb")
    if not cache.exists():
        cache.write_bytes(urllib.request.urlopen(SOURCE).read())
    glb = cache.read_bytes()
    assert hashlib.sha256(glb).hexdigest() == SHA256, "Source checksum changed"
    assert glb[:4] == b"glTF"
    length = struct.unpack_from("<I", glb, 12)[0]
    document = json.loads(glb[20:20 + length])
    binary = memoryview(glb)[28 + length:]

    def accessor(index):
        a = document["accessors"][index]
        view = document["bufferViews"][a["bufferView"]]
        offset = view.get("byteOffset", 0) + a.get("byteOffset", 0)
        width = {"SCALAR": 1, "VEC3": 3}[a["type"]]
        kind = {5126: "f", 5125: "I"}[a["componentType"]]
        stride = view.get("byteStride", width * 4)
        return [struct.unpack_from("<" + kind * width, binary, offset + i * stride) for i in range(a["count"])]

    mesh = next(m for m in document["meshes"] if m["name"] == "unified-cortex")
    primitive = mesh["primitives"][0]
    vertices = accessor(primitive["attributes"]["POSITION"])
    normals = accessor(primitive["attributes"]["NORMAL"])
    curvature = accessor(primitive["attributes"]["_CURVATURE"])
    indices = accessor(primitive["indices"])
    low = [min(v[a] for v in vertices) for a in range(3)]
    high = [max(v[a] for v in vertices) for a in range(3)]
    center = [(a + b) / 2 for a, b in zip(low, high)]
    scale = 2 / (high[1] - low[1])
    out = bytearray(b"GYRS" + struct.pack("<II", len(vertices), len(indices) // 3))
    for v, n, curv in zip(vertices, normals, curvature):
        p = tuple((v[a] - center[a]) * scale for a in range(3))
        # Native signed cortical curvature: ridges catch light, sulcal walls recede.
        exposure = .16 + .84 / (1 + math.exp(curv[0] * 9))
        out.extend(struct.pack("<7f", *p, *n, exposure))
    for i in indices:
        out.extend(struct.pack("<I", i[0]))
    target = ROOT / "Resources/Brain/Cortex.brainmesh"
    target.write_bytes(out)
    print(f"Bilateral pial cortex: {len(vertices):,} vertices, {len(indices) // 3:,} triangles; {len(out):,} bytes")
    print(f"SHA256 {hashlib.sha256(out).hexdigest()}")


if __name__ == "__main__":
    main()
