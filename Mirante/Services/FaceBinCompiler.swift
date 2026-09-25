import Foundation

/// Builds a compiled watchface `.bin` from an editable project, entirely
/// in-app. It now produces a real o66 package (the format the Xiaomi Smart
/// Band 10 Pro expects) with a compressed preview image, definitions and
/// resources — wrapped in the same header contract (`CompiledFaceMagic`, size
/// guard, `XiaomiProto.watchfaceID`) the transport and proto already rely on.
enum FaceBinCompiler {
    /// Pure compile with a placeholder preview; used by tests and callers that
    /// cannot render one. The file is always structurally valid.
    static func compile(_ project: WatchFaceProject) throws -> O66CompiledFace {
        try O66Compiler.compile(project: project, previewPNG: nil)
    }

    /// Compiles with a caller-provided preview PNG (device-sized) baked into
    /// the package's preview block.
    static func compile(_ project: WatchFaceProject, previewPNG: Data?) throws -> O66CompiledFace {
        try O66Compiler.compile(project: project, previewPNG: previewPNG)
    }

    /// Convenience used by the export/publish sheets: renders the live preview
    /// on the main actor, then compiles with that preview embedded.
    @MainActor
    static func compile(_ project: WatchFaceProject, editor: EditorState) throws -> O66CompiledFace {
        let preview = PreviewRenderer.renderPNG(project, editor: editor)
        return try compile(project, previewPNG: preview)
    }

    /// A stable, collision-likely-low 9-digit face id (FNV-1a, 32-bit, mod
    /// 10⁹) so the same project always compiles to the same face id without a
    /// PRNG — matched by `O66Compiler.numericID`.
    static func numericID(name: String, deviceID: String) -> String {
        O66Compiler.numericID(from: name, deviceID: deviceID)
    }
}