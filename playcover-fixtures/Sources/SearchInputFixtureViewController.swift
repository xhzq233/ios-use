import UIKit

// Opt-in public reproduction for host UIKit search focus and accessibility.
// Normal fixture launch is unchanged; select via IOSUseFixtureSearchMode.
final class SearchInputFixtureViewController: UITableViewController, UISearchResultsUpdating, UISearchBarDelegate, UITextFieldDelegate {
    private let mode: String
    private let search = UISearchController(searchResultsController: nil)
    private let bar = UISearchBar()
    private let field = UITextField()
    private var events: [[String: Any]] = []

    init(mode: String) {
        self.mode = mode
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search Input Fixture"
        view.backgroundColor = .systemBackground
        definesPresentationContext = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Dismiss", style: .plain, target: self, action: #selector(dismissInput))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "fixture.search.dismiss"
        if mode == "field" {
            field.placeholder = "Search"
            field.borderStyle = .roundedRect
            field.accessibilityIdentifier = "fixture.search.input"
            field.autocorrectionType = .no
            field.delegate = self
            field.addTarget(self, action: #selector(textChanged), for: .editingChanged)
            field.frame = CGRect(x: 0, y: 0, width: 430, height: 56)
            tableView.tableHeaderView = field
        } else {
            let activeBar = mode == "bar" ? bar : search.searchBar
            activeBar.placeholder = "搜索"
            activeBar.searchTextField.accessibilityIdentifier = "fixture.search.input"
            activeBar.searchTextField.autocorrectionType = .no
            activeBar.searchTextField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
            activeBar.delegate = self
            if mode == "bar" {
                bar.frame = CGRect(x: 0, y: 0, width: 430, height: 56)
                tableView.tableHeaderView = bar
            } else {
                search.obscuresBackgroundDuringPresentation = false
                search.hidesNavigationBarDuringPresentation = false
                search.searchResultsUpdater = self
                navigationItem.searchController = search
                navigationItem.hidesSearchBarWhenScrolling = false
            }
        }
        NSSetUncaughtExceptionHandler { exception in
            let data: [String: Any] = ["name": exception.name.rawValue, "reason": exception.reason ?? "", "stack": exception.callStackSymbols]
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("search-exception.json")
            if let encoded = try? JSONSerialization.data(withJSONObject: data, options: .prettyPrinted) { try? encoded.write(to: url) }
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        record("appeared")
    }
    @objc private func textChanged() { record("editingChanged") }
    @objc private func dismissInput() {
        view.endEditing(true)
        search.isActive = false
        record("dismissed")
    }
    func updateSearchResults(for searchController: UISearchController) { record("searchResults") }
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) { record("searchBegin") }
    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) { record("searchEnd") }
    func textFieldDidBeginEditing(_ textField: UITextField) { record("fieldBegin") }
    func textFieldDidEndEditing(_ textField: UITextField) { record("fieldEnd") }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 12 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = "Search row \(indexPath.row)"
        cell.accessibilityIdentifier = "fixture.search.row.\(indexPath.row)"
        return cell
    }
    private func record(_ event: String) {
        guard let window = view.window else { return }
        var responders: [String] = []
        func visit(_ view: UIView) {
            if view.isFirstResponder { responders.append(NSStringFromClass(type(of: view))) }
            view.subviews.forEach(visit)
        }
        visit(window)
        let control = mode == "field" ? field : (mode == "bar" ? bar.searchTextField : search.searchBar.searchTextField)
        let data: [String: Any] = ["event": event, "text": control.text ?? "", "firstResponders": responders,
                                 "inputIsFirstResponder": control.isFirstResponder, "inputClass": NSStringFromClass(type(of: control)), "searchActive": search.isActive]
        events.append(data)
        let state: [String: Any] = ["mode": mode, "latest": data, "events": events]
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("search-state.json")
        if let encoded = try? JSONSerialization.data(withJSONObject: state, options: .prettyPrinted) { try? encoded.write(to: url, options: .atomic) }
    }
}
