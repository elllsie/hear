import UIKit

final class WordPlayerViewController: UIViewController {
    private let segmented = UISegmentedControl(items: ["A1","A2","B1"])
    private let searchBar = UISearchBar()
    private let wordLabel = UILabel()
    private let phoneticLabel = UILabel()
    private let translationLabel = UILabel()
    private let exampleLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let prevButton = UIButton(type: .system)

    private var books: [WordBook] = []
    private var currentBook: WordBook?
    private var filteredWords: [Word] = []
    private var currentIndex: Int = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        loadBooks()
        AudioPlayerManager.shared.delegate = self
    }

    private func setupUI() {
        segmented.selectedSegmentIndex = 0
        segmented.addTarget(self, action: #selector(bookChanged), for: .valueChanged)
        searchBar.delegate = self

        wordLabel.font = .systemFont(ofSize: 28, weight: .bold)
        phoneticLabel.font = .systemFont(ofSize: 14, weight: .regular)
        translationLabel.font = .systemFont(ofSize: 18)
        exampleLabel.font = .systemFont(ofSize: 14)
        exampleLabel.numberOfLines = 0

        playButton.setTitle("Play", for: .normal)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        nextButton.setTitle("Next", for: .normal)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        prevButton.setTitle("Prev", for: .normal)
        prevButton.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)

        let controlStack = UIStackView(arrangedSubviews: [prevButton, playButton, nextButton])
        controlStack.axis = .horizontal
        controlStack.distribution = .fillEqually
        controlStack.spacing = 8

        let stack = UIStackView(arrangedSubviews: [segmented, searchBar, wordLabel, phoneticLabel, translationLabel, exampleLabel, controlStack])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16)
        ])
    }

    private func loadBooks() {
        books = DataLoader.loadBooks(named: ["A1","A2","B1"])
        if let first = books.first { selectBook(first) }
    }

    private func selectBook(_ book: WordBook) {
        currentBook = book
        filteredWords = book.words
        currentIndex = 0
        showCurrent()
    }

    private func showCurrent() {
        guard filteredWords.indices.contains(currentIndex) else {
            wordLabel.text = "--"
            translationLabel.text = ""
            phoneticLabel.text = ""
            exampleLabel.text = ""
            return
        }
        let w = filteredWords[currentIndex]
        wordLabel.text = w.word
        translationLabel.text = w.translation
        phoneticLabel.text = w.phonetic ?? ""
        exampleLabel.text = "例句: \(w.example ?? "无")"
        if let article = w.article, !article.isEmpty {
            wordLabel.text = "\(article) \(w.word)"
        }
        updateButtons()
    }

    private func updateButtons() {
        let title = AudioPlayerManager.shared.isPlaying ? "Pause" : "Play"
        playButton.setTitle(title, for: .normal)
    }

    @objc private func bookChanged() {
        let idx = segmented.selectedSegmentIndex
        guard books.indices.contains(idx) else { return }
        selectBook(books[idx])
    }

    @objc private func playTapped() {
        guard filteredWords.indices.contains(currentIndex) else { return }
        if AudioPlayerManager.shared.isPlaying {
            AudioPlayerManager.shared.pause()
        } else {
            let w = filteredWords[currentIndex]
            AudioPlayerManager.shared.play(word: w)
        }
        updateButtons()
    }

    @objc private func nextTapped() {
        currentIndex = min(filteredWords.count - 1, currentIndex + 1)
        showCurrent()
        let w = filteredWords[currentIndex]
        AudioPlayerManager.shared.play(word: w)
    }

    @objc private func prevTapped() {
        currentIndex = max(0, currentIndex - 1)
        showCurrent()
        let w = filteredWords[currentIndex]
        AudioPlayerManager.shared.play(word: w)
    }
}

// MARK: UISearchBarDelegate
extension WordPlayerViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard let book = currentBook else { return }
        if searchText.isEmpty {
            filteredWords = book.words
        } else {
            filteredWords = book.words.filter {
                $0.word.lowercased().contains(searchText.lowercased()) ||
                $0.translation.lowercased().contains(searchText.lowercased())
            }
        }
        currentIndex = 0
        showCurrent()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

// MARK: AudioPlayerManagerDelegate
extension WordPlayerViewController: AudioPlayerManagerDelegate {
    func audioPlayerManager(didStartPlaying itemDescription: String) {
        DispatchQueue.main.async { self.updateButtons() }
    }

    func audioPlayerManager(didFinishPlaying itemDescription: String) {
        DispatchQueue.main.async { self.updateButtons() }
    }

    func audioPlayerManager(didUpdateState isPlaying: Bool) {
        DispatchQueue.main.async { self.updateButtons() }
    }

    func audioPlayerManager(didEncounter error: Error) {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: "Playback Error", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(alert, animated: true)
        }
    }
}
