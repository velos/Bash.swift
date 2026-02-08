import Testing
import BashPython

@Suite("Pyodide Configuration")
struct PyodideConfigurationTests {
    @Test("default configuration prefers bundled pyodide loader")
    func defaultConfigurationUsesBundledLoader() {
        let configuration = PyodideConfiguration.default
        #expect(configuration.indexURL.isFileURL)

        switch configuration.loaderSource {
        case let .file(url):
            #expect(url.lastPathComponent == "pyodide.js")
            #expect(configuration.indexURL == url.deletingLastPathComponent())
        case .inline:
            Issue.record("Expected bundled pyodide.js loader file, got inline source")
        case .remote:
            Issue.record("Expected bundled pyodide.js loader file, got remote loader URL")
        }
    }
}
