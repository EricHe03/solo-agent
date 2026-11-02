import SwiftUI

@MainActor
func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    guard var top = scene?.keyWindow?.rootViewController else { return nil }
    while let presented = top.presentedViewController {
        top = presented
    }
    return top
}

// Pushing a view that holds a NavigationStack onto another NavigationStack hangs the main thread (iOS 27.2 24B115).
@available(iOS 27, *)
@MainActor
enum SwipletPresentation {
    static func open(name: String, entry: SwipletEntry) {
        guard let top = topViewController() else {
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { _ in
                if let token {
                    NotificationCenter.default.removeObserver(token)
                }
                open(name: name, entry: entry)
            }
            return
        }
        top.present(SwipletPresentationController(name: name, entry: entry), animated: true)
    }
}

@available(iOS 27, *)
private final class SwipletPresentationController: UIHostingController<AnyView>, UIViewControllerTransitioningDelegate, UIGestureRecognizerDelegate {
    private let name: String
    private var interaction: UIPercentDrivenInteractiveTransition?

    init(name: String, entry: SwipletEntry) {
        self.name = name
        super.init(rootView: AnyView(SwipletInterface(name: name, entry: entry).modifier(ErrorAlertPresenter(level: ErrorAlert.shared.cover()))))
        modalPresentationStyle = .fullScreen
        transitioningDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let swipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swipeBack))
        swipe.edges = .left
        swipe.delegate = self
        view.addGestureRecognizer(swipe)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        SwipletHost.shared.didPresent(name) { [weak self] in self?.presentingViewController?.dismiss(animated: true) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed else { return }
        SwipletHost.shared.didDismiss(name)
        ErrorAlert.shared.uncover()
        rootView = AnyView(EmptyView())
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        !Self.navigationBars(in: view).contains { ($0.delegate as? UINavigationController)?.viewControllers.count ?? 0 > 1 }
    }

    private static func navigationBars(in view: UIView) -> [UINavigationBar] {
        if let bar = view as? UINavigationBar {
            return [bar]
        }
        return view.subviews.flatMap(navigationBars)
    }

    @objc private func swipeBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
        let progress = min(max(gesture.translation(in: view).x / view.bounds.width, 0), 1)
        switch gesture.state {
        case .began:
            interaction = UIPercentDrivenInteractiveTransition()
            dismiss(animated: true)
        case .changed:
            interaction?.update(progress)
        case .ended, .cancelled:
            if gesture.state == .ended, progress > 0.5 || gesture.velocity(in: view).x > 500 {
                interaction?.finish()
            } else {
                interaction?.cancel()
            }
            interaction = nil
        default:
            break
        }
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        SlideTransition(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        SlideTransition(presenting: false)
    }

    func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        interaction
    }
}

private final class SlideTransition: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool

    init(presenting: Bool) {
        self.presenting = presenting
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.5
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let from = context.view(forKey: .from), let to = context.view(forKey: .to), let toController = context.viewController(forKey: .to) else {
            context.completeTransition(false)
            return
        }
        let container = context.containerView
        let frame = context.finalFrame(for: toController)
        let width = container.bounds.width
        let front = presenting ? to : from
        let back = presenting ? from : to
        if presenting {
            container.addSubview(to)
        } else {
            container.insertSubview(to, belowSubview: from)
        }
        to.frame = frame
        let shown = CGAffineTransform.identity
        let covered = CGAffineTransform(translationX: -width / 3, y: 0)
        let away = CGAffineTransform(translationX: width, y: 0)
        front.transform = presenting ? away : shown
        back.transform = presenting ? shown : covered
        let animations = {
            front.transform = self.presenting ? shown : away
            back.transform = self.presenting ? covered : shown
        }
        let completion = { (_: Bool) in
            front.transform = .identity
            back.transform = .identity
            context.completeTransition(!context.transitionWasCancelled)
        }
        if context.isInteractive {
            UIView.animate(withDuration: transitionDuration(using: context), delay: 0, options: .curveLinear, animations: animations, completion: completion)
        } else {
            UIView.animate(withDuration: transitionDuration(using: context), delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, animations: animations, completion: completion)
        }
    }
}
