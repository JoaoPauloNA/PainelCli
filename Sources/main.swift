import AppKit

private enum Screen { case home, settings }
private enum SettingsSection { case add, cliProxy }
private enum CLIPackageCatalog {
    static let candidates = CLIProvider.allCases
}

private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                   color: NSColor = .labelColor) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.font = .systemFont(ofSize: size, weight: weight)
    view.textColor = color
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

// Semantic AppKit colors are resolved while drawing, including appearance changes.
private final class Surface: NSView {
    let fill: NSColor
    let radius: CGFloat
    init(_ fill: NSColor, radius: CGFloat = 0) {
        self.fill = fill
        self.radius = radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class TopAlignedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private func navigationMaterial() -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
}

private enum CLIListItem {
    case detected(CLIAutomaticInstallation)
    case manual(CLIEntry)

    var id: UUID {
        switch self { case .detected(let item): return item.id; case .manual(let item): return item.id }
    }
    var displayName: String {
        switch self { case .detected(let item): return item.displayName; case .manual(let item): return item.displayName }
    }
    var provider: String {
        switch self { case .detected(let item): return item.target.rawValue; case .manual(let item): return item.provider }
    }
    var manualEntry: CLIEntry? {
        if case .manual(let entry) = self { return entry }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var contentView: NSView!
    private var settingsButton: NSButton!
    private var catalogWindow: NSWindow?
    private var catalogStatusLabel: NSTextField?
    private var selectedSettingsSection: SettingsSection = .add
    private var entryStore: CLIEntryStore?
    private var installService: CLIInstallService?
    private var entries: [CLIEntry] = []
    private var detections: [CLIDiscovery] = []
    private var automaticInstallations: [CLIAutomaticInstallation] = []
    private var migrationNotice: String?
    private var installingRegistrationIDs = Set<UUID>()
    private var installationFailures: [UUID: String] = [:]
    private var listItems: [CLIListItem] {
        automaticInstallations.map(CLIListItem.detected) + entries.map(CLIListItem.manual)
    }
    private var storageLoadFailed = false

    private func navigationButton(_ title: String, symbol: String, action: Selector,
                                  selected: Bool) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol,
                              accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .left
        button.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        button.bezelStyle = .inline
        button.setButtonType(.pushOnPushOff)
        button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        button.state = selected ? .on : .off
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        button.setAccessibilityValue(selected ? "Selecionado" : "")
        return button
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let store = try CLIEntryStore.userStore()
            entryStore = store
            entries = try store.load()
            installService = try CLIInstallService.userService()
            refreshCLIEntries()
        } catch {
            storageLoadFailed = true
        }

        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Sair do PainelCli", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let root = NSMenuItem()
        root.submenu = appMenu
        menu.addItem(root)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "PainelCli"
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.titlebarSeparatorStyle = .automatic
        window.backgroundColor = .windowBackgroundColor

        let rootView = NSView()
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        contentView = Surface(.windowBackgroundColor)
        rootView.addSubview(sidebar)
        rootView.addSubview(contentView)
        let divider = Surface(.separatorColor)
        rootView.addSubview(divider)

