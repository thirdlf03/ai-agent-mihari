import AppKit
import Foundation
import Testing
import os

@testable import MihariCore

/// ファイル系 op（find_files / fetch_file / hand_off_file）の線上の形と
/// 許可フォルダの守りを確かめる。room 側は `room/tests/test_mac_file_ops.py`。
@Suite("Mac control のファイル操作")
struct MacControlFileOpsTests {

    private func parse(_ json: String) throws -> MacControlOpFrame {
        let parsed = try MacControlIncomingFrame.parse(data: Data(json.utf8))
        guard case .op(let op) = parsed?.frame else {
            Issue.record("op フレームのはず: \(String(describing: parsed))")
            throw NSError(domain: "test", code: 1)
        }
        return op
    }

    private func makeOp(kind: MacControlWire.OpKind, params: [String: MacJSONValue] = [:]) -> MacControlOpFrame {
        MacControlOpFrame(
            opID: "op-1",
            runID: "run-1",
            jobID: "job-1",
            kind: kind,
            params: params,
            expected: nil,
            sentAt: ""
        )
    }

    /// 書き込み・掃除つきの一時フォルダ。
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihari-mac-file-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeOperator(
        allowedRoots: [URL],
        handoffPresenter: (any MacFileHandoffPresenting)? = nil,
        handoffStage: MacHandoffStage? = nil
    ) -> CGEventMacControlOperator {
        CGEventMacControlOperator(
            filePolicy: MacFileAccessPolicy(allowedRoots: allowedRoots),
            handoffPresenter: handoffPresenter,
            handoffStage: handoffStage
                ?? MacHandoffStage(
                    stageRoot: FileManager.default.temporaryDirectory
                        .appendingPathComponent("mihari-handoffs-\(UUID().uuidString)"),
                    window: 0.02,
                    openFolder: { _ in }
                ),
            accessibilityIsTrusted: { true },
            screenRecordingIsGranted: { true }
        )
    }

    // MARK: - 線上の形

    @Test("find_files の op が読める")
    func parseFindFiles() throws {
        let op = try parse(
            #"{"type":"op","op_id":"o1","run_id":"r1","job_id":"j1","kind":"find_files","#
                + #""params":{"query":"請求書","scope":"content","limit":5,"dirs":["/tmp","~/Docs"]}}"#
        )
        #expect(op.kind == .findFiles)
        #expect(op.query == "請求書")
        #expect(op.searchScope == "content")
        #expect(op.searchLimit == 5)
        #expect(op.searchDirs == ["/tmp", "~/Docs"])
    }

    @Test("fetch_file / hand_off_file の op が読める")
    func parseFetchAndHandOff() throws {
        let fetch = try parse(
            #"{"type":"op","op_id":"o2","run_id":"r1","job_id":"j1","kind":"fetch_file","#
                + #""params":{"path":"/tmp/a.txt","max_bytes":1024}}"#
        )
        #expect(fetch.kind == .fetchFile)
        #expect(fetch.filePath == "/tmp/a.txt")
        #expect(fetch.maxBytes == 1024)

        let handoff = try parse(
            #"{"type":"op","op_id":"o3","run_id":"r1","job_id":"j1","kind":"hand_off_file","#
                + #""params":{"path":"/tmp/a.txt","label":"このファイルだよ"}}"#
        )
        #expect(handoff.kind == .handOffFile)
        #expect(handoff.filePath == "/tmp/a.txt")
        #expect(handoff.handOffLabel == "このファイルだよ")
    }

