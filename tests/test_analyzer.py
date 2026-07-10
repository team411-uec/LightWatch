import numpy as np

from lightwatch.analyzer import LightAnalyzer
from lightwatch.models import LightROI, ROIKind
from lightwatch.person_segmenter import LiteRTPersonSegmenter


class FixedPersonSegmenter:
    def __init__(self, mask: np.ndarray) -> None:
        self.mask = mask

    def make_mask(self, frame: np.ndarray) -> np.ndarray:
        return self.mask


def test_litert_person_segmenter_returns_frame_sized_probability_mask() -> None:
    frame = np.zeros((90, 160, 3), dtype=np.uint8)

    mask = LiteRTPersonSegmenter().make_mask(frame)

    assert mask.shape == frame.shape[:2]
    assert np.all((mask >= 0) & (mask <= 1))


def test_analyze_roi_excludes_person_pixels() -> None:
    frame = np.full((10, 10, 3), 200, dtype=np.uint8)
    frame[:, :5] = 20
    person_mask = np.zeros((10, 10), dtype=np.float32)
    person_mask[:, :5] = 1
    roi = LightROI("whole", ROIKind.POSITIVE, 0, 0, 1, 1)
    analyzer = LightAnalyzer([roi], FixedPersonSegmenter(person_mask))

    stats = analyzer.analyze_roi(roi, frame, person_mask)

    assert stats.medianLuma == 200
    assert stats.brightRatio == 1
    assert stats.observableRatio == 0.5
    assert stats.isObservable is True


def test_analyze_roi_rejects_mostly_occluded_region() -> None:
    frame = np.full((10, 10, 3), 200, dtype=np.uint8)
    person_mask = np.ones((10, 10), dtype=np.float32)
    person_mask[:, :3] = 0
    roi = LightROI("whole", ROIKind.POSITIVE, 0, 0, 1, 1)
    analyzer = LightAnalyzer([roi], FixedPersonSegmenter(person_mask))

    stats = analyzer.analyze_roi(roi, frame, person_mask)

    assert stats.observableRatio == 0.3
    assert stats.isObservable is False
