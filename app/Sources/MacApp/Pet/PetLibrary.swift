import Foundation

/// 利用できるペットを集める。アプリに同梱したものと、ユーザーが Codex Desktop で作ったものを合わせて扱う。
enum PetLibrary {
    /// 選択が保存されていないときに使うペットの id。
    static let defaultPetID = "mauve"

    /// 同梱ペットを先に、ユーザーのカスタムペットを後に並べた一覧。id が重複する場合は同梱側を優先する。
    static func availablePets() -> [PetDefinition] {
        var pets: [PetDefinition] = []
        var seenIDs: Set<String> = []
        for pet in bundledPets() + userPets() where seenIDs.insert(pet.id).inserted {
            pets.append(pet)
        }
        return pets
    }

    /// 一覧から id でペットを引く。見つからなければデフォルト、それも無ければ先頭を返す。
    static func pet(id: String?, in pets: [PetDefinition]) -> PetDefinition? {
        if let id, let matched = pets.first(where: { $0.id == id }) {
            return matched
        }
        return pets.first(where: { $0.id == defaultPetID }) ?? pets.first
    }

    /// アプリに同梱したペット(`Resources/pets/`)。
    private static func bundledPets() -> [PetDefinition] {
        guard let root = Bundle.module.url(forResource: "pets", withExtension: nil) else { return [] }
        return loadPets(inRoot: root)
    }

    /// Codex Desktop がユーザーの `${CODEX_HOME:-~/.codex}/pets/` に置くカスタムペット。
    private static func userPets() -> [PetDefinition] {
        loadPets(inRoot: codexHome().appendingPathComponent("pets"))
    }

    /// Codex のホームディレクトリ。`CODEX_HOME` があればそれを優先する。
    private static func codexHome() -> URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// `<root>/<id>/pet.json` を順に読む。ディレクトリが無い場合や壊れた `pet.json` は読み飛ばす。
    private static func loadPets(inRoot root: URL) -> [PetDefinition] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        return
            entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { loadPet(inDirectory: $0) }
    }

    /// 1 ディレクトリ分の `pet.json` を読む。読めなければ nil を返す。
    private static func loadPet(inDirectory directory: URL) -> PetDefinition? {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONDecoder().decode(PetManifest.self, from: data),
            !manifest.id.isEmpty,
            !manifest.spritesheetPath.isEmpty
        else {
            return nil
        }
        return PetDefinition(
            manifest: manifest,
            directoryURL: directory,
            speechURL: speechURL(inDirectory: directory)
        )
    }

    /// セリフを差し替える `speech.json` を探す。置かれていなければ nil を返す。
    private static func speechURL(inDirectory directory: URL) -> URL? {
        let url = directory.appendingPathComponent("speech.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
