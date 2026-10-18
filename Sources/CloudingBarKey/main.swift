import CryptoKit
import Foundation
import Security

// cloudingbar-key: keeps the claude.ai session key in the Keychain for
// Clouding Bar.
//
// Why a helper: without a Team ID the Keychain ties "Always Allow" to the
// exact build that asked (its cdhash), so every rebuild of the app asked
// again. This helper is rebuilt only when this file changes, so the answer
// sticks. It answers only Clouding Bar itself: its parent process must be
// dev.cloudingbar.app signed with the same certificate as the helper.
//
//   cloudingbar-key read     prints the key
//   cloudingbar-key save     stores the key it reads from stdin
//   cloudingbar-key delete
//
// Exit: 0 done, 1 no key, 2 the caller isn't Clouding Bar, 3 anything else.

let service = "Clouding Bar · claude.ai session key"
let account = "sessionKey"

/// SHA-1 of the leaf certificate a piece of code is signed with.
func leafHash(_ code: SecStaticCode) -> String? {
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certs.first else { return nil }
    return Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
}

func callerIsCloudingBar() -> Bool {
    var me: SecCode?
    var mine: SecStaticCode?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
          SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
          let leaf = leafHash(mine) else { return false }
    var parent: SecCode?
    var requirement: SecRequirement?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: getppid()] as CFDictionary, [], &parent) == errSecSuccess,
          let parent,
          SecRequirementCreateWithString("identifier \"dev.cloudingbar.app\" and certificate leaf = H\"\(leaf)\"" as CFString,
                                         [], &requirement) == errSecSuccess,
          let requirement else { return false }
    return SecCodeCheckValidity(parent, [], requirement) == errSecSuccess
}

let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service,
                            kSecAttrAccount as String: account]

guard CommandLine.arguments.count == 2 else { exit(3) }
guard callerIsCloudingBar() else { exit(2) }

switch CommandLine.arguments[1] {
case "read":
    var out: CFTypeRef?
    var q = query
    q[kSecReturnData as String] = true
    let status = SecItemCopyMatching(q as CFDictionary, &out)
    guard status == errSecSuccess, let data = out as? Data else { exit(status == errSecItemNotFound ? 1 : 3) }
    FileHandle.standardOutput.write(data)
case "save":
    let key = FileHandle.standardInput.readDataToEndOfFile()
    guard !key.isEmpty else { exit(3) }
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    item[kSecValueData as String] = key
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { exit(3) }
case "delete":
    let status = SecItemDelete(query as CFDictionary)
    exit(status == errSecSuccess || status == errSecItemNotFound ? 0 : 3)
default:
    exit(3)
}
