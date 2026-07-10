from __future__ import annotations

from pathlib import Path
from typing import Protocol

import cv2
import numpy as np
from ai_edge_litert.interpreter import Interpreter


class PersonSegmenter(Protocol):
    def make_mask(self, frame: np.ndarray) -> np.ndarray: ...


class LiteRTPersonSegmenter:
    def __init__(self, model_path: Path | None = None) -> None:
        resolved_model_path = model_path or (
            Path(__file__).parent / "assets" / "selfie_segmentation_landscape.tflite"
        )
        self.interpreter = Interpreter(model_path=str(resolved_model_path))
        self.interpreter.allocate_tensors()
        input_details = self.interpreter.get_input_details()[0]
        output_details = self.interpreter.get_output_details()[0]
        self.inputIndex = int(input_details["index"])
        self.outputIndex = int(output_details["index"])
        _, self.inputHeight, self.inputWidth, _ = input_details["shape"]

    def make_mask(self, frame: np.ndarray) -> np.ndarray:
        height, width = frame.shape[:2]
        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        resized_frame = cv2.resize(
            rgb_frame,
            (self.inputWidth, self.inputHeight),
            interpolation=cv2.INTER_LINEAR,
        )
        input_tensor = resized_frame.astype(np.float32)[None] / 255
        self.interpreter.set_tensor(self.inputIndex, input_tensor)
        self.interpreter.invoke()
        model_mask = self.interpreter.get_tensor(self.outputIndex)[0, :, :, 0]
        return cv2.resize(model_mask, (width, height), interpolation=cv2.INTER_LINEAR)
