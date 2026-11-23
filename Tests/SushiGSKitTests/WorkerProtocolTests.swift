import Foundation
import Testing
@testable import SushiGSKit

@Suite("Worker NDJSON Protocol & AppPaths")
struct WorkerProtocolTests {
    @Test("Parses all worker NDJSON event types accurately")
    func parsesWorkerEvents() throws {
        let stageLine = #"{"type":"stage","stage":"calculating_shifts","detail":"Matching audio patterns","timestamp":"2026-11-23T12:00:00.000Z"}"#
        if case let .stage(name, detail, _) = try #require(WorkerEventParser.parse(line: stageLine)) {
            #expect(name == "calculating_shifts")
            #expect(detail == "Matching audio patterns")
        } else {
            Issue.record("Expected stage event")
        }

        let progLine = #"{"type":"progress","fraction":0.62,"stage":"calculating_shifts","timestamp":"2026-11-23T12:00:01.000Z"}"#
        if case let .progress(fraction, stage, _) = try #require(WorkerEventParser.parse(line: progLine)) {
            #expect(fraction == 0.62)
            #expect(stage == "calculating_shifts")
        } else {
            Issue.record("Expected progress event")
        }

        let warnLine = #"{"type":"warning","code":"broken_segment","summary":"Events from 0:05:00 to 0:05:20 broken","lineIndex":42,"timestamp":"2026-11-23T12:00:02.000Z"}"#
        if case let .warning(code, summary, idx, _) = try #require(WorkerEventParser.parse(line: warnLine)) {
            #expect(code == "broken_segment")
            #expect(summary.contains("0:05:00"))
            #expect(idx == 42)
        } else {
            Issue.record("Expected warning event")
        }

        let resLine = #"{"type":"result","ok":true,"syncedFiles":["/tmp/ep01.mkv.sushi.ass"],"mergedFilepath":"/tmp/Merged Files/ep01.mkv","mergeSucceeded":true,"hasWarnings":false,"warnings":[],"timestamp":"2026-11-23T12:00:05.000Z"}"#
        if case let .jobResult(result) = try #require(WorkerEventParser.parse(line: resLine)) {
            #expect(result.ok)
            #expect(result.syncedFiles == ["/tmp/ep01.mkv.sushi.ass"])
            #expect(result.mergeSucceeded)
            #expect(!result.hasWarnings)
        } else {
            Issue.record("Expected jobResult event")
        }
    }

    @Test("AppPaths respects APP_STORE override and keeps Application Support path clean")
    func appPathsIsolation() {
        let isolated = AppPaths.current(environment: ["APP_STORE": "/tmp/sushigs-unit-test"])
        #expect(isolated.isOverridden)
        #expect(isolated.rootDir.path == "/tmp/sushigs-unit-test")
        #expect(isolated.venvPython.path == "/tmp/sushigs-unit-test/venv/bin/python3")

        let standard = AppPaths.current(environment: [:])
        #expect(!standard.isOverridden)
        #expect(standard.rootDir.path.hasSuffix("Library/Application Support/Sushi.GS"))
    }

    @Test("WorkerJobPayload encodes settings and subtitle targets cleanly")
    func encodesWorkerJobPayload() throws {
        let paths = AppPaths(rootDir: URL(fileURLWithPath: "/tmp/sushigs-test"))
        let config = AppConfiguration()
        let sub = SubtitleTrack(id: 3, codec: "ass", lang: "eng", title: "English", extensionName: ".ass", supported: true, default: true)
        let payload = WorkerJobPayload(
            mode: "sync",
            jobIndex: 1,
            srcFilepath: "/media/src.mkv",
            dstFilepath: "/media/dst.mkv",
            srcAudioStreamId: 1,
            dstAudioStreamId: 2,
            subtitleTargets: [.embedded(sub)],
            outputDir: nil,
            paths: paths,
            config: config
        )

        let data = try JSONEncoder().encode(payload)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["srcAudioStreamId"] as? Int == 1)
        #expect(obj["dstAudioStreamId"] as? Int == 2)
        #expect((obj["subtitleTargets"] as? [[String: Any]])?.count == 1)
    }

    @Test("SyncSettings maps all non-default Sushi flags 1:1 to sushi-sub-next CLI arguments")
    func mapsSushiFlagsAccurately() {
        let defaults = SyncSettings()
        #expect(defaults.sushiCLIArguments() == ["--sample-rate", "24000"])

        var custom = SyncSettings(
            useHighQualityResample: false,
            advancedArgs: SushiAdvancedArgs(
                window: 15,
                maxWindow: 45,
                rewindThresh: 8,
                smoothRadius: 5,
                maxTsDuration: 0.5,
                maxTsDistance: 0.6
            ),
            grouping: false,
            chaptersMode: .none,
            keyframesSource: .auto,
            maxKfDistance: 3.5,
            kfMode: .snap,
            srcFps: "23.976",
            dstFps: "23.976",
            verboseLogging: true
        )

        let cli = custom.sushiCLIArguments()
        #expect(!cli.contains("--sample-rate"))
        #expect(cli.contains("--window") && cli.contains("15"))
        #expect(cli.contains("--max-window") && cli.contains("45"))
        #expect(cli.contains("--rewind-thresh") && cli.contains("8"))
        #expect(cli.contains("--smooth-radius") && cli.contains("5"))
        #expect(cli.contains("--max-ts-duration") && cli.contains("0.5"))
        #expect(cli.contains("--max-ts-distance") && cli.contains("0.6"))
        #expect(cli.contains("--no-grouping"))
        #expect(cli.contains("--chapters") && cli.contains("none"))
        #expect(cli.contains("--src-keyframes") && cli.contains("--dst-keyframes") && cli.contains("auto"))
        #expect(cli.contains("--max-kf-distance") && cli.contains("3.5"))
        #expect(cli.contains("--kf-mode") && cli.contains("snap"))
        #expect(cli.contains("--src-fps") && cli.contains("--dst-fps"))
        #expect(cli.contains("-v"))

        // Verify external chapters & keyframes files serialize cleanly too
        custom.chaptersMode = .file
        custom.chaptersFile = "/tmp/chapters.xml"
        custom.keyframesSource = .files
        custom.srcKeyframesFile = "/tmp/src_kf.txt"
        custom.dstKeyframesFile = "/tmp/dst_kf.txt"
        let fileCli = custom.sushiCLIArguments()
        #expect(fileCli.contains("/tmp/chapters.xml"))
        #expect(fileCli.contains("/tmp/src_kf.txt"))
        #expect(fileCli.contains("/tmp/dst_kf.txt"))
    }
}
