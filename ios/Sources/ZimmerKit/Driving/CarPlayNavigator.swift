import Foundation

/// The modal half of a CarPlay interface controller, as `CarPlayNavigator` drives it. The app's
/// `CPInterfaceController` conforms through CarPlay's async calls; the tests' strict fake
/// conforms by failing exactly where CarPlay does.
///
/// What CarPlay does, from its documentation (`presentTemplate`, `dismissTemplate`,
/// `pushTemplate`): it presents one modal template at a time, a presentation or dismissal can
/// fail, and **a failure with no completion closure is an exception — the app crashes.** Every
/// call here is an `async throws` one, which CarPlay always answers through a completion, so a
/// failure is an error to report and never a crash.
@MainActor
public protocol CarPlayModalHost: AnyObject {
    associatedtype Template: AnyObject
    /// The modal on screen, if any.
    var presentedTemplate: Template? { get }
    /// Present `template` modally. Throws when CarPlay refuses.
    func present(_ template: Template, animated: Bool) async throws
    /// Dismiss the modal on screen. Throws when CarPlay refuses — including when none is.
    func dismissPresented(animated: Bool) async throws
}

/// Every modal change the car makes, one at a time.
///
/// The CarPlay scene changes its modal from several places that do not wait on each other: a
/// call starting, the call's state going idle, a new subject rebuilding the call screen, the
/// scene disconnecting. Made directly, two of those inside one animation collide — a present
/// while another is still going up, a dismiss of a modal that is already on its way down — and
/// CarPlay refuses the second. So every change goes through here: each waits for the one before
/// it to finish, looks at what is on screen *then*, and does only what still needs doing. A
/// refusal is logged through `onError` and the next change carries on.
@MainActor
public final class CarPlayNavigator<Host: CarPlayModalHost> {
    public typealias Template = Host.Template

    private weak var host: Host?
    /// The modal this navigator put up and has not taken down. Compared by this rather than by
    /// `host.presentedTemplate === template`, because CarPlay's `presentedTemplate` is not the
    /// object that was presented: compared by identity, every dismissal of the call screen was
    /// skipped and it stayed up — "Connecting…" over a car that had given up — which the
    /// CarPlay drill caught in the Simulator's CarPlay window. The host is asked only whether
    /// anything is up, which also covers a modal the driver closed with CarPlay's own button.
    private var shown: Template?
    /// The last change queued; the next one waits for it.
    private var tail: Task<Void, Never>?
    /// A change CarPlay refused, in words, for the log.
    public var onError: ((String) -> Void)?

    public init(host: Host) {
        self.host = host
    }

    /// Put `template` on screen, giving way whatever modal is up first. True when it is up.
    @discardableResult
    public func present(_ template: Template) async -> Bool {
        await serially { host in
            if self.shown === template, host.presentedTemplate != nil { return true }
            if host.presentedTemplate != nil {
                do { try await host.dismissPresented(animated: false) } catch {
                    self.report("dismiss before present", error)
                    return false
                }
            }
            self.shown = nil
            do {
                try await host.present(template, animated: true)
                self.shown = template
                return true
            } catch {
                self.report("present", error)
                return false
            }
        } otherwise: { false }
    }

    /// Take `template` down if it is the modal on screen. Anything else on screen stays.
    public func dismiss(_ template: Template) async {
        await serially { host in
            guard self.shown === template else { return }
            self.shown = nil
            guard host.presentedTemplate != nil else { return }
            do { try await host.dismissPresented(animated: true) } catch { self.report("dismiss", error) }
        } otherwise: { () }
    }

    /// Swap `old` for `new` if `old` is on screen: the call screen rebuilt for a new subject or
    /// for Mute, without animation, so it is a blink rather than a slide down and up. With `old`
    /// gone already, nothing is presented: whatever took it down meant it.
    @discardableResult
    public func replace(_ old: Template, with new: Template) async -> Bool {
        await serially { host in
            guard self.shown === old, host.presentedTemplate != nil else { return false }
            self.shown = nil
            do {
                try await host.dismissPresented(animated: false)
                try await host.present(new, animated: false)
                self.shown = new
                return true
            } catch {
                self.report("replace", error)
                return false
            }
        } otherwise: { false }
    }

    /// Wait for every change queued so far.
    public func settle() async {
        await tail?.value
    }

    private func serially<T: Sendable>(_ body: @escaping @MainActor (Host) async -> T, otherwise: @escaping @MainActor () -> T) async -> T {
        let previous = tail
        let mine = Task { @MainActor [weak self] () -> T in
            await previous?.value
            guard let self, let host = self.host else { return otherwise() }
            return await body(host)
        }
        tail = Task { @MainActor in _ = await mine.value }
        return await mine.value
    }

    private func report(_ what: String, _ error: Error) {
        onError?("CarPlay refused to \(what): \(error)")
    }
}
