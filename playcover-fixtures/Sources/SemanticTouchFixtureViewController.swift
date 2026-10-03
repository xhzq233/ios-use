import UIKit

/// An AX target moves without UIKit animations, as restored list positions can.
/// The App records actual touch callbacks independently of Driver responses.
final class SemanticTouchFixtureViewController: UIViewController {
    private let target = UIButton(type: .system)
    private let duration: TimeInterval
    private var timer: Timer?
    private var targetTaps = 0
    private var otherTaps = 0
    private var presses = 0
    private var moving = false

    init(duration: TimeInterval) {
        self.duration = duration
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        for index in 0..<12 {
            let other = UIButton(type: .system)
            other.setTitle("Other row \(index)", for: .normal)
            other.frame = CGRect(x: 30, y: 180 + index * 35, width: 220, height: 30)
            other.addTarget(self, action: #selector(tappedOther), for: .touchUpInside)
            view.addSubview(other)
        }
        target.setTitle("Moving target", for: .normal)
        target.accessibilityIdentifier = "fixture.touch.target"
        target.backgroundColor = .systemYellow
        target.frame = CGRect(x: 30, y: 300, width: 220, height: 30)
        target.addTarget(self, action: #selector(tappedTarget), for: .touchUpInside)
        target.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(pressedTarget)))
        view.addSubview(target)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let startedAt = ProcessInfo.processInfo.systemUptime
        moving = duration > 0
        recordState()
        guard moving else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            self.moving = elapsed < self.duration
            self.target.frame.origin.y = self.moving ? 350 + 100 * sin(elapsed * 30) : 497
            if !self.moving { timer.invalidate() }
            self.recordState()
        }
    }

    @objc private func tappedTarget() { targetTaps += 1; recordState() }
    @objc private func tappedOther() { otherTaps += 1; recordState() }
    @objc private func pressedTarget(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { presses += 1; recordState() }
    }

    private func recordState() {
        let state: [String: Any] = ["targetTaps": targetTaps, "otherTaps": otherTaps,
                                    "presses": presses, "moving": moving, "targetY": target.frame.minY]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("touch-state.json"), options: .atomic)
    }
}
