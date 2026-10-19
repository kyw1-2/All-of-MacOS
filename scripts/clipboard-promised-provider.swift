// Disposable named-pasteboard fixture. Never touches the general clipboard.
import AppKit

final class SlowProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        Thread.sleep(forTimeInterval: 0.35)
        item.setString("AOM promised-provider fixture", forType: type)
    }
}
let args = CommandLine.arguments
precondition(args.count == 3)
let board = NSPasteboard(name: .init(args[1]))
let provider = SlowProvider()
let item = NSPasteboardItem()
item.setDataProvider(provider, forTypes: [.string])
board.clearContents()
precondition(board.writeObjects([item]))
try Data("ready".utf8).write(to: URL(fileURLWithPath: args[2]))
withExtendedLifetime(provider) { RunLoop.current.run(until: Date().addingTimeInterval(20)) }
