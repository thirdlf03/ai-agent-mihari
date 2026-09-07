import XCTest

@testable import MihariCore

/// 文書（Markdown / PDF）成果物の型（#20）と公開設定フック（#19 準備）の検証。
final class RoomDocumentModelsTests: XCTestCase {
    private let json = """
        {
          "id": "art-job1-v2",
          "job_id": "job1",
          "session_id": "sess-1",
          "version": 2,
          "kind": "web",
          "preview_url": "https://preview.example.test/previews/token1/",
          "expires_at": null,
          "sha256": "abc",
          "source_ids": [],
          "documents": [
            {
              "name": "報告書.md",
              "kind": "markdown",
              "preview_url": "https://preview.example.test/previews/token1/報告書.md.html",
              "download_url": "https://preview.example.test/previews/token1/報告書.md"
            },
            {
              "name": "report.pdf",
              "kind": "pdf",
              "preview_url": "https://preview.example.test/previews/token1/report.pdf",
              "download_url": "https://preview.example.test/previews/token1/report.pdf"
            }
          ]
        }
        """

    func testDecodesDocumentsWithPreviewAndDownload() throws {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let artifact = try JSONDecoder().decode(RoomArtifact.self, from: data)

        XCTAssertEqual(artifact.documents.count, 2)
        let md = artifact.documents[0]
        XCTAssertEqual(md.name, "報告書.md")
        XCTAssertEqual(md.kind, "markdown")
        XCTAssertEqual(md.kindLabel, "Markdown")
        XCTAssertEqual(md.previewURL?.pathComponents.last, "報告書.md.html")
        XCTAssertEqual(md.downloadURL?.pathComponents.last, "報告書.md")

        let pdf = artifact.documents[1]
        XCTAssertEqual(pdf.kind, "pdf")
        XCTAssertEqual(pdf.kindLabel, "PDF")
        XCTAssertEqual(pdf.previewURL, pdf.downloadURL)
        // id は name+URL から一意になる（同じ URL の開く/ダウンロードが区別される）。
        XCTAssertNotEqual(md.id, pdf.id)
    }

    func testOldPayloadWithoutDocumentsDefaultsToEmpty() throws {
        let old = """
            {
              "id": "art-job1-v1",
              "job_id": "job1",
              "version": 1,
              "kind": "web",
              "preview_url": "https://preview.example.test/previews/token1/",
              "source_ids": []
            }
            """
        let data = try XCTUnwrap(old.data(using: .utf8))
        let artifact = try JSONDecoder().decode(RoomArtifact.self, from: data)
        XCTAssertTrue(artifact.documents.isEmpty)
        XCTAssertEqual(artifact.version, "1")
    }

    func testBrokenDocumentFieldsAreTolerated() throws {
        let broken = """
            {
              "id": "art-job1-v3",
              "documents": [
                {"name": "x.md", "preview_url": ""},
                {"kind": "pdf"},
                {"name": "y.pdf", "kind": "pdf", "preview_url": "https://example.com/y.pdf"}
              ]
            }
            """
        let data = try XCTUnwrap(broken.data(using: .utf8))
        let artifact = try JSONDecoder().decode(RoomArtifact.self, from: data)
        XCTAssertEqual(artifact.documents.count, 3)
        XCTAssertNil(artifact.documents[0].previewURL)
        XCTAssertEqual(artifact.documents[1].kindLabel, "PDF")
        XCTAssertEqual(artifact.documents[2].previewURL?.absoluteString, "https://example.com/y.pdf")
    }

    func testKindLabelFallbacks() {
        XCTAssertEqual(RoomArtifactDocument(name: "a.md", kind: "markdown").kindLabel, "Markdown")
        XCTAssertEqual(RoomArtifactDocument(name: "a.pdf", kind: "pdf").kindLabel, "PDF")
        XCTAssertEqual(RoomArtifactDocument(name: "a.html", kind: "html").kindLabel, "HTML")
        XCTAssertEqual(RoomArtifactDocument(name: "a.xyz", kind: "docx").kindLabel, "docx")
        XCTAssertEqual(RoomArtifactDocument(name: "a", kind: "").kindLabel, "文書")
    }

    func testPublicationHookValue() {
        let publication = RoomArtifactPublication(
            artifactID: "art-job1-v2",
            documentName: "report.md",
            isPublic: false
        )
        XCTAssertEqual(publication.artifactID, "art-job1-v2")
        XCTAssertEqual(publication.documentName, "report.md")
        XCTAssertFalse(publication.isPublic)
        XCTAssertEqual(
            RoomArtifactPublication(artifactID: "art-job1-v2"),
            RoomArtifactPublication(artifactID: "art-job1-v2")
        )
        XCTAssertNotEqual(
            RoomArtifactPublication(artifactID: "a", documentName: "x.md"),
            RoomArtifactPublication(artifactID: "a", documentName: "y.md")
        )
    }
}
