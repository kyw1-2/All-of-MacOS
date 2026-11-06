import Foundation
import Security
import CryptoKit

@objc(AOMHardwareHelperProtocol)
protocol HardwareHelperProtocol {
    func configure(battery: String, fan: String, reply: @escaping (String?) -> Void)
    func renew(reply: @escaping (String?) -> Void)
    func releaseControl(reply: @escaping (String?) -> Void)
}

enum HardwareHelperIdentity {
    static let name = "com.kyw.allofmacos.HardwareHelper"
    static let plist = name + ".plist"

    /// Bind both peers to the exact signing certificate, including AOM's
    /// self-signed development identity. Ad-hoc binaries cannot manage hardware.
    static func requirement(identifier: String) throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var raw: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else {
            throw HardwareControlError.unavailable("Hardware control requires a certificate-signed AOM build")
        }
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(digest)\""
    }
}
