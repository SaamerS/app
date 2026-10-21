import XCTest
@testable import BindersKit

final class DecisionChoiceTests: XCTestCase {
    func testWhatTheSettingHolds() {
        XCTAssertEqual(DecisionChoice(stored: "", appleSilicon: true), .tev1, "until you choose: Tev1 0.8B on Apple silicon")
        XCTAssertEqual(DecisionChoice(stored: "", appleSilicon: false), .off, "and Off on an Intel Mac")
        XCTAssertEqual(DecisionChoice(stored: "tev1", appleSilicon: true), .tev1)
        XCTAssertEqual(DecisionChoice(stored: "off", appleSilicon: true), .off)
        XCTAssertEqual(DecisionChoice(stored: "mlx-community/Qwen3.5-4B-MLX-4bit", appleSilicon: true), .huggingFace("mlx-community/Qwen3.5-4B-MLX-4bit"))
        XCTAssertEqual(DecisionChoice(stored: "/Users/sam/Models/x", appleSilicon: true), .folder("/Users/sam/Models/x"))
        XCTAssertEqual(DecisionChoice(stored: "~/Models/x", appleSilicon: true), .folder("~/Models/x"))
        XCTAssertEqual(DecisionChoice(stored: "/Users/sam/Models/Pocketfold Decider ", appleSilicon: true), .folder("/Users/sam/Models/Pocketfold Decider "),
                       "a path as the open panel gave it")
        XCTAssertEqual(DecisionChoice(stored: "http://127.0.0.1:8008", appleSilicon: true), .server("http://127.0.0.1:8008"))
        XCTAssertEqual(DecisionChoice(stored: "https://127.0.0.1:8008", appleSilicon: true), .server("https://127.0.0.1:8008"),
                       "a server, refused later with the reason")
        XCTAssertEqual(DecisionChoice(stored: "nonsense", appleSilicon: true), .off, "nothing Settings writes")
    }

    func testAnIntelMacNeverGetsAnMLXChoice() {
        for stored in ["", "tev1", "mlx-community/Qwen3.5-4B-MLX-4bit", "/Users/sam/Models/x", "~/Models/x"] {
            XCTAssertEqual(DecisionChoice(stored: stored, appleSilicon: false), .off, stored)
        }
        XCTAssertEqual(DecisionChoice(stored: "http://127.0.0.1:8008", appleSilicon: false), .server("http://127.0.0.1:8008"), "a server is fine there")
    }

    func testWhatIsStoredReadsBack() {
        let choices: [DecisionChoice] = [.off, .tev1, .huggingFace("mlx-community/Qwen3.5-4B-MLX-4bit"), .folder("/Users/sam/Models/x"),
                                         .folder("~/Models/x"), .server("http://[::1]:8008")]
        for choice in choices {
            XCTAssertEqual(DecisionChoice(stored: choice.stored, appleSilicon: true), choice, choice.stored)
        }
        XCTAssertEqual(DecisionChoice.tev1.stored, "tev1")
        XCTAssertEqual(DecisionChoice.off.stored, "off")
        XCTAssertEqual(choices.map(\.isMLX), [false, true, true, true, true, false])
    }
}

final class ModelNamesTests: XCTestCase {
    func testTev1UnderAnyName() {
        for name in ["togethercomputer/Tev1-0.8B-experimental", "someone/TEV1-0.8b-mlx", "tev1fan/model", "x/tev1", "TEV1fan/x", " someone/tev1-0.8b-mlx-bf16 "] {
            XCTAssertTrue(ModelNames.isTev1(name), name)
        }
        for name in ["mlx-community/Qwen3.5-4B-MLX-4bit", "mlx-community/gemma-4-e2b-it-4bit", "tev/v1", "mlx-community/te-v1"] {
            XCTAssertFalse(ModelNames.isTev1(name), name)
        }
    }

    /// A "%" escape decoded by the server would otherwise name Tev1's repository in the address.
    func testTev1UnderAnEscapedName() {
        for name in ["togethercomputer/Tev%31-0.8B-experimental", "togethercomputer/%54ev1-0.8B-experimental",
                     "togethercomputer/%2554ev1-0.8B-experimental", "%74%65%76%31/x"] {
            XCTAssertTrue(ModelNames.isTev1(name), name)
            XCTAssertFalse(ModelNames.isRepoName(name), name)
        }
    }

    func testOnlyARepositorysNameIsTakenForADownload() {
        for name in ["mlx-community/Qwen3.5-4B-MLX-4bit", "mlx-community/gemma-4-e2b-it-4bit", "mlx-community/embeddinggemma-300m-4bit",
                     "a/b", "Owner_1/model.v2-final"] {
            XCTAssertTrue(ModelNames.isRepoName(name), name)
        }
        for name in ["Qwen3.5-4B-MLX-4bit", "a/b/c", "/a", "a/", "a/b ", " a/b", "a b/c", "a/b?x=1", "a/b#c", "a/%41", "a/../b",
                     "../a", "a/.b", "-a/b", "a/b\n", "a/\u{e9}", "a//b", ""] {
            XCTAssertFalse(ModelNames.isRepoName(name), name)
        }
    }
}

final class DecisionReaderTests: XCTestCase {
    /// A chat template that refuses a system message, as Gemma's does: the system line heads the user message.
    static let systemInUser = ChatFrame(before: "<bos><start_of_turn>user\n", between: nil, after: "<end_of_turn>\n<start_of_turn>model\n")
    /// Tev1's own template, with thinking off: the frame its family's chat template gives.
    static let tev1Frame = ChatFrame(before: Tev1Prompt.templateParts.beforeSystem, between: Tev1Prompt.templateParts.between,
                                     after: Tev1Prompt.templateParts.afterUser)

    /// For each reader and version, the SHA-256 of what it sends a model for the first warm-up, worked out in Python from
    /// the warm-up lane R1's bench tool dumped (scratch-R2/reader_pins.py). A change to those bytes under the same version
    /// fails here: bump DecisionReader.version, and add the new version's entry, so old measures stop applying.
    static let pinned: [String: String] = [
        "tev1.1/256": "017794eaf46913e33489c036094fa06cba46b07e2b317fb0ac7b83c1f4990001",
        "chat.1/256": "b741c20dec404c781f6c3d85e5b271a8dd7acc993b5691793462d84bf9fa937a",
        "jev.1": "cd3b45a8581e5a73cd72c07827ff792bd7333dbf124bb740c4ce4163c7aa919f",
    ]

    func testEachReadersBytesArePinnedForItsVersion() throws {
        let warmUp = RouterQuestions.warmUps[0]
        for reader in DecisionReader.allCases {
            let sent: String
            switch reader {
            case .tev1: sent = try XCTUnwrap(reader.prompt(warmUp))
            case .chat: sent = try XCTUnwrap(reader.prompt(warmUp, frame: Self.systemInUser))
            case .jev: sent = String(decoding: try JevAPI.request(state: warmUp.state, questions: [warmUp], model: nil), as: UTF8.self)
            }
            XCTAssertEqual(DecisionFingerprint.sha256Hex(sent), Self.pinned[reader.id],
                           "\(reader.id): a change to what it sends needs DecisionReader.version to go up, and its own entry here")
        }
    }

    func testTheReadersNames() {
        XCTAssertEqual(DecisionReader.version, 1)
        XCTAssertEqual(DecisionReader.tev1.id, "tev1.1/256")
        XCTAssertEqual(DecisionReader.chat.id, "chat.1/256")
        XCTAssertEqual(DecisionReader.jev.id, "jev.1")
        XCTAssertEqual(DecisionBands.tev1BF16.reader, DecisionReader.tev1.id, "the built-in entry is for this version")
    }

    func testTev1sPromptIsItsFamilysFrame() throws {
        let warmUp = RouterQuestions.warmUps[0]
        XCTAssertEqual(Array(try XCTUnwrap(DecisionReader.chat.prompt(warmUp, frame: Self.tev1Frame)).utf8), Array(Tev1Prompt.prompt(warmUp).utf8),
                       "read through its own template's frame, Tev1 gets Tev1Prompt's bytes")
        XCTAssertNil(DecisionReader.chat.prompt(warmUp), "the chat reader needs its frame")
        XCTAssertNil(DecisionReader.jev.prompt(warmUp), "a server is sent a request")
        let inUser = try XCTUnwrap(DecisionReader.chat.prompt(warmUp, frame: Self.systemInUser))
        XCTAssertTrue(inUser.hasPrefix("<bos><start_of_turn>user\n" + Tev1Prompt.system + "\n\n{\"state\": "))
    }

    func testTheReaderComesFromConfig() {
        // Tev1's conversions, as dm/dl's config.json has them.
        let tev1: [String: Any] = ["model_type": "qwen3_5", "tie_word_embeddings": true,
                                   "text_config": ["model_type": "qwen3_5_text", "tie_word_embeddings": true, "vocab_size": 248_320]]
        XCTAssertEqual(DecisionReader.forConfig(tev1), .tev1)
        var untied = tev1
        untied["text_config"] = ["tie_word_embeddings": false, "vocab_size": 248_320]
        XCTAssertEqual(DecisionReader.forConfig(untied), .chat, "an untied Qwen 3.5, as OpenJev's conversion is")
        var otherVocabulary = tev1
        otherVocabulary["text_config"] = ["tie_word_embeddings": true, "vocab_size": 151_936]
        XCTAssertEqual(DecisionReader.forConfig(otherVocabulary), .chat)
        XCTAssertEqual(DecisionReader.forConfig(["model_type": "gemma3", "text_config": ["tie_word_embeddings": true, "vocab_size": 248_320]]), .chat)
        XCTAssertEqual(DecisionReader.forConfig([:]), .chat)
    }
}

