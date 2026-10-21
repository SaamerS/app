import CryptoKit
import XCTest
@testable import BindersKit

/// What the test builds before Auto mode took its name everywhere saved, read as today's (EarlierSpellings). The strings
/// in the old spelling here are what an earlier test build saved.
final class EarlierSpellingsTests: XCTestCase {
    private func read<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try JSONDecoder().decode(type, from: EarlierSpellings.json(Data(json.utf8)))
    }

    func testTheModeAndWhyACardWasntStartedReadInTodaysSpelling() throws {
        XCTAssertEqual(try read([MomentMode].self, #"["yolo", "add", "suggest"]"#), [.auto, .add, .suggest]) // reads what an earlier test build saved
        XCTAssertEqual(try read([RouterRules.NotStarted].self,
                                #"["not in Yolo", "under Yolo's bar", "no Yolo level", "start switch turned on before Yolo", "# // reads what an earlier test build saved
                                  + #""heard too long ago for Yolo", "start switch turned on before Yolo read captures", "only mentioned"]"#), // reads what an earlier test build saved
                       [.notAuto, .underAutoBar, .noAutoLevel, .switchBeforeAuto, .tooLongAgo, .switchBeforeSolo, .onlyMentioned])
        XCTAssertEqual(try read([RouteOrigin].self, #"["yolo"]"#), [.auto]) // reads what an earlier test build saved
        // Today's spelling reads as it is, and anything else as it was.
        XCTAssertEqual(try read([MomentMode].self, #"["auto"]"#), [.auto])
        XCTAssertThrowsError(try read([MomentMode].self, #"["Auto"]"#))
        XCTAssertEqual(MomentMode(stored: "auto"), .auto)
    }

    func testKeysMoveToTodaysNamesAndWordsYouSaidStay() throws {
        let read = try read([String: String].self, #"{"yoloHold": "voice", "said": "yolo, said once", "yolo_start": "1", "Yolo Bot": "x"}"#) // reads what an earlier test build saved
        XCTAssertEqual(read["autoHold"], "voice")
        XCTAssertEqual(read["auto_mode_start"], "1", "the start in Auto mode has a name of its own")
        XCTAssertEqual(read["said"], "yolo, said once", "only a whole raw value is read in today's spelling") // what an earlier test build saved
        XCTAssertEqual(read["Yolo Bot"], "x", "a key that isn't a name of Binders' own, an agent's, keeps it") // what an earlier test build saved
        XCTAssertEqual(read.count, 4)
        // Today's name wins when both are there.
        XCTAssertEqual(try self.read([String: String].self, #"{"yoloHold": "voice", "autoHold": "audio"}"#), ["autoHold": "audio"]) // what an earlier test build saved
        // What never had the old spelling comes back byte for byte.
        let today = Data(#"{"b":1.10,"a":"auto"}"#.utf8)
        XCTAssertEqual(EarlierSpellings.json(today), today)
    }

    func testTheDefaultsMoveOnce() throws {
        let name = "earlier-spellings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "momentYoloListed") // what an earlier test build saved
        defaults.set("yolo", forKey: "momentMode") // what an earlier test build saved
        defaults.set(["momentYolo", "outcomes"], forKey: "macFeatures") // what an earlier test build saved
        defaults.set(Data(#"{"yoloHold":"voice"}"#.utf8), forKey: "yoloWatch") // what an earlier test build saved
        defaults.set(false, forKey: "soloAutoListed")
        defaults.set(true, forKey: "soloYoloListed") // what an earlier test build saved
        EarlierSpellings.moveDefaults(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "momentAutoListed"))
        XCTAssertNil(defaults.object(forKey: "momentYoloListed")) // what an earlier test build saved
        XCTAssertEqual(defaults.string(forKey: "momentMode"), MomentMode.auto.rawValue)
        XCTAssertEqual(defaults.stringArray(forKey: "macFeatures"), [MomentPayload.autoFeature, "outcomes"])
        let watch = try XCTUnwrap(defaults.data(forKey: "autoWatch"))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: watch), ["autoHold": "voice"])
        XCTAssertFalse(defaults.bool(forKey: "soloAutoListed"), "today's value wins")
        XCTAssertNil(defaults.object(forKey: "soloYoloListed")) // what an earlier test build saved
        // Once: a key written in the old spelling later stays as it is.
        defaults.set(true, forKey: "momentYoloListed") // what an earlier test build saved
        EarlierSpellings.moveDefaults(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: "momentYoloListed")) // what an earlier test build saved
    }

    func testAMeasureSealedByAnEarlierTestBuildStaysSealed() throws {
        let record = MeasureSealsTests.record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // The record and the file as the earlier build wrote them: Auto's level under its old key, sorted last.
        func earlier(_ text: String) -> String {
            text.replacingOccurrences(of: #""bands":{"auto":0.7,"#, with: #""bands":{"#)
                .replacingOccurrences(of: #""suggest":0.55}"#, with: #""suggest":0.55,"yolo":0.7}"#) // what an earlier test build saved
        }
        let earlierRecord = earlier(String(decoding: try encoder.encode(record), as: UTF8.self))
        XCTAssertNotEqual(earlierRecord, String(decoding: try encoder.encode(record), as: UTF8.self))
        let earlierSeal = SHA256.hash(data: Data(earlierRecord.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = try XCTUnwrap(DecisionMeasures.decode(Data(earlier(String(decoding: try DecisionMeasures(measures: [record]).encoded(), as: UTF8.self)).utf8)))
        XCTAssertEqual(file.measures.first?.bands?.auto, 0.7)
        let checked = MeasureSeals.check(file, kept: { _ in earlierSeal }, keptVerdicts: MeasureSeals.seal(verdicts: []), firstRead: false)
        XCTAssertEqual(checked.measures.changed, [])
        XCTAssertEqual(checked.measures.measures.map(\.key), [record.key])
        XCTAssertEqual(checked.adopted, [record.key: MeasureSeals.seal(record)], "sealed again as today's")
    }
}
