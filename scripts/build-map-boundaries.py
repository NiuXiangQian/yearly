#!/usr/bin/env python3
"""Build the compact Natural Earth snapshot used for offline photo grouping."""

import argparse
import gzip
import json
from pathlib import Path

def simplify(points, tolerance):
    last = len(points) - 1
    retained = {0, last}
    segments = [(0, last)]
    while segments:
        start, end = segments.pop()
        start_x, start_y = points[start]
        dx = points[end][0] - start_x
        dy = points[end][1] - start_y
        length = dx * dx + dy * dy
        farthest, maximum = None, tolerance * tolerance
        for index in range(start + 1, end):
            offset_x = points[index][0] - start_x
            offset_y = points[index][1] - start_y
            if length:
                ratio = max(0, min(1, (offset_x * dx + offset_y * dy) / length))
                offset_x -= ratio * dx
                offset_y -= ratio * dy
            distance = offset_x * offset_x + offset_y * offset_y
            if distance > maximum:
                farthest, maximum = index, distance
        if farthest is not None:
            retained.add(farthest)
            segments.extend(((start, farthest), (farthest, end)))
    return [points[index] for index in sorted(retained)]


def encode_ring(ring):
    points = [[round(lon * 10_000), round(lat * 10_000)] for lon, lat in ring]
    if len(points) < 4:
        return []
    simplified = simplify(points, tolerance=40)
    return simplified if len(simplified) >= 4 else points


def encode(source, region):
    for feature in json.loads(source.read_text(encoding="utf-8"))["features"]:
        properties = {key.lower(): value for key, value in feature["properties"].items()}
        code = properties["adm1_code" if region else "adm0_a3"]
        name = properties.get("name_zh") or properties["name"]
        geometry = feature["geometry"]
        polygons = geometry["coordinates"]
        if geometry["type"] == "Polygon":
            polygons = [polygons]
        for exterior, *interiors in polygons:
            outer = encode_ring(exterior)
            if outer:
                holes = [ring for interior in interiors if (ring := encode_ring(interior))]
                yield [code, name, [outer, *holes]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("countries", type=Path)
    parser.add_argument("regions", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as output, gzip.GzipFile(filename="", fileobj=output, mode="wb", mtime=0) as compressed:
        for level, source in [("country", args.countries), ("region", args.regions)]:
            for code, name, rings in encode(source, level == "region"):
                encoded = json.dumps([level, code, name, rings], ensure_ascii=False, separators=(",", ":"))
                compressed.write((encoded + "\n").encode())


if __name__ == "__main__":
    main()