final class DecisionFingerprintTests: XCTestCase {
    typealias File = DecisionFingerprint.File

    /// Tev1 0.8B bf16 in dm/dl, the folder the founder has: its six counted files (its README.md isn't one), as
    /// scratch-R2/fingerprint.py hashed them. The 8-bit and 4-bit conversions beside it, for the tests only.
    static let bf16 = [
        File(name: "chat_template.jinja", size: 7_650, sha256: "d78de6bee4c952ca3145eb161921560a6ede7b59a34e7e4be815f3c5386b4364"),
        File(name: "config.json", size: 2_420, sha256: "71299c62cbb9019472d82561c23a203d547848c90fbdc8563864fc9ecadc8121"),
        File(name: "model.safetensors", size: 1_504_832_503, sha256: "724718b51f03f242cc7555bf71083ca87aec8e2415ef3c55eea31f3812a7b567"),
        File(name: "model.safetensors.index.json", size: 28_023, sha256: "afab31d617dbbffbdf9859197c1cebe6e19268caa825c562620b3331c813400b"),
        File(name: "tokenizer.json", size: 19_989_339, sha256: "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f"),
        File(name: "tokenizer_config.json", size: 1_501, sha256: "86f01837a638275f2d3479804e79802aaff0e3ccef15e5f29dd6afbe6551daed"),
    ]
    static let eightBit = [
        File(name: "chat_template.jinja", size: 7_650, sha256: "d78de6bee4c952ca3145eb161921560a6ede7b59a34e7e4be815f3c5386b4364"),
        File(name: "config.json", size: 2_625, sha256: "6be57d16e737968c6aa40d9834f4c4c47736461d29f7fa0b0483796afa4024f9"),
        File(name: "model.safetensors", size: 799_978_896, sha256: "f0cfeac27538e0738b36cd49804553a452d561682e407bae29029fc79c0ef107"),
        File(name: "model.safetensors.index.json", size: 60_784, sha256: "23acad88dafdb7edf586a0c7da6f792c85151d6cd85b5995e776e056126ef0ec"),
        File(name: "tokenizer.json", size: 19_989_339, sha256: "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f"),
        File(name: "tokenizer_config.json", size: 1_501, sha256: "86f01837a638275f2d3479804e79802aaff0e3ccef15e5f29dd6afbe6551daed"),
    ]
    static let fourBit = [
        File(name: "chat_template.jinja", size: 7_650, sha256: "d78de6bee4c952ca3145eb161921560a6ede7b59a34e7e4be815f3c5386b4364"),
        File(name: "config.json", size: 2_625, sha256: "919d818806acc6093475afcccc40b4c27deb509ef1508ba940c71c9b3ce83ab5"),
        File(name: "model.safetensors", size: 424_031_372, sha256: "af18fafefed0b912004e3a28737fd493564dbb8c799b943ea4d17eec0e84c18e"),
        File(name: "model.safetensors.index.json", size: 60_784, sha256: "8fe78962dc431fb784a482ab30d1cdf167f54b898c35ca5ac14ebc47b432b2c9"),
        File(name: "tokenizer.json", size: 19_989_339, sha256: "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f"),
        File(name: "tokenizer_config.json", size: 1_501, sha256: "86f01837a638275f2d3479804e79802aaff0e3ccef15e5f29dd6afbe6551daed"),
    ]

    func testWhichFilesCount() {
        for name in ["model.safetensors", "model-00001-of-00002.safetensors", "config.json", "chat_template.jinja", "tokenizer.model", "cl100k.tiktoken",
                     "merges.txt", "vocab.txt", "Config.JSON", "MERGES.TXT", "model.safetensors.index.json"] {
            XCTAssertTrue(DecisionFingerprint.counts(name), name)
        }
        for name in ["README.md", "LICENSE", "LICENSE-APACHE-2.0", ".DS_Store", ".cache", ".hidden.json", "x.part", "model.safetensors.part", "NOTICE",
                     "SHA256SUMS", "notes.txt", ""] {
            XCTAssertFalse(DecisionFingerprint.counts(name), name)
        }
        XCTAssertFalse(DecisionFingerprint.counts("optiq", isDirectory: true), "a subfolder")
        XCTAssertFalse(DecisionFingerprint.counts("weights.safetensors", isDirectory: true), "a folder, whatever its name")
    }

    func testTheManifestSortsByUTF8Bytes() {
        let files = ["zeta.json", "\u{C4}pfel.json", "alpha.json", "Beta.json"].map { File(name: $0, size: 1, sha256: "00") }
        XCTAssertEqual(DecisionFingerprint.manifest(files),
                       "binders-decision-folder/1\nBeta.json\t1\t00\nalpha.json\t1\t00\nzeta.json\t1\t00\n\u{C4}pfel.json\t1\t00\n",
                       "Ä's bytes (C3 84) come after z's (7A), and capitals before lower case")
    }

    func testTev1sFingerprints() {
        XCTAssertEqual(DecisionFingerprint.folder(Self.bf16), "mlx1-b73a343455582c89eed2254a")
        XCTAssertEqual(DecisionFingerprint.sha256Hex(DecisionFingerprint.manifest(Self.bf16)),
                       "b73a343455582c89eed2254abc3f643e1ea13e6fa3e0bbcf22566140ec51da3e")
        XCTAssertEqual(DecisionFingerprint.folder(Self.bf16.reversed()), "mlx1-b73a343455582c89eed2254a", "the order they're listed in doesn't count")
        XCTAssertEqual(DecisionFingerprint.folder(Self.bf16), DecisionBands.tev1BF16.fingerprint, "the built-in entry's")
        XCTAssertEqual(DecisionFingerprint.folder(Self.eightBit), "mlx1-3e64dbd1bfe8abd4c77552bb")
        XCTAssertEqual(DecisionFingerprint.folder(Self.fourBit), "mlx1-6797669efe158bc4ff019342")
        var resized = Self.bf16
        resized[2].size -= 1
        XCTAssertNotEqual(DecisionFingerprint.folder(resized), DecisionFingerprint.folder(Self.bf16), "one size changed")
        var rehashed = Self.bf16
        rehashed[1].sha256 = "81299c62cbb9019472d82561c23a203d547848c90fbdc8563864fc9ecadc8121"
        XCTAssertNotEqual(DecisionFingerprint.folder(rehashed), DecisionFingerprint.folder(Self.bf16), "one hex digit changed")
        XCTAssertTrue(DecisionFingerprint.folder([]).hasPrefix("mlx1-"))
        XCTAssertEqual(DecisionFingerprint.folder(Self.bf16).count, 5 + 24)
    }