        let appIcon = NSImageView()
        appIcon.image = NSImage(named: NSImage.applicationIconName)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        appIcon.setAccessibilityElement(false)
        let appTitle = label("PainelCli", size: 15, weight: .semibold)
        let sectionTitle = label("Geral", size: 11, weight: .semibold, color: .secondaryLabelColor)
        settingsButton = navigationButton("Configurações", symbol: "gearshape", action: #selector(showSettings), selected: false)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let footer = label("Versão \(version)", size: 11, color: .secondaryLabelColor)
        [appIcon, appTitle, sectionTitle, settingsButton!, footer].forEach { sidebar.addSubview($0) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 184),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: rootView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: rootView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            appIcon.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            appIcon.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 20),
            appIcon.widthAnchor.constraint(equalToConstant: 36),
            appIcon.heightAnchor.constraint(equalToConstant: 36),
            appTitle.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 8),
            appTitle.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
            sectionTitle.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            sectionTitle.topAnchor.constraint(equalTo: appIcon.bottomAnchor, constant: 28),
            settingsButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            settingsButton.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            settingsButton.topAnchor.constraint(equalTo: sectionTitle.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16)
        ])
        window.contentView = rootView
        window.center()
        render(.home)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "PainelCli")
        let statusMenu = NSMenu()
        let openItem = statusMenu.addItem(withTitle: "Abrir janela", action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = statusMenu
        openWindow()
    }

    private func render(_ screen: Screen) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        switch screen {
        case .home:
            settingsButton.state = .off
            let title = label("PainelCli", size: 26, weight: .semibold)
            contentView.addSubview(title)
            NSLayoutConstraint.activate([
                title.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                title.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
            ])
        case .settings:
            settingsButton.state = .on
            settingsButton.setAccessibilityValue("Selecionado")
            renderSettings()
        }
    }

    private func renderSettings() {
        let navigation = navigationMaterial()
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        let divider = Surface(.separatorColor)
        [navigation, body, divider].forEach { contentView.addSubview($0) }
        let heading = label("Configurações", size: 14, weight: .semibold)
        let add = navigationButton("Adicionar", symbol: "plus.square", action: #selector(showAddCLICatalog),
                                   selected: selectedSettingsSection == .add)
        let proxy = navigationButton("CLIProxy", symbol: "network", action: #selector(showCLIProxy),
                                     selected: selectedSettingsSection == .cliProxy)
        [heading, add, proxy].forEach { navigation.addSubview($0) }
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            navigation.topAnchor.constraint(equalTo: contentView.topAnchor),
            navigation.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            navigation.widthAnchor.constraint(equalToConstant: 172),
            divider.leadingAnchor.constraint(equalTo: navigation.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: contentView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            body.topAnchor.constraint(equalTo: contentView.topAnchor),
            body.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            heading.leadingAnchor.constraint(equalTo: navigation.leadingAnchor, constant: 16),
            heading.topAnchor.constraint(equalTo: navigation.topAnchor, constant: 24),
            add.leadingAnchor.constraint(equalTo: navigation.leadingAnchor, constant: 10),
            add.trailingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: -10),
            add.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            proxy.leadingAnchor.constraint(equalTo: add.leadingAnchor),
            proxy.trailingAnchor.constraint(equalTo: add.trailingAnchor),
            proxy.topAnchor.constraint(equalTo: add.bottomAnchor, constant: 6)
        ])
        guard selectedSettingsSection == .add else { return }
        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Abrir catálogo de CLIs")!,
                                 target: self, action: #selector(openCLICatalog))
        addButton.bezelStyle = .rounded
        addButton.toolTip = "Abrir catálogo de CLIs"
        addButton.setAccessibilityLabel("Abrir catálogo de CLIs")
        addButton.translatesAutoresizingMaskIntoConstraints = false
        let title = label("Suas CLIs", size: 22, weight: .semibold)
        body.addSubview(title)
        body.addSubview(addButton)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            title.topAnchor.constraint(equalTo: body.topAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -16),
            addButton.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            addButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 36),
            addButton.heightAnchor.constraint(equalToConstant: 32)
        ])
        renderEntryList(in: body)
    }

    private func cliSymbol() -> NSImage? {
        NSImage(systemSymbolName: "terminal", accessibilityDescription: "CLI")
    }

    // Native identification cues, not provider logos. Public builds distribute no third-party marks.
    private func detectedAppearance(for target: CLIDiscoveryTarget) -> (NSImage?, NSColor) {
        let symbol: String
        let tint: NSColor
        switch target {
        case .codex:
            symbol = "chevron.left.forwardslash.chevron.right"
            tint = .systemBlue
        case .claude:
            symbol = "text.bubble"
            tint = .systemOrange
        case .gemini:
            symbol = "sparkles"
            tint = .systemPurple
        case .antigravity:
            symbol = "arrow.up.circle"
            tint = .systemTeal
        }
        return (NSImage(systemSymbolName: symbol, accessibilityDescription: target.displayName) ?? cliSymbol(), tint)
    }

    // Presentation only. The caller owns availability, target/action, and isolated-install rules.
    private func makeInstallButton(displayName: String, tag: Int) -> NSButton {
        let button = NSButton(title: "Instalar",
                              image: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil) ?? NSImage(),
                              target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.tag = tag
        button.setAccessibilityLabel("Instalar \(displayName)")
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func renderEntryList(in body: NSView) {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let document = TopAlignedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        body.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -24),
            scrollView.topAnchor.constraint(equalTo: body.topAnchor, constant: 76),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -24),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        if let migrationNotice {
            let notice = NSTextField(wrappingLabelWithString: migrationNotice)
            notice.font = .systemFont(ofSize: 12)
            notice.textColor = .secondaryLabelColor
            stack.addArrangedSubview(notice)
            notice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        if storageLoadFailed || listItems.isEmpty {
            let message = storageLoadFailed
                ? "Não foi possível carregar os registros salvos. O arquivo foi preservado e novos registros estão indisponíveis."
                : "Nenhuma CLI adicionada. Use + para escolher no catálogo."
            let notice = NSTextField(wrappingLabelWithString: message)
            notice.font = .systemFont(ofSize: 13)
            notice.textColor = .secondaryLabelColor
            stack.addArrangedSubview(notice)
            notice.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            for (index, entry) in listItems.enumerated() {
                if index == 0 || (index == automaticInstallations.count && !entries.isEmpty) {
                    let section = NSView()
                    section.translatesAutoresizingMaskIntoConstraints = false
                    let sectionName = label(entry.manualEntry == nil ? "Instalações detectadas" : "Cadastros manuais",
                                            size: 11, weight: .semibold, color: .secondaryLabelColor)
                    section.addSubview(sectionName)
                    NSLayoutConstraint.activate([
                        section.heightAnchor.constraint(equalToConstant: 32),
                        sectionName.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 4),
                        sectionName.centerYAnchor.constraint(equalTo: section.centerYAnchor)
                    ])
                    stack.addArrangedSubview(section)
                    section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
                let row = NSView()
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: 56).isActive = true
                let icon = NSImageView()
                if case .detected(let installation) = entry {
                    let appearance = detectedAppearance(for: installation.target)
                    icon.image = appearance.0
                    icon.contentTintColor = appearance.1
                } else if let target = CLIDiscoveryTarget(rawValue: entry.provider) {
                    let appearance = detectedAppearance(for: target)
                    icon.image = appearance.0
                    icon.contentTintColor = appearance.1
                } else {
                    icon.image = cliSymbol()
                    icon.contentTintColor = .secondaryLabelColor
                }
                icon.imageScaling = .scaleProportionallyUpOrDown
                icon.setAccessibilityElement(false)
                let origin = NSImageView()
                let originSymbol: String
                let originDescription: String
                switch entry {
                case .detected(let installation):
                    originSymbol = installation.isManaged ? "app" : "desktopcomputer"
                    originDescription = installation.isManaged ? "CLI instalada pelo PainelCli" : "CLI encontrada na máquina"
                case .manual:
                    originSymbol = "app"
                    originDescription = "Cadastro manual no PainelCli"
                }
                origin.image = NSImage(systemSymbolName: originSymbol, accessibilityDescription: originDescription)
                origin.imageScaling = .scaleProportionallyUpOrDown
                origin.contentTintColor = .secondaryLabelColor
                origin.toolTip = originDescription
                origin.setAccessibilityLabel(originDescription)
                let name = label(entry.displayName, size: 13, weight: .medium)
                let statusText = listStatus(for: entry)
                let compactStatus: String
                if entry.manualEntry == nil && statusText.hasPrefix("Encontrada") {
                    compactStatus = "Encontrada no sistema"
                } else if entry.manualEntry == nil && statusText.hasPrefix("Instalada") {
                    compactStatus = "Instalada pelo PainelCli"
                } else {
                    compactStatus = statusText
                }
                let status = label(compactStatus, size: 11, color: .secondaryLabelColor)
                status.isHidden = entry.manualEntry == nil
                name.toolTip = statusText
                name.setAccessibilityHelp(statusText)
                status.lineBreakMode = .byTruncatingTail
                status.maximumNumberOfLines = 1
                status.toolTip = statusText
                row.toolTip = statusText
                status.setAccessibilityValue(statusText)
                status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                name.lineBreakMode = .byTruncatingTail
                name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

                let actions = NSStackView()
                actions.orientation = .horizontal
                actions.alignment = .centerY
                actions.spacing = 8
                actions.translatesAutoresizingMaskIntoConstraints = false

                let account = NSButton(image: NSImage(systemSymbolName: "person.crop.circle",
                                                       accessibilityDescription: nil)!,
                                       target: nil, action: nil)
                account.bezelStyle = .inline
                account.isBordered = false
                account.tag = index
                let isManualEntry = entry.manualEntry != nil
                account.isEnabled = false
                account.contentTintColor = .disabledControlTextColor
                account.toolTip = "Login indisponível até haver perfil isolado por cadastro"
                account.setAccessibilityLabel("Login indisponível para \(entry.displayName)")
                account.setAccessibilityValue("Perfil isolado por cadastro não disponível")
                account.translatesAutoresizingMaskIntoConstraints = false
                actions.addArrangedSubview(account)
                account.widthAnchor.constraint(equalToConstant: 28).isActive = true
                account.heightAnchor.constraint(equalToConstant: 28).isActive = true

                let remove = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: nil)!,
                                      target: self, action: #selector(removeCLI(_:)))
                remove.bezelStyle = .inline
                remove.isBordered = false
                remove.tag = index
                remove.isEnabled = isManualEntry && !storageLoadFailed &&
                    entry.manualEntry.map { !installingRegistrationIDs.contains($0.id) } == true
                remove.contentTintColor = remove.isEnabled ? .systemRed : .disabledControlTextColor
                remove.toolTip = isManualEntry
                    ? "Remover \(entry.displayName) da lista"
                    : "Instalações detectadas não podem ser removidas daqui"
                remove.setAccessibilityLabel(isManualEntry
                    ? "Remover \(entry.displayName) da lista"
                    : "Remoção indisponível para instalação detectada \(entry.displayName)")
                remove.setAccessibilityValue(isManualEntry ? "Disponível" : "Inativo")
                remove.translatesAutoresizingMaskIntoConstraints = false
                actions.addArrangedSubview(remove)
                remove.widthAnchor.constraint(equalToConstant: 28).isActive = true
                remove.heightAnchor.constraint(equalToConstant: 28).isActive = true

                [icon, origin, name, status, actions].forEach {
                    $0.translatesAutoresizingMaskIntoConstraints = false
                    row.addSubview($0)
                }
                let textTrailing = actions.leadingAnchor
                if let manualEntry = entry.manualEntry,
                   manualEntry.provider == CLIProvider.codex.rawValue {
                    let install = makeInstallButton(displayName: entry.displayName, tag: index)
                    let state = registrationInstallState(for: manualEntry)
                    install.target = self
                    install.action = #selector(installCLI(_:))
                    install.isEnabled = canInstall(manualEntry)
                    install.contentTintColor = install.isEnabled ? .controlAccentColor : .disabledControlTextColor
                    install.toolTip = state.displayText
                    install.setAccessibilityLabel("Instalar \(entry.displayName)")
                    install.setAccessibilityValue(state.displayText)
                    install.translatesAutoresizingMaskIntoConstraints = false
                    actions.insertArrangedSubview(install, at: 0)
                    install.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
                    install.heightAnchor.constraint(equalToConstant: 28).isActive = true
                }
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                row.addSubview(separator)
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
                    icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 20),
                    icon.heightAnchor.constraint(equalToConstant: 20),
                    origin.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                    origin.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
                    origin.widthAnchor.constraint(equalToConstant: 16),
                    origin.heightAnchor.constraint(equalToConstant: 16),
                    name.leadingAnchor.constraint(equalTo: origin.trailingAnchor, constant: 10),
                    entry.manualEntry == nil
                        ? name.centerYAnchor.constraint(equalTo: row.centerYAnchor)
                        : name.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
                    name.trailingAnchor.constraint(lessThanOrEqualTo: textTrailing, constant: -12),
                    status.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                    status.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
                    status.trailingAnchor.constraint(equalTo: textTrailing, constant: -12),
                    actions.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
                    actions.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    separator.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                    separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                    separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                    separator.heightAnchor.constraint(equalToConstant: 1)
                ])
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    private func listStatus(for item: CLIListItem) -> String {
        switch item {
        case .manual(let entry): return entryStatus(for: entry)
        case .detected(let installation):
            let status = installation.isManaged ? "Instalada pelo PainelCli" : "Encontrada no sistema"
            let note = installation.target == .gemini ? " · contas individuais não atendidas" : ""
            return "\(status) · \(displayLocation(installation.discoveryURL))\(note)"
        }
    }

    private func entryStatus(for entry: CLIEntry) -> String {
        if entry.provider == "GeminiCLI" {
            guard let detection = detections.first(where: { $0.target == .gemini }) else {
                return entry.statusText
            }
            return "Cadastro legado GeminiCLI · encontrada no sistema · \(displayLocation(detection.discoveryURL))"
        }
        return registrationInstallState(for: entry).displayText
    }

    private func registrationInstallState(for entry: CLIEntry) -> CLIRegistrationInstallStatus {
        if installingRegistrationIDs.contains(entry.id) { return .installing }
        if let message = installationFailures[entry.id] { return .failed(message) }
        return installService?.registrationInstallStatus(for: entry) ?? .unsupported
    }

    private func canInstall(_ entry: CLIEntry) -> Bool {
        guard !storageLoadFailed,
              entry.provider == CLIProvider.codex.rawValue,
              installService != nil,
              !installingRegistrationIDs.contains(entry.id) else { return false }
        return registrationInstallState(for: entry).canInstall
    }

    private func displayLocation(_ executable: URL) -> String {
        let home = NSHomeDirectory()
        if executable.path.hasPrefix(home + "/") {
            return "~" + String(executable.path.dropFirst(home.count))
        }
        if executable.path.contains("/Applications/ChatGPT.app/") { return "ChatGPT" }
        return executable.path
    }

    private func refreshCLIEntries() {
        guard !storageLoadFailed, let entryStore, let installService else { return }
        detections = installService.detectedInstallations()
        do {
            let snapshot = try entryStore.snapshot(discoveries: detections)
            entries = snapshot.manualRegistrations
            automaticInstallations = snapshot.detectedInstallations
            migrationNotice = snapshot.migrationNotice ?? migrationNotice
        } catch {
            storageLoadFailed = true
        }
    }

    @objc private func removeCLI(_ sender: NSButton) {
        guard !storageLoadFailed, let entryStore, listItems.indices.contains(sender.tag),
              let entry = listItems[sender.tag].manualEntry,
              !installingRegistrationIDs.contains(entry.id) else { return }
        let id = entry.id
        do {
            entries = try entryStore.remove(id: id)
            refreshCLIEntries()
            render(.settings)
        } catch {
            showStoreFailure("Não foi possível remover o registro. Os dados existentes foram preservados.")
        }
    }

    @objc private func installCLI(_ sender: NSButton) {
        guard !storageLoadFailed, let service = installService,
              listItems.indices.contains(sender.tag),
              let entry = listItems[sender.tag].manualEntry,
              entry.provider == CLIProvider.codex.rawValue,
              canInstall(entry),
              installingRegistrationIDs.insert(entry.id).inserted else { return }

        installationFailures.removeValue(forKey: entry.id)
        render(.settings)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<URL, Error>
            do { result = .success(try service.install(entry: entry)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.installingRegistrationIDs.remove(entry.id)
                if case .failure(let error) = result {
                    if let installError = error as? CLIInstallError {
                        self.installationFailures[entry.id] = installError.errorDescription ??
                            "A instalação não foi concluída."
                    } else {
                        self.installationFailures[entry.id] =
                            "Erro local ao preparar a instalação; nenhuma credencial foi usada."
                    }
                }
                self.refreshCLIEntries()
                self.render(.settings)
            }
        }
    }

    private func showStoreFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Falha ao salvar alterações"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func catalogRow(_ provider: CLIProvider, index: Int) -> NSView {
        let name = provider.catalogTitle
        let row = Surface(.quaternaryLabelColor.withAlphaComponent(0.07), radius: 10)
        let nameLabel = label(name, size: 14, weight: .semibold)
        let makerName: String
        switch provider {
        case .codex: makerName = "OpenAI"
        case .claude: makerName = "Anthropic"
        case .antigravity: makerName = "Google"
        }
        let maker = label(makerName, size: 12, color: .secondaryLabelColor)
        let icon = NSImageView()
        icon.image = cliSymbol()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        row.addSubview(icon)
        row.addSubview(nameLabel)
        row.addSubview(maker)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 72),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16),
            maker.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            maker.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4)
        ])
        let selectButton = NSButton(title: "", target: self, action: #selector(selectCatalogCandidate(_:)))
        selectButton.isBordered = false
        selectButton.tag = index
        selectButton.setAccessibilityLabel("Adicionar \(name) à lista")
        selectButton.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(selectButton, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            selectButton.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            selectButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            selectButton.topAnchor.constraint(equalTo: row.topAnchor),
            selectButton.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    @objc private func openCLICatalog() {
        guard catalogWindow == nil else { return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Catálogo de CLIs"
        panel.isReleasedWhenClosed = false
        let root = Surface(.windowBackgroundColor)
        let heading = label("Catálogo de CLIs", size: 22, weight: .semibold)
        let subtitle = label("CLIs no catálogo", size: 13, color: .secondaryLabelColor)
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        for (index, name) in CLIPackageCatalog.candidates.enumerated() {
            let row = catalogRow(name, index: index)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        let notice = NSTextField(wrappingLabelWithString: "Selecionar uma CLI cria um cadastro. Instalação e login ficam indisponíveis até haver isolamento real por cadastro.")
        notice.font = .systemFont(ofSize: 12)
        notice.textColor = .secondaryLabelColor
        notice.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(title: "Fechar", target: self, action: #selector(closeCLICatalog))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.translatesAutoresizingMaskIntoConstraints = false
        [heading, subtitle, rows, notice, close].forEach { root.addSubview($0) }
        catalogStatusLabel = notice
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            rows.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            rows.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            notice.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: rows.trailingAnchor),
            notice.topAnchor.constraint(equalTo: rows.bottomAnchor, constant: 16),
            close.trailingAnchor.constraint(equalTo: rows.trailingAnchor),
            close.topAnchor.constraint(greaterThanOrEqualTo: notice.bottomAnchor, constant: 16),
            close.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
            close.widthAnchor.constraint(greaterThanOrEqualToConstant: 76)
        ])
        panel.contentView = root
        catalogWindow = panel
        window.beginSheet(panel, completionHandler: nil)
    }

    @objc private func closeCLICatalog() {
        guard let catalogWindow else { return }
        window.endSheet(catalogWindow, returnCode: .OK)
        self.catalogWindow = nil
        catalogStatusLabel = nil
    }

    @objc private func selectCatalogCandidate(_ sender: NSButton) {
        guard CLIPackageCatalog.candidates.indices.contains(sender.tag) else { return }
        guard !storageLoadFailed, let entryStore else {
            showCatalogSaveFailure()
            return
        }
        let provider = CLIPackageCatalog.candidates[sender.tag]
        do {
            entries = try entryStore.add(provider: provider)
            refreshCLIEntries()
            closeCLICatalog()
            selectedSettingsSection = .add
            render(.settings)
        } catch {
            showCatalogSaveFailure()
        }
    }

    private func showCatalogSaveFailure() {
        catalogStatusLabel?.stringValue = "Não foi possível salvar o registro. Os dados existentes foram preservados."
        catalogStatusLabel?.textColor = .systemRed
    }
    @objc private func showSettings() {
        selectedSettingsSection = .add
        refreshCLIEntries()
        render(.settings)
    }
    @objc private func showAddCLICatalog() {
        selectedSettingsSection = .add
        refreshCLIEntries()
        render(.settings)
    }
    @objc private func showCLIProxy() {
        selectedSettingsSection = .cliProxy
        render(.settings)
    }
    @objc func openWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
