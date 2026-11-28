"""Bounded sampling and per-person face tracks for compressed video."""
import math
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import imageio_ffmpeg

VIDEO_FACE_SIMILARITY = 0.65
MAX_VIDEO_FRAMES = 120
MAX_REFINEMENT_WINDOWS = 6
MAX_TRACK_SAMPLES = 3


def similarity(first, second):
    if not first or len(first) != len(second):
        return -1.0
    return sum(a * b for a, b in zip(first, second, strict=True))


def overlap(first, second):
    if not first or not second:
        return 0.0
    x, y, w, h = first
    xx, yy, ww, hh = second
    intersection = max(0, min(x + w, xx + ww) - max(x, xx)) * max(0, min(y + h, yy + hh) - max(y, yy))
    union = w * h + ww * hh - intersection
    return intersection / union if union else 0.0


def quality(face):
    return face.get("_quality", 0)


@dataclass
class Track:
    representative: dict
    last: dict
    frames: set = field(default_factory=set)
    samples: list = field(default_factory=list)

    def append(self, face):
        self.last = face
        self.frames.add(face["frame_seconds"])
        if quality(face) > quality(self.representative):
            self.representative = face
        if not face.get("_usable", True):
            return
        # Similar adjacent frames should not crowd out an alternative pose.
        for index, sample in enumerate(self.samples):
            if similarity(face["embedding"], sample["embedding"]) >= .97:
                if quality(face) > quality(sample):
                    self.samples[index] = face
                break
        else:
            self.samples.append(face)
        self.samples.sort(key=quality, reverse=True)
        del self.samples[MAX_TRACK_SAMPLES:]


def track_faces(found, interval=.5):
    tracks = []
    frames = {}
    for face in found:
        frames.setdefault(face["frame_seconds"], []).append(face)
    for seconds, faces in sorted(frames.items()):
        pairs = []
        for face_index, face in enumerate(faces):
            for track_index, track in enumerate(tracks):
                if seconds - track.last["frame_seconds"] > min(1.5, interval * 2.1):
                    continue
                appearance = similarity(face["embedding"], track.representative["embedding"])
                position = overlap(face.get("box"), track.last.get("box"))
                if appearance >= .78 or (appearance >= .50 and position >= .38):
                    pairs.append((appearance + .3 * position, face_index, track_index))
        used_faces, used_tracks = set(), set()
        for _, face_index, track_index in sorted(pairs, reverse=True):
            if face_index not in used_faces and track_index not in used_tracks:
                tracks[track_index].append(faces[face_index])
                used_faces.add(face_index)
                used_tracks.add(track_index)
        for index, face in enumerate(faces):
            if index not in used_faces:
                track = Track(face, face)
                track.append(face)
                tracks.append(track)
    return tracks


def merge_tracks(tracks):
    groups = []
    for track in sorted(tracks, key=lambda item: quality(item.representative), reverse=True):
        peers = [(similarity(track.representative["embedding"], group.representative["embedding"]), group)
                 for group in groups if track.frames.isdisjoint(group.frames)]
        score, best = max(peers, key=lambda item: item[0], default=(-1, None))
        # Use a fixed anchor and require stronger evidence across disconnected shots.
        if score >= .82:
            best.frames.update(track.frames)
            for sample in track.samples:
                best.append(sample)
        else:
            groups.append(track)
    return sorted(groups, key=lambda item: item.representative["frame_seconds"])


def extract_frames(executable, video, directory, detector, start, interval, count, duration=None):
    pattern = str(Path(directory) / "frame-%04d.jpg")
    command = [executable, "-hide_banner", "-loglevel", "info", "-threads", "1", "-filter_threads", "1"]
    if start:
        command.extend(["-ss", str(start)])
    command.extend(["-i", str(video)])
    if duration is not None:
        command.extend(["-t", str(duration)])
    threshold = interval - .000001
    command.extend([
        "-vf", f"select=isnan(prev_selected_t)+gte(t-prev_selected_t\\,{threshold:.6f}),"
        "scale=1280:1280:force_original_aspect_ratio=decrease,showinfo",
        "-fps_mode", "vfr", "-frames:v", str(count), "-y", pattern,
    ])
    output = subprocess.run(command, check=True, capture_output=True, text=True, timeout=12 if duration is not None else 100)
    stamps = [float(value) for value in re.findall(r"\bn:\s*\d+\s+pts:\s*-?\d+\s+pts_time:([\d.eE+-]+)", output.stderr)]
    paths = sorted(Path(directory).glob("frame-*.jpg"))
    if not paths and start == 0 and duration is None:
        raise ValueError("视频没有可分析的画面")
    found = []
    try:
        for path, timestamp in zip(paths, stamps[:len(paths)], strict=True):
            found.extend(detector.detect(path.read_bytes(), round(start + timestamp, 3)))
    finally:
        for path in paths:
            path.unlink()
    return found


def combine_frame_detections(initial, refined):
    frames = {}
    for face in initial:
        frames.setdefault(face["frame_seconds"], []).append(face)
    for face in refined:
        faces = frames.setdefault(face["frame_seconds"], [])
        for index, existing in enumerate(faces):
            if (overlap(face.get("box"), existing.get("box")) >= .7
                    and similarity(face["embedding"], existing["embedding"]) >= .85):
                if quality(face) > quality(existing):
                    faces[index] = face
                break
        else:
            faces.append(face)
    return [face for faces in frames.values() for face in faces]


def detect_video_faces(video, directory, detector, fallback_duration_ms=None):
    executable = imageio_ffmpeg.get_ffmpeg_exe()
    probe = subprocess.run([executable, "-hide_banner", "-i", str(video)],
                           capture_output=True, text=True, timeout=15)
    match = re.search(r"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)", probe.stderr)
    duration = (int(match[1]) * 3600 + int(match[2]) * 60 + float(match[3])) if match else (fallback_duration_ms or 60000) / 1000
    count = min(MAX_VIDEO_FRAMES, max(1, math.ceil(duration * 2)))
    interval = max(.5, duration / count)
    initial = extract_frames(executable, video, directory, detector, 0, interval, count)
    windows = []
    weak = [track.representative["frame_seconds"] for track in sorted(track_faces(initial, interval),
            key=lambda item: quality(item.representative)) if quality(track.representative) < .55]
    # Probe a few spaced windows as well, for short appearances between coarse frames.
    coverage = [duration * fraction for fraction in (.25, .50, .75)] if duration > 1 else [duration / 2]
    for seconds in [*weak, *coverage]:
        start = round(max(0, seconds - .65), 3)
        if all(abs(start - previous) >= 1.25 for previous in windows):
            windows.append(start)
        if len(windows) == MAX_REFINEMENT_WINDOWS:
            break
    refined = []
    for start in windows:
        refined.extend(extract_frames(executable, video, directory, detector, start, .15, 10, 1.4))
    detections = combine_frame_detections(initial, refined)
    results = []
    for track in merge_tracks(track_faces(detections, interval)):
        best = track.representative
        if not best.get("_usable", True):
            continue
        results.append({**best, "alternate_embeddings": [sample["embedding"] for sample in track.samples if sample is not best]})
    return results