    func testTheWeightIndexRule() {
        func index(_ names: [String]) -> Data {
            let map = Dictionary(uniqueKeysWithValues: names.enumerated().map { ("model.layers.\($0.offset).weight", $0.element) })
            return try! JSONSerialization.data(withJSONObject: ["metadata": ["total_size": 1], "weight_map": map])
        }
        XCTAssertNil(DecisionFingerprint.indexProblem(index(["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"])))
        XCTAssertNil(DecisionFingerprint.indexProblem(index(["model-00001-of-00003.safetensors"])),
                     "a file it names that isn't there is fine: the loader goes by the names then")
        XCTAssertEqual(DecisionFingerprint.indexProblem(index(["model.safetensors", "optiq/mtp.safetensors"])),
                       "its model.safetensors.index.json puts weights in optiq/mtp.safetensors, outside the folder's top level, and Binders only uses a model whose weights are all beside its config.json")
        for name in ["../x.safetensors", ".", "..", "/Users/sam/x.safetensors", "", "sub/model.safetensors", "x\u{0}.safetensors"] {
            XCTAssertNotNil(DecisionFingerprint.indexProblem(index([name])), name)
        }
        XCTAssertEqual(DecisionFingerprint.indexProblem(Data("not json".utf8)), "its model.safetensors.index.json can't be read")
        XCTAssertEqual(DecisionFingerprint.indexProblem(Data(#"{"metadata": {}}"#.utf8)), "its model.safetensors.index.json can't be read",
                       "no weight_map, which mlx-swift-lm's loader needs")
        XCTAssertEqual(DecisionFingerprint.indexProblem(Data(#"{"weight_map": {"a": 3}}"#.utf8)), "its model.safetensors.index.json can't be read")
    }

    func testAServersFingerprint() {
        let server = DecisionIdentity.Server(address: "http://127.0.0.1:18708", names: ["kev-latest", "jev-latest"], fields: ["dtype=bfloat16", "backend=mlx"],
                                             answeredBy: [], probes: [[0.63407, 0.28631, 0.0796], [0.65387, 0.34613], [-0.0, 1.0]])
        XCTAssertEqual(DecisionFingerprint.serverManifest(server), """
            binders-decision-server/2
            address\t"http://127.0.0.1:18708"
            name\t"kev-latest"
            name\t"jev-latest"
            field\t"backend=mlx"
            field\t"dtype=bfloat16"
            probe\t0.634,0.286,0.080
            probe\t0.654,0.346
            probe\t0.000,1.000

            """)
        let fingerprint = DecisionFingerprint.server(server)
        XCTAssertTrue(fingerprint.hasPrefix("jev1-"))
        XCTAssertEqual(fingerprint.count, 5 + 24)
        XCTAssertEqual(DecisionIdentity(server: server).fingerprint, fingerprint)
        XCTAssertEqual(DecisionIdentity(server: server).reader, "jev.1")
        var wobble = server
        wobble.probes[0][0] = 0.63414
        XCTAssertEqual(DecisionFingerprint.server(wobble), fingerprint, "to 3 places")
        var moved = server
        moved.probes[0][0] = 0.6351
        XCTAssertNotEqual(DecisionFingerprint.server(moved), fingerprint)
        // Every part counts, and none can pass for another.
        XCTAssertNotEqual(DecisionFingerprint.server(.init(address: "http://127.0.0.1:18709", names: server.names, fields: server.fields, answeredBy: [],
                                                           probes: server.probes)), fingerprint)
        let forged = DecisionIdentity.Server(address: server.address, names: ["kev-latest\nfield\tx=y"], fields: [], answeredBy: [], probes: [])
        let honest = DecisionIdentity.Server(address: server.address, names: ["kev-latest"], fields: ["x=y"], answeredBy: [], probes: [])
        XCTAssertNotEqual(DecisionFingerprint.server(forged), DecisionFingerprint.server(honest))
        let named = DecisionIdentity.Server(address: server.address, names: server.names, fields: server.fields, answeredBy: ["english", "english"],
                                            probes: server.probes)
        XCTAssertEqual(named.answeredBy, ["english"], "a set")
        XCTAssertNotEqual(DecisionFingerprint.server(named), fingerprint)
    }
}

final class ServerMatchTests: XCTestCase {
    static func server(_ probes: [[Double]], names: [String] = ["kev-latest", "jev-latest"],
                       fields: [String] = ["backend=mlx", "base=Qwen/Qwen3.5-0.8B", "dtype=bfloat16"], answeredBy: [String] = []) -> DecisionIdentity.Server {
        DecisionIdentity.Server(address: "http://127.0.0.1:18708", names: names, fields: fields, answeredBy: answeredBy, probes: probes)
    }

    /// One probability moved by `delta` in log-odds.
    static func moved(_ p: Double, by delta: Double) -> Double {
        let odds = log(p / (1 - p)) + delta
        return 1 / (1 + exp(-odds))
    }

    static var measured: [[Double]] { DecisionBands.tev1?.golden ?? [] }

    func testWithinTheToleranceIsTheSameModel() {
        let measured = Self.measured
        var near = measured
        near[0][2] = Self.moved(measured[0][2], by: 0.019)
        near[1][1] = Self.moved(measured[1][1], by: -0.019)
        XCTAssertTrue(ServerMatch.same(Self.server(measured), Self.server(near)))
        var far = measured
        far[2][6] = Self.moved(measured[2][6], by: 0.03)
        XCTAssertFalse(ServerMatch.same(Self.server(measured), Self.server(far)), "0.03 in log-odds is another model")
        XCTAssertTrue(DecisionIdentity(server: Self.server(measured)).sameModel(as: DecisionIdentity(server: Self.server(near))))
    }

    func testTinyProbabilitiesDontDecide() {
        XCTAssertTrue(ServerMatch.sameProbe([0.9999, 0.0001], [0.996, 0.004]), "0.0001 and 0.004 are both 0.005 once clipped, as 0.9999 and 0.996 are 0.995")
        XCTAssertFalse(ServerMatch.sameProbe([0.98, 0.02], [0.99, 0.01]))
        XCTAssertFalse(ServerMatch.sameProbe([0.5001, 0.4999], [0.4999, 0.5001]), "the top option must be the same")
        XCTAssertFalse(ServerMatch.sameProbe([0.5, 0.5], [0.5, 0.25, 0.25]))
        XCTAssertFalse(ServerMatch.sameProbe([], []))
        XCTAssertFalse(ServerMatch.sameProbe([.nan, 0.5], [.nan, 0.5]))
    }

    func testWhatItSaysAboutItselfMustBeTheSame() {
        let probes = Self.measured
        XCTAssertFalse(ServerMatch.same(Self.server(probes), Self.server(probes, fields: ["backend=mlx", "base=Qwen/Qwen3.5-4B", "dtype=bfloat16"])))
        XCTAssertFalse(ServerMatch.same(Self.server(probes), Self.server(probes, names: ["kev-latest"])))
        XCTAssertFalse(ServerMatch.same(Self.server(probes), Self.server(probes, answeredBy: ["english"])))
        XCTAssertTrue(ServerMatch.same(Self.server(probes, fields: ["b=2", "a=1"]), Self.server(probes, fields: ["a=1", "b=2"])), "fields as a sorted list")
        var elsewhere = Self.server(probes)
        elsewhere.address = "http://127.0.0.1:18709"
        XCTAssertFalse(ServerMatch.same(Self.server(probes), elsewhere))
    }

    /// The skeptic's case: lane R1's one warm-up, 8 of whose 11 probabilities are under 0.003, held at 0.002 on every
    /// option, couldn't tell two models apart. The binder probe here is within 0.002 of the measured one everywhere, but
    /// the two agent probes answer as another conversion of the same model does: bf16's dev answers moved by the distances
    /// scratch-R2/identity_probe_check.py measured between bf16 and 8-bit (0.12 in log-odds on short-02, and fr-06's top
    /// option changing).
    func testOneBinderProbeIsntEnough() {
        let measured = Self.measured
        var other = measured
        other[0][2] += 0.0015
        other[0][4] -= 0.0015
        XCTAssertTrue(zip(other[0], measured[0]).allSatisfy { abs($0 - $1) <= 0.002 }, "the binder probe passes lane R1's old tolerance")
        XCTAssertTrue(ServerMatch.sameProbe(other[0], measured[0]), "and this one")
        other[1][1] = Self.moved(measured[1][1], by: -0.12)
        other[1][8] = measured[1][8] + (measured[1][1] - other[1][1])
        other[2][2] = measured[2][6]
        other[2][6] = measured[2][2]
        XCTAssertGreaterThan(ServerMatch.distance(other[1], measured[1]), 0.1)
        XCTAssertFalse(ServerMatch.same(Self.server(measured), Self.server(other)), "another model: no start on the measured one's bands")
        XCTAssertFalse(DecisionIdentity(server: Self.server(measured)).sameModel(as: DecisionIdentity(server: Self.server(other))))
    }

    /// A card's answer must come from a model the probes reached before anything starts on it (DecisionModels.confirm).
    func testACardsModelMustBeOneTheProbesReached() {
        let kev = Self.server(Self.measured)
        XCTAssertTrue(kev.reached(nil), "Kev names no model, and neither did its probes")
        XCTAssertFalse(kev.reached("openjev-0.8b"), "a model named where the probes named none is another one behind the port")
        let laya = Self.server(Self.measured, names: [], fields: [], answeredBy: ["multilingual", "english", "english"])
        XCTAssertEqual(laya.answeredBy, ["english", "multilingual"])
        XCTAssertTrue(laya.reached("english") && laya.reached("multilingual"))
        XCTAssertFalse(laya.reached("typed-decisions"), "a checkpoint no probe reached")
        XCTAssertFalse(laya.reached(nil), "an answer that names none where the probes' all did")
    }

    func testKevsCountersAndAnOpenAICreatedDontCount() throws {
        func kev(hits: Int, batches: Int) -> Data {
            let card: [String: Any] = ["description": "Kev pointer head on Qwen/Qwen3.5-0.8B, serving runs/kev-0.8b at temperature 2.35",
                                       "release_date": "2026-09-30", "run": "runs/kev-0.8b", "base": "Qwen/Qwen3.5-0.8B", "lora": NSNull(),
                                       "device": "mps", "backend": "mlx", "dtype": "bfloat16", "temperature": 2.3511, "max_state_tokens": 65_536,
                                       "truncate_states": false, "cuda_graphs": NSNull(),
                                       "prefix_cache": ["size": 4, "hits": hits, "misses": 2], "batches": ["count": batches, "requests": batches, "queued": 0]]
            let models = ["kev-latest", "jev-latest"].map { name in card.merging(["name": name]) { $1 } }
            return try! JSONSerialization.data(withJSONObject: ["models": models])
        }
        let first = try XCTUnwrap(JevAPI.models(status: 200, body: kev(hits: 1, batches: 1)))
        let later = try XCTUnwrap(JevAPI.models(status: 200, body: kev(hits: 57, batches: 40)))
        XCTAssertEqual(first, later)
        XCTAssertEqual(first.names, ["kev-latest", "jev-latest"])
        XCTAssertTrue(ServerMatch.same(Self.server(Self.measured, names: first.names, fields: first.fields),
                                       Self.server(Self.measured, names: later.names, fields: later.fields)))
        func openAI(created: Int) -> Data {
            try! JSONSerialization.data(withJSONObject: ["object": "list", "data": [["id": "decider", "object": "model", "created": created,
                                                                                     "owned_by": "vllm", "root": "/models/decider", "max_model_len": 8_192]]])
        }
        XCTAssertEqual(try JevAPI.models(status: 200, body: openAI(created: 1)), try JevAPI.models(status: 200, body: openAI(created: 1_792_431_731)))
    }
}

final class DecisionBandsTests: XCTestCase {
    static let at = Date(timeIntervalSince1970: 1_792_425_731)
    static let eightBit = DecisionIdentity(fingerprint: "mlx1-3e64dbd1bfe8abd4c77552bb", reader: "tev1.1/256")

    static func measure(_ identity: DecisionIdentity, start: Double?, noStart: DecisionMeasure.NoStart? = nil, golden: [[Double]]? = [[0.5, 0.5]]) -> DecisionMeasure {
        DecisionMeasure(key: identity.key, fingerprint: identity.fingerprint, reader: identity.reader, server: identity.server, at: at, golden: golden,
                        bands: .init(start: start, suggest: 0.55, generalBelow: 0.41, generalBelowTitlesOnly: 0.30), noStart: noStart)
    }

    func testTheBuiltInEntryIsR1s() throws {
        XCTAssertEqual(DecisionBands.builtIn.count, 1, "nothing else is built in")
        let resolved = DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures())
        XCTAssertEqual(resolved.source, .builtIn)
        XCTAssertEqual(resolved.source.logName, "built-in")
        XCTAssertEqual(resolved.bands, RouterBands(start: 0.97, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33, auto: 0.60))
        XCTAssertEqual(resolved.golden?.map(\.count), [11, 9, 9], "three goldens, one per warm-up")
        XCTAssertNil(resolved.measure)
        // R1's band edges.
        let bands = resolved.bands
        XCTAssertEqual(bands.band(0.4999), .none)
        XCTAssertEqual(bands.band(0.50), .suggest)
        XCTAssertEqual(bands.band(0.9699), .suggest)
        XCTAssertEqual(bands.band(0.97), .start)
        let tev1 = try XCTUnwrap(DecisionBands.tev1)
        XCTAssertEqual([tev1.test.binderOK, tev1.test.agentOK, tev1.test.starts, tev1.test.wrongStarts], [147, 118, 4, 0])
        XCTAssertEqual(tev1.test.score ?? 0, 0.7934, accuracy: 0.00005)
        XCTAssertEqual(tev1.dev.score ?? 0, 0.7703, accuracy: 0.00005)
    }

    /// A load's three warm-ups against the goldens of its bands: every probability within 0.002, and nothing to match
    /// without a golden.
    func testWarmUpsMatchTheirGoldensWithinTheTolerance() throws {
        let golden = try XCTUnwrap(DecisionBands.tev1?.golden)
        XCTAssertEqual(DecisionBands.goldenTolerance, 0.002)
        XCTAssertTrue(DecisionBands.warmUpsMatch(golden, golden), "the built-in goldens hold to themselves")
        var near = golden
        near[1][0] += 0.0019
        near[2][8] -= 0.0019
        XCTAssertTrue(DecisionBands.warmUpsMatch(near, golden), "0.0019 off is within it")
        var off = golden
        off[2][6] += 0.0021
        XCTAssertFalse(DecisionBands.warmUpsMatch(off, golden), "0.0021 off on one option of the third warm-up isn't")
        XCTAssertFalse(DecisionBands.warmUpsMatch(Array(golden.prefix(1)), golden), "R1's one warm-up isn't three")
        XCTAssertFalse(DecisionBands.warmUpsMatch(golden.map { Array($0.dropLast()) }, golden), "an option fewer isn't the same question")
        XCTAssertFalse(DecisionBands.warmUpsMatch(golden, nil), "a model never measured has no golden")
        XCTAssertFalse(DecisionBands.warmUpsMatch([], golden), "no warm-up yet")
        XCTAssertFalse(DecisionBands.warmUpsMatch([], []), "nor an empty golden")
        var broken = golden
        broken[0][2] = .nan
        XCTAssertFalse(DecisionBands.warmUpsMatch(broken, golden), "a value that isn't a number never matches")
    }

    func testOnlyThatModelReadThatWayIsBuiltIn() {
        let measures = DecisionMeasures()
        for identity in [DecisionIdentity(fingerprint: DecisionBands.tev1BF16.fingerprint, reader: "chat.1/256"),
                         DecisionIdentity(fingerprint: DecisionBands.tev1BF16.fingerprint, reader: "tev1.2/256"),
                         DecisionIdentity(fingerprint: DecisionBands.tev1BF16.fingerprint, reader: "tev1.1/512"),
                         Self.eightBit, DecisionIdentity(fingerprint: "mlx1-6797669efe158bc4ff019342", reader: "tev1.1/256")] {
            let resolved = DecisionBands.resolve(identity, measures: measures)
            XCTAssertEqual(resolved.source, .unmeasured, identity.key)
            XCTAssertEqual(resolved.bands, DecisionBands.unmeasured, identity.key)
            XCTAssertNil(resolved.golden, identity.key)
        }
    }

    func testAMeasureOnThisMacWins() {
        let measures = DecisionMeasures(measures: [Self.measure(DecisionBands.tev1BF16, start: 0.98)])
        let resolved = DecisionBands.resolve(DecisionBands.tev1BF16, measures: measures)
        XCTAssertEqual(resolved.source, .measured(Self.at), "this Mac's own numbers take the built-in entry's place")
        XCTAssertEqual(resolved.source.logName, "measured")
        XCTAssertEqual(resolved.bands, RouterBands(start: 0.98, suggest: 0.55, generalBelow: 0.41, generalBelowTitlesOnly: 0.30))
        XCTAssertEqual(resolved.golden, [[0.5, 0.5]])
        XCTAssertEqual(resolved.measure?.key, DecisionBands.tev1BF16.key)
        // Bands are kept per model: another model's measure is never used.
        XCTAssertEqual(DecisionBands.resolve(Self.eightBit, measures: measures).source, .unmeasured)
        let both = DecisionMeasures(measures: [Self.measure(DecisionBands.tev1BF16, start: 0.98), Self.measure(Self.eightBit, start: nil, noStart: .noLevel)])
        XCTAssertEqual(DecisionBands.resolve(DecisionBands.tev1BF16, measures: both).bands.start, 0.98)
        XCTAssertNil(DecisionBands.resolve(Self.eightBit, measures: both).bands.start)
    }

    func testAMeasureWithNoStartLevelStartsNothing() {
        let resolved = DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures(measures: [Self.measure(Self.eightBit, start: nil, noStart: .noLevel)]))
        XCTAssertNil(resolved.bands.start)
        XCTAssertEqual(resolved.measure?.noStart, .noLevel, "and keeps its reason")
        XCTAssertEqual(resolved.bands.suggest, 0.55, "it still names agents")
        // A reason with a level written beside it still starts nothing.
        let odd = DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures(measures: [Self.measure(Self.eightBit, start: 0.97, noStart: .testFew)]))
        XCTAssertNil(odd.bands.start)
    }

    func testATestVerdictTakesTheStartAway() {
        let verdict = DecisionMeasure.TestVerdict(key: DecisionBands.tev1BF16.key, at: Self.at, level: 0.97, noStart: .testWrong)
        let measures = DecisionMeasures(measures: [Self.measure(DecisionBands.tev1BF16, start: 0.97)], testVerdicts: [verdict])
        let resolved = DecisionBands.resolve(DecisionBands.tev1BF16, measures: measures)
        XCTAssertNil(resolved.bands.start)
        XCTAssertEqual(resolved.bands.generalBelow, 0.41, "filing and naming bands are kept")
        XCTAssertEqual(resolved.verdict, verdict)
        XCTAssertNil(DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures(testVerdicts: [verdict])).bands.start,
                     "and from the built-in entry too")
    }

    func testAServersMeasureIsFoundByItsMatch() {
        let probes = DecisionBands.tev1?.golden ?? []
        let server = DecisionIdentity.Server(address: "http://127.0.0.1:18708", names: ["kev-latest", "jev-latest"], fields: ["backend=mlx"], answeredBy: [],
                                             probes: probes.map { $0.map { ($0 * 1000).rounded() / 1000 } })
        let measured = DecisionIdentity(server: server)
        let measures = DecisionMeasures(measures: [Self.measure(measured, start: 0.98)])
        XCTAssertEqual(DecisionBands.resolve(measured, measures: measures).bands.start, 0.98, "by its key")
        // One probability 0.0004 across a rounding edge: another strict key, the same model.
        var edge = server
        edge.probes[0][2] = 0.6345 + 0.0002
        edge.probes[0][4] = server.probes[0][4] - (edge.probes[0][2] - server.probes[0][2])
        var shifted = server
        shifted.probes[0][2] = 0.6345 - 0.0002
        shifted.probes[0][4] = server.probes[0][4] - (shifted.probes[0][2] - server.probes[0][2])
        let below = DecisionIdentity(server: shifted), above = DecisionIdentity(server: edge)
        XCTAssertNotEqual(below.key, above.key, "the strict key, to 3 places, differs")
        let found = DecisionMeasures(measures: [Self.measure(below, start: 0.98)])
        XCTAssertEqual(DecisionBands.resolve(above, measures: found).bands.start, 0.98, "found by the match")
        XCTAssertEqual(DecisionBands.resolve(above, measures: found).source, .measured(Self.at))
        // A probe moved by 0.01 at 0.3 is another model.
        var moved = server
        moved.probes[2][8] = 0.30
        var movedAgain = server
        movedAgain.probes[2][8] = 0.31
        let nearly = DecisionMeasures(measures: [Self.measure(DecisionIdentity(server: moved), start: 0.98)])
        XCTAssertEqual(DecisionBands.resolve(DecisionIdentity(server: movedAgain), measures: nearly).source, .unmeasured)
    }

    // MARK: Auto's level

    func testTheBuiltInEntryHasAutosLevelAndItsCounts() throws {
        let tev1 = try XCTUnwrap(DecisionBands.tev1)
        XCTAssertEqual(tev1.bands.auto, 0.60)
        XCTAssertEqual(tev1.auto?.dev, DecisionMeasure.AutoCounts(picks: 23, right: 19, falseAssignments: 1, named: 4, namedRight: 4))
        XCTAssertEqual(tev1.auto?.test, DecisionMeasure.AutoCounts(picks: 31, right: 31, falseAssignments: 0, named: 6, namedRight: 6))
        XCTAssertNil(DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures()).whyNoAuto)
        XCTAssertNil(DecisionBands.unmeasured.auto, "a model not measured has none")
        let unmeasured = DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures())
        XCTAssertNil(unmeasured.bands.auto)
        XCTAssertEqual(unmeasured.whyNoAuto, .unmeasured)
    }

    func testAMeasuresOwnAutoLevel() {
        var measured = Self.measure(Self.eightBit, start: 0.97)
        measured.bands?.auto = 0.70
        measured.auto = .init(dev: .init(picks: 12, right: 11), test: .init(picks: 20, right: 19))
        let resolved = DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures(measures: [measured]))
        XCTAssertEqual(resolved.bands.auto, 0.70)
        XCTAssertNil(resolved.whyNoAuto)
        var none = Self.measure(Self.eightBit, start: 0.97)
        none.noAuto = .devShare
        let noLevel = DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures(measures: [none]))
        XCTAssertNil(noLevel.bands.auto)
        XCTAssertEqual(noLevel.measure?.noAuto, .devShare, "and keeps its reason")
        XCTAssertEqual(noLevel.whyNoAuto, .noLevel)
        XCTAssertEqual(noLevel.bands.start, 0.97, "starts aren't touched")
    }

    func testARecordFromBeforeAutoReadsAsMeasuredBefore() {
        let before = Self.measure(Self.eightBit, start: 0.97)
        XCTAssertTrue(before.measuredBeforeAuto)
        let resolved = DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures(measures: [before]))
        XCTAssertNil(resolved.bands.auto, "Auto hands nothing over until it's measured again")
        XCTAssertEqual(resolved.whyNoAuto, .measuredBefore)
        XCTAssertEqual(resolved.bands.start, 0.97, "its starts go on")
        var after = before
        after.noAuto = .devFew
        XCTAssertFalse(after.measuredBeforeAuto)
        after.noAuto = nil
        after.bands?.auto = 0.6
        XCTAssertFalse(after.measuredBeforeAuto)
    }

    /// Tev1 0.8B bf16 measured under R2 (no Auto fields): the same bytes, read the same way, giving the same numbers, so the
    /// level worked out from R1's runs is its own.
    func testTev1MeasuredBeforeAutoKeepsTheBuiltInLevel() throws {
        let tev1 = try XCTUnwrap(DecisionBands.tev1)
        func record(golden: [[Double]]?, bands: RouterBands = DecisionBands.tev1!.bands) -> DecisionMeasure {
            var stripped = bands
            stripped.auto = nil
            return DecisionMeasure(key: DecisionBands.tev1BF16.key, fingerprint: DecisionBands.tev1BF16.fingerprint, reader: DecisionBands.tev1BF16.reader,
                                   at: Self.at, golden: golden, bands: DecisionMeasure.Bands(stripped), dev: tev1.dev, test: tev1.test)
        }
        let same = DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures(measures: [record(golden: tev1.golden)]))
        XCTAssertEqual(same.source, .measured(Self.at))
        XCTAssertEqual(same.bands.auto, 0.60)
        XCTAssertEqual(same.bands.start, 0.97)
        XCTAssertNil(same.whyNoAuto)
        var near = tev1.golden
        near[1][0] += 0.0019
        XCTAssertEqual(DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures(measures: [record(golden: near)])).bands.auto, 0.60,
                       "within the warm-ups' tolerance")
        var off = tev1.golden
        off[2][6] += 0.003
        let differs = DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures(measures: [record(golden: off)]))
        XCTAssertNil(differs.bands.auto, "a golden 0.003 off: other numbers, so none")
        XCTAssertEqual(differs.whyNoAuto, .measuredBefore)
        XCTAssertNil(DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures(measures: [record(golden: nil)])).bands.auto)
        let otherBands = record(golden: tev1.golden, bands: RouterBands(start: 0.98, suggest: 0.50, generalBelow: 0.45, generalBelowTitlesOnly: 0.33))
        XCTAssertNil(DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures(measures: [otherBands])).bands.auto, "other bands")
        // Another model's record with Tev1's goldens and bands is still another model.
        var eight = record(golden: tev1.golden)
        eight.key = Self.eightBit.key
        XCTAssertNil(DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures(measures: [eight])).bands.auto)
        // A record of this build keeps its own answer.
        var ownNone = record(golden: tev1.golden)
        ownNone.noAuto = .testShare
        XCTAssertNil(DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures(measures: [ownNone])).bands.auto)
    }

    func testAutosVerdicts() {
        let key = Self.eightBit.key
        var measured = Self.measure(Self.eightBit, start: 0.97)
        measured.bands?.auto = 0.60
        let took = DecisionMeasure.TestVerdict(key: key, at: Self.at, level: nil, noStart: nil, noAuto: .testShare)
        XCTAssertFalse(took.tookStart, "it says nothing about starting")
        let resolved = DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures(measures: [measured], testVerdicts: [took]))
        XCTAssertNil(resolved.bands.auto, "a test that took Auto mode away holds")
        XCTAssertEqual(resolved.whyNoAuto, .noLevel)
        XCTAssertEqual(resolved.bands.start, 0.97, "and leaves starting as it was")
        let raised = DecisionMeasure.TestVerdict(key: key, at: Self.at, level: nil, noStart: nil, autoLevel: 0.70)
        XCTAssertEqual(DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures(measures: [measured], testVerdicts: [raised])).bands.auto, 0.70,
                       "never under a level a test raised it to")
        XCTAssertEqual(raised.autoBefore?.level, 0.70)
        XCTAssertNil(DecisionMeasure.TestVerdict(key: key, at: Self.at, level: 0.97, noStart: .testWrong).autoBefore)
        // The built-in entry, too.
        let builtInTook = DecisionMeasure.TestVerdict(key: DecisionBands.tev1BF16.key, at: Self.at, level: nil, noStart: nil, noAuto: .testShare)
        let builtIn = DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures(testVerdicts: [builtInTook]))
        XCTAssertNil(builtIn.bands.auto)
        XCTAssertEqual(builtIn.bands.start, 0.97)
        XCTAssertEqual(builtIn.whyNoAuto, .noLevel)
    }

    func testAutosPartsJoinTheVerdictThatHolds() {
        let key = Self.eightBit.key
        let measured = Self.measure(Self.eightBit, start: nil, noStart: .testWrong)
        var file = DecisionMeasures()
        file.keep(measured, verdict: .init(key: key, at: Self.at, level: 0.97, noStart: .testWrong))
        file.keep(measured, verdict: .init(key: key, at: Self.at, level: nil, noStart: nil, autoLevel: 0.70))
        XCTAssertEqual(file.testVerdicts.count, 1, "one verdict per model")
        XCTAssertEqual(file.testVerdicts.first?.noStart, .testWrong, "the first start verdict holds")
        XCTAssertEqual(file.testVerdicts.first?.autoLevel, 0.70)
        file.keep(measured, verdict: .init(key: key, at: Self.at, level: nil, noStart: nil, autoLevel: 0.60))
        XCTAssertEqual(file.testVerdicts.first?.autoLevel, 0.70, "a raised level never goes down")
        file.keep(measured, verdict: .init(key: key, at: Self.at, level: nil, noStart: nil, noAuto: .testShare))
        XCTAssertEqual(file.testVerdicts.first?.noAuto, .testShare)
        file.keep(measured, verdict: .init(key: key, at: Self.at, level: nil, noStart: nil, autoLevel: 0.80))
        XCTAssertEqual(file.testVerdicts.first?.noAuto, .testShare, "and once Auto is taken away, it stays away")
        // Auto first, then a start verdict: the start part joins it.
        var other = DecisionMeasures()
        other.keep(measured, verdict: .init(key: key, at: Self.at, level: nil, noStart: nil, noAuto: .testShare))
        XCTAssertEqual(DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures(measures: [Self.measure(Self.eightBit, start: 0.97)],
                                                                                          testVerdicts: other.testVerdicts)).bands.start, 0.97,
                       "an Auto verdict alone leaves the start level")
        other.keep(measured, verdict: .init(key: key, at: Self.at, level: 0.97, noStart: .testFew))
        XCTAssertEqual(other.testVerdicts.count, 1)
        XCTAssertEqual(other.testVerdicts.first?.noStart, .testFew)
        XCTAssertEqual(other.testVerdicts.first?.level, 0.97)
        XCTAssertEqual(other.testVerdicts.first?.noAuto, .testShare)
    }

    func testAModelWithNoMeasureNeverStarts() {
        let unmeasured = DecisionBands.unmeasured
        XCTAssertEqual(unmeasured, RouterBands(start: nil, suggest: 0.50, generalBelow: 0.35, generalBelowTitlesOnly: 0.35))
        XCTAssertEqual(unmeasured.band(0.999), .suggest, "0.999 is a suggestion")
        XCTAssertEqual(unmeasured.generalThreshold(.titles), 0.35)
        XCTAssertEqual(unmeasured.generalThreshold(.both), 0.35)
        func check(bands: RouterBands, numbersMatch: Bool) -> RouterRules.NotStarted? {
            RouterRules.mayStart(RouterRules.StartCheck(agent: "Scribe", how: .model, startsOnItsOwn: true, hasOwnPurpose: true, draftsFirst: true,
                                                        checksBoard: false, bands: bands, numbersMatch: numbersMatch,
                                                        modelTop: RankedOption(key: "Scribe", p: 0.999), takesBinder: true, takerNow: true,
                                                        leftOutTakesBinder: false, origin: .typedReady, kind: .card, wouldWake: true))
        }
        XCTAssertEqual(check(bands: unmeasured, numbersMatch: true), .noStartBar, "at 0.999, with its numbers matching")
        XCTAssertEqual(check(bands: DecisionBands.resolve(Self.eightBit, measures: DecisionMeasures()).bands, numbersMatch: true), .noStartBar)
        let builtIn = DecisionBands.resolve(DecisionBands.tev1BF16, measures: DecisionMeasures()).bands
        XCTAssertEqual(check(bands: builtIn, numbersMatch: false), .numbersDiffer)
        XCTAssertNil(check(bands: builtIn, numbersMatch: true))
    }
}

