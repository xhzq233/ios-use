import UIKit

/// Unequal sibling tables and a nested horizontal strip expose wrong-container
/// swipes. State is written by the App's scroll callbacks, independently of AX.
final class ScrollFixtureViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let left = UITableView()
    private let right = UITableView()
    private let strip = UIScrollView()
    private let reset = UIButton(type: .system)
    private let reorder = UIButton(type: .system)
    private let status = UILabel()
    private var reversed = false
    private var selected = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        for (table, name) in [(left, "left"), (right, "right")] {
            table.accessibilityIdentifier = "fixture.scroll.\(name)"
            table.dataSource = self
            table.delegate = self
            table.rowHeight = 60
            table.contentInsetAdjustmentBehavior = .never
            view.addSubview(table)
        }
        strip.accessibilityIdentifier = "fixture.scroll.strip"
        strip.delegate = self
        strip.contentInsetAdjustmentBehavior = .never
        strip.backgroundColor = .secondarySystemBackground
        strip.contentSize = CGSize(width: 1500, height: 70)
        for index in 0..<15 {
            let label = UILabel(frame: CGRect(x: index * 100, y: 0, width: 96, height: 70))
            label.text = "Strip \(index)"
            label.accessibilityIdentifier = "fixture.strip.\(index)"
            strip.addSubview(label)
        }
        // The strip is inside the left table, rather than another sibling.
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 180, height: 80))
        header.addSubview(strip)
        left.tableHeaderView = header
        reset.setTitle("Reset Scrolls", for: .normal)
        reset.accessibilityIdentifier = "fixture.scroll.reset"
        reset.addTarget(self, action: #selector(resetScrolls), for: .touchUpInside)
        reorder.setTitle("Reorder Rows", for: .normal)
        reorder.accessibilityIdentifier = "fixture.scroll.reorder"
        reorder.addTarget(self, action: #selector(reorderRows), for: .touchUpInside)
        status.accessibilityIdentifier = "fixture.scroll.offsets"
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.numberOfLines = 2
        for child in [reset, reorder, status] { view.addSubview(child) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let frame = view.bounds.inset(by: view.safeAreaInsets)
        let width = frame.width
        reset.frame = CGRect(x: frame.minX, y: frame.minY, width: width / 2, height: 40)
        reorder.frame = CGRect(x: frame.midX, y: frame.minY, width: width / 2, height: 40)
        status.frame = CGRect(x: frame.minX + 8, y: frame.minY + 42, width: width - 16, height: 36)
        let top = frame.minY + 82
        let height = max(140, frame.height - 94)
        left.frame = CGRect(x: frame.minX + 8, y: top, width: width * 0.40 - 12, height: height * 0.72)
        right.frame = CGRect(x: frame.minX + width * 0.40 + 4, y: top, width: width * 0.60 - 12, height: height)
        strip.frame = CGRect(x: 0, y: 0, width: left.bounds.width, height: 70)
        recordState()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 40 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .default, reuseIdentifier: "row")
        let name = tableView === left ? "left" : "right"
        let index = reversed ? 39 - indexPath.row : indexPath.row
        // Repeated native labels coexist with stable accessibility identifiers.
        cell.textLabel?.text = "Row \(index % 4)"
        cell.accessibilityIdentifier = "fixture.\(name).row.\(index)"
        return cell
    }

    @objc private func resetScrolls() {
        selected = ""
        left.setContentOffset(.zero, animated: false)
        right.setContentOffset(.zero, animated: false)
        strip.setContentOffset(.zero, animated: false)
        recordState()
    }

    @objc private func reorderRows() {
        reversed.toggle()
        left.reloadData()
        right.reloadData()
        recordState()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { recordState() }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let index = reversed ? 39 - indexPath.row : indexPath.row
        selected = "\(tableView === left ? "left" : "right").\(index)"
        recordState()
    }

    private func recordState() {
        let state: [String: Any] = [
            "left": left.contentOffset.y,
            "right": right.contentOffset.y,
            "strip": strip.contentOffset.x,
            "reversed": reversed,
            "selected": selected,
        ]
        status.text = "Left \(Int(left.contentOffset.y)) Right \(Int(right.contentOffset.y))\nStrip \(Int(strip.contentOffset.x))"
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: directory.appendingPathComponent("scroll-state.json"), options: .atomic)
        }
    }
}
