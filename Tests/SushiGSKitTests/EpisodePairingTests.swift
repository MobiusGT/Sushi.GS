import Foundation
import Testing
@testable import SushiGSKit

@Suite("Episode Pairing, Multi-Tier Cascade, Auto-Verification & Batch Track Rules")
struct EpisodePairingTests {
    @Test(
        "Extracts episode keys from common anime and TV release naming patterns",
        arguments: [
            ("[SubsPlease] Frieren - 01 (1080p) [A1B2C3D4].mkv", nil as Int?, 1.0, nil as String?),
            ("Frieren.S01E02.1080p.BluRay.x265.10bit.FLAC2.0.mkv", 1, 2.0, nil),
            ("Show.S01E005.2160p.4K.AV1.DDP5.1.mkv", 1, 5.0, nil),
            ("[Group] Show Name [03][1080p][HEVC].mkv", nil, 3.0, nil),
            ("Show.Name.1x04.720p.WEB-DL.mkv", 1, 4.0, nil),
            ("Show Name EP05 (2024) [2160p].mkv", nil, 5.0, nil),
            ("Show Name Episode 5.mkv", nil, 5.0, nil),
            ("Show Name - 01v2 [1080p].mkv", nil, 1.0, nil),
            ("Show Name - 01.5 [1080p].mkv", nil, 1.5, nil),
            ("Show Name - 12.5 [1080p].mkv", nil, 12.5, nil),
            ("Show Name OVA 02 [BD 1080p].mkv", nil, 2.0, "OVA"),
            ("Show_Name_07_1080p_x264.mkv", nil, 7.0, nil),
            ("Show Season 2 - 05 [1080p].mkv", 2, 5.0, nil),
            ("Show #08.mkv", nil, 8.0, nil),
        ]
    )
    func extractsEpisodeKey(filename: String, expectedSeason: Int?, expectedEpisode: Double, expectedTag: String?) throws {
        let key = try #require(EpisodePairing.extractEpisodeKey(from: filename))
        #expect(key.season == expectedSeason)
        #expect(key.episode == expectedEpisode)
        #expect(key.specialTag == expectedTag)
    }

    @Test("Tier 1: Auto-verifies exact filenames and exact stems across differing container extensions")
    func exactNameAndStemAutoVerification() {
        let sources = [
            URL(fileURLWithPath: "/src/Show - 01.mkv"),
            URL(fileURLWithPath: "/src/Show - 02.mkv"),
            URL(fileURLWithPath: "/src/Special Feature Movie.mkv"),
        ]
        let targets = [
            URL(fileURLWithPath: "/dst/Show - 01.mp4"),
            URL(fileURLWithPath: "/dst/Show - 02.mkv"),
            URL(fileURLWithPath: "/dst/special feature movie.mp4"),
        ]

        let paired = EpisodePairing.pairFiles(sources: sources, targets: targets)
        #expect(paired.count == 3)
        let allExactName = paired.allSatisfy { $0.matchKind == .exactFilename }
        let allAutoVerified = paired.allSatisfy(\.isVerified)
        #expect(allExactName)
        #expect(allAutoVerified)
    }