    @Test("知らない kind は unsupported になり、click には倒れない")
    func unknownKindBecomesUnsupported() async throws {
        let op = try parse(
            #"{"type":"op","op_id":"o9","run_id":"r1","job_id":"j1","kind":"run_shell","params":{}}"#
        )
        #expect(op.kind == .unsupported)
        #expect(op.rawKind == "run_shell")

        // 実行しても失敗で返る（クリック等は絶対に走らない）。
        let result = try await makeOperator(allowedRoots: []).execute(op: op)
        guard case .failure(let code, _) = result else {
            Issue.record("失敗のはず: \(result)")
            return
        }
        #expect(code == "unsupported_op")

        // op.result は届いた kind の文字列をそのまま返す。
        let text = try MacControlOutgoing.opResult(op: op, result: result)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "run_shell")
        #expect(object["ok"] as? Bool == false)
    }

    // MARK: - 許可フォルダの守り

    @Test("ポリシーは許可ルートの内側だけを通し、.. や外のパスをはじく")
    func policyContainment() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("note.txt")
        try "hello".write(to: inside, atomically: true, encoding: .utf8)

        let policy = MacFileAccessPolicy(allowedRoots: [root])
        #expect(policy.allows(inside))
        #expect(policy.allows(root))
        // ルート自身の兄弟は通さない。
        #expect(!policy.allows(root.deletingLastPathComponent().appendingPathComponent("other.txt")))
        // `..` で抜ける指定も正規化のあと外になる。
        #expect(!policy.allows(root.appendingPathComponent("../outside.txt")))
        // 存在しないパスでも内側なら通す（検索先の絞り込みに使うため）。
        #expect(policy.allows(root.appendingPathComponent("sub/dir")))

        // dirs で外を指定しても内側だけ残る。全部外ならエラー。
        let resolved = try policy.resolveSearchDirs(param: [inside.path, "/definitely/outside"])
        #expect(resolved == [MacFileAccessPolicy.normalize(inside)])
        #expect(throws: MacFileSearchError.self) {
            _ = try policy.resolveSearchDirs(param: ["/definitely/outside"])
        }
    }

    @Test("MIHARI_MAC_SEARCH_DIRS は : 区切りで許可ルートを上書きする")
    func policyEnvironmentRoots() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = MacFileAccessPolicy(
            environment: [MacFileAccessPolicy.searchDirsEnvironmentKey: "\(root.path):/nope"]
        )
        #expect(policy.allows(root.appendingPathComponent("a.txt")))
        #expect(!policy.allows(URL(fileURLWithPath: "/usr/bin/ls")))
        // 未指定なら Desktop / Documents / Downloads の 3 つ。
        let defaults = MacFileAccessPolicy(environment: [:], home: URL(fileURLWithPath: "/home/u"))
        #expect(defaults.allowedRoots.count == 3)
        #expect(defaults.allows(URL(fileURLWithPath: "/home/u/Desktop/a.txt")))
        #expect(!defaults.allows(URL(fileURLWithPath: "/home/u/Elsewhere/a.txt")))
    }

    // MARK: - 実行

    @Test("find_files は許可フォルダ内で名前が合うファイルだけ返す")
    func findFilesByName() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try "a".write(to: root.appendingPathComponent("見積もり.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: root.appendingPathComponent("memo.md"), atomically: true, encoding: .utf8)

        let op = makeOp(
            kind: .findFiles,
            params: ["query": .string("見積"), "limit": .number(10)]
        )
        let result = try await makeOperator(allowedRoots: [root]).execute(op: op)
        guard case .success(let value) = result else {
            Issue.record("成功のはず: \(result)")
            return
        }
        guard case .array(let files) = value["files"] else {
            Issue.record("files は配列のはず: \(value)")
            return
        }
        #expect(files.count == 1)
        guard case .object(let first) = files.first else {
            Issue.record("files[0] は辞書のはず")
            return
        }
        #expect(first["name"]?.string() == "見積もり.txt")
        #expect(first["path"]?.string()?.hasSuffix("見積もり.txt") == true)
    }

    @Test("fetch_file は本文を base64 で返し、max_bytes 超は truncated になる")
    func fetchFileReadsAndTruncates() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("data.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)

        let op = makeOp(
            kind: .fetchFile,
            params: ["path": .string(file.path), "max_bytes": .number(5)]
        )
        let result = try await makeOperator(allowedRoots: [root]).execute(op: op)
        guard case .success(let value) = result else {
            Issue.record("成功のはず: \(result)")
            return
        }
        #expect(value["name"]?.string() == "data.txt")
        #expect(value["size"]?.int() == 11)
        #expect(value["truncated"]?.boolValue() == true)
        let base64 = try #require(value["data_base64"]?.string())
        #expect(Data(base64Encoded: base64) == Data("hello".utf8))
    }

    @Test("fetch_file は許可フォルダの外を拒む")
    func fetchFileRejectsOutside() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let op = makeOp(kind: .fetchFile, params: ["path": .string(outside.path)])
        let result = try await makeOperator(allowedRoots: [root]).execute(op: op)
        guard case .failure(let code, _) = result else {
            Issue.record("失敗のはず: \(result)")
            return
        }
        #expect(code == "path_not_allowed")
    }

    @Test("hand_off_file はフォルダを開き、出し手が無ければ presented=false で返す")
    func handOffWithoutPresenter() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("渡す.txt")
        try "中身".write(to: file, atomically: true, encoding: .utf8)

        let stageRoot = root.appendingPathComponent("handoffs")
        let opened = OpenedFolders()
        let stage = MacHandoffStage(
            stageRoot: stageRoot,
            window: 0.02,
            openFolder: { opened.record($0) }
        )
        let op = makeOp(
            kind: .handOffFile,
            params: ["path": .string(file.path), "label": .string("これだよ")]
        )
        let result = try await makeOperator(
            allowedRoots: [root],
            handoffStage: stage
        ).execute(op: op)
        guard case .success(let value) = result else {
            Issue.record("成功のはず: \(result)")
            return
        }
        #expect(value["revealed"]?.boolValue() == true)
        #expect(value["presented"]?.boolValue() == false)
        // 原本の場所ではなく、依頼（job）ごとのフォルダが1回だけ開く。
        let dir = try #require(opened.urls.first)
        #expect(dir.path == stageRoot.appendingPathComponent("job-1").path)
        #expect(opened.urls.count == 1)
        // フォルダの中身は原本へのシンボリックリンク。
        let link = dir.appendingPathComponent("渡す.txt")
        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(dest == MacFileAccessPolicy.normalize(file).path)
    }

    @Test("hand_off_file は出し手がいれば presented=true と label を渡す")
    func handOffWithPresenter() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("渡す.txt")
        try "中身".write(to: file, atomically: true, encoding: .utf8)

        let presenter = RecordingHandoffPresenter()
        let op = makeOp(
            kind: .handOffFile,
            params: ["path": .string(file.path), "label": .string("請求書です")]
        )
        let result = try await makeOperator(
            allowedRoots: [root],
            handoffPresenter: presenter
        ).execute(op: op)
        guard case .success(let value) = result else {
            Issue.record("成功のはず: \(result)")
            return
        }
        #expect(value["revealed"]?.boolValue() == true)
        #expect(value["presented"]?.boolValue() == true)
        #expect(presenter.calls.count == 1)
        #expect(presenter.calls.first?.label == "請求書です")
    }

    @Test("連続した hand_off_file は1フォルダにまとまり、演出は1回だけ出る")
    func handOffBatchesIntoOneFolder() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.txt")
        let second = root.appendingPathComponent("b.txt")
        try "a".write(to: first, atomically: true, encoding: .utf8)
        try "b".write(to: second, atomically: true, encoding: .utf8)

        let stageRoot = root.appendingPathComponent("handoffs")
        let opened = OpenedFolders()
        let stage = MacHandoffStage(
            stageRoot: stageRoot,
            window: 0.1,
            openFolder: { opened.record($0) }
        )
        let presenter = RecordingHandoffPresenter()
        let sut = makeOperator(
            allowedRoots: [root],
            handoffPresenter: presenter,
            handoffStage: stage
        )
        async let firstResult = sut.execute(
            op: makeOp(kind: .handOffFile, params: ["path": .string(first.path)])
        )
        async let secondResult = sut.execute(
            op: makeOp(kind: .handOffFile, params: ["path": .string(second.path)])
        )
        let results = [try await firstResult, try await secondResult]
        for result in results {
            guard case .success(let value) = result else {
                Issue.record("成功のはず: \(result)")
                return
            }
            #expect(value["revealed"]?.boolValue() == true)
            #expect(value["presented"]?.boolValue() == true)
        }
        // 開かれたフォルダもカットインも1回だけ。フォルダ名は jobID。
        #expect(opened.urls.count == 1)
        #expect(opened.urls[0].lastPathComponent == "job-1")
        #expect(presenter.calls.count == 1)
        #expect(presenter.calls.first?.label == "2件のファイル")
        // 2 ファイルぶんのリンクが同じフォルダに入る。
        let contents = try FileManager.default.contentsOfDirectory(atPath: opened.urls[0].path)
        #expect(contents.sorted() == ["a.txt", "b.txt"])
    }

    @Test("同じ job の後発ファイルは同じフォルダへ追加され、別の job は別フォルダになる")
    func handOffReusesFolderPerJob() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        let c = root.appendingPathComponent("c.txt")
        for url in [a, b, c] {
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }

        let stageRoot = root.appendingPathComponent("handoffs")
        let opened = OpenedFolders()
        let stage = MacHandoffStage(
            stageRoot: stageRoot,
            window: 0.02,
            openFolder: { opened.record($0) }
        )
        let sut = makeOperator(allowedRoots: [root], handoffStage: stage)

        // job-1 の2件は窓を跨いでも同じフォルダへ。
        _ = try await sut.execute(
            op: makeOp(kind: .handOffFile, params: ["path": .string(a.path)])
        )
        _ = try await sut.execute(
            op: makeOp(kind: .handOffFile, params: ["path": .string(b.path)])
        )
        // 別 job（job-2）は別フォルダ。
        var other = makeOp(kind: .handOffFile, params: ["path": .string(c.path)])
        other = MacControlOpFrame(
            opID: other.opID,
            runID: other.runID,
            jobID: "job-2",
            kind: other.kind,
            params: other.params,
            expected: other.expected,
            sentAt: other.sentAt
        )
        _ = try await sut.execute(op: other)

        #expect(opened.urls.count == 3)
        #expect(opened.urls[0].path == stageRoot.appendingPathComponent("job-1").path)
        #expect(opened.urls[1].path == stageRoot.appendingPathComponent("job-1").path)
        #expect(opened.urls[2].path == stageRoot.appendingPathComponent("job-2").path)
        let job1 = try FileManager.default.contentsOfDirectory(
            atPath: stageRoot.appendingPathComponent("job-1").path
        )
        #expect(job1.sorted() == ["a.txt", "b.txt"])
        let job2 = try FileManager.default.contentsOfDirectory(
            atPath: stageRoot.appendingPathComponent("job-2").path
        )
        #expect(job2 == ["c.txt"])
    }

    @Test("hand_off_file も許可フォルダの外は拒む")
    func handOffRejectsOutside() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let op = makeOp(kind: .handOffFile, params: ["path": .string(outside.path)])
        let result = try await makeOperator(allowedRoots: [root]).execute(op: op)
        guard case .failure(let code, _) = result else {
            Issue.record("失敗のはず: \(result)")
            return
        }
        #expect(code == "path_not_allowed")
    }

    // MARK: - 手渡しの出し手

    @Test("手渡しの出し手はカットインへファイルチップを渡す")
    @MainActor
    func petHandoffPresenterPresentsChip() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("渡す.txt")
        try "中身".write(to: file, atomically: true, encoding: .utf8)

        let suiteName = "mihari-handoff-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let controller = PetController(defaults: defaults)
        let cutIn = RecordingCutIn()
        // 自動退場はテストでは待たないよう長く取る。
        let presenter = PetFileHandoffPresenter(cutIn: cutIn, pet: controller, holdSeconds: 300)

        let presented = await presenter.presentFile(at: file, label: "伝票です")
        #expect(presented)
        #expect(cutIn.files.count == 1)
        // label があればファイル名の代わりに帯へ出す。
        #expect(cutIn.files.first?.chip.name == "伝票です")
        #expect(cutIn.files.first?.pet.id == controller.currentPet?.id)
        // 演出を出すためにペットは表へ出る。
        #expect(controller.isAwake)
    }
}

