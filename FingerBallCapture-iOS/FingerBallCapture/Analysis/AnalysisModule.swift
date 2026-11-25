import Foundation

enum AnalysisMode: String, Codable {
    case hand, shoulderElbow, ball
}

struct AnalysisInput {
    let takeFolder: URL
    let movie: URL
    let timestamps: URL
    let annotations: URL?
}

struct AnalysisResult {
    let output: URL
    let mode: AnalysisMode
    let modelVersion: String
}

protocol AnalysisModule {
    var mode: AnalysisMode { get }
    func analyze(_ input: AnalysisInput) async throws -> AnalysisResult
}