    @Test("Tier 2: Matches S01E05 <-> Show - 5, S01E005 <-> noisy [1080p][x265][DEADBEEF], 01v2 <-> 1, and fractional 01.5 <-> 1.5")
    func tier2NormalizedEpisodeMatching() {
        let sources = [
            URL(fileURLWithPath: "/src/Show - 01v2 (1080p).mkv"),
            URL(fileURLWithPath: "/src/Show - 01.5 [WEB-DL].mkv"),
            URL(fileURLWithPath: "/src/Show.S01E05.1080p.BluRay.x265.10bit.FLAC2.0.mkv"),
            URL(fileURLWithPath: "/src/Other.S01E005.2160p.HEVC.mkv"),
        ]
        let targets = [
            URL(fileURLWithPath: "/dst/Show - 1.mkv"),
            URL(fileURLWithPath: "/dst/Show - 1.5.mp4"),
            URL(fileURLWithPath: "/dst/Show - 5.mkv"),
            URL(fileURLWithPath: "/dst/Other - 05 [1080p][x265][DEADBEEF].mkv"),
        ]

        let paired = EpisodePairing.pairFiles(sources: sources, targets: targets)
        #expect(paired.count == 4)

        let bySourceName = Dictionary(uniqueKeysWithValues: paired.compactMap { draft -> (String, PairedEpisodeDraft)? in
            guard let src = draft.sourceFile?.lastPathComponent else { return nil }
            return (src, draft)
        })

        #expect(bySourceName["Show - 01v2 (1080p).mkv"]?.targetFile?.lastPathComponent == "Show - 1.mkv")
        #expect(bySourceName["Show - 01.5 [WEB-DL].mkv"]?.targetFile?.lastPathComponent == "Show - 1.5.mp4")
        #expect(bySourceName["Show.S01E05.1080p.BluRay.x265.10bit.FLAC2.0.mkv"]?.targetFile?.lastPathComponent == "Show - 5.mkv")
        #expect(bySourceName["Other.S01E005.2160p.HEVC.mkv"]?.targetFile?.lastPathComponent == "Other - 05 [1080p][x265][DEADBEEF].mkv")

        let allTier2Unverified = paired.allSatisfy { $0.matchKind == .episodeRegex && !$0.isVerified }
        #expect(allTier2Unverified)
    }

    @Test("Strict Season Mismatch Rule: differing explicit seasons NEVER match across any tier")
    func strictSeasonMismatchRejection() {
        let sources = [
            URL(fileURLWithPath: "/src/Show.S01E01.1080p.mkv"),
            URL(fileURLWithPath: "/src/Show Season 1 - 05.mkv"),
            URL(fileURLWithPath: "/src/Show.1x09.mkv"),
            URL(fileURLWithPath: "/src/Show Season 1 OVA.mkv"),
        ]
        let targets = [
            URL(fileURLWithPath: "/dst/Show.S02E01.1080p.mkv"),
            URL(fileURLWithPath: "/dst/Show Season 2 - 05.mkv"),
            URL(fileURLWithPath: "/dst/Show.2x09.mkv"),
            URL(fileURLWithPath: "/dst/Show Season 2 OVA.mkv"),
        ]

        let paired = EpisodePairing.pairFiles(sources: sources, targets: targets)
        // None of the 4 sources should match any of the 4 targets -> 8 unpaired entries!
        #expect(paired.count == 8)
        let allUnmatched = paired.allSatisfy { $0.matchKind == .unmatched && !$0.isVerified && ($0.sourceFile == nil || $0.targetFile == nil) }
        #expect(allUnmatched)
    }

    @Test("Tier 2 locks matching explicit seasons together before matching unseasoned files")
    func matchingSeasonsPrioritized() {
        let sources = [
            URL(fileURLWithPath: "/src/Show.S01E05.WEB.mkv"),
            URL(fileURLWithPath: "/src/Show.S02E05.WEB.mkv"),
        ]
        let targets = [
            URL(fileURLWithPath: "/dst/Show.S2E5.BluRay.mkv"),
            URL(fileURLWithPath: "/dst/Show.S1E5.BluRay.mkv"),
        ]

        let paired = EpisodePairing.pairFiles(sources: sources, targets: targets)
        #expect(paired.count == 2)
        #expect(paired[0].sourceFile?.lastPathComponent == "Show.S01E05.WEB.mkv")
        #expect(paired[0].targetFile?.lastPathComponent == "Show.S1E5.BluRay.mkv")
        #expect(paired[1].sourceFile?.lastPathComponent == "Show.S02E05.WEB.mkv")
        #expect(paired[1].targetFile?.lastPathComponent == "Show.S2E5.BluRay.mkv")
    }

