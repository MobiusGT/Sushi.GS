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
}
