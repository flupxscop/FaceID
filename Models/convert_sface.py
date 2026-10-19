#!/usr/bin/env python3
"""Convert OpenCV Zoo SFace (Apache-2.0) from ONNX to a Core ML .mlpackage for FaceIDAgent.

    python3 Models/convert_sface.py face_recognition_sface_2021dec.onnx Models/FaceEmbedding.mlpackage

Requires (in a virtualenv): coremltools, onnx, onnx2torch, torch, onnxruntime, numpy, pillow.

Model contract (from OpenCV's FaceRecognizerSF and opencv_zoo/sface.py):
  * input: an aligned 112x112 RGB face, pixel values 0-255 (no mean, no /255);
    alignment = similarity transform of 5 landmarks onto OpenCV's reference points;
  * output: a raw embedding — L2 normalisation happens at match time (cosine similarity).
The converted model keeps that contract: image input "face" (RGB, scale 1, bias 0), output "embedding".

coremltools has no ONNX frontend any more, so the path is ONNX -> PyTorch (onnx2torch) -> TorchScript
-> Core ML. The result is checked against onnxruntime on random faces before it is accepted.
"""

import sys

import coremltools as ct
import numpy as np
import onnx
import onnxruntime as ort
import torch
from onnx2torch import convert
from PIL import Image

INPUT_SIZE = 112
MIN_COSINE = 0.9999  # Core ML vs ONNX agreement required to accept the conversion


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b)))


def main(source: str, destination: str) -> int:
    onnx_model = onnx.load(source)
    onnx.checker.check_model(onnx_model)
    input_name = onnx_model.graph.input[0].name
    dims = [d.dim_value for d in onnx_model.graph.input[0].type.tensor_type.shape.dim]
    print(f"ONNX input {input_name} {dims}")

    torch_model = convert(onnx_model).eval()
    example = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE) * 255
    with torch.no_grad():
        traced = torch.jit.trace(torch_model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="face",
            shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
            color_layout=ct.colorlayout.RGB,
            scale=1.0,
            bias=[0.0, 0.0, 0.0],
        )],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        # Float32 keeps embeddings identical to the reference model, so FAR/FRR measured
        # with the threshold apply unchanged.
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = "SFace (MobileFaceNet) face embedding, converted for FaceID for macOS"
    mlmodel.license = "Apache-2.0 — OpenCV Zoo face_recognition_sface (https://github.com/opencv/opencv_zoo)"
    mlmodel.author = "SFace: Yaoyao Zhong et al.; ONNX: OpenCV Zoo; Core ML conversion: FaceID for macOS"
    mlmodel.input_description["face"] = "Aligned 112x112 RGB face, 0-255"
    mlmodel.output_description["embedding"] = "Raw face embedding (normalise before cosine similarity)"

    # Validate: the same uint8 faces through onnxruntime and Core ML must agree.
    session = ort.InferenceSession(source)
    rng = np.random.default_rng(0)
    worst = 1.0
    dimension = 0
    for _ in range(8):
        pixels = rng.integers(0, 256, size=(INPUT_SIZE, INPUT_SIZE, 3), dtype=np.uint8)
        reference = session.run(None, {input_name: pixels.transpose(2, 0, 1)[None].astype(np.float32)})[0].ravel()
        converted = np.asarray(mlmodel.predict({"face": Image.fromarray(pixels)})["embedding"]).ravel()
        dimension = reference.size
        worst = min(worst, cosine(reference, converted))
    print(f"embedding dimension {dimension}; worst Core ML vs ONNX cosine {worst:.6f}")
    if worst < MIN_COSINE:
        print(f"error: conversion differs from the reference (cosine {worst:.6f} < {MIN_COSINE})", file=sys.stderr)
        return 1

    mlmodel.save(destination)
    print(f"saved {destination}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