    @Test("Tier 3: Matches non-numbered specials conservatively without cross-matching NCOP vs NCED")
    func conservativeSpecialsTitleFallback() {
        let sources = [
            URL(fileURLWithPath: "/src/[SubsPlease] Frieren - OVA (1080p) [11223344].mkv"),
            URL(fileURLWithPath: "/src/[SubsPlease] Frieren - NCOP (1080p).mkv"),
        ]
        let targets = [
            URL(fileURLWithPath: "/dst/Frieren.OVA.1080p.BluRay.x265.FLAC.mkv"),
            URL(fileURLWithPath: "/dst/Frieren.NCED.1080p.BluRay.x265.FLAC.mkv"),
        ]

        let paired = EpisodePairing.pairFiles(sources: sources, targets: targets)
        let ovaMatch = paired.first { $0.sourceFile?.lastPathComponent.contains("OVA") == true }
        #expect(ovaMatch?.targetFile?.lastPathComponent.contains("OVA") == true)
        #expect(ovaMatch?.matchKind == .titleSimilarity)
        #expect(ovaMatch?.isVerified == false)

        // NCOP must NOT falsely match NCED
        let ncopEntry = paired.first { $0.sourceFile?.lastPathComponent.contains("NCOP") == true }
        let ncedEntry = paired.first { $0.targetFile?.lastPathComponent.contains("NCED") == true }
        #expect(ncopEntry?.targetFile == nil)
        #expect(ncopEntry?.matchKind == .unmatched)
        #expect(ncedEntry?.sourceFile == nil)
        #expect(ncedEntry?.matchKind == .unmatched)
    }

    @Test("Does not force bad matches for unrelated files or mismatched episode numbers")
    func unrelatedAndMissingEpisodesStayUnmatched() {
        let sources = [
            URL(fileURLWithPath: "/src/Show - 01.mkv"),
            URL(fileURLWithPath: "/src/Show - 03.mkv"),
            URL(fileURLWithPath: "/src/Completely Unrelated Alpha.mkv"),
        ]
        let targets = [
            URL(fileURLWithPath: "/dst/Show - 01.mp4"),
            URL(fileURLWithPath: "/dst/Show - 04.mp4"),
            URL(fileURLWithPath: "/dst/Random Documentary Beta.mp4"),
        ]

        let paired = EpisodePairing.pairFiles(sources: sources, targets: targets)
        // Ep 01 matches exact stem (1 row), Ep 03 source unmatched (1), Ep 04 target unmatched (1),
        // Alpha source unmatched (1), Beta target unmatched (1) => 5 rows total.
        #expect(paired.count == 5)
        let matched = paired.filter { $0.sourceFile != nil && $0.targetFile != nil }
        #expect(matched.count == 1)
        #expect(matched[0].matchKind == .exactFilename)
        #expect(matched[0].isVerified == true)

        let unmatched = paired.filter { $0.matchKind == .unmatched }
        #expect(unmatched.count == 4)
        let allOneSided = unmatched.allSatisfy { ($0.sourceFile == nil) != ($0.targetFile == nil) }
        #expect(allOneSided)
    }

