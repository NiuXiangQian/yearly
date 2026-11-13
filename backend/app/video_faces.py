"""Bounded video sampling and conservative selection of representative face crops."""
import math
import re
import subprocess
from pathlib import Path

import imageio_ffmpeg

# Separate from the identity/auto-link thresholds: grouping never assigns a person.
VIDEO_FACE_SIMILARITY = 0.65
MAX_VIDEO_FRAMES = 120


def similarity(first, second):
    if not first or len(first) != len(second):
        return -1.0
    return sum(a * b for a, b in zip(first, second, strict=True))


def representative_faces(found):
    """Keep the best crop per strong appearance match; preserve co-occurring faces."""
    groups = []
    for face in sorted(found, key=lambda item: item.get("_quality", 0), reverse=True):
        matches = [(similarity(face["embedding"], best["embedding"]), frames)
                   for best, frames in groups if face["frame_seconds"] not in frames]
        score, frames = max(matches, key=lambda item: item[0], default=(-1, None))
        if score >= VIDEO_FACE_SIMILARITY:
            frames.add(face["frame_seconds"])
        else:
            groups.append((face, {face["frame_seconds"]}))
    # Never update a representative with a weaker match: avoid identity drift across a clip.
    return sorted((face for face, _ in groups), key=lambda item: item["frame_seconds"])


def detect_video_faces(video, directory, detector, fallback_duration_ms=None):
    executable = imageio_ffmpeg.get_ffmpeg_exe()
    probe = subprocess.run([executable, "-hide_banner", "-i", str(video)],
                           capture_output=True, text=True, timeout=15)
    match = re.search(r"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)", probe.stderr)
    duration = (int(match[1]) * 3600 + int(match[2]) * 60 + float(match[3])) if match else (fallback_duration_ms or 60000) / 1000
    count = min(MAX_VIDEO_FRAMES, max(1, math.ceil(duration * 2)))
    interval = max(0.5, duration / count)
    # Decode once. Bound extraction, CPU threads, image size and temporary disk use.
    subprocess.run([executable, "-hide_banner", "-loglevel", "error", "-threads", "1",
        "-filter_threads", "1", "-i", str(video), "-vf",
        f"fps=1/{interval}:start_time=0:round=up,scale=1280:1280:force_original_aspect_ratio=decrease",
        "-frames:v", str(count), str(Path(directory) / "frame-%04d.jpg")],
        check=True, capture_output=True, timeout=120)
    found = []
    for number, frame in enumerate(sorted(Path(directory).glob("frame-*.jpg"))):
        found.extend(detector.detect(frame.read_bytes(), round(number * interval, 3)))
        frame.unlink()
    return representative_faces(found)
