"""Local image-quality checks only; no identities or feature-vector comparisons."""
import base64
import io
import threading
from functools import lru_cache

from PIL import Image

QUALITY_VERSION = "crop-quality-v1"
MINIMUM_SIDE = 64
MINIMUM_SHARPNESS = 40.0
_detector_lock = threading.Lock()


def pixel_quality(pixels):
    import cv2
    import numpy as np
    height, width = pixels.shape[:2]
    if min(height, width) < MINIMUM_SIDE:
        return "too_small"
    if not 0.68 <= width / height <= 1.6:
        return "incomplete_face"
    gray = cv2.cvtColor(cv2.resize(pixels, (80, 80)), cv2.COLOR_BGR2GRAY)
    # Normalize size and suppress JPEG/noise edges before measuring image detail.
    gray = cv2.GaussianBlur(gray, (3, 3), 0.5)
    if float(np.std(gray)) < 12 or float(cv2.Laplacian(gray, cv2.CV_64F).var()) < MINIMUM_SHARPNESS:
        return "blurred"
    return None


def landmark_quality(landmarks, width, height):
    import numpy as np
    points = np.asarray(landmarks, dtype=float).reshape(5, 2)
    if not np.isfinite(points).all():
        return "incomplete_face"
    margin = min(width, height) * 0.04
    if ((points[:, 0] < margin).any() or (points[:, 0] > width - margin).any()
            or (points[:, 1] < margin).any() or (points[:, 1] > height - margin).any()):
        return "incomplete_face"
    eyes, mouth = points[:2], points[3:]
    axis = eyes[1] - eyes[0]
    distance = float(np.linalg.norm(axis))
    if distance < width * 0.24:
        return "incomplete_face"
    nose_offset = abs(float(np.dot(points[2] - eyes.mean(axis=0), axis))) / distance**2
    if nose_offset > 0.55 or np.linalg.norm(mouth[1] - mouth[0]) < distance * 0.35:
        return "incomplete_face"
    # The mouth must be below the eyes, allowing camera/head rotation.
    vertical = np.array([-axis[1], axis[0]]) / distance
    if float(np.dot(mouth.mean(axis=0) - eyes.mean(axis=0), vertical)) < distance * 0.35:
        return "incomplete_face"
    return None


def source_quality(pixels, face, image_width, image_height):
    """Check an original detection before any recognition work is performed."""
    x, y, width, height = map(float, face[:4])
    if x <= 0 or y <= 0 or x + width >= image_width or y + height >= image_height:
        return "incomplete_face"
    reason = pixel_quality(pixels)
    if reason:
        return reason
    import numpy as np
    points = np.asarray(face[4:14], dtype=float).reshape(5, 2) - [int(x), int(y)]
    return landmark_quality(points, pixels.shape[1], pixels.shape[0])


@lru_cache(maxsize=1)
def _detector(model_path):
    import cv2
    return cv2.FaceDetectorYN.create(model_path, "", (320, 320), 0.85, 0.3, 5000)


@lru_cache(maxsize=2048)
def _assess(thumbnail, box, model_path):
    """A None verdict means unavailable, never evidence for discarding a row."""
    try:
        import cv2
        import numpy as np
        with Image.open(io.BytesIO(base64.b64decode(thumbnail, validate=True))) as image:
            image.load()
            pixels = cv2.cvtColor(np.array(image.convert("RGB")), cv2.COLOR_RGB2BGR)
        if len(box) != 4 or not all(np.isfinite(box)):
            return False, "invalid_crop"
        x, y, width, height = box
        if width <= 0 or height <= 0 or x <= 0.0005 or y <= 0.0005 or x + width >= 0.9995 or y + height >= 0.9995:
            return False, "incomplete_face"
        reason = pixel_quality(pixels)
        if reason:
            return False, reason
        # Stored crops are tight. Padding permits the same local detector to inspect
        # both eyes, nose and both mouth corners without requiring the original file.
        height, width = pixels.shape[:2]
        pad = max(height, width) // 4
        padded = cv2.copyMakeBorder(pixels, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=(127, 127, 127))
        with _detector_lock:
            detector = _detector(model_path)
            detector.setInputSize((padded.shape[1], padded.shape[0]))
            _, detected = detector.detect(padded)
        if detected is None or len(detected) != 1:
            return False, "incomplete_face"
        points = detected[0][4:14].reshape(5, 2) - pad
        reason = landmark_quality(points, width, height)
        return (False, reason) if reason else (True, "accepted")
    except (ValueError, OSError):
        return False, "invalid_crop"
    except Exception:
        # Missing OpenCV/model or a runtime failure must not turn into a mass cleanup.
        return None, "assessment_unavailable"


def assess_crop(thumbnail, box):
    from .face_engine import MODELS, model_directory
    model = model_directory() / MODELS["face_detection_yunet"][0]
    if not model.is_file():
        return None, "assessment_unavailable"
    return _assess(thumbnail, tuple(box), str(model))
