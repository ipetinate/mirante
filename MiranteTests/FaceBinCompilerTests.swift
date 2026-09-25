import XCTest
@testable import Mirante

final class FaceBinCompilerTests: XCTestCase {
    /// A compiled .bin must start with the o66 magic, embed the numeric face
    /// id at offset 0x28 (the layout `CompiledFaceMagic` and
    /// `XiaomiProto.watchfaceID` expect) and stay within the transport's size
    /// budget.
    func testHeaderLayout() throws {
        let project = WatchFaceProject(name: "Test Face", deviceID: "band10pro")
        let result = try FaceBinCompiler.compile(project)
        let bin = result.data

        XCTAssertTrue(CompiledFaceMagic.matches(bin))
        XCTAssertEqual(XiaomiProto.watchfaceID(from: bin) ?? "", FaceBinCompiler.numericID(name: "Test Face", deviceID: "band10pro"))
        XCTAssertGreaterThanOrEqual(bin.count, O66Compiler.mainHeaderSize + O66Compiler.faceHeaderSize)
        XCTAssertLessThanOrEqual(bin.count, maxFacePayloadBytes)
    }

    /// `deviceID` is unknown in tests unless referenced; only the 9-digit id
    /// contract is guaranteed here.
    func testNumericID() throws {
        let a = FaceBinCompiler.numericID(name: "Amber", deviceID: "band10pro")
        let b = FaceBinCompiler.numericID(name: "Amber", deviceID: "band10pro")
        let other = FaceBinCompiler.numericID(name: "Amber", deviceID: "band7")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, other)
        XCTAssertEqual(a.count, 9)
        XCTAssertTrue(a.allSatisfy(\.isNumber))
    }

    /// Compiling a project with no widgets still yields a structurally valid
    /// package with a placeholder preview and no warnings.
    func testCompileEmptyProject() throws {
        let project = WatchFaceProject(name: "Pulse", deviceID: "band10pro")
        let result = try FaceBinCompiler.compile(project)
        XCTAssertEqual(result.warnings, [])
        XCTAssertTrue(CompiledFaceMagic.matches(result.data))
        XCTAssertNotNil(XiaomiProto.watchfaceID(from: result.data))
        XCTAssertLessThanOrEqual(result.data.count, maxFacePayloadBytes)
        try O66Compiler.assertStructuralIntegrity([UInt8](result.data))
    }

    /// A too-long name breaks the 60-byte header slot and must be rejected.
    func testNameTooLong() throws {
        let project = WatchFaceProject(name: String(repeating: "x", count: 61), deviceID: "band10pro")
        XCTAssertThrowsError(try FaceBinCompiler.compile(project))
    }
}