    @Test("Marks regex-matched pairs with differing filenames as unverified while keeping exact stems verified")
    func regexMatchedPairsStartUnverified() {
        let sources = [
            URL(fileURLWithPath: "/src/Dungeon Meshi - 01.mkv"),
            URL(fileURLWithPath: "/src/[SubsPlease] Dungeon Meshi - 02 (1080p) [11223344].mkv"),
            URL(fileURLWithPath: "/src/[SubsPlease] Dungeon Meshi - 03 (1080p) [55667788].mkv"),
        ]
        let targets = [
            URL(fileURLWithPath: "/dst/Dungeon Meshi - 01.mp4"),
            URL(fileURLWithPath: "/dst/Dungeon.Meshi.S01E02.1080p.BluRay.x265.mkv"),
            URL(fileURLWithPath: "/dst/Dungeon.Meshi.S01E03.1080p.BluRay.x265.mkv"),
        ]
        let subs = [
            URL(fileURLWithPath: "/src/Dungeon Meshi - 02.ass"),
            URL(fileURLWithPath: "/src/Dungeon Meshi - 01.ass"),
        ]

        let paired = EpisodePairing.pairFiles(sources: sources, targets: targets, externalSubtitles: subs)
        #expect(paired.count == 3)

        // Episode 1 shares exact stem -> auto-verified
        #expect(paired[0].matchKind == .exactFilename)
        #expect(paired[0].isVerified == true)
        #expect(paired[0].externalSubtitleFile?.lastPathComponent.contains("- 01") == true)

        // Episodes 2 & 3 matched via episode regex with differing filenames -> start unverified
        #expect(paired[1].matchKind == .episodeRegex)
        #expect(paired[1].isVerified == false)
        #expect(paired[1].targetFile?.lastPathComponent.contains("S01E02") == true)
        #expect(paired[1].externalSubtitleFile?.lastPathComponent.contains("- 02") == true)

        #expect(paired[2].matchKind == .episodeRegex)
        #expect(paired[2].isVerified == false)
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

    @Test("External Mode 3-Way Pairing: auto-verifies ONLY when all 3 sides match exact filename/stem; heuristic target or subtitle starts unverified")
    func threeWayExternalSubtitleAutoVerification() {
        let sources = [
            URL(fileURLWithPath: "/src/Show - 01.mkv"),
            URL(fileURLWithPath: "/src/Show - 02.mkv"),
            URL(fileURLWithPath: "/src/[SubsPlease] Show - 03 (1080p).mkv"),
            URL(fileURLWithPath: "/src/[SubsPlease] Show - OVA (1080p).mkv"),
        ]
        let targets = [
            URL(fileURLWithPath: "/dst/Show - 01.mp4"),
            URL(fileURLWithPath: "/dst/Show - 02.mp4"),
            URL(fileURLWithPath: "/dst/Show.S01E03.1080p.BluRay.x265.mkv"),
            URL(fileURLWithPath: "/dst/Show.OVA.1080p.BluRay.x265.mkv"),
        ]
        let subs = [
            URL(fileURLWithPath: "/sub/Show - 01.ass"),
            URL(fileURLWithPath: "/sub/[Fansub] Show S01E02 (1080p).srt"),
            URL(fileURLWithPath: "/sub/[SubsPlease] Show - 03 (1080p).ass"),
            URL(fileURLWithPath: "/sub/Show OVA BluRay.ssa"),
        ]

        let paired = EpisodePairing.pairFiles(
            sources: sources,
            targets: targets,
            externalSubtitles: subs,
            subtitleMode: .external
        )
        #expect(paired.count == 4)

        // Ep 01: exact stem across Source, Target, AND Subtitle -> auto-verified!
        let ep1 = paired.first { $0.sourceFile?.lastPathComponent == "Show - 01.mkv" }
        #expect(ep1?.targetFile?.lastPathComponent == "Show - 01.mp4")
        #expect(ep1?.externalSubtitleFile?.lastPathComponent == "Show - 01.ass")
        #expect(ep1?.matchKind == .exactFilename)
        #expect(ep1?.isVerified == true)

        // Ep 02: exact media stems, but subtitle matched via Tier 2 regex -> unverified!
        let ep2 = paired.first { $0.sourceFile?.lastPathComponent == "Show - 02.mkv" }
        #expect(ep2?.targetFile?.lastPathComponent == "Show - 02.mp4")
        #expect(ep2?.externalSubtitleFile?.lastPathComponent == "[Fansub] Show S01E02 (1080p).srt")
        #expect(ep2?.matchKind == .episodeRegex)
        #expect(ep2?.isVerified == false)

        // Ep 03: exact subtitle stem with Source, but Target matched via Tier 2 regex -> unverified!
        let ep3 = paired.first { $0.sourceFile?.lastPathComponent.contains("03") == true }
        #expect(ep3?.targetFile?.lastPathComponent.contains("S01E03") == true)
        #expect(ep3?.externalSubtitleFile?.lastPathComponent.contains("03") == true)
        #expect(ep3?.matchKind == .episodeRegex)
        #expect(ep3?.isVerified == false)

        // OVA: Tier 3 conservative specials matching across all 3 sides -> unverified!
        let ova = paired.first { $0.sourceFile?.lastPathComponent.contains("OVA") == true }
        #expect(ova?.targetFile?.lastPathComponent.contains("OVA") == true)
        #expect(ova?.externalSubtitleFile?.lastPathComponent == "Show OVA BluRay.ssa")
        #expect(ova?.matchKind == .titleSimilarity)
        #expect(ova?.isVerified == false)
    }

    @Test("External Mode Season Mismatch Rejection: differing explicit seasons NEVER pair subtitles with mismatched media")
    func threeWayExternalSubtitleSeasonMismatchRejection() {
        let sources = [
            URL(fileURLWithPath: "/src/Show.S01E05.WEB.mkv"),
        ]
        let targets = [
            URL(fileURLWithPath: "/dst/Show.S01E05.BluRay.mkv"),
        ]
        let subs = [
            URL(fileURLWithPath: "/sub/Show.S02E05.ass"),
        ]

        let paired = EpisodePairing.pairFiles(
            sources: sources,
            targets: targets,
            externalSubtitles: subs,
            subtitleMode: .external
        )
        // Media pair (S01E05) must NOT attach S02E05.ass; S02E05.ass stays in its own unmatched row.
        #expect(paired.count == 2)
        let s1Row = paired.first { $0.sourceFile != nil }
        #expect(s1Row?.targetFile != nil)
        #expect(s1Row?.externalSubtitleFile == nil)
        #expect(s1Row?.isVerified == false)
        #expect(s1Row?.matchKind == .unmatched)

        let s2SubRow = paired.first { $0.externalSubtitleFile?.lastPathComponent == "Show.S02E05.ass" }
        #expect(s2SubRow?.sourceFile == nil)
        #expect(s2SubRow?.targetFile == nil)
        #expect(s2SubRow?.isVerified == false)
        #expect(s2SubRow?.matchKind == .unmatched)
    }

    @Test("Partial 1-folder and 2-folder combinations pair populated sides and leave missing side(s) nil")
    func partialFolderCombinations() {
        // 1-folder: Source only
        let sourceOnly = EpisodePairing.pairFiles(
            sources: [
                URL(fileURLWithPath: "/src/Show - 01.mkv"),
                URL(fileURLWithPath: "/src/Show - 02.mkv"),
            ],
            targets: [],
            externalSubtitles: [],
            subtitleMode: .embedded
        )
        #expect(sourceOnly.count == 2)
        #expect(sourceOnly.allSatisfy { $0.sourceFile != nil && $0.targetFile == nil && !$0.isVerified })

        // 1-folder: External Subtitles only
        let subsOnly = EpisodePairing.pairFiles(
            sources: [],
            targets: [],
            externalSubtitles: [
                URL(fileURLWithPath: "/sub/Show - 01.ass"),
                URL(fileURLWithPath: "/sub/Show - 02.srt"),
            ],
            subtitleMode: .external
        )
        #expect(subsOnly.count == 2)
        #expect(subsOnly.allSatisfy { $0.sourceFile == nil && $0.targetFile == nil && $0.externalSubtitleFile != nil && !$0.isVerified })

        // 2-folder: Target + External Subtitles (Source missing)
        let targetAndSubs = EpisodePairing.pairFiles(
            sources: [],
            targets: [
                URL(fileURLWithPath: "/dst/Show.S01E01.BluRay.mkv"),
                URL(fileURLWithPath: "/dst/Show.S01E02.BluRay.mkv"),
            ],
            externalSubtitles: [
                URL(fileURLWithPath: "/sub/Show - 02.ass"),
                URL(fileURLWithPath: "/sub/Show - 01.ass"),
            ],
            subtitleMode: .external
        )
        #expect(targetAndSubs.count == 2)
        #expect(targetAndSubs[0].sourceFile == nil)
        #expect(targetAndSubs[0].targetFile?.lastPathComponent == "Show.S01E01.BluRay.mkv")
        #expect(targetAndSubs[0].externalSubtitleFile?.lastPathComponent == "Show - 01.ass")
        #expect(targetAndSubs[0].isVerified == false)
        #expect(targetAndSubs[1].sourceFile == nil)
        #expect(targetAndSubs[1].targetFile?.lastPathComponent == "Show.S01E02.BluRay.mkv")
        #expect(targetAndSubs[1].externalSubtitleFile?.lastPathComponent == "Show - 02.ass")

        // 2-folder: Source + External Subtitles (Target missing)
        let sourceAndSubs = EpisodePairing.pairFiles(
            sources: [
                URL(fileURLWithPath: "/src/Show - 01v2.mkv"),
            ],
            targets: [],
            externalSubtitles: [
                URL(fileURLWithPath: "/sub/Show - 001.ass"),
            ],
            subtitleMode: .external
        )
        #expect(sourceAndSubs.count == 1)
        #expect(sourceAndSubs[0].sourceFile?.lastPathComponent == "Show - 01v2.mkv")
        #expect(sourceAndSubs[0].targetFile == nil)
        #expect(sourceAndSubs[0].externalSubtitleFile?.lastPathComponent == "Show - 001.ass")
        #expect(sourceAndSubs[0].isVerified == false)
    }
}