final class DecisionMeasureCodableTests: XCTestCase {
    static let at = Date(timeIntervalSince1970: 1_792_425_731)

    static var record: DecisionMeasure {
        DecisionMeasure(key: "jev1-0123456789abcdef01234567 jev.1", fingerprint: "jev1-0123456789abcdef01234567", reader: "jev.1",
                        server: .init(address: "http://127.0.0.1:18708", names: ["kev-latest"], fields: ["backend=mlx"], answeredBy: ["english"],
                                      probes: [[0.6, 0.4], [0.7, 0.3], [0.2, 0.8]]),
                        at: at, build: "25", mac: "Mac17,6, Apple M5 Max", golden: [[0.6, 0.4], [0.7, 0.3], [0.2, 0.8]], letterShare: [0.9998, 0.9996, 0.9993],
                        bands: .init(start: 0.97, suggest: 0.5, generalBelow: 0.45, generalBelowTitlesOnly: 0.33), noStart: nil,
                        dev: .init(items: 111, binderOK: 98, agentOK: 73, score: 0.7703, starts: 3, wrongStarts: 0, titlesBinderOK: 92, level: 0.97),
                        test: .init(items: 167, binderOK: 147, agentOK: 118, score: 0.7934, starts: 4, wrongStarts: 0, level: 0.97),
                        answeredBy: ["english", "multilingual"], ms: .init(p50: 80, p95: 86))
    }

