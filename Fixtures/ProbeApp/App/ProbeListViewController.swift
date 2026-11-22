import UIKit

/// The list probe (docs/probe-app.md#list-probe): shown instead of the touch
/// surface when the app is launched with `-ProbeList YES`. A table of sixty
/// rows and a strip of forty columns, both of which keep only the cells near
/// the screen, so a row further on has no accessibility element until the
/// list has moved: what `scroll --search` is for. Selecting a row or a column
/// is recorded in `probe.list.last`.
final class ProbeListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
                                     UICollectionViewDataSource, UICollectionViewDelegate {
    static var isRequested: Bool { UserDefaults.standard.bool(forKey: "ProbeList") }
    /// `-ProbeListStagger YES` (with `-ProbeList YES`): each row's element is
    /// a label of its own width at a leading inset that changes from row to
    /// row (`staggerInset`), so no two neighbouring rows share an edge.
    static var isStaggered: Bool { UserDefaults.standard.bool(forKey: "ProbeListStagger") }
    static func staggerInset(_ number: Int) -> CGFloat { CGFloat(16 + (number * 37) % 160) }
    static let rowCount = 60, columnCount = 40
    static let lastIdentifier = "probe.list.last"
    static func rowIdentifier(_ number: Int) -> String { "probe.list.row.\(number)" }
    static func columnIdentifier(_ number: Int) -> String { "probe.list.col.\(number)" }

    private let last = UILabel()
    private let table = UITableView(frame: .zero, style: .plain)
    private let strip: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 96, height: 52)
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        last.text = "Last: none"
        last.textAlignment = .center
        last.accessibilityIdentifier = Self.lastIdentifier
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        table.register(ProbeListStaggerCell.self, forCellReuseIdentifier: "stagger")
        strip.dataSource = self
        strip.delegate = self
        strip.register(ProbeListColumnCell.self, forCellWithReuseIdentifier: "column")
        strip.backgroundColor = .secondarySystemBackground
        for subview in [last, strip, table] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            last.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            last.leadingAnchor.constraint(equalTo: guide.leadingAnchor), last.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            last.heightAnchor.constraint(equalToConstant: 32),
            strip.topAnchor.constraint(equalTo: last.bottomAnchor, constant: 8),
            strip.leadingAnchor.constraint(equalTo: guide.leadingAnchor), strip.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 68),
            table.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: guide.leadingAnchor), table.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
    }

    private func record(_ what: String) {
        last.text = "Last: \(what)"
        last.accessibilityValue = what
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Self.rowCount }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if Self.isStaggered {
            let cell = tableView.dequeueReusableCell(withIdentifier: "stagger", for: indexPath)
            (cell as? ProbeListStaggerCell)?.show(indexPath.row + 1)
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = "Row \(indexPath.row + 1)"
        cell.contentConfiguration = content
        cell.accessibilityLabel = content.text
        cell.accessibilityIdentifier = Self.rowIdentifier(indexPath.row + 1)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        record("row-\(indexPath.row + 1)")
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { Self.columnCount }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "column", for: indexPath)
        (cell as? ProbeListColumnCell)?.show(indexPath.item + 1)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        record("col-\(indexPath.item + 1)")
    }
}

/// A staggered row: the cell is not an element; its label is, sized to its
/// text and placed at the row's own inset, so rows share no edge.
final class ProbeListStaggerCell: UITableViewCell {
    private let title = UILabel()
    private var leading: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        isAccessibilityElement = false
        title.isAccessibilityElement = true
        title.accessibilityTraits = .button
        title.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(title)
        let leading = title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        self.leading = leading
        NSLayoutConstraint.activate([leading, title.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ number: Int) {
        title.text = String(repeating: "·", count: number % 4) + "Row \(number)"
        title.accessibilityLabel = "Row \(number)"
        title.accessibilityIdentifier = ProbeListViewController.rowIdentifier(number)
        leading?.constant = ProbeListViewController.staggerInset(number)
    }
}

/// One column of the strip: a button-trait element named by its number.
final class ProbeListColumnCell: UICollectionViewCell {
    private let title = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.textAlignment = .center
        title.frame = contentView.bounds
        title.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(title)
        contentView.backgroundColor = .tertiarySystemBackground
        contentView.layer.cornerRadius = 12
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ number: Int) {
        title.text = "Col \(number)"
        accessibilityLabel = title.text
        accessibilityIdentifier = ProbeListViewController.columnIdentifier(number)
    }
}
