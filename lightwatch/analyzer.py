from __future__ import annotations

from datetime import datetime

import cv2
import mediapipe as mp
import numpy as np

from lightwatch.models import (
    LightAnalysisSnapshot,
    LightROI,
    LightSceneLevel,
    LightWatchState,
    PersonPresence,
    ROIStats,
)


class LightAnalyzer:
    def __init__(self, rois: list[LightROI]) -> None:
        self.rois = rois
        self.segmenter = mp.solutions.selfie_segmentation.SelfieSegmentation(model_selection=1)
        self.brightThreshold = 180
        self.darkThreshold = 50
        self.personMaskThreshold = 0.5
        self.minimumObservableRatio = 0.35

    def analyze(self, frame: np.ndarray, state: LightWatchState) -> LightAnalysisSnapshot:
        person_mask = self.make_person_mask(frame)
        person_presence = self.analyze_person_presence(person_mask)
        roi_stats = [self.analyze_roi(roi, frame, person_mask) for roi in self.rois]
        return LightAnalysisSnapshot(
            timestamp=datetime.now().astimezone(),
            state=state,
            roiStats=roi_stats,
            sceneLevel=LightSceneLevel.from_stats(roi_stats, person_presence),
        )

    def make_person_mask(self, frame: np.ndarray) -> np.ndarray:
        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        result = self.segmenter.process(rgb_frame)
        return np.asarray(result.segmentation_mask, dtype=np.float32)

    def analyze_person_presence(self, person_mask: np.ndarray) -> PersonPresence:
        height, width = person_mask.shape[:2]
        step = max(1, min(width, height) // 120)
        sampled_mask = person_mask[0:height:step, 0:width:step]
        if sampled_mask.size == 0:
            return PersonPresence(maskedRatio=0)
        return PersonPresence(maskedRatio=float(np.mean(sampled_mask >= self.personMaskThreshold)))

    def analyze_roi(self, roi: LightROI, frame: np.ndarray, person_mask: np.ndarray) -> ROIStats:
        height, width = frame.shape[:2]
        x_start = max(0, min(width - 1, int(roi.x * width)))
        y_start = max(0, min(height - 1, int(roi.y * height)))
        x_end = max(x_start + 1, min(width, int((roi.x + roi.width) * width)))
        y_end = max(y_start + 1, min(height, int((roi.y + roi.height) * height)))
        step = max(1, min(width, height) // 80)

        roi_frame = frame[y_start:y_end:step, x_start:x_end:step]
        roi_mask = person_mask[y_start:y_end:step, x_start:x_end:step]
        total_sample_count = roi_frame.shape[0] * roi_frame.shape[1]
        if total_sample_count == 0:
            raise ValueError("ROIの解析対象ピクセルがありません。")

        observable_pixels = roi_frame[roi_mask < self.personMaskThreshold]
        sample_count = len(observable_pixels)
        observable_ratio = sample_count / total_sample_count
        if sample_count == 0 or observable_ratio < self.minimumObservableRatio:
            return ROIStats(roi.name, roi.kind, 0, 0, 0, observable_ratio, False, False)

        blue = observable_pixels[:, 0].astype(np.float64)
        green = observable_pixels[:, 1].astype(np.float64)
        red = observable_pixels[:, 2].astype(np.float64)
        luma = np.rint(0.2126 * red + 0.7152 * green + 0.0722 * blue).astype(np.int16)
        median_luma = float(np.median(luma))
        return ROIStats(
            name=roi.name,
            kind=roi.kind,
            medianLuma=median_luma,
            brightRatio=float(np.mean(luma >= self.brightThreshold)),
            darkRatio=float(np.mean(luma <= self.darkThreshold)),
            observableRatio=observable_ratio,
            isObservable=True,
            isDark=median_luma <= self.darkThreshold,
        )
