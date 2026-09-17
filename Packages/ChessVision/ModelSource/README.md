# Piece classifier model package

`PieceClassifier.mlpackage` is the Core ML model package that
`../Sources/ChessVision/Model/PieceClassifier.mlmodelc` was compiled from. Both hold the same
weights. Only the compiled model is a package resource, so only it ships in the app.

To compile the model package again after changing it:

```sh
xcrun coremlcompiler compile PieceClassifier.mlpackage ../Sources/ChessVision/Model
```

The model's inputs, outputs and class order are described in
`../Sources/ChessVision/Classification/PieceClassifier.swift`, which loads it:

- Input `squares`: Float32 `MLMultiArray`, shape `[64, 3, 64, 64]`, RGB values in 0 to 1. Each
  entry is one square of the detected board, resized to 64 by 64 pixels with bilinear filtering
  and no added margin. Fewer than 64 squares are padded with zeros.
- Output `logits`: Float32 `[64, 13]`, in the class order
  `empty, wP, wN, wB, wR, wQ, wK, bP, bN, bB, bR, bQ, bK`.
- Output `highlight`: Float32 `[64, 1]`, one logit per square for whether the square carries a
  last-move or selection tint.
- Optional metadata key `calibration_temperature`: a decimal string. The recognizer reports
  `softmax(logits / temperature)` as a square's confidence. The model shipped here does not set
  the key, so the recognizer uses its own default (`PieceClassifier.defaultTemperature`).

The program that produced the weights is not part of this repository.
