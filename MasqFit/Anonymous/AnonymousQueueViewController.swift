import UIKit

final class AnonymousQueueViewController: UITableViewController {
    private var observer: NSObjectProtocol?
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Submission queue"
        observer = NotificationCenter.default.addObserver(forName: AnonymousSubmissionStore.changed, object: nil, queue: .main) { [weak self] _ in self?.tableView.reloadData() }
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Retry", style: .plain, target: self, action: #selector(retry))
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    @objc private func retry() { AnonymousSubmissionStore.shared.retry(force: true); tableView.reloadData() }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, AnonymousSubmissionStore.shared.items.count) }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let store = AnonymousSubmissionStore.shared
        cell.detailTextLabel?.numberOfLines = 0
        if store.items.isEmpty {
            cell.textLabel?.text = "No submissions"
            cell.detailTextLabel?.text = store.storageError ?? "Only submissions you explicitly consent to appear here."
        } else {
            let item = store.items[indexPath.row]
            cell.textLabel?.text = item.state.capitalized + " · " + item.id.uuidString.prefix(8)
            cell.detailTextLabel?.text = store.storageError ?? item.message ?? "Saved on this phone."
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        let items = AnonymousSubmissionStore.shared.items
        return !items.isEmpty && items[indexPath.row].state != "sending"
    }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let item = AnonymousSubmissionStore.shared.items[indexPath.row]
        let alert = UIAlertController(title: "Remove from this phone?", message: "This removes the local queue item or receipt. It does not delete a contribution already received by BreatheSafe.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            do { try AnonymousSubmissionStore.shared.remove(item.id) }
            catch {
                let errorAlert = UIAlertController(title: "Could not remove item", message: error.localizedDescription, preferredStyle: .alert)
                errorAlert.addAction(UIAlertAction(title: "OK", style: .default)); self?.present(errorAlert, animated: true)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); present(alert, animated: true)
    }
}

final class AnonymousMaskPickerViewController: UITableViewController, UISearchBarDelegate {
    var importedName = ""
    var onSelect: ((Int?, String?, Bool) -> Void)?
    private var masks: [(Int, String)] = []
    private var task: URLSessionDataTask?
    private let session = URLSession(configuration: .ephemeral)
    private var search = ""
    private var page = 1
    private var hasMore = false
    private var suggestions = true
    private var requestID = UUID()
    private var status = ""
    private var loading = false
    private var failed = false
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Suggested matches"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Keep unresolved", style: .plain, target: self, action: #selector(unresolved))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Propose mask", style: .plain, target: self, action: #selector(propose))
        let bar = UISearchBar(); bar.placeholder = "Search other mask models"; bar.delegate = self
        search = importedName.trimmingCharacters(in: .whitespacesAndNewlines)
        bar.text = search
        bar.sizeToFit(); tableView.tableHeaderView = bar
        suggestions = !search.isEmpty
        load()
    }
    deinit { task?.cancel(); session.invalidateAndCancel() }
    @objc private func unresolved() { finish(nil, nil, false) }
    private func finish(_ id: Int?, _ name: String?, _ proposed: Bool) {
        requestID = UUID(); task?.cancel()
        dismiss(animated: true) { self.onSelect?(id, name, proposed) }
    }
    @objc private func propose() {
        let alert = UIAlertController(title: "Propose a new mask", message: "Enter the brand, model and size. Do not include names or event details. If you submit your contribution, an admin will review this mask and match it to the catalog or create an entry. Nothing is submitted yet.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Brand, model and size"; $0.text = self.importedName }
        let save = UIAlertAction(title: "Use proposed mask", style: .default) { [weak self, weak alert] _ in
            let name = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 200, name.rangeOfCharacter(from: .controlCharacters) == nil else { return }
            self?.finish(nil, name, true)
        }
        alert.addAction(save); alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // Validate while editing so an empty proposal cannot dismiss the dialog.
        let field = alert.textFields![0]
        field.addTarget(self, action: #selector(proposalNameChanged(_:)), for: .editingChanged)
        save.isEnabled = validName(field.text ?? "")
        present(alert, animated: true)
    }
    private func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 200 && name.rangeOfCharacter(from: .controlCharacters) == nil
    }
    @objc private func proposalNameChanged(_ field: UITextField) {
        (presentedViewController as? UIAlertController)?.actions.first?.isEnabled = validName(field.text ?? "")
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder(); search = String((searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        searchBar.text = search
        suggestions = !search.isEmpty; title = suggestions ? "Suggested matches" : "Catalog search"
        page = 1; masks = []; load()
    }
    private func load() {
        task?.cancel(); requestID = UUID()
        let currentRequest = requestID
        let route = suggestions ? "mask_suggestions" : "masks"
        var url = URLComponents(string: "https://www.breathesafe.xyz/anonymous_contributions/" + route)!
        url.queryItems = suggestions ? [URLQueryItem(name: "name", value: search)]
            : [URLQueryItem(name: "search", value: search), URLQueryItem(name: "page", value: String(page))]
        loading = true; failed = false; status = "Finding masks…"; tableView.reloadData()
        task = session.dataTask(with: url.url!) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, self.requestID == currentRequest else { return }
                self.loading = false
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rows = object["masks"] as? [[String: Any]] else {
                    self.status = "Catalog unavailable. Tap to retry, search again, or propose a mask for later review."
                    self.failed = true; self.hasMore = false; self.tableView.reloadData(); return
                }
                self.masks += rows.compactMap { row in
                    guard let id = row["id"] as? Int, let name = row["name"] as? String else { return nil }
                    return (id, name)
                }
                self.hasMore = object["has_more"] as? Bool ?? false
                self.status = self.hasMore ? "Load more" : "No correct match? Search above or propose a new mask."
                self.tableView.reloadData()
                if self.suggestions, self.presentedViewController == nil, self.view.window != nil, let best = self.masks.first { self.confirm(best) }
            }
        }; task?.resume()
    }
    private func confirm(_ mask: (Int, String)) {
        let alert = UIAlertController(title: "Is this the correct mask?", message: "Imported: \(importedName)\n\nCatalog: \(mask.1)\n\nCheck the model and size before confirming.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Yes, use this mask", style: .default) { [weak self] _ in self?.finish(mask.0, mask.1, false) })
        alert.addAction(UIAlertAction(title: "No, see other options", style: .cancel))
        present(alert, animated: true)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { masks.count + 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil); cell.textLabel?.numberOfLines = 0
        cell.textLabel?.text = indexPath.row < masks.count ? masks[indexPath.row].1 : status
        if suggestions && indexPath.row == 0 && !masks.isEmpty { cell.detailTextLabel?.text = "Best suggested match — tap to confirm" }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !loading else { return }
        if indexPath.row < masks.count { confirm(masks[indexPath.row]) }
        else if hasMore { page += 1; load() }
        else if failed { load() }
    }
}
