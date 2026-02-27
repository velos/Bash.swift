import Foundation
import Bash

public struct BashSecretsReferenceResolver: SecretReferenceResolving {
    public init() {}

    public func resolveSecretReference(_ reference: String) async throws -> Data {
        try await Secrets.resolveReference(reference)
    }
}
