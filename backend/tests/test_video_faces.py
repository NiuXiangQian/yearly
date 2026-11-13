import io
import math
import subprocess

import imageio_ffmpeg
import pytest
from PIL import Image

from app.face_engine import FaceEngine
from app.video_faces import detect_video_faces, representative_faces, MAX_VIDEO_FRAMES


def detection(vector, seconds, quality):
    return dict(embedding=vector, frame_seconds=seconds, _quality=quality)


def test_prefers_later_frontal_crop_and_retains_distinct_people():
    side = detection([1, 0, 0], 0, 0.25)
    front = detection([0.95, math.sqrt(1 - 0.95**2), 0], 2, 0.9)
    other = detection([0, 0, 1], 4, 0.8)
    assert representative_faces([side, front, other]) == [front, other]


def test_similar_faces_in_same_frame_stay_separate_across_repeated_frames():
    first = [1, 0]
    relative = [0.9, math.sqrt(1 - 0.9**2)]
    found = [detection(first, 0, 0.5), detection(relative, 0, 0.4),
             detection(first, 1, 0.9), detection(relative, 1, 0.8)]
    assert representative_faces(found) == found[2:]


def test_grouping_does_not_drift_through_a_chain_of_weak_matches():
    found = [detection([math.cos(a), math.sin(a)], t, 1 - t/10)
             for t, a in enumerate([0, 0.6, 1.2])]
    assert representative_faces(found) == [found[0], found[2]]


def test_quality_prefers_frontal_detail_and_allows_head_tilt():
    cv2 = pytest.importorskip("cv2")
    np = pytest.importorskip("numpy")
    engine = FaceEngine.__new__(FaceEngine)
    engine.cv, engine.np = cv2, np
    face = np.array([0, 0, 160, 180, 45, 60, 115, 60, 80, 100, 55, 140, 105, 140, .99], dtype=float)
    detail = np.random.default_rng(4).integers(0, 256, (180, 160, 3), dtype=np.uint8)
    profile = face.copy()
    profile[8] = 111
    assert engine.quality(face, detail) > engine.quality(profile, detail)
    assert engine.quality(face, detail) > engine.quality(face, cv2.GaussianBlur(detail, (21, 21), 6))
    tilted = face.copy()
    angle = math.pi / 8
    rotation = np.array([[math.cos(angle), -math.sin(angle)], [math.sin(angle), math.cos(angle)]])
    tilted[4:14] = (face[4:14].reshape(5, 2) @ rotation.T).flatten()
    assert engine.quality(tilted, detail) == pytest.approx(engine.quality(face, detail))


def test_short_clip_is_sampled_past_the_opening_and_uses_actual_duration(tmp_path):
    video = tmp_path / "clip.mp4"
    subprocess.run([imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    "testsrc2=s=240x320:r=10:d=3", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(video)], check=True)
    timestamps = []
    class Detector:
        def detect(self, raw, frame_seconds):
            assert Image.open(io.BytesIO(raw)).size == (960, 1280)
            timestamps.append(frame_seconds)
            if frame_seconds == 0:
                return [detection([1, 0], frame_seconds, .2)]
            if frame_seconds == 1.5:
                return [detection([1, 0], frame_seconds, .9), detection([0, 1], frame_seconds, .8)]
            return []
    # Missing upload metadata previously caused short clips to be sampled as 60-second clips.
    result = detect_video_faces(video, tmp_path, Detector(), fallback_duration_ms=None)
    assert timestamps == [0, .5, 1, 1.5, 2, 2.5]
    assert len(result) == 2 and all(face["frame_seconds"] == 1.5 for face in result)
    assert not list(tmp_path.glob("frame-*.jpg"))


def test_long_clip_extraction_is_bounded_and_spans_its_duration(tmp_path, monkeypatch):
    commands = []
    def run(command, **kwargs):
        commands.append(command)
        return subprocess.CompletedProcess(command, 1, stderr="Duration: 00:20:00.00, start: 0.000000")
    monkeypatch.setattr("app.video_faces.subprocess.run", run)
    detect_video_faces(tmp_path / "long.mp4", tmp_path, object())
    extract = commands[1]
    assert extract[extract.index("-frames:v") + 1] == str(MAX_VIDEO_FRAMES)
    assert "fps=1/10.0" in extract[extract.index("-vf") + 1]
