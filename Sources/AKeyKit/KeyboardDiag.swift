import Foundation
import Security

/// 当前这份 app 的「身份」信息。
///
/// 为什么需要它：输入监控（kTCCServiceListenEvent）的授权记录**绑在签名身份 + 路径上**。
/// 于是同一份代码在下面三种情况下会「开关明明开着，事件就是不进来」：
///   - 换机器拷贝过来（TCC 记录没跟过去，或者跟过去的是另一条记录的影子）
///   - 每次重新编译（ad-hoc 签名的代码要求是 cdhash，一编就变）
///   - 同时存在两份副本（列表里那一项不是正在跑的这一份）
/// 这些都没法从 IOHIDCheckAccess 里看出来，只能把身份摊开给人看。
public struct SigningInfo: Sendable, Equatable {
    /// 正在运行的这个 bundle 的路径（TCC 认的就是它）
    public var bundlePath: String
    public var bundleID: String
    /// 人话版签名身份："Apple Development: xxx" / "ad-hoc（无证书）" / "未签名"
    public var identity: String
    public var teamID: String?
    public var isAdhoc: Bool
    /// 被 Gatekeeper 挪到 /private/var/folders/.../AppTranslocation 下跑（从下载目录直接双击会这样）
    public var translocated: Bool
    /// 机器上其他位置的同名 app（列表里那一项可能是它们）
    public var otherCopies: [String]

    /// 签名稳定 = 重装/重编之后授权还能用
    public var isStable: Bool { !isAdhoc && !translocated }

    public var pathNote: String {
        var note = bundlePath
        if translocated { note += "（App Translocation）" }
        return note
    }

    public static func current() -> SigningInfo {
        let bundle = Bundle.main
        let path = bundle.bundleURL.path
        let id = bundle.bundleIdentifier ?? "—"

        var identity = "未签名"
        var team: String?
        var adhoc = false
        var signed = false

        var code: SecStaticCode?
        if SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess, let code {
            var info: CFDictionary?
            let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
            if SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
               let dict = info as? [String: Any] {
                signed = true
                let raw = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
                // kSecCodeSignatureAdhoc = 0x0002：没有证书，代码要求退化成 cdhash
                adhoc = (raw & 0x0002) != 0
                team = dict[kSecCodeInfoTeamIdentifier as String] as? String
                if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
                   let first = certs.first,
                   let summary = SecCertificateCopySubjectSummary(first) as String? {
                    identity = summary
                }
                if adhoc { identity = "ad-hoc（无证书）" }
            }
        }
        if !signed { identity = "未签名 / 无签名信息" }

        return SigningInfo(bundlePath: path,
                           bundleID: id,
                           identity: identity,
                           teamID: team,
                           isAdhoc: adhoc,
                           translocated: path.contains("/AppTranslocation/"),
                           otherCopies: otherCopies(besides: path))
    }

    /// 容易同时存在副本的几个位置。只做存在性检查，不递归扫盘。
    private static func otherCopies(besides running: String) -> [String] {
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/A-Key-Stats.app",
            "\(home)/Applications/A-Key-Stats.app",
            "\(home)/Downloads/A-Key-Stats.app",
            "\(home)/Desktop/A-Key-Stats.app",
            "\(home)/Documents/A-Key-Stats.app",
        ]
        let runningResolved = URL(fileURLWithPath: running).resolvingSymlinksInPath().path
        return candidates.filter { path in
            guard FileManager.default.fileExists(atPath: path) else { return false }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return resolved != runningResolved
        }
    }
}

/// 一句话结论，给提示条/诊断文字复用，避免两处文案不一致
public enum SigningVerdict {
    public static func note(_ info: SigningInfo) -> String? {
        if info.translocated {
            return "正在从系统临时目录（App Translocation）运行。把 app 拖到「应用程序」文件夹再打开，否则每次授权都对不上。"
        }
        if !info.otherCopies.isEmpty {
            return "机器上还有另一份：\(info.otherCopies.joined(separator: "、"))。列表里那一项可能是它的授权。"
        }
        if info.isAdhoc {
            return "这份是 ad-hoc 签名：每次重新编译，系统那边就当成一个新 app，旧授权作废。"
        }
        return nil
    }
}
