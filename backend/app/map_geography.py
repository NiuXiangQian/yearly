"""Offline classification for display groups and geographic camera bounds."""

from array import array
from collections import defaultdict
from functools import lru_cache
from itertools import chain
import gzip
import json
from math import floor
from pathlib import Path

COORDINATE_SCALE = 10_000
INDEX_STEP = 2 * COORDINATE_SCALE
COUNTRY_DISPLAY_NAMES = {"CHN": "中国"}


def wrap_longitude(value):
    return value if -180 <= value < 180 else (value + 180) % 360 - 180


def ring_contains(ring, x, y):
    inside = False
    previous_x, previous_y = ring[-2], ring[-1]
    ordinates = iter(ring)
    for next_x, next_y in zip(ordinates, ordinates):
        if (previous_y > y) != (next_y > y):
            crossing = (next_x - previous_x) * (y - previous_y) / (next_y - previous_y) + previous_x
            if x < crossing:
                inside = not inside
        previous_x, previous_y = next_x, next_y
    return inside


class BoundaryIndex:
    def __init__(self):
        self.tiles = defaultdict(list)

    def add(self, code, name, rings):
        xs, ys = zip(*rings[0])
        west, south, east, north = min(xs), min(ys), max(xs), max(ys)
        packed = tuple(array("i", chain.from_iterable(ring)) for ring in rings)
        entry = (west, south, east, north, code, name, packed)
        for x in range(west // INDEX_STEP, east // INDEX_STEP + 1):
            for y in range(south // INDEX_STEP, north // INDEX_STEP + 1):
                self.tiles[x, y].append(entry)

    def lookup(self, latitude, longitude):
        x, y = longitude * COORDINATE_SCALE, latitude * COORDINATE_SCALE
        for west, south, east, north, code, name, rings in self.tiles.get((floor(x / INDEX_STEP), floor(y / INDEX_STEP)), ()):
            if (west <= x <= east and south <= y <= north
                    and ring_contains(rings[0], x, y)
                    and not any(ring_contains(ring, x, y) for ring in rings[1:])):
                return code, name
        return None


@lru_cache(maxsize=1)
def boundary_indexes():
    indexes = {"country": BoundaryIndex(), "region": BoundaryIndex()}
    path = Path(__file__).with_name("data") / "map-boundaries.jsonl.gz"
    with gzip.open(path, "rt", encoding="utf-8") as source:
        for line in source:
            level, code, name, rings = json.loads(line)
            display_name = COUNTRY_DISPLAY_NAMES.get(code, name) if level == "country" else name
            indexes[level].add(code, display_name, rings)
    return indexes


@lru_cache(maxsize=32768)
def administrative_place(latitude, longitude, level):
    return boundary_indexes()[level].lookup(latitude, wrap_longitude(longitude))


def geographic_bounds(points):
    """Fit the shortest circular longitude interval, which can cross ±180°."""
    if not points:
        return None
    latitudes, longitudes = zip(*points)
    ordered = sorted({wrap_longitude(value) for value in longitudes})
    gaps = [end - start for start, end in zip(ordered, ordered[1:])]
    gaps.append(ordered[0] + 360 - ordered[-1])
    gap = max(range(len(gaps)), key=gaps.__getitem__)
    return {
        "south": min(latitudes), "north": max(latitudes),
        "west": ordered[(gap + 1) % len(ordered)], "east": ordered[gap],
    }