/// `AttendanceCutInPresenting` の記録用スタブ。
@MainActor
private final class RecordingCutIn: AttendanceCutInPresenting {
    struct FileCall {
        let chip: AttendanceFileChip
        let pet: PetDefinition
    }

    private(set) var files: [FileCall] = []

    func present(_ image: AttendanceCutInImage, of pet: PetDefinition, on screen: NSScreen?) {}

    func presentFile(_ chip: AttendanceFileChip, of pet: PetDefinition, on screen: NSScreen?) {
        files.append(FileCall(chip: chip, pet: pet))
    }

    func swap(to image: AttendanceCutInImage, flash: Bool) {}

    func dismiss() {}
}

/// バッチフォルダとして開かれた URL の記録用。@Sendable クロージャから書き込めるようクラスにする。
private final class OpenedFolders: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [URL]())

    var urls: [URL] {
        state.withLock { $0 }
    }

    func record(_ url: URL) {
        state.withLock { $0.append(url) }
    }
}

/// `hand_off_file` の出し手の記録用スタブ。
private final class RecordingHandoffPresenter: MacFileHandoffPresenting {
    struct Call {
        let url: URL
        let label: String?
    }

    private let state = OSAllocatedUnfairLock(initialState: [Call]())

    var calls: [Call] {
        state.withLock { $0 }
    }

    func presentFile(at url: URL, label: String?) async -> Bool {
        state.withLock { $0.append(Call(url: url, label: label)) }
        return true
    }
}
