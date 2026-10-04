import XCTest
import SwiftUI
import QuickLook
@testable import Quoote

/// What the system previewer does to the sheet beneath it. The editor saves and sends its note when it disappears,
/// and closes when its keyboard goes away, so a preview that made it disappear would commit the note it was opened
/// from. SwiftUI presents QuickLook over the sheet (`overFullScreen`), which leaves it in place: this fails if a
/// system update changes that.
@MainActor
final class AttachmentPreviewPresentationTests: XCTestCase {

    private final class Probe {
        var appeared = 0
        var disappeared = 0
    }

    /// A sheet standing in for the editor, with the same `.quickLookPreview` binding the editor uses.
    private struct Host: View {
        @ObservedObject var previewer: AttachmentPreviewer
        let probe: Probe
        @State private var showSheet = true

        var body: some View {
            Color.black.sheet(isPresented: $showSheet) {
                Color.gray
                    .onAppear { probe.appeared += 1 }
                    .onDisappear { probe.disappeared += 1 }
                    .quickLookPreview($previewer.previewURL)
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

    private func showsQuickLook(_ controller: UIViewController) -> Bool {
        controller is QLPreviewController || controller.children.contains(where: showsQuickLook)
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAPreviewOpensOverTheSheetWithoutMakingItDisappearAndItsCopyGoesWhenItCloses() async throws {
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
        await waitUntil("QuickLook") { showsQuickLook(top(root)) }

        XCTAssertEqual(probe.disappeared, 0, "the sheet under the preview must not disappear")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: previews.path).count, 1)

        top(root).dismiss(animated: false)
        await waitUntil("the preview to close") { previewer.previewURL == nil }

        XCTAssertEqual(probe.disappeared, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: previews.path), [], "the copy goes with the preview")
    }
}
