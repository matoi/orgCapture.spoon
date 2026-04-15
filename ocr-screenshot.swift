#!/usr/bin/swift
import Foundation
import Vision
import AppKit

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: ocr-screenshot <image-path>\n", stderr)
    exit(1)
}

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)

guard let image = NSImage(contentsOf: url),
      let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let cgImage = bitmap.cgImage else {
    fputs("Error: cannot load image at \(path)\n", stderr)
    exit(1)
}

let semaphore = DispatchSemaphore(value: 0)
var recognizedText = ""

let request = VNRecognizeTextRequest { request, error in
    defer { semaphore.signal() }
    if let error = error {
        fputs("OCR error: \(error.localizedDescription)\n", stderr)
        return
    }
    guard let observations = request.results as? [VNRecognizedTextObservation] else {
        return
    }
    let lines = observations.compactMap { $0.topCandidates(1).first?.string }
    recognizedText = lines.joined(separator: "\n")
}

request.recognitionLevel = .accurate
request.recognitionLanguages = ["ja", "en"]
request.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do {
    try handler.perform([request])
} catch {
    fputs("Vision error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

semaphore.wait()

if !recognizedText.isEmpty {
    print(recognizedText)
}
