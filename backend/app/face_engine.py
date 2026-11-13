"""Local YuNet detection and SFace embeddings; model files are installed explicitly."""
import base64
import hashlib
import importlib.util
import io
from pathlib import Path
from urllib.request import urlopen

from fastapi import HTTPException
from PIL import Image, ImageOps

from .config import settings

MODEL_VERSION = "yunet-2023mar-sface-2021dec-v1"
MODELS = {
    "face_detection_yunet": ("face_detection_yunet_2023mar.onnx", "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"),
    "face_recognition_sface": ("face_recognition_sface_2021dec.onnx", "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"),
}


def model_directory():
    return Path(settings().face_model_directory).expanduser()


def availability():
    enabled = settings().face_matching_enabled
    ready = bool(importlib.util.find_spec("cv2")) and all(
        (model_directory() / name).is_file() for name, _ in MODELS.values())
    message = "" if enabled and ready else (
        "人脸匹配尚未启用" if not enabled else "人脸模型尚未安装，请管理员完成服务端配置")
    return dict(enabled=enabled, ready=ready, message=message, model=MODEL_VERSION)


def setup_models():
    directory = model_directory()
    directory.mkdir(parents=True, exist_ok=True)
    for folder, (name, checksum) in MODELS.items():
        target = directory / name
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == checksum:
            continue
        url = f"https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/{folder}/{name}"
        with urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != checksum:
            raise ValueError(f"模型 SHA-256 校验失败：{name}")
        target.write_bytes(data)
        with urlopen(f"https://raw.githubusercontent.com/opencv/opencv_zoo/main/models/{folder}/LICENSE", timeout=30) as response:
            (directory / f"{folder}.LICENSE").write_bytes(response.read())


class FaceEngine:
    def __init__(self):
        state = availability()
        if not state["enabled"] or not state["ready"]:
            raise HTTPException(503, state["message"])
        import cv2
        import numpy as np
        self.cv = cv2
        self.np = np
        self.detector = cv2.FaceDetectorYN.create(str(model_directory() / MODELS["face_detection_yunet"][0]), "", (320, 320), 0.85, 0.3, 5000)
        self.recognizer = cv2.FaceRecognizerSF.create(str(model_directory() / MODELS["face_recognition_sface"][0]), "")

    def detect(self, raw, frame_seconds=None):
        with Image.open(io.BytesIO(raw)) as source:
            image = ImageOps.exif_transpose(source).convert("RGB")
        image.thumbnail((1280, 1280))
        pixels = self.cv.cvtColor(self.np.array(image), self.cv.COLOR_RGB2BGR)
        width, height = image.size
        self.detector.setInputSize((width, height))
        _, detected = self.detector.detect(pixels)
        results = []
        for face in ([] if detected is None else detected):
            x, y, w, h = map(float, face[:4])
            left, top = max(0, int(x)), max(0, int(y))
            right, bottom = min(width, int(x + w)), min(height, int(y + h))
            if right - left < 24 or bottom - top < 24:
                continue
            aligned = self.recognizer.alignCrop(pixels, face)
            vector = self.recognizer.feature(aligned).flatten()
            vector = vector / self.np.linalg.norm(vector)
            crop = image.crop((left, top, right, bottom))
            crop.thumbnail((112, 112))
            output = io.BytesIO()
            crop.save(output, "JPEG", quality=80)
            results.append(dict(box=[left / width, top / height, (right-left) / width, (bottom-top) / height],
                                embedding=vector.tolist(), thumbnail=base64.b64encode(output.getvalue()).decode(),
                                frame_seconds=frame_seconds))
        return results