    func testARecordRoundTrips() throws {
        let verdict = DecisionMeasure.TestVerdict(key: "mlx1-3e64dbd1bfe8abd4c77552bb tev1.1/256", at: Self.at, level: 0.97, noStart: .testWrong)
        let file = DecisionMeasures(measures: [Self.record], testVerdicts: [verdict])
        let data = try file.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""schema":"binders-decision-measures/2""#))
        XCTAssertTrue(text.contains(#""at":"2026-10-19T"#), "dates in ISO 8601: \(text)")
        XCTAssertEqual(DecisionMeasures.decode(data), file)
        XCTAssertEqual(DecisionMeasures.decode(data)?.measures.first?.golden?.count, 3)
        XCTAssertEqual(DecisionMeasures.decode(data)?.testVerdicts, [verdict])
    }

    func testAnOldOrShortRecordReads() throws {
        let json = #"{"schema": "binders-decision-measures/2", "measures": [{"key": "mlx1-x tev1.1/256", "bands": {"start": null, "suggest": null, "generalBelow": 0.4}},"#
            + #" {"bands": {"start": 0.97}}, {"key": "mlx1-y tev1.1/256", "noStart": "aReasonFromALaterBuild", "at": "not a date", "extra": [1, 2]}]}"#
        let file = try XCTUnwrap(DecisionMeasures.decode(Data(json.utf8)))
        XCTAssertEqual(file.measures.map(\.key), ["mlx1-x tev1.1/256", "mlx1-y tev1.1/256"], "a record with no key is skipped, not the file")
        let short = file.measures[0]
        let bands = try XCTUnwrap(short.bands?.routerBands)
        XCTAssertEqual(bands.suggest, RouterBands.never, "suggest null names no agent")
        XCTAssertNil(bands.start)
        XCTAssertEqual(bands.generalBelow, 0.4)
        XCTAssertEqual(bands.generalBelowTitlesOnly, 0.4, "a form left out takes the other's")
        XCTAssertNil(file.measures[1].noStart, "a reason this build doesn't know is left out, not the record")
        XCTAssertNil(file.measures[1].at)
        XCTAssertEqual(file.testVerdicts, [])
        XCTAssertEqual(DecisionMeasures.decode(Data("[]".utf8)), nil)
        XCTAssertEqual(DecisionMeasures.decode(Data("{}".utf8)), DecisionMeasures())
        XCTAssertEqual(DecisionMeasure.Bands(RouterBands(start: nil, suggest: RouterBands.never, generalBelow: 0.45, generalBelowTitlesOnly: 0.33)).suggest, nil)
    }

    func testAutosFieldsRoundTripAndOldRecordsRead() throws {
        var record = Self.record
        record.bands?.auto = 0.6
        record.noAuto = nil
        record.auto = .init(dev: .init(picks: 23, right: 19, falseAssignments: 1, named: 4, namedRight: 4),
                            test: .init(picks: 31, right: 31, falseAssignments: 0, named: 6, namedRight: 6))
        let verdict = DecisionMeasure.TestVerdict(key: record.key, at: Self.at, level: nil, noStart: nil, autoLevel: 0.6, noAuto: nil)
        let file = DecisionMeasures(measures: [record], testVerdicts: [verdict])
        let data = try file.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""auto":0.6"#), text)
        XCTAssertTrue(text.contains(#""false":1"#), "as the design writes it: \(text)")
        XCTAssertTrue(text.contains(#""autoLevel":0.6"#), text)
        XCTAssertEqual(DecisionMeasures.decode(data), file)
        var none = Self.record
        none.noAuto = .testShare
        XCTAssertEqual(DecisionMeasures.decode(try DecisionMeasures(measures: [none]).encoded())?.measures.first?.noAuto, .testShare)
        // R2's records and verdicts, without them.
        let json = #"{"schema": "binders-decision-measures/2", "measures": [{"key": "mlx1-x tev1.1/256", "bands": {"start": 0.97, "suggest": 0.5,"#
            + #" "generalBelow": 0.45}, "noStart": null}], "testVerdicts": [{"key": "mlx1-x tev1.1/256", "level": 0.97, "noStart": "testWrong"}]}"#
        let old = try XCTUnwrap(DecisionMeasures.decode(Data(json.utf8)))
        XCTAssertNil(old.measures.first?.bands?.auto)
        XCTAssertNil(old.measures.first?.noAuto)
        XCTAssertNil(old.measures.first?.auto)
        XCTAssertEqual(old.measures.first?.measuredBeforeAuto, true)
        XCTAssertEqual(old.testVerdicts.first?.noStart, .testWrong)
        XCTAssertNil(old.testVerdicts.first?.autoLevel)
        XCTAssertEqual(old.testVerdicts.first?.tookStart, true)
        // A reason a later build added is left out, not the record.
        let later = #"{"measures": [{"key": "mlx1-y tev1.1/256", "noAuto": "aLaterReason", "auto": {"dev": {"picks": 3}}}]}"#
        let read = try XCTUnwrap(DecisionMeasures.decode(Data(later.utf8)))
        XCTAssertEqual(read.measures.map(\.key), ["mlx1-y tev1.1/256"])
        XCTAssertNil(read.measures.first?.noAuto)
    }

    func testOneMeasurePerModelAndTheFirstVerdictHolds() {
        var file = DecisionMeasures()
        let first = DecisionMeasure(key: "mlx1-a tev1.1/256", fingerprint: "mlx1-a", reader: "tev1.1/256", at: Self.at,
                                    bands: .init(start: nil, suggest: 0.5, generalBelow: 0.45, generalBelowTitlesOnly: 0.33), noStart: .testWrong)
        file.keep(first, verdict: .init(key: first.key, at: Self.at, level: 0.97, noStart: .testWrong))
        var again = first
        again.noStart = .testBefore
        again.at = Self.at.addingTimeInterval(60)
        file.keep(again, verdict: .init(key: first.key, at: again.at, level: 0.97, noStart: .testFew))
        XCTAssertEqual(file.measures, [again], "a new measure takes the old one's place")
        XCTAssertEqual(file.testVerdicts.map(\.noStart), [.testWrong], "the first verdict holds")
        let other = DecisionMeasure(key: "mlx1-a chat.1/256", fingerprint: "mlx1-a", reader: "chat.1/256", at: Self.at)
        file.keep(other)
        file.keep(DecisionMeasure(key: "mlx1-b tev1.1/256", fingerprint: "mlx1-b", reader: "tev1.1/256", at: Self.at))
        XCTAssertEqual(file.measures.count, 3)
        file.remove(fingerprint: "mlx1-a")
        XCTAssertEqual(file.measures.map(\.key), ["mlx1-b tev1.1/256"], "Delete takes a model's measures under every reader")
        XCTAssertEqual(file.testVerdicts, [], "and its verdicts")
    }

    func testAServersMeasureIsReplacedByItsMatch() {
        let server = DecisionIdentity.Server(address: "http://127.0.0.1:18708", names: ["kev-latest"], fields: [], answeredBy: [], probes: [[0.6342, 0.3658]])
        var wobble = server
        wobble.probes = [[0.6347, 0.3653]]
        let one = DecisionIdentity(server: server), two = DecisionIdentity(server: wobble)
        XCTAssertNotEqual(one.key, two.key)
        var file = DecisionMeasures()
        file.keep(DecisionMeasure(key: one.key, fingerprint: one.fingerprint, reader: one.reader, server: server, at: Self.at))
        file.keep(DecisionMeasure(key: two.key, fingerprint: two.fingerprint, reader: two.reader, server: wobble, at: Self.at))
        XCTAssertEqual(file.measures.map(\.key), [two.key], "one model, one measure")
        XCTAssertEqual(file.measure(for: one)?.key, two.key)
    }
}

final class LetterTokensTests: XCTestCase {
    static let tev1 = Array(32...55)

    func testTwentyFourBareSingleTokens() {
        XCTAssertEqual(try LetterTokens.check(encoded: Self.tev1.map { [$0] }, bare: Self.tev1).get(), Self.tev1)
        XCTAssertNil(LetterTokens.tev1Problem(Self.tev1))
        let other = Array(1000..<1024)
        XCTAssertEqual(try LetterTokens.check(encode: { [1000 + Int($0.unicodeScalars.first!.value) - 65] },
                                              bare: { 1000 + Int($0.unicodeScalars.first!.value) - 65 }).get(), other)
        XCTAssertEqual(LetterTokens.tev1Problem(other), "its letters A to X aren't one token each, 32 to 55", "the Tev1 family wants 32 to 55")
        XCTAssertEqual(LetterTokens.letters.count, 24)
        XCTAssertEqual(LetterTokens.letters.last, "X")
    }

    func testALetterOfTwoTokens() {
        var encoded = Self.tev1.map { [$0] }
        encoded[10] = [75, 76]
        XCTAssertEqual(LetterTokens.check(encoded: encoded, bare: Self.tev1), .failure(.notOneToken("K")))
        XCTAssertEqual(LetterTokens.Problem.notOneToken("K").words,
                       "in its tokenizer, “K” isn't a token of its own, and Binders reads the model's choice as one letter from A to X")
        encoded[10] = []
        XCTAssertEqual(LetterTokens.check(encoded: encoded, bare: Self.tev1), .failure(.notOneToken("K")))
    }

    func testALetterThatIsntTheBareLetter() {
        // A tokenizer that marks a lone letter as a word's start: "A" encodes to "▁A", not the vocabulary's "A".
        var encoded = Self.tev1.map { [$0] }
        encoded[0] = [9_001]
        XCTAssertEqual(LetterTokens.check(encoded: encoded, bare: Self.tev1), .failure(.notTheLetter("A")))
        var bare: [Int?] = Self.tev1
        bare[3] = nil
        XCTAssertEqual(LetterTokens.check(encoded: Self.tev1.map { [$0] }, bare: bare), .failure(.notTheLetter("D")), "no bare letter at all")
        XCTAssertTrue(LetterTokens.Problem.notTheLetter("A").words.hasPrefix("in its tokenizer, “A” on its own"))
    }

    func testTwoLettersOfOneToken() {
        var ids = Self.tev1
        ids[1] = ids[0]
        XCTAssertEqual(LetterTokens.check(encoded: ids.map { [$0] }, bare: ids), .failure(.same("A", "B")))
        // A tokenizer without letters at all reads each as its unknown token: one id for all.
        XCTAssertEqual(LetterTokens.check(encoded: Array(repeating: [0], count: 24), bare: Array(repeating: 0, count: 24)), .failure(.same("A", "B")))
    }
}

final class ChatFrameTests: XCTestCase {
    /// Tev1's family's template with thinking off.
    static func qwen(system: String, user: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    static func renderings(_ render: (String, String) -> String) -> [ChatFrame.Rendering] {
        ChatFrame.markers.map { ChatFrame.Rendering(text: render($0.system, $0.user), system: $0.system, user: $0.user) }
    }

    func testTwoRenderingsMakeAFrame() throws {
        let frame = try ChatFrame.frame(Self.renderings(Self.qwen)).get()
        XCTAssertEqual(frame, DecisionReaderTests.tev1Frame)
        XCTAssertFalse(frame.systemInUser)
        for question in RouterQuestions.warmUps {
            XCTAssertEqual(Array(frame.prompt(question).utf8), Array(Tev1Prompt.prompt(question).utf8), "Tev1's prompt is its family's frame")
        }
        XCTAssertEqual(ChatFrame.markers.count, 2)
        XCTAssertNotEqual(ChatFrame.markers[0].system.count, ChatFrame.markers[1].system.count, "markers of other lengths")
        XCTAssertNotEqual(ChatFrame.markers[0].user.count, ChatFrame.markers[1].user.count)
    }

    func testRenderingsThatDisagreeMakeNoFrame() {
        // Pieces that differ: a template that writes the question's length.
        XCTAssertEqual(ChatFrame.frame(Self.renderings { "<s>\($0)|\($1.count)|\($1)</s>" }), .failure(.changesWords))
        // A marker missing: a template that drops the system message.
        XCTAssertEqual(ChatFrame.frame(Self.renderings { _, user in "<user>\(user)</user><model>" }), .failure(.changesWords))
        // A marker twice: a template that repeats the question.
        XCTAssertEqual(ChatFrame.frame(Self.renderings { "\($0)\n\($1)\n\($1)" }), .failure(.changesWords))
        // The user before the system.
        XCTAssertEqual(ChatFrame.frame(Self.renderings { "<u>\($1)</u><s>\($0)</s>" }), .failure(.changesWords))
        // One rendering can't tell its pieces from the words.
        XCTAssertEqual(ChatFrame.frame(Array(Self.renderings(Self.qwen).prefix(1))), .failure(.changesWords))
    }

    func testTheTemplatesOwnRenderingMustBeTheFrames() {
        XCTAssertNil(ChatFrame.check(templateIDs: [[1, 2, 3], [4, 5]], frameIDs: [[1, 2, 3], [4, 5]]))
        XCTAssertEqual(ChatFrame.check(templateIDs: [[1, 2, 3], [4, 5]], frameIDs: [[1, 2, 3], [4, 6]]), .changesWords,
                       "a template that trims or escapes the question's words")
        XCTAssertEqual(ChatFrame.check(templateIDs: [[1, 2]], frameIDs: [[1, 2], [3]]), .changesWords)
        XCTAssertEqual(ChatFrame.check(templateIDs: [], frameIDs: []), .changesWords)
        XCTAssertEqual(ChatFrame.Problem.changesWords.words, "its chat template changes the question's words, so Binders can't be sure what the model reads")
    }

    func testTheSystemLineInTheUserMessage() throws {
        // A template that refuses a system message is rendered with one user message: the system marker, a blank line, the user marker.
        func gemma(_ content: String) -> String { "<bos><start_of_turn>user\n\(content)<end_of_turn>\n<start_of_turn>model\n" }
        let renderings = ChatFrame.markers.map { ChatFrame.Rendering(text: gemma($0.system + "\n\n" + $0.user), system: $0.system, user: $0.user) }
        let frame = try ChatFrame.frame(renderings, systemInUser: true).get()
        XCTAssertTrue(frame.systemInUser)
        XCTAssertEqual(frame, DecisionReaderTests.systemInUser)
        XCTAssertEqual(frame.text(system: "S", user: "U"), "<bos><start_of_turn>user\nS\n\nU<end_of_turn>\n<start_of_turn>model\n")
        // One that trims the blank line changes the words.
        let trimmed = ChatFrame.markers.map { ChatFrame.Rendering(text: gemma($0.system + "\n" + $0.user), system: $0.system, user: $0.user) }
        XCTAssertEqual(ChatFrame.frame(trimmed, systemInUser: true), .failure(.changesWords))
    }

    func testAPieceOver16KB() {
        let preamble = String(repeating: "You are a helpful assistant. ", count: 600)
        XCTAssertGreaterThan(preamble.utf8.count, ChatFrame.maxPiece)
        XCTAssertEqual(ChatFrame.frame(Self.renderings { preamble + Self.qwen(system: $0, user: $1) }), .failure(.tooLong))
        XCTAssertEqual(ChatFrame.Problem.tooLong.words, "its chat template wraps a question in more than 16 KB of its own words")
    }

    func testThinkingLeftOn() {
        XCTAssertFalse(ChatFrame.thinkingOpen("<|im_start|>assistant\n<think>\n\n</think>\n\n"), "turned off")
        XCTAssertTrue(ChatFrame.thinkingOpen("<|im_start|>assistant\n<think>\n"), "the model would think first")
        XCTAssertTrue(ChatFrame.thinkingOpen("</think> then <think>"))
        XCTAssertFalse(ChatFrame.thinkingOpen("<|im_start|>assistant\n"))
        XCTAssertFalse(ChatFrame.thinkingOpen(""))
        XCTAssertTrue(ChatFrame.thinkingOpen("<start_of_turn>model\n<reasoning>", open: "<reasoning>", close: "</reasoning>"), "the model's own markers")
        XCTAssertEqual(ChatFrame.Problem.thinks.words, "it thinks before it answers, and its chat template can't turn that off")
    }

    func testTheWords() {
        XCTAssertEqual(ChatFrame.Problem.noTemplate.words, "it has no chat template, so Binders can't put a question to it")
        XCTAssertEqual(ChatFrame.Problem.tookTooLong(seconds: 20).words, "filling in its chat template took more than 20 seconds")
        XCTAssertEqual(ChatFrame.Problem.tookTooLong(seconds: 0.5).words, "filling in its chat template took more than 0.5 seconds")
        XCTAssertEqual(ChatFrame.Problem.tookTooLong(seconds: 1).words, "filling in its chat template took more than 1 second")
    }

    func testAsTheHelperWritesIt() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = DecisionReaderTests.tev1Frame
        XCTAssertEqual(String(decoding: try encoder.encode(plain), as: UTF8.self),
                       #"{"afterUser":"<|im_end|>\n<|im_start|>assistant\n<think>\n\n<\/think>\n\n","beforeSystem":"<|im_start|>system\n","between":"<|im_end|>\n<|im_start|>user\n"}"#)
        let inUser = DecisionReaderTests.systemInUser
        let written = String(decoding: try encoder.encode(inUser), as: UTF8.self)
        XCTAssertTrue(written.contains(#""systemInUser":true"#) && written.contains(#""beforeUser":"<bos>"#) && !written.contains("between"), written)
        for frame in [plain, inUser] {
            XCTAssertEqual(try JSONDecoder().decode(ChatFrame.self, from: encoder.encode(frame)), frame)
        }
        // Compared by bytes: an NFC and an NFD é are other words to a model.
        XCTAssertNotEqual(ChatFrame(before: "\u{e9}", between: "", after: ""), ChatFrame(before: "e\u{301}", between: "", after: ""))
    }
}

final class MeasureSealsTests: XCTestCase {
    static let eightBit = DecisionBandsTests.eightBit

    /// A record as a measure on this Mac writes it: a date with a fraction of a second, numbers with long decimals.
    static var record: DecisionMeasure {
        var record = DecisionBandsTests.measure(eightBit, start: 0.97, golden: [[0.1 + 0.2, 1.0 / 3, 2.0 / 3]])
        record.at = Date(timeIntervalSince1970: 1_792_425_731.618)
        record.bands?.auto = 0.7
        return record
    }

    /// The file as it is on disk, read back.
    static func read(_ file: DecisionMeasures) throws -> DecisionMeasures {
        try XCTUnwrap(DecisionMeasures.decode(try file.encoded()))
    }

    func testARecordReadBackHasTheSealItWasWrittenWith() throws {
        let record = Self.record
        let read = try XCTUnwrap(Self.read(DecisionMeasures(measures: [record])).measures.first)
        XCTAssertNotEqual(read.at, record.at, "the file keeps the date to the second")
        XCTAssertEqual(MeasureSeals.seal(read), MeasureSeals.seal(record))
        XCTAssertEqual(MeasureSeals.seal(record).count, 64)
        var other = record
        other.bands?.auto = 0.0
        XCTAssertNotEqual(MeasureSeals.seal(other), MeasureSeals.seal(record))
        XCTAssertEqual(MeasureSeals.seal(verdicts: []).count, 64, "an empty list has a seal too")
    }

    func testARecordWhoseSealDiffersReadsAsUnmeasured() throws {
        let record = Self.record
        let seal = MeasureSeals.seal(record)
        var edited = record
        edited.bands?.auto = 0.0
        edited.bands?.start = 0.5
        let file = try Self.read(DecisionMeasures(measures: [edited]))
        let checked = MeasureSeals.check(file, kept: { $0 == record.key ? seal : nil }, keptVerdicts: MeasureSeals.seal(verdicts: []), firstRead: false)
        XCTAssertEqual(checked.measures.measures, [])
        XCTAssertEqual(checked.measures.changed.map(\.key), [record.key])
        XCTAssertEqual(checked.adopted, [:])
        let resolved = DecisionBands.resolve(Self.eightBit, measures: checked.measures)
        XCTAssertEqual(resolved.source, .unmeasured)
        XCTAssertTrue(resolved.changed)
        XCTAssertEqual(resolved.bands, DecisionBands.unmeasured, "no start level, no Auto level")
        XCTAssertNil(resolved.golden)
        XCTAssertEqual(resolved.whyNoAuto, .changed)
        // The same record as written reads as measured.
        let kept = MeasureSeals.check(try Self.read(DecisionMeasures(measures: [record])), kept: { _ in seal }, keptVerdicts: nil, firstRead: false)
        XCTAssertEqual(kept.measures.changed, [])
        let measured = DecisionBands.resolve(Self.eightBit, measures: kept.measures)
        XCTAssertFalse(measured.changed)
        XCTAssertEqual(measured.bands.auto, 0.7)
        XCTAssertEqual(measured.bands.start, 0.97)
    }

    func testTev1sOwnKeyChangedGetsNothingBuiltIn() throws {
        let tev1 = DecisionBands.tev1BF16
        var forged = DecisionMeasure(key: tev1.key, fingerprint: tev1.fingerprint, reader: tev1.reader, at: DecisionBandsTests.at,
                                     golden: DecisionBands.tev1?.golden, bands: .init(start: 0.5, suggest: 0.5, generalBelow: 0.45, generalBelowTitlesOnly: 0.33, auto: 0.0))
        forged.noAuto = nil
        let checked = MeasureSeals.check(try Self.read(DecisionMeasures(measures: [forged])), kept: { _ in nil }, keptVerdicts: nil, firstRead: false)
        let resolved = DecisionBands.resolve(tev1, measures: checked.measures)
        XCTAssertTrue(resolved.changed)
        XCTAssertNil(resolved.bands.start)
        XCTAssertNil(resolved.bands.auto)
        XCTAssertEqual(resolved.source, .unmeasured)
    }

    func testTheFirstReadAdoptsWhatHasNoSeal() throws {
        let record = Self.record
        let verdict = DecisionMeasure.TestVerdict(key: record.key, at: DecisionBandsTests.at, level: 0.97, noStart: .testWrong)
        let file = try Self.read(DecisionMeasures(measures: [record], testVerdicts: [verdict]))
        let first = MeasureSeals.check(file, kept: { _ in nil }, keptVerdicts: nil, firstRead: true)
        XCTAssertEqual(first.measures.measures.map(\.key), [record.key])
        XCTAssertEqual(first.adopted, [record.key: MeasureSeals.seal(record)])
        XCTAssertEqual(first.adoptedVerdicts, MeasureSeals.seal(verdicts: [verdict]))
        XCTAssertEqual(first.measures.testVerdicts, file.testVerdicts)
        // After that, a record with no seal was added outside Binders.
        let later = MeasureSeals.check(file, kept: { _ in nil }, keptVerdicts: first.adoptedVerdicts, firstRead: false)
        XCTAssertEqual(later.measures.changed.map(\.key), [record.key])
        XCTAssertEqual(later.adopted, [:])
        // A seal that differs is changed even on the first read.
        let differs = MeasureSeals.check(file, kept: { _ in String(repeating: "0", count: 64) }, keptVerdicts: nil, firstRead: true)
        XCTAssertEqual(differs.measures.changed.map(\.key), [record.key])
    }

    func testAChangedVerdictsListTakesEverythingAway() throws {
        let record = Self.record
        let verdict = DecisionMeasure.TestVerdict(key: record.key, at: DecisionBandsTests.at, level: nil, noStart: nil, autoLevel: 0.8)
        let sealed = MeasureSeals.seal(verdicts: [verdict])
        var raised = verdict
        raised.autoLevel = nil
        let file = try Self.read(DecisionMeasures(measures: [record], testVerdicts: [raised]))
        let checked = MeasureSeals.check(file, kept: { _ in MeasureSeals.seal(record) }, keptVerdicts: sealed, firstRead: false)
        XCTAssertTrue(checked.measures.verdictsChanged)
        XCTAssertEqual(checked.measures.testVerdicts.map(\.noStart), [.testBefore])
        XCTAssertEqual(checked.measures.testVerdicts.map(\.noAuto), [.testBefore])
        let resolved = DecisionBands.resolve(Self.eightBit, measures: checked.measures)
        XCTAssertNil(resolved.bands.start)
        XCTAssertNil(resolved.bands.auto)
        // An empty list with no seal has nothing to take away; a list with no seal after the first read does.
        XCTAssertFalse(MeasureSeals.check(DecisionMeasures(), kept: { _ in nil }, keptVerdicts: nil, firstRead: false).measures.verdictsChanged)
        XCTAssertTrue(MeasureSeals.check(file, kept: { _ in nil }, keptVerdicts: nil, firstRead: false).measures.verdictsChanged)
    }

    func testChangedRecordsStayInTheFileUntilAMeasureReplacesThem() throws {
        let record = Self.record
        var other = DecisionBandsTests.measure(DecisionBands.tev1BF16, start: 0.97)
        other.at = DecisionBandsTests.at
        let file = try Self.read(DecisionMeasures(measures: [record, other]))
        var checked = MeasureSeals.check(file, kept: { $0 == other.key ? MeasureSeals.seal(other) : nil }, keptVerdicts: nil, firstRead: false).measures
        XCTAssertEqual(checked.measures.map(\.key), [other.key])
        XCTAssertEqual(MeasureSeals.file(checked).measures.map(\.key), [other.key, record.key], "written back as it was, never sealed")
        XCTAssertEqual(checked.changedMeasure(for: Self.eightBit)?.key, record.key)
        checked.keep(Self.record)
        XCTAssertEqual(checked.changed, [], "a measure of that model takes its place")
        XCTAssertFalse(DecisionBands.resolve(Self.eightBit, measures: checked).changed)
        checked.changed = [record]
        checked.remove(fingerprint: Self.eightBit.fingerprint)
        XCTAssertEqual(checked.changed, [], "and Delete takes it away")
    }
}
