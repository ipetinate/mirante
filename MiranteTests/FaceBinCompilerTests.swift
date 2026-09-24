import XCTest
@testable import Mirante

final class FaceBinCompilerTests: XCTestCase {
    /// A compiled .bin must start with the magic header and embed a numeric
    /// face id at offset 0x28 (the layout both `CompiledFaceMagic` and
    /// `XiaomiProto.watchfaceID` expect).
    func testHeaderLayout() throws {
        let payload = Data("fake fprj payload".utf8)
        let bin = try FaceBinCompiler.compile(name: "Test Face", deviceID: "band7", payload: payload)

        XCTAssertEqual(bin.count, FaceBinCompiler.headerSize + payload.count)
        XCTAssertTrue(CompiledFaceMagic.matches(bin))
        XCTAssertNotNil(XiaomiProto.watchfaceID(from: bin))
        XCTAssertGreaterThanOrEqual(XiaomiProto.watchfaceID(from: bin)?.count ?? 0, 1)
    }

    /// The same project must compile to the same numeric id.
    func testStableID() throws {
        let a = FaceBinCompiler.numericID(name: "Amber", deviceID: "band7")
        let b = FaceBinCompiler.numericID(name: "Amber", deviceID: "band7")
        let other = FaceBinCompiler.numericID(name: "Amber", deviceID: "band6")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, other)
        XCTAssertTrue(a.allSatisfy(\.isNumber))
    }

    /// Compiling from a project uses its export data as the payload.
    func testCompileFromProject() throws {
        let project = WatchFaceProject(name: "Pulse", deviceID: "band7")
        let bin = try FaceBinCompiler.compile(project)
        XCTAssertTrue(CompiledFaceMagic.matches(bin))
        XCTAssertNotNil(XiaomiProto.watchfaceID(from: bin))
        XCTAssertLessThanOrEqual(bin.count, maxFacePayloadBytes)
    }
}