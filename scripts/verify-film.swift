// Run from the repository root with: swift scripts/verify-film.swift
import AVFoundation
import Foundation

let movie = URL(fileURLWithPath: "docs/media/feature-tour.mp4")
let asset = AVURLAsset(url: movie)
let duration = try await asset.load(.duration).seconds
guard duration.isFinite, duration > 0,
      let track = try await asset.loadTracks(withMediaType: .video).first else {
    fatalError("The feature film needs a video track and a positive duration.")
}

let formats = try await track.load(.formatDescriptions)
let frameRate = try await track.load(.nominalFrameRate)
guard formats.first?.mediaSubType == .h264, frameRate > 0, frameRate <= 30.01 else {
    fatalError("The mobile film must use H.264 at up to 30 fps.")
}

// Progressive playback requires the movie header before the first block of media data.
let data = try Data(contentsOf: movie, options: .mappedIfSafe)
var offset = 0
var hasMovieHeader = false
var hasMediaData = false
while offset + 8 <= data.count {
    let size = data[offset..<(offset + 4)].reduce(0) { $0 * 256 + Int($1) }
    let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
    guard size >= 8, size <= data.count - offset else { fatalError("Invalid MP4 box at offset \(offset)") }
    if type == "moov" { hasMovieHeader = true }
    if type == "mdat" {
        hasMediaData = true
        break
    }
    offset += size
}
guard hasMovieHeader, hasMediaData else { fatalError("Encode the film with faststart for streaming.") }
print("Verified H.264 film, \(duration) seconds at \(frameRate) fps, with a streaming header.")
