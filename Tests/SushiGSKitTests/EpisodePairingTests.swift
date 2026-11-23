import Foundation
import Testing
@testable import SushiGSKit

@Suite("Episode Pairing & Batch Track Rules")
struct EpisodePairingTests {
    @Test(
        "Extracts episode keys from common anime and TV release naming patterns",
        arguments: [
            ("[SubsPlease] Frieren - 01 (1080p) [A1B2C3D4].mkv", nil as Int?, 1.0, nil as String?),
            ("Frieren.S01E02.1080p.BluRay.x265.10bit.FLAC2.0.mkv", 1, 2.0, nil),
            ("[Group] Show Name [03][1080p][HEVC].mkv", nil, 3.0, nil),
            ("Show.Name.1x04.720p.WEB-DL.mkv", 1, 4.0, nil),
            ("Show Name EP05 (2024) [2160p].mkv", nil, 5.0, nil),
            ("Show Name - 12.5 [1080p].mkv", nil, 12.5, nil),
            ("Show Name OVA 02 [BD 1080p].mkv", nil, 2.0, "OVA"),
            ("Show_Name_07_1080p_x264.mkv", nil, 7.0, nil),
        ]
    )
    func extractsEpisodeKey(filename: String, expectedSeason: Int?, expectedEpisode: Double, expectedTag: String?) throws {
        let key = try #require(EpisodePairing.extractEpisodeKey(from: filename))
        #expect(key.season == expectedSeason)
        #expect(key.episode == expectedEpisode)
        #expect(key.specialTag == expectedTag)
    }

    @Test("Pairs WEB-DL sources with Blu-Ray targets and external subtitles accurately")
    func pairsSourcesTargetsAndExternalSubtitles() {
        let sources = [
            URL(fileURLWithPath: "/src/[SubsPlease] Dungeon Meshi - 02 (1080p) [11223344].mkv"),
            URL(fileURLWithPath: "/src/[SubsPlease] Dungeon Meshi - 01 (1080p) [AABBCCDD].mkv"),
            URL(fileURLWithPath: "/src/[SubsPlease] Dungeon Meshi - 03 (1080p) [55667788].mkv"),
        ]
        let targets = [
            URL(fileURLWithPath: "/dst/Dungeon.Meshi.S01E03.1080p.BluRay.x265.mkv"),
            URL(fileURLWithPath: "/dst/Dungeon.Meshi.S01E01.1080p.BluRay.x265.mkv"),
            URL(fileURLWithPath: "/dst/Dungeon.Meshi.S01E02.1080p.BluRay.x265.mkv"),
        ]
        let subs = [
            URL(fileURLWithPath: "/src/Dungeon Meshi - 02.ass"),
            URL(fileURLWithPath: "/src/Dungeon Meshi - 01.ass"),
        ]

        let paired = EpisodePairing.pairFiles(sources: sources, targets: targets, externalSubtitles: subs)
        #expect(paired.count == 3)
        let allExact = paired.allSatisfy(\.isExactMatch)
        #expect(allExact)
        #expect(paired[0].sourceFile?.lastPathComponent.contains("- 01") == true)
        #expect(paired[0].targetFile?.lastPathComponent.contains("S01E01") == true)
        #expect(paired[0].externalSubtitleFile?.lastPathComponent.contains("- 01") == true)
        #expect(paired[1].targetFile?.lastPathComponent.contains("S01E02") == true)
        #expect(paired[2].targetFile?.lastPathComponent.contains("S01E03") == true)
        #expect(paired[2].externalSubtitleFile == nil)
    }

    @Test("BatchTrackRule resolves audio and subtitle tracks by language, title, position, and stream ID")
    func batchTrackRuleResolution() {
        let audioTracks = [
            AudioTrack(id: 1, codec: "aac", lang: "eng", title: "English Dub", channelLayout: "stereo", default: true),
            AudioTrack(id: 2, codec: "flac", lang: "jpn", title: "Japanese 2.0", channelLayout: "stereo", default: false),
            AudioTrack(id: 3, codec: "flac", lang: "jpn", title: "Director Commentary", channelLayout: "stereo", default: false),
        ]
        let subTracks = [
            SubtitleTrack(id: 4, codec: "ass", lang: "eng", title: "Signs & Songs", extensionName: ".ass", supported: true, default: false, forced: true),
            SubtitleTrack(id: 5, codec: "ass", lang: "eng", title: "Full Dialogue", extensionName: ".ass", supported: true, default: true, forced: false),
            SubtitleTrack(id: 6, codec: "hdmv_pgs_subtitle", lang: "jpn", title: "PGS", extensionName: "", supported: false),
        ]

        let byLang = BatchTrackRule(mode: .languageAndTitle, languageFilter: "jpn", titleContains: "2.0")
        #expect(byLang.resolveAudio(in: audioTracks)?.id == 2)

        let byPos = BatchTrackRule(mode: .trackPosition, trackPosition: 2)
        #expect(byPos.resolveAudio(in: audioTracks)?.id == 2)

        let byID = BatchTrackRule(mode: .streamID, streamID: 3)
        #expect(byID.resolveAudio(in: audioTracks)?.id == 3)

        let subRule = BatchTrackRule(mode: .languageAndTitle, languageFilter: "eng", titleContains: "Dialogue")
        let matchedSubs = subRule.resolveSubtitles(in: subTracks)
        #expect(matchedSubs.map(\.id) == [5])
    }
}
