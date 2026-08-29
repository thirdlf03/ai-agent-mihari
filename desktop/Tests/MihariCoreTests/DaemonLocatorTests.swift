import Testing

@testable import MihariCore

@Suite("uv と bridge/ の場所の解決")
struct DaemonLocatorTests {

    @Test("UV_PATH があればそれを使う")
    func honorsUVPath() throws {
        let locator = DaemonLocator(
            environment: ["UV_PATH": "/custom/uv"],
            isExecutable: { $0 == "/custom/uv" },
            directoryExists: { _ in true }
        )
        #expect(try locator.uvPath(home: "/Users/x") == "/custom/uv")
    }

    @Test("UV_PATH が実行できなければ、他を探さずに失敗する")
    func brokenUVPathFails() {
        // 指定されたのに動かない場合、黙って別の uv を使うと原因が分からなくなる。
        let locator = DaemonLocator(
            environment: ["UV_PATH": "/custom/uv"],
            isExecutable: { $0 == "/opt/homebrew/bin/uv" },
            directoryExists: { _ in true }
        )
        #expect(throws: DaemonError.uvNotFound) { try locator.uvPath(home: "/Users/x") }
    }

    @Test("UV_PATH がなければ既定の候補を順に探す")
    func fallsBackToCandidates() throws {
        let locator = DaemonLocator(
            environment: [:],
            isExecutable: { $0 == "/opt/homebrew/bin/uv" },
            directoryExists: { _ in true }
        )
        #expect(try locator.uvPath(home: "/Users/x") == "/opt/homebrew/bin/uv")
    }

    @Test("候補の探索順はホーム配下 → homebrew → /usr/local")
    func candidateOrder() {
        #expect(
            DaemonLocator.uvCandidates(home: "/Users/x") == [
                "/Users/x/.local/bin/uv",
                "/opt/homebrew/bin/uv",
                "/usr/local/bin/uv",
            ]
        )
    }

    @Test("どこにも uv がなければ失敗する")
    func missingUVFails() {
        let locator = DaemonLocator(environment: [:], isExecutable: { _ in false }, directoryExists: { _ in true })
        #expect(throws: DaemonError.uvNotFound) { try locator.uvPath(home: "/Users/x") }
    }

    @Test("DEVICE_BRIDGE_DIR があればそれを使う")
    func honorsBridgeDir() throws {
        let locator = DaemonLocator(
            environment: ["DEVICE_BRIDGE_DIR": "/somewhere/bridge"],
            isExecutable: { _ in true },
            directoryExists: { $0 == "/somewhere/bridge" }
        )
        #expect(try locator.bridgeDirectory(defaultPath: "/default/bridge") == "/somewhere/bridge")
    }

    @Test("bridge/ が存在しなければ、探したパスを添えて失敗する")
    func missingBridgeDirFails() {
        let locator = DaemonLocator(environment: [:], isExecutable: { _ in true }, directoryExists: { _ in false })
        #expect(throws: DaemonError.bridgeDirectoryNotFound(path: "/default/bridge")) {
            try locator.bridgeDirectory(defaultPath: "/default/bridge")
        }
    }

    @Test("リポジトリから逆算した既定のパスは bridge で終わる")
    func repositoryPathEndsWithBridge() {
        #expect(DaemonLocator.repositoryBridgePath.hasSuffix("/bridge"))
    }
}
