import AVFoundation
import CoreMedia
import SwiftUI

/// Song Info, from a song's long-press menu: what the file actually is (read from the file on the
/// phone), its tags, and where it's kept.
struct SongInfoView: View {
    let track: Track

    @Environment(\.dismiss) private var dismiss
    @State private var details: AudioDetails?

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    row("Format", details?.format ?? track.fileExtension.uppercased())
                    row("Codec", details?.codec)
                    row("Bitrate", details?.bitrate.map { "\(Int($0.rounded())) kbps" })
                    row("Sample Rate", details?.sampleRate.map(Formatting.sampleRate))
                    row("Bit Depth", details?.bitDepth.map { "\($0)-bit" })
                    row("Channels", details?.channels.map(Self.channelName))
                    row("Duration", Formatting.duration(track.duration))
                    row("Size", details?.size.map { Formatting.bytes(UInt64(max($0, 0))) })
                }
                Section("Tags") {
                    row("Title", track.title)
                    row("Artist", track.artist)
                    row("Album Artist", track.albumArtist)
                    row("Album", track.album)
                    row("Track", track.trackNumber.map(String.init))
                    row("Disc", track.discNumber.map(String.init))
                    row("Year", track.year.map(String.init))
                }
                Section("File") {
                    row("Name", track.url.lastPathComponent)
                    row("Folder", Self.shortFolder(track.folder))
                    row("Added", track.addedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .navigationTitle("Song Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                let url = track.url, duration = track.duration
                details = await Task.detached(priority: .userInitiated) { await AudioDetails.load(url, duration: duration) }.value
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) {
                Text(value).textSelection(.enabled).multilineTextAlignment(.trailing)
            }
        }
    }

    private static func channelName(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(count) channels"
        }
    }

    /// The folder inside the app's library, e.g. "Music/Artist/Album".
    private static func shortFolder(_ folder: URL) -> String {
        let parts = folder.standardizedFileURL.pathComponents
        if let documents = parts.lastIndex(of: "Documents"), documents + 1 < parts.count {
            return parts[(documents + 1)...].joined(separator: "/")
        }
        return parts.suffix(3).joined(separator: "/")
    }
}

/// The audio details of a file, read with AVFoundation; whatever it can't read stays nil.
struct AudioDetails: Sendable {
    var format: String?
    var codec: String?
    /// kbps.
    var bitrate: Double?
    var sampleRate: Double?
    var bitDepth: Int?
    var channels: Int?
    var size: Int64?

    static func load(_ url: URL, duration: Double) async -> AudioDetails {
        var details = AudioDetails()
        details.format = url.pathExtension.uppercased()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        details.size = (attributes?[.size] as? NSNumber)?.int64Value

        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                details.bitrate = Double(rate) / 1000
            }
            if let description = try? await track.load(.formatDescriptions).first,
               let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                details.sampleRate = stream.mSampleRate > 0 ? stream.mSampleRate : nil
                details.channels = stream.mChannelsPerFrame > 0 ? Int(stream.mChannelsPerFrame) : nil
                details.codec = codecName(stream.mFormatID)
                details.bitDepth = bitDepth(stream)
            }
        }
        // No bitrate from the file (some formats don't say): work it out from size and length.
        if details.bitrate == nil, let size = details.size, duration > 0 {
            details.bitrate = Double(size) * 8 / duration / 1000
        }
        return details
    }

    private static func codecName(_ id: AudioFormatID) -> String {
        switch id {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD:
            return "AAC"
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatAppleLossless: return "Apple Lossless (ALAC)"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatLinearPCM: return "PCM (uncompressed)"
        case kAudioFormatOpus: return "Opus"
        case kAudioFormatAC3: return "Dolby Digital"
        case kAudioFormatEnhancedAC3: return "Dolby Digital Plus"
        default:
            // The four-letter code, e.g. "vorb".
            let bytes = [24, 16, 8, 0].map { UInt8((id >> $0) & 0xFF) }
            return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
        }
    }

    /// Uncompressed audio states it directly; ALAC and FLAC carry it in their format flags; lossy
    /// formats have none.
    private static func bitDepth(_ stream: AudioStreamBasicDescription) -> Int? {
        if stream.mFormatID == kAudioFormatLinearPCM, stream.mBitsPerChannel > 0 { return Int(stream.mBitsPerChannel) }
        guard stream.mFormatID == kAudioFormatAppleLossless || stream.mFormatID == kAudioFormatFLAC else { return nil }
        switch stream.mFormatFlags {
        case kAppleLosslessFormatFlag_16BitSourceData: return 16
        case kAppleLosslessFormatFlag_20BitSourceData: return 20
        case kAppleLosslessFormatFlag_24BitSourceData: return 24
        case kAppleLosslessFormatFlag_32BitSourceData: return 32
        default: return stream.mBitsPerChannel > 0 ? Int(stream.mBitsPerChannel) : nil
        }
    }
}
