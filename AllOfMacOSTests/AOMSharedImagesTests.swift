import XCTest
@testable import AllOfMacOS

final class AOMSharedImagesTests: XCTestCase {
    func testSharedImagesPreserveOrderAndEscapedFileNames() {
        var components = URLComponents(string: "aom://share-images")!
        components.queryItems = [URLQueryItem(name: "mode", value: "pin"),
                                URLQueryItem(name: "file", value: "/tmp/한글 & one.png"),
                                URLQueryItem(name: "file", value: "/tmp/two.tiff")]
        let request = AOMSharedImages.parse(components.url!)
        XCTAssertEqual(request?.mode, .pin)
        XCTAssertEqual(request?.files.map(\.path), ["/tmp/한글 & one.png", "/tmp/two.tiff"])
    }

    func testRejectsAmbiguousOrRemoteRequests() {
        for value in ["aom://share-images?mode=pin&mode=annotate&file=/tmp/a.png",
                      "aom://share-images?mode=pin&file=relative.png",
                      "aom://share-images?mode=pin&file=https://example.com/a.png",
                      "aom://share-images?mode=pin&file=/tmp/a.png&execute=1",
                      "aom://user@share-images?mode=pin&file=/tmp/a.png",
                      "aom://share-images?mode=pin&file=/tmp/a.png#extra",
                      "aom://share-images?mode=pin&file=/tmp/a.png&file",
                      "aom://share-images?mode=pin"] {
            XCTAssertNil(AOMSharedImages.parse(URL(string: value)!), value)
        }
    }
}
