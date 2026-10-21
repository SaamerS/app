import XCTest
@testable import BindersKit

final class JevAPITests: XCTestCase {
    static let binder = DecisionQuestion(state: "Fix the login typo", question: RouterQuestions.binderQuestion, options: [
        DecisionOption(key: "Home", description: "The flat: repairs Recent: Boiler service"),
        DecisionOption(key: "Website", description: "The website Recent: Pricing page"),
    ])
    static let agent = DecisionQuestion(state: "Fix the login typo", question: RouterQuestions.agentQuestion, options: [
        DecisionOption(key: "Scribe", description: "the website: pages, copy and fixes"),
        DecisionOption(key: RouterQuestions.nobody, description: RouterQuestions.nobodyDescription),
    ])

    static func body(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    static func answer(_ probabilities: [String: Any], choice: String = "Website", extra: [String: Any] = [:]) -> Data {
        body(["model": "kev-latest", "answers": ["q1": ["type": "choice", "choice": choice, "confidence": 0.3, "probabilities": probabilities]],
              "usage": ["input_tokens": 12, "output_tokens": 3], "latency_ms": 41.2].merging(extra) { $1 })
    }

    func testTheRequestsExactBytes() throws {
        let body = String(decoding: try JevAPI.request(state: Self.binder.state, questions: [Self.binder, Self.agent], model: nil), as: UTF8.self)
        XCTAssertEqual(body, #"{"state": "Fix the login typo", "questions": {"q1": {"type": "choice", "instructions": "Which binder does this go in?", "#
            + #""criteria": {"Home": "The flat: repairs Recent: Boiler service", "Website": "The website Recent: Pricing page"}}, "#
            + #""q2": {"type": "choice", "instructions": "Which agent should this go to?", "#
            + #""criteria": {"Scribe": "the website: pages, copy and fixes", "nobody": "for you to do yourself; no agent's work"}}}}"#)
        let named = String(decoding: try JevAPI.request(state: Self.agent.state, questions: [Self.agent], model: "stand-in-decider"), as: UTF8.self)
        XCTAssertTrue(named.hasPrefix(#"{"model": "stand-in-decider", "state": "Fix the login typo", "questions": {"q1": "#), named)
        XCTAssertFalse(String(decoding: try JevAPI.request(state: "x", questions: [Self.agent], model: nil), as: UTF8.self).contains("\"model\""),
                       "model only when /v1/models named one")
        // Python's escapes: quotes, backslashes and control characters; nothing beyond ASCII, not even U+2028.
        let tricky = DecisionQuestion(state: "Say \"hi\" \\ then\nleave\u{1}\u{2028} à jeudi", question: "Q", options: [
            DecisionOption(key: "Café", description: "a/b"), DecisionOption(key: "nobody", description: "x"),
        ])
        XCTAssertEqual(String(decoding: try JevAPI.request(state: tricky.state, questions: [tricky], model: nil), as: UTF8.self),
                       "{\"state\": \"Say \\\"hi\\\" \\\\ then\\nleave\\u0001\u{2028} à jeudi\", \"questions\": {\"q1\": {\"type\": \"choice\", "
                       + "\"instructions\": \"Q\", \"criteria\": {\"Café\": \"a/b\", \"nobody\": \"x\"}}}}")
        // And it parses as the JSON a server reads, with the options in the order asked.
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: JevAPI.request(state: tricky.state, questions: [tricky], model: nil)) as? [String: Any])
        XCTAssertEqual(parsed["state"] as? String, tricky.state)
    }

    func testOneStateIsOneRequest() throws {
        let other = DecisionQuestion(state: "Book the dentist", question: RouterQuestions.agentQuestion, options: Self.agent.options)
        let requests = try JevAPI.requests([Self.binder, other, Self.agent], model: nil)
        XCTAssertEqual(requests.map(\.questions), [[0, 2], [1]], "questions that share a state go in one request, in order")
        XCTAssertTrue(String(decoding: requests[1].body, as: UTF8.self).contains(#""state": "Book the dentist""#))
        XCTAssertEqual(try JevAPI.requests([], model: nil), [])
        // A state Swift calls equal but with other bytes is another state to the server.
        let nfd = DecisionQuestion(state: "Cafe\u{301}", question: "Q", options: Self.agent.options)
        let nfc = DecisionQuestion(state: "Caf\u{e9}", question: "Q", options: Self.agent.options)
        XCTAssertEqual(try JevAPI.requests([nfd, nfc], model: nil).count, 2)
    }

    func testDuplicateKeysAreRefusedBeforeSending() {
        func refused(_ keys: [String]) -> Bool {
            let question = DecisionQuestion(state: "s", question: "q", options: keys.map { DecisionOption(key: $0, description: "d") })
            do {
                _ = try JevAPI.request(state: "s", questions: [question], model: nil)
                return false
            } catch {
                return error as? JevAPI.Problem == .duplicateKeys
            }
        }
        XCTAssertTrue(refused(["Home", "Home"]), "equal bytes")
        XCTAssertTrue(refused(["Caf\u{e9}", "Cafe\u{301}"]), "an NFC and an NFD Café, which the server would keep apart and Binders couldn't")
        XCTAssertTrue(refused(["Home", ""]), "an empty key")
        XCTAssertTrue(refused(["Home", " \u{a0}"]), "a blank one")
        XCTAssertFalse(refused(["Home", "home"]), "case makes another key")
        XCTAssertEqual(JevAPI.Problem.duplicateKeys.words, "two options with one key")
    }

    func testTheAnswerMapsInTheOrderAsked() throws {
        // Keys come back reversed, and one in another normal form: they map by key, in the order asked.
        let reversed = Self.body(["answers": ["q1": ["type": "choice", "probabilities": ["Website": 0.8, "Home": 0.2]],
                                              "q2": ["type": "choice", "probabilities": ["nobody": 0.1, "Scribe": 0.9]]]])
        let mapped = try JevAPI.answers(status: 200, body: reversed, for: [Self.binder, Self.agent], sent: nil)
        XCTAssertEqual(mapped.probs, [[0.2, 0.8], [0.9, 0.1]])
        let accented = DecisionQuestion(state: "s", question: "q", options: [DecisionOption(key: "Caf\u{e9}", description: ""),
                                                                             DecisionOption(key: "nobody", description: "")])
        let nfd = Self.body(["answers": ["q1": ["type": "choice", "probabilities": ["Cafe\u{301}": 0.25, "nobody": 0.75]]]])
        XCTAssertEqual(try JevAPI.answers(status: 200, body: nfd, for: [accented], sent: nil).probs, [[0.25, 0.75]])
        // The choice and the confidence are never read.
        let disagrees = Self.answer(["Home": 0.7, "Website": 0.3], choice: "Website")
        XCTAssertEqual(try JevAPI.answers(status: 200, body: disagrees, for: [Self.binder], sent: nil).probs, [[0.7, 0.3]])
        // Rounded to 4 places by the server, a little off 1: fine. An extra key is ignored.
        XCTAssertEqual(try JevAPI.answers(status: 200, body: Self.answer(["Home": 0.4995, "Website": 0.5, "Garden": 0.0]), for: [Self.binder], sent: nil).probs,
                       [[0.4995, 0.5]])
        XCTAssertEqual(try JevAPI.answers(status: 200, body: Self.answer(["Home": 0, "Website": 1]), for: [Self.binder], sent: nil).probs, [[0, 1]],
                       "whole numbers are numbers")
    }

    /// JSONSerialization reads a long decimal as an NSDecimalNumber whose doubleValue can miss the nearest double by a bit
    /// (0.0004620289534555946 comes back 0.0004620289534555947): the probabilities are the very doubles the server wrote, so
    /// a measure's goldens are a server's probes exactly.
    func testLongDecimalsAreTheDoublesWritten() throws {
        let written: [Double] = [0.0004620289534555946, 0.9995379710465444054]
        let text = #"{"answers": {"q1": {"type": "choice", "probabilities": {"Website": \#(written[1]), "Home": \#(written[0])}}}}"#
        XCTAssertEqual(try JevAPI.answers(status: 200, body: Data(text.utf8), for: [Self.binder], sent: nil).probs, [written])
    }

    func testAnswersThatDontMapAreRefused() {
        func problem(_ body: Data, status: Int = 200) -> JevAPI.Problem? {
            do {
                _ = try JevAPI.answers(status: status, body: body, for: [Self.binder], sent: nil)
                return nil
            } catch {
                return error as? JevAPI.Problem
            }
        }
        XCTAssertEqual(problem(Self.answer(["Home": 0.5])), .noProbabilities, "a key missing")
        XCTAssertEqual(problem(Self.answer(["Home": -0.1, "Website": 1.1])), .noProbabilities)
        XCTAssertEqual(problem(Self.answer(["Home": 1.2, "Website": -0.2])), .noProbabilities)
        XCTAssertEqual(problem(Self.answer(["Home": 0.47, "Website": 0.5])), .noProbabilities, "a sum of 0.97")
        XCTAssertEqual(problem(Self.answer(["Home": 0.5, "Website": 0.5, "Garden": 0.5])), nil, "weight on a key not asked about shows only in the sum")
        XCTAssertEqual(problem(Self.answer(["Home": 0.3, "Website": 0.6, "Garden": 0.1])), .noProbabilities)
        XCTAssertEqual(problem(Self.answer(["Home": true, "Website": false])), .noProbabilities, "a boolean isn't a probability")
        XCTAssertEqual(problem(Self.answer(["Home": "0.5", "Website": "0.5"])), .noProbabilities)
        XCTAssertEqual(problem(Data(#"{"answers": {"q1": {"type": "choice", "probabilities": {"Home": NaN, "Website": 0.5}}}}"#.utf8)),
                       .server("its answer wasn't JSON"), "NaN isn't JSON")
        XCTAssertEqual(problem(Self.body(["answers": ["q1": ["type": "noul", "noul": 0.3]]])), .noProbabilities)
        XCTAssertEqual(problem(Self.body(["model": "kev-latest"])), .noProbabilities)
        XCTAssertEqual(problem(Data("<html>".utf8)), .server("its answer wasn't JSON"))
        XCTAssertEqual(problem(Data(repeating: 0x20, count: JevAPI.maxAnswer + 1)), .server("its answer was over 1 MB"))
        XCTAssertEqual(JevAPI.Problem.noProbabilities.words, "no probability for each option")
    }

    func testWhatEachStatusMeans() {
        func problem(_ status: Int, _ body: Data = Data()) -> JevAPI.Problem? {
            do {
                _ = try JevAPI.answers(status: status, body: body, for: [Self.binder], sent: nil)
                return nil
            } catch {
                return error as? JevAPI.Problem
            }
        }
        XCTAssertEqual(problem(401), .wantsKey(status: 401))
        XCTAssertEqual(problem(403), .wantsKey(status: 403))
        XCTAssertEqual(problem(401)?.words, "wants a key")
        XCTAssertEqual(problem(404), .notADecisionServer(status: 404, path: "/v1/systemone"))
        XCTAssertEqual(problem(404)?.words, "HTTP 404 for /v1/systemone")
        XCTAssertEqual(problem(405)?.words, "HTTP 405 for /v1/systemone")
        XCTAssertEqual(problem(422, Self.body(["detail": "state is required\nand more"])), .refused("state is required"))
        XCTAssertEqual(problem(422, Self.body(["detail": [["loc": ["body"], "msg": "Input should be 'noul'"], ["msg": "Value error, criteria must have 1..255 options"]]])),
                       .refused("Input should be 'noul'"), "FastAPI's list of errors: the first")
        XCTAssertEqual(problem(422, Self.body(["error": ["code": 422, "message": "state and a non-empty questions map are required"]])),
                       .refused("state and a non-empty questions map are required"), "OpenJev's")
        XCTAssertEqual(problem(422)?.words, "it refused the question: HTTP 422")
        XCTAssertEqual(problem(500), .server("HTTP 500"))
        XCTAssertEqual(problem(502), .server("HTTP 502"))
        XCTAssertEqual(problem(302), .server("HTTP 302"), "a redirect is never followed")
    }

    func testWhichModelAnswered() throws {
        let probabilities: [String: Any] = ["Home": 0.2, "Website": 0.8]
        // Laya's router names the checkpoint that answered.
        let laya = Self.answer(probabilities, extra: ["routing": ["model": "multilingual", "repo": "convaiinnovations/laya/multilingual", "reason": "…"]])
        XCTAssertEqual(try JevAPI.answers(status: 200, body: laya, for: [Self.binder], sent: nil).answeredBy, "multilingual")
        // OpenJev's helper puts its model folder, calibration, flags and its own hash in `model`.
        let openJev = Self.body(["id": "shim-1", "model": "jev-qwen T=1.1 noul=3.0,-0.4 flags={} shim=shim.py@0123456789ab",
                                 "answers": ["q1": ["type": "choice", "probabilities": probabilities]]])
        XCTAssertEqual(try JevAPI.answers(status: 200, body: openJev, for: [Self.binder], sent: nil).answeredBy,
                       "jev-qwen T=1.1 noul=3.0,-0.4 flags={} shim=shim.py@0123456789ab")
        // Kev echoes the model it was asked for, or its default name, which /v1/models lists.
        XCTAssertNil(try JevAPI.answers(status: 200, body: Self.answer(probabilities), for: [Self.binder], sent: "kev-latest").answeredBy)
        XCTAssertNil(try JevAPI.answers(status: 200, body: Self.answer(probabilities), for: [Self.binder], sent: nil,
                                        names: ["kev-latest", "jev-latest"]).answeredBy)
        XCTAssertEqual(try JevAPI.answers(status: 200, body: Self.answer(probabilities), for: [Self.binder], sent: nil).answeredBy, "kev-latest",
                       "a name nothing listed is the model that answered")
    }

    func testWhatAServerSaysItServes() throws {
        let card: [String: Any] = ["description": "Kev pointer head on Qwen/Qwen3.5-0.8B, serving runs/kev-0.8b at temperature 2.35",
                                   "release_date": "2026-09-30", "run": "runs/kev-0.8b", "base": "Qwen/Qwen3.5-0.8B", "lora": "kev-0.8b-lora",
                                   "device": "mps", "backend": "mlx", "dtype": "bfloat16", "temperature": 2.3511, "max_state_tokens": 65_536,
                                   "truncate_states": false, "cuda_graphs": ["captured": 2],
                                   "prefix_cache": ["size": 4, "hits": 1], "batches": ["count": 1, "requests": 1, "queued": 0]]
        let kev = Self.body(["models": ["kev-latest", "jev-latest"].map { name in card.merging(["name": name]) { $1 } }])
        let served = try XCTUnwrap(JevAPI.models(status: 200, body: kev))
        XCTAssertEqual(served.names, ["kev-latest", "jev-latest"])
        XCTAssertEqual(served.fields, ["backend=mlx", "base=Qwen/Qwen3.5-0.8B", "description=Kev pointer head on Qwen/Qwen3.5-0.8B, serving runs/kev-0.8b at temperature 2.35",
                                       "device=mps", "dtype=bfloat16", "lora=kev-0.8b-lora", "max_state_tokens=65536", "name=jev-latest", "name=kev-latest",
                                       "release_date=2026-09-30", "run=runs/kev-0.8b", "temperature=2.3511", "truncate_states=false"],
                       "Kev's twelve fixed fields, sorted, without repeats; its counters are objects, so they don't count")
        let openAI = Self.body(["object": "list", "data": [["id": "decider", "object": "model", "created": 1_792_431_731, "owned_by": "vllm",
                                                           "root": "/models/decider", "parent": NSNull(), "max_model_len": 8_192]]])
        XCTAssertEqual(try JevAPI.models(status: 200, body: openAI), JevAPI.Served(names: ["decider"], fields: ["id=decider", "max_model_len=8192",
                                                                                                                  "owned_by=vllm", "root=/models/decider"]))
        XCTAssertNil(try JevAPI.models(status: 404, body: Data()), "none listed: then /v1/version")
        XCTAssertEqual(try JevAPI.models(status: 200, body: Data("<html>".utf8)), JevAPI.Served(names: [], fields: []))
        XCTAssertThrowsError(try JevAPI.models(status: 401, body: Data())) { XCTAssertEqual($0 as? JevAPI.Problem, .wantsKey(status: 401)) }
        XCTAssertThrowsError(try JevAPI.models(status: 500, body: Data())) { XCTAssertEqual(($0 as? JevAPI.Problem)?.words, "HTTP 500 for /v1/models") }
        // OpenJev's /v1/version: its model folder, calibration and its own file's hash; its flags are an object.
        let version = Self.body(["model_dir": "jev-qwen", "T": 1.1, "noul_t": 3.5, "noul_bias": -0.4, "flags": ["perms": 1],
                                 "shim_file": "shim.py", "shim_sha256": "0123456789abcdef"])
        XCTAssertEqual(try JevAPI.version(status: 200, body: version),
                       JevAPI.Served(names: [], fields: ["T=1.1", "model_dir=jev-qwen", "noul_bias=-0.4", "noul_t=3.5", "shim_file=shim.py",
                                                         "shim_sha256=0123456789abcdef"]))
        XCTAssertNil(try JevAPI.version(status: 404, body: Data()))
    }
}

final class LoopbackRuleTests: XCTestCase {
    func allowed(_ typed: String) -> LoopbackAddress? { try? LoopbackRule.check(typed).get() }

    func refusal(_ typed: String) -> String? {
        if case .failure(let refusal) = LoopbackRule.check(typed) { return refusal.words }
        return nil
    }

    func testThisMacsOwnAddresses() {
        XCTAssertEqual(allowed("http://127.0.0.1:8008"), LoopbackAddress(host: .ipv4, port: 8008))
        XCTAssertEqual(allowed("http://[::1]:8008"), LoopbackAddress(host: .ipv6, port: 8008))
        XCTAssertEqual(allowed("http://localhost:8008"), LoopbackAddress(host: .localhost, port: 8008))
        XCTAssertEqual(allowed("HTTP://LOCALHOST:8008"), LoopbackAddress(host: .localhost, port: 8008), "any case")
        XCTAssertEqual(allowed("127.0.0.1:18708"), LoopbackAddress(host: .ipv4, port: 18708), "read with http:// in front")
        XCTAssertEqual(allowed("  localhost:8008\n"), LoopbackAddress(host: .localhost, port: 8008))
        for path in ["", "/", "/v1", "/v1/", "/v1/systemone"] {
            XCTAssertEqual(allowed("http://127.0.0.1:8008" + path)?.normalized, "http://127.0.0.1:8008", "\(path) is dropped")
        }
        XCTAssertEqual(allowed("http://127.0.0.1:8008")?.normalized, "http://127.0.0.1:8008")
        XCTAssertEqual(allowed("http://[::1]:8008")?.normalized, "http://[::1]:8008")
        XCTAssertEqual(allowed("http://localhost:8008")?.normalized, "http://localhost:8008")
        XCTAssertEqual(allowed("http://[::1]:8008")?.display, "[::1]:8008")
        XCTAssertEqual(allowed("http://127.0.0.1:1")?.port, 1)
        XCTAssertEqual(allowed("http://127.0.0.1:65535")?.port, 65_535)
    }

    func testEveryRefusal() {
        XCTAssertEqual(refusal(""), "Type the server's address, such as http://127.0.0.1:8008.")
        XCTAssertEqual(refusal("   "), "Type the server's address, such as http://127.0.0.1:8008.")
        XCTAssertEqual(refusal("http://::1:8008"), "That isn't an address: type one such as http://127.0.0.1:8008.")
        XCTAssertEqual(refusal("http://"), "That isn't an address: type one such as http://127.0.0.1:8008.")
        XCTAssertEqual(refusal("http://127.0.0.1 :8008"), "That isn't an address: type one such as http://127.0.0.1:8008.")
        XCTAssertEqual(refusal("https://127.0.0.1:8008"),
                       "Use http:// for a decision server on this Mac: the connection never leaves it, and Binders checks no certificate for one.")
        XCTAssertEqual(refusal("ftp://127.0.0.1:21"), "Type an http:// address, such as http://127.0.0.1:8008.")
        XCTAssertEqual(refusal("http://user:secret@127.0.0.1:8008"), "Leave the name and password out of the address: Binders sends no key to a decision server.")
        XCTAssertEqual(refusal("http://user@127.0.0.1:8008"), "Leave the name and password out of the address: Binders sends no key to a decision server.")
        for host in ["192.168.1.20", "0.0.0.0", "127.0.0.2", "[::ffff:127.0.0.1]", "mac.local", "binders.io", "10.0.0.5", "127.0.0.1.", "[::1%25lo0]"] {
            XCTAssertEqual(refusal("http://\(host):8008"),
                           "Binders uses a decision server only on this Mac, and \(host.replacingOccurrences(of: "%25", with: "%")) isn't one of its own addresses. Type 127.0.0.1, ::1 or localhost, with the server's port.",
                           host)
        }
        XCTAssertEqual(refusal("http://127.0.0.1"), "Add the port the server listens on, such as http://127.0.0.1:8008.")
        XCTAssertEqual(refusal("http://127.0.0.1:"), "Add the port the server listens on, such as http://127.0.0.1:8008.")
        XCTAssertEqual(refusal("http://[::1]"), "Add the port the server listens on, such as http://127.0.0.1:8008.")
        XCTAssertEqual(refusal("http://127.0.0.1:0"), "The port must be from 1 to 65535.")
        XCTAssertEqual(refusal("http://127.0.0.1:65536"), "The port must be from 1 to 65535.")
        XCTAssertEqual(refusal("http://127.0.0.1:99999999999999999999"), "The port must be from 1 to 65535.")
        for rest in ["/v2", "/v1/systemone/", "/..", "/%2e%2e", "?key=x", "?", "#f", "/v1?x"] {
            XCTAssertEqual(refusal("http://127.0.0.1:8008" + rest), "Type only the address and the port, such as http://127.0.0.1:8008.", rest)
        }
    }

    func testWhatCountsAsThisMacsLoopback() {
        XCTAssertTrue(LoopbackRule.isLoopback(.ipv4([127, 0, 0, 1])))
        XCTAssertTrue(LoopbackRule.isLoopback(.ipv4([127, 4, 5, 6])))
        XCTAssertTrue(LoopbackRule.isLoopback(.ipv6(Array(repeating: 0, count: 15) + [1], interface: nil)))
        let linkLocal: [UInt8] = [0xFE, 0x80] + Array(repeating: 0, count: 13) + [1]
        XCTAssertTrue(LoopbackRule.isLoopback(.ipv6(linkLocal, interface: "lo0")), "fe80::1 on lo0")
        XCTAssertFalse(LoopbackRule.isLoopback(.ipv6(linkLocal, interface: "en0")), "fe80::1 on en0")
        XCTAssertFalse(LoopbackRule.isLoopback(.ipv6(linkLocal, interface: nil)))
        XCTAssertFalse(LoopbackRule.isLoopback(.ipv4([192, 168, 1, 20])))
        XCTAssertFalse(LoopbackRule.isLoopback(.ipv4([10, 0, 0, 5])))
        XCTAssertFalse(LoopbackRule.isLoopback(.ipv4([0, 0, 0, 0])))
        XCTAssertFalse(LoopbackRule.isLoopback(.ipv6(Array(repeating: 0, count: 10) + [0xFF, 0xFF, 127, 0, 0, 1], interface: nil)), "::ffff:127.0.0.1")
        XCTAssertFalse(LoopbackRule.isLoopback(.ipv4([127, 0, 0])), "not four bytes")
    }

    func testWhereLocalhostLeads() {
        let v4 = LoopbackRule.Resolved.ipv4([127, 0, 0, 1])
        let v6 = LoopbackRule.Resolved.ipv6(Array(repeating: 0, count: 15) + [1], interface: nil)
        XCTAssertEqual(try LoopbackRule.pick([v6, v4]).get(), v4, "the first 127.x")
        XCTAssertEqual(try LoopbackRule.pick([v6]).get(), v6, "else ::1")
        let lan = LoopbackRule.Resolved.ipv4([192, 168, 1, 20])
        XCTAssertEqual(LoopbackRule.pick([lan, v4]), .failure(.init("On this Mac, localhost leads to 192.168.1.20, which isn't its own loopback address, so Binders won't send to it. Use 127.0.0.1 and the port.")),
                       "one address elsewhere refuses the connection")
        let elsewhere = LoopbackRule.Resolved.ipv6([0xFE, 0x80] + Array(repeating: 0, count: 13) + [1], interface: "en0")
        if case .failure(let refusal) = LoopbackRule.pick([v4, elsewhere]) {
            XCTAssertTrue(refusal.words.contains("leads to fe80::1%en0,"), refusal.words)
        } else {
            XCTFail("fe80::1 on en0 isn't this Mac's loopback")
        }
        if case .failure(let refusal) = LoopbackRule.pick([]) {
            XCTAssertEqual(refusal.words, "On this Mac, localhost leads to no address, so Binders didn't connect. Use 127.0.0.1 and the port.")
        } else {
            XCTFail("no address")
        }
        XCTAssertEqual(LoopbackRule.Resolved.ipv6(Array(repeating: 0, count: 10) + [0xFF, 0xFF, 127, 0, 0, 1], interface: nil).display, "::ffff:7f00:1")
        XCTAssertEqual(LoopbackRule.Resolved.ipv6([0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1], interface: nil).display, "2001:db8::1:0:0:1",
                       "the first longest run of zeros")
        XCTAssertEqual(LoopbackRule.Resolved.ipv4([10, 0, 0, 5]).display, "10.0.0.5")
    }
}
