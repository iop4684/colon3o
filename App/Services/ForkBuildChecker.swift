import Foundation
import UIKit

/// Tracks this fork's own builds (iop4684/colon3o). The fork has no signed install page, so it
/// asks GitHub for the newest successful CI run on this build's branch instead. CI stamps each
/// build with its run number (CFBundleVersion), so a higher run number means a newer build.
@MainActor
final class ForkBuildChecker: ObservableObject {
    struct Build: Equatable {
        let runNumber: Int
        let message: String
        let date: Date?
        let url: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Build)
        case available(Build)
        case failed(String)
    }

    nonisolated static let owner = "iop4684"
    nonisolated static let repo = "colon3o"
    nonisolated static let repositoryURL = URL(string: "https://github.com/\(owner)/\(repo)")!

    @Published private(set) var state: State = .idle

    let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    /// beta builds follow the beta branch, everything else main.
    let branch = (Bundle.main.object(forInfoDictionaryKey: "Colon3Channel") as? String) == "beta" ? "beta" : "main"

    private struct Response: Decodable {
        struct Run: Decodable {
            struct Commit: Decodable { let message: String? }
            let run_number: Int
            let html_url: String
            let updated_at: String?
            let head_commit: Commit?
        }
        let workflow_runs: [Run]
    }

    func check() async {
        guard state != .checking else { return }
        var components = URLComponents(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/actions/workflows/build.yml/runs")!
        components.queryItems = [
            URLQueryItem(name: "branch", value: branch),
            URLQueryItem(name: "status", value: "success"),
            URLQueryItem(name: "event", value: "push"),
            URLQueryItem(name: "per_page", value: "1"),
        ]
        guard let url = components.url else { return }
        state = .checking
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                state = .failed(status == 403 || status == 429
                                ? "GitHub is limiting requests. Try again in a while."
                                : "GitHub answered \(status).")
                return
            }
            guard let run = try JSONDecoder().decode(Response.self, from: data).workflow_runs.first,
                  let runURL = URL(string: run.html_url) else {
                state = .failed("No \(branch) build of this fork yet.")
                return
            }
            let build = Build(runNumber: run.run_number,
                              message: run.head_commit?.message?.components(separatedBy: .newlines).first ?? "",
                              date: run.updated_at.flatMap { ISO8601DateFormatter().date(from: $0) },
                              url: runURL)
            state = build.runNumber > currentBuild ? .available(build) : .upToDate(build)
        } catch is DecodingError {
            state = .failed("Couldn't read GitHub's answer.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The build's run page on GitHub, where the IPA is under Artifacts (needs a GitHub sign-in).
    func open(_ build: Build) {
        UIApplication.shared.open(build.url)
    }
}
