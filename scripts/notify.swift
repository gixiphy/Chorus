import Foundation
let args = CommandLine.arguments
var info: [String: String] = ["instance": args[1], "action": args[2]]
if args.count > 3 { info["value"] = args[3] }
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.hermes.Chorus.test"), object: nil, userInfo: info, deliverImmediately: true)
Thread.sleep(forTimeInterval: 0.3)
