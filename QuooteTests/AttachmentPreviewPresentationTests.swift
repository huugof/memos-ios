import XCTest
import SwiftUI
import QuickLook
@testable import Quoote

/// What the preview sheet does to the sheet beneath it. The editor saves and sends its note when it disappears, and
/// closes when its keyboard goes away, so a preview that made it disappear would commit the note it was opened from.
/// A sheet over a sheet leaves the one beneath in place: these fail if a system update changes that.
@MainActor
final class AttachmentPreviewPresentationTests: XCTestCase {

    private final class Probe {
        var appeared = 0
        var disappeared = 0
    }

    private struct PreviewItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    /// A sheet standing in for the editor, with the same preview sheet the editor shows.
    private struct Host: View {
        @ObservedObject var previewer: AttachmentPreviewer
        let probe: Probe
        @State private var showSheet = true

        var body: some View {
            Color.black.sheet(isPresented: $showSheet) {
                Color.gray
                    .onAppear { probe.appeared += 1 }
                    .onDisappear { probe.disappeared += 1 }
                    .sheet(item: Binding(
                        get: { previewer.previewURL.map(PreviewItem.init) },
                        set: { if $0 == nil { previewer.previewURL = nil } }
                    ), onDismiss: { previewer.previewDidClose() }) { item in
                        AttachmentPreviewSheet(url: item.url)
                    }
            }
        }
    }

    private var tempDirectory: URL!
    private var window: UIWindow?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory.appendingPathComponent("vault/attachments"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        window?.isHidden = true
        window = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    private func top(_ root: UIViewController) -> UIViewController {
        var controller = root
        while let next = controller.presentedViewController { controller = next }
        return controller
    }

    private func quickLook(in controller: UIViewController) -> QLPreviewController? {
        if let preview = controller as? QLPreviewController { return preview }
        for child in controller.children {
            if let found = quickLook(in: child) { return found }
        }
        return nil
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Opens a preview of a small vault file over the stand-in sheet.
    private func openPreview() async throws -> (previewer: AttachmentPreviewer, probe: Probe, root: UIViewController, previews: URL) {
        let vault = tempDirectory.appendingPathComponent("vault", isDirectory: true)
        let previews = tempDirectory.appendingPathComponent("previews", isDirectory: true)
        try "hello".write(to: vault.appendingPathComponent("attachments/Note.txt"), atomically: true, encoding: .utf8)
        let files = AttachmentPreviewFiles(environment: .init(
            vaultAccess: { body in body(VaultFileStore(root: vault)) },
            attachmentsFolder: { "attachments" },
            directory: previews
        ))
        let previewer = AttachmentPreviewer(files: files)
        let probe = Probe()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        self.window = window
        let root = UIHostingController(rootView: Host(previewer: previewer, probe: probe))
        window.rootViewController = root
        // Not the key window: the app under test opens its own editor and keyboard at launch, and taking key
        // status from it stalls UIKit's keyboard queue for a long time.
        window.windowLevel = .alert + 1
        window.isHidden = false
        await waitUntil("the sheet") { top(root) !== root && probe.appeared == 1 }

        previewer.open(NoteAttachment(target: "Note.txt", name: "Note.txt", kind: .file), notePath: nil) { _ in }
        await waitUntil("QuickLook") { quickLook(in: top(root)) != nil }
        return (previewer, probe, root, previews)
    }

    func testAPreviewOpensOverTheSheetWithoutMakingItDisappearAndItsCopyGoesWhenItCloses() async throws {
        let (previewer, probe, root, previews) = try await openPreview()

        XCTAssertEqual(probe.disappeared, 0, "the sheet under the preview must not disappear")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: previews.path).count, 1)

        top(root).dismiss(animated: false)
        await waitUntil("the preview to close") { previewer.previewURL == nil }
        await waitUntil("its copy to go") { ((try? FileManager.default.contentsOfDirectory(atPath: previews.path)) ?? ["?"]).isEmpty }

        XCTAssertEqual(probe.disappeared, 0)
    }

    /// Close clears the binding as the sheet starts to slide away, and QuickLook is still showing the file for another
    /// half second: the copy must outlive that, and go only once the sheet has left the screen.
    func testTheCopyIsKeptUntilTheSheetShowingItHasLeft() async throws {
        let (previewer, probe, root, previews) = try await openPreview()
        let preview = try XCTUnwrap(quickLook(in: top(root)))
        let close = try XCTUnwrap(preview.navigationItem.leftBarButtonItem?.primaryAction, "no Close button")
        let copies = { ((try? FileManager.default.contentsOfDirectory(atPath: previews.path)) ?? ["?"]).count }

        var copiesWhenCleared: Int?
        var onScreenWhenCopyWent: Bool?
        let watcher = Task { @MainActor in
            while previewer.previewURL != nil { try? await Task.sleep(for: .milliseconds(1)) }
            copiesWhenCleared = copies()
            while copies() > 0 { try? await Task.sleep(for: .milliseconds(1)) }
            onScreenWhenCopyWent = preview.view.window != nil
        }
        close.performWithSender(nil, target: nil)
        await waitUntil("the preview to close") { previewer.previewURL == nil }
        await watcher.value

        XCTAssertEqual(copiesWhenCleared, 1, "the copy is still there when the sheet is told to close")
        XCTAssertEqual(onScreenWhenCopyWent, false, "and goes only once the sheet is off the screen")
        XCTAssertEqual(probe.disappeared, 0)
    }

    /// Dragging the sheet down has to be able to close the preview, which a full-screen cover would not allow.
    func testThePreviewSheetCanBeDraggedAway() async throws {
        let (_, _, root, _) = try await openPreview()

        XCTAssertFalse(top(root).isModalInPresentation)
        XCTAssertNotEqual(top(root).modalPresentationStyle, .fullScreen)
        XCTAssertNotEqual(top(root).modalPresentationStyle, .overFullScreen)
    }
}
