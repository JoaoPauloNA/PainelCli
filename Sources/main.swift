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
    private var authenticationStates: [UUID: CLIAuthenticationUIState] = [:]
    private var authenticationProcesses: [UUID: Process] = [:]
    private var checkingAuthenticationIDs = Set<UUID>()
    private var cancelledAuthenticationIDs = Set<UUID>()
    private var activeLogoutIDs = Set<UUID>()
    private var activeRemovalIDs = Set<UUID>()
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
        refreshAuthenticationStatuses()
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

    // Visual normalization only: never changes enabled state, tag, target, or action.
    private func applyActionAppearance(_ button: NSButton) {
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = button.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    }

    // Presentation only. The caller owns availability, target/action, and isolated-install rules.
    private func makeInstallButton(displayName: String, tag: Int) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "arrow.down.circle",
                                             accessibilityDescription: "Instalar \(displayName)") ?? NSImage(),
                              target: nil, action: nil)
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.tag = tag
        button.setAccessibilityLabel("Instalar \(displayName)")
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func makeInstallationProgress() -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.toolTip = "Instalação ou desinstalação em andamento"
        progress.setAccessibilityLabel("Operação do pacote em andamento")
        progress.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(progress)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: 28),
            slot.heightAnchor.constraint(equalToConstant: 28),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
            progress.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: slot.centerYAnchor)
        ])
        progress.startAnimation(nil)
        return slot
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
                let isAntigravityManual = entry.manualEntry?.provider == CLIProvider.antigravity.rawValue
                let managedRegistration = entry.manualEntry.flatMap {
                    ($0.provider == CLIProvider.codex.rawValue || $0.provider == CLIProvider.claude.rawValue) ? $0 : nil
                }
                let authState = managedRegistration.map { authenticationUIState(for: $0) }
                let canCancelLogin = managedRegistration.map {
                    isAuthenticationRunningState(authenticationUIState(for: $0)) &&
                    authenticationProcesses[$0.id]?.isRunning == true
                } ?? false
                let canStartLogin = managedRegistration.map { canStartAuthentication(for: $0) } ?? false
                let installState = managedRegistration.map { registrationInstallState(for: $0) }
                let isAuthenticated = authState == .authenticated
                account.target = managedRegistration == nil ? nil : self
                account.action = managedRegistration == nil ? nil :
                    (isAuthenticated ? #selector(logoutCLI(_:)) : #selector(loginCLI(_:)))
                account.isEnabled = !isAntigravityManual && managedRegistration != nil && !storageLoadFailed &&
                    (managedRegistration.map { !activeRemovalIDs.contains($0.id) } ?? true) &&
                    (canCancelLogin || (installState == .installed && (isAuthenticated || canStartLogin)))
                account.contentTintColor = account.isEnabled
                    ? ((canCancelLogin || isAuthenticated) ? .systemOrange : .systemGreen)
                    : .disabledControlTextColor
                if canCancelLogin {
                    account.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Cancelar login")
                    account.toolTip = "Cancelar login deste cadastro"
                    account.setAccessibilityLabel("Cancelar login de \(entry.displayName)")
                } else if isAuthenticated {
                    account.image = NSImage(systemSymbolName: "power",
                                            accessibilityDescription: "Sair")
                    account.toolTip = "Sair deste cadastro e limpar as credenciais locais. Isso não revoga a sessão remotamente."
                    account.setAccessibilityLabel("Sair de \(entry.displayName)")
                } else if isAntigravityManual {
                    account.toolTip = "Login do Antigravity está fora desta etapa; nenhum status de conta é consultado nem simulado."
                    account.setAccessibilityLabel("Login indisponível nesta etapa para \(entry.displayName)")
                } else if case .statusError = authState {
                    account.image = NSImage(systemSymbolName: "exclamationmark.circle",
                                            accessibilityDescription: "Estado do login indeterminado")
                    account.toolTip = "Não foi possível confirmar o estado do login. Atualize a verificação antes de entrar ou sair."
                    account.setAccessibilityLabel("Estado do login indeterminado em \(entry.displayName)")
                } else if installState != .installed {
                    account.toolTip = "Instale este cadastro para verificar ou alterar seu login; dados locais existentes são preservados."
                    account.setAccessibilityLabel("Login indisponível enquanto \(entry.displayName) não está instalado")
                } else {
                    account.toolTip = managedRegistration == nil
                        ? "Login disponível somente para um CLI instalado neste cadastro"
                        : "Entrar pelo navegador neste cadastro"
                    account.setAccessibilityLabel(managedRegistration == nil
                        ? "Login indisponível para \(entry.displayName)"
                        : "Entrar pelo navegador em \(entry.displayName)")
                }
                account.setAccessibilityValue(isAntigravityManual
                    ? "Login indisponível nesta etapa"
                    : (authState?.displayText ?? "Login indisponível"))
                applyActionAppearance(account)
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
                    entry.manualEntry.map {
                        !installingRegistrationIDs.contains($0.id) &&
                        !activeLogoutIDs.contains($0.id) &&
                        !activeRemovalIDs.contains($0.id) &&
                        !checkingAuthenticationIDs.contains($0.id) &&
                        !isAuthenticationRunningState(authenticationUIState(for: $0)) &&
                        authenticationProcesses[$0.id]?.isRunning != true
                    } == true
                remove.contentTintColor = remove.isEnabled ? .systemRed : .disabledControlTextColor
                remove.toolTip = isManualEntry
                    ? (entry.manualEntry?.provider == CLIProvider.codex.rawValue
                        ? "Remover \(entry.displayName) e apagar definitivamente os dados locais deste UUID"
                        : "Remover definitivamente o cadastro \(entry.displayName)")
                    : "Instalações detectadas não podem ser removidas daqui"
                remove.setAccessibilityLabel(isManualEntry
                    ? "Remover definitivamente o cadastro e os dados de \(entry.displayName)"
                    : "Remoção indisponível para instalação detectada \(entry.displayName)")
                remove.setAccessibilityValue(remove.isEnabled ? "Disponível" : "Inativo")
                applyActionAppearance(remove)
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
                   manualEntry.provider == CLIProvider.codex.rawValue ||
                    manualEntry.provider == CLIProvider.claude.rawValue ||
                    manualEntry.provider == CLIProvider.antigravity.rawValue {
                    let install = makeInstallButton(displayName: entry.displayName, tag: index)
                    let state = registrationInstallState(for: manualEntry)
                    let isInstalled = state == .installed
                    let providerName = CLIProvider(rawValue: manualEntry.provider)?.catalogTitle ?? manualEntry.provider
                    let actionSymbol: String
                    if isInstalled {
                        actionSymbol = "shippingbox"
                    } else if state == .incomplete {
                        actionSymbol = "exclamationmark.triangle"
                    } else {
                        actionSymbol = "arrow.down.circle"
                    }
                    install.image = NSImage(systemSymbolName: actionSymbol,
                                            accessibilityDescription: isInstalled ? "Desinstalar" : "Instalar")
                    install.target = self
                    install.action = isInstalled ? #selector(uninstallCLI(_:)) : #selector(installCLI(_:))
                    install.isEnabled = !storageLoadFailed && (isInstalled
                        ? canUninstall(manualEntry)
                        : canInstall(manualEntry))
                    install.contentTintColor = install.isEnabled
                        ? (isInstalled ? .systemOrange : .controlAccentColor) : .disabledControlTextColor
                    if isInstalled, manualEntry.provider == CLIProvider.claude.rawValue {
                        install.toolTip = "Sair deste cadastro e remover o pacote Claude; configurações e histórico ficam para reinstalação."
                    } else if isInstalled, manualEntry.provider == CLIProvider.antigravity.rawValue {
                        install.toolTip = "Desinstalar somente o binário Antigravity deste UUID; login não é iniciado nesta etapa."
                    } else {
                        install.toolTip = isInstalled
                            ? "Desinstalar somente o pacote gerenciado. Configuração, histórico e credenciais locais serão preservados."
                            : state.displayText
                    }
                    install.setAccessibilityLabel(isInstalled
                        ? "Desinstalar \(providerName) gerenciado de \(entry.displayName)"
                        : "Instalar \(providerName) em \(entry.displayName)")
                    install.setAccessibilityValue(state.displayText)
                    applyActionAppearance(install)
                    install.translatesAutoresizingMaskIntoConstraints = false
                    actions.insertArrangedSubview(install, at: 0)
                    install.widthAnchor.constraint(equalToConstant: 28).isActive = true
                    install.heightAnchor.constraint(equalToConstant: 28).isActive = true
                    install.isHidden = state == .installing
                    if state == .installing {
                        actions.insertArrangedSubview(makeInstallationProgress(), at: 0)
                    }
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
        let installState = registrationInstallState(for: entry)
        if entry.provider == CLIProvider.antigravity.rawValue {
            return installState == .installed
                ? "Instalada neste UUID · login indisponível nesta etapa"
                : installState.displayText
        }
        guard installState == .installed else { return installState.displayText }
        return authenticationUIState(for: entry).displayText
    }

    private func authenticationUIState(for entry: CLIEntry) -> CLIAuthenticationUIState {
        authenticationStates[entry.id] ?? (checkingAuthenticationIDs.contains(entry.id) ? .checking : .notAuthenticated)
    }

    private func canStartAuthentication(for entry: CLIEntry) -> Bool {
        guard (entry.provider == CLIProvider.codex.rawValue || entry.provider == CLIProvider.claude.rawValue),
              installService?.registrationInstallStatus(for: entry) == .installed,
              !activeRemovalIDs.contains(entry.id),
              !checkingAuthenticationIDs.contains(entry.id),
              authenticationProcesses[entry.id]?.isRunning != true else { return false }
        switch authenticationUIState(for: entry) {
        case .notAuthenticated, .failed, .cancelled: return true
        case .checking, .starting, .awaitingBrowserAuthorization, .awaitingClaudeBrowser,
             .loggingOut, .authenticated, .statusError: return false
        }
    }

    private func isAuthenticationRunningState(_ state: CLIAuthenticationUIState) -> Bool {
        switch state {
        case .starting, .awaitingBrowserAuthorization, .awaitingClaudeBrowser, .loggingOut: return true
        case .checking, .notAuthenticated, .authenticated, .failed, .statusError, .cancelled: return false
        }
    }

    private func registrationInstallState(for entry: CLIEntry) -> CLIRegistrationInstallStatus {
        if installingRegistrationIDs.contains(entry.id) { return .installing }
        let actual = installService?.registrationInstallStatus(for: entry) ?? .unsupported
        if actual == .notInstalled, let message = installationFailures[entry.id] { return .failed(message) }
        return actual
    }

    private func canInstall(_ entry: CLIEntry) -> Bool {
        guard !storageLoadFailed,
              entry.provider == CLIProvider.codex.rawValue || entry.provider == CLIProvider.claude.rawValue ||
                entry.provider == CLIProvider.antigravity.rawValue,
              installService != nil,
              !installingRegistrationIDs.contains(entry.id),
              !activeLogoutIDs.contains(entry.id),
              !activeRemovalIDs.contains(entry.id) else { return false }
        return registrationInstallState(for: entry).canInstall
    }

    private func canUninstall(_ entry: CLIEntry) -> Bool {
        guard !storageLoadFailed,
              entry.provider == CLIProvider.codex.rawValue || entry.provider == CLIProvider.claude.rawValue ||
                entry.provider == CLIProvider.antigravity.rawValue,
              !installingRegistrationIDs.contains(entry.id),
              !activeLogoutIDs.contains(entry.id),
              !activeRemovalIDs.contains(entry.id),
              !checkingAuthenticationIDs.contains(entry.id),
              authenticationProcesses[entry.id]?.isRunning != true else { return false }
        return registrationInstallState(for: entry) == .installed
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

    private func refreshAuthenticationStatuses() {
        guard let service = installService else { return }
        for entry in entries where entry.provider == CLIProvider.codex.rawValue || entry.provider == CLIProvider.claude.rawValue {
            guard service.registrationInstallStatus(for: entry) == .installed,
                  checkingAuthenticationIDs.insert(entry.id).inserted else { continue }
            authenticationStates[entry.id] = .checking
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let state: CLIAuthenticationUIState
                do {
                    if entry.provider == CLIProvider.claude.rawValue {
                        switch try service.claudeAuthenticationStatus(for: entry) {
                        case .authenticated: state = .authenticated
                        case .notAuthenticated: state = .notAuthenticated
                        case .unsupportedMethod: state = .statusError(
                            "O método de login não é compatível com o isolamento deste cadastro.")
                        }
                    } else {
                        switch try service.authenticationStatus(for: entry) {
                        case .authenticated: state = .authenticated
                        case .notAuthenticated: state = .notAuthenticated
                        }
                    }
                } catch let error as CLIInstallError {
                    state = .statusError(error.errorDescription ?? "Não foi possível verificar o login.")
                } catch {
                    state = .statusError("Não foi possível verificar o login isolado.")
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.checkingAuthenticationIDs.remove(entry.id)
                    self.authenticationStates[entry.id] = state
                    if self.settingsButton.state == .on { self.render(.settings) }
                }
            }
        }
    }

    @objc private func removeCLI(_ sender: NSButton) {
        guard !storageLoadFailed, let entryStore, listItems.indices.contains(sender.tag),
              let entry = listItems[sender.tag].manualEntry,
              !installingRegistrationIDs.contains(entry.id),
              !activeLogoutIDs.contains(entry.id),
              !activeRemovalIDs.contains(entry.id),
              !checkingAuthenticationIDs.contains(entry.id),
              !isAuthenticationRunningState(authenticationUIState(for: entry)),
              authenticationProcesses[entry.id]?.isRunning != true else { return }

        let isManagedRegistration = entry.provider == CLIProvider.codex.rawValue ||
            entry.provider == CLIProvider.claude.rawValue ||
            entry.provider == CLIProvider.antigravity.rawValue
        guard !isManagedRegistration || installService != nil else { return }
        let service = installService
        let alert = NSAlert()
        alert.messageText = "Remover definitivamente \(entry.displayName)?"
        if entry.provider == CLIProvider.claude.rawValue {
            alert.informativeText = "Esta ação apagará o pacote Claude Code gerenciado, configuração, histórico, caches e credenciais locais deste UUID. Não pode ser desfeita. O logout oficial pode invalidar a credencial no provedor, mas não garante revogar todas as sessões remotas. Instalações globais e outros cadastros não serão alterados."
        } else if entry.provider == CLIProvider.antigravity.rawValue {
            alert.informativeText = "Esta ação apagará o binário e todos os dados locais deste cadastro Antigravity UUID. Login não é iniciado, verificado nem removido nesta etapa. Instalações globais, outros UUIDs e perfis pessoais do sistema não serão alterados."
        } else if isManagedRegistration {
            alert.informativeText = "Esta ação apagará o CLI gerenciado deste cadastro, suas configurações, histórico, caches e login local. Não pode ser desfeita. Instalações globais e outros cadastros não serão alterados; não será enviado logout nem revogada uma sessão remota."
        } else {
            alert.informativeText = "Esta ação removerá o cadastro \(entry.displayName) da lista. Não pode ser desfeita e não altera instalações detectadas ou globais."
        }
        alert.alertStyle = .critical
        let cancelButton = alert.addButton(withTitle: "Cancelar")
        cancelButton.keyEquivalent = "\r"
        let removeButton = alert.addButton(withTitle: "Remover definitivamente")
        removeButton.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        activeRemovalIDs.insert(entry.id)
        render(.settings)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do {
                if isManagedRegistration {
                    guard let service else { throw CLIInstallError.unsupportedProvider }
                    try service.removeRegistration(entry: entry) {
                        _ = try entryStore.remove(id: entry.id)
                    }
                } else {
                    _ = try entryStore.remove(id: entry.id)
                }
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeRemovalIDs.remove(entry.id)
                self.refreshCLIEntries()
                switch result {
                case .success:
                    self.showRegistrationRemovalResult(
                        title: "Cadastro removido",
                        message: isManagedRegistration
                            ? "O pacote e os dados locais deste UUID foram apagados. A ação Desinstalar preserva o cadastro; a lixeira remove ambos. Nenhuma sessão remota foi revogada."
                            : "O cadastro foi removido. Instalações detectadas e globais não foram alteradas.")
                case .failure(let error):
                    self.showRegistrationRemovalResult(
                        title: "Cadastro mantido",
                        message: error.localizedDescription + " A entrada continua disponível para nova tentativa.")
                }
                if self.settingsButton.state == .on { self.render(.settings) }
            }
        }
    }

    private func showRegistrationRemovalResult(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = title == "Cadastro removido" ? .informational : .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    @objc private func installCLI(_ sender: NSButton) {
        guard !storageLoadFailed, let service = installService,
              listItems.indices.contains(sender.tag),
              let entry = listItems[sender.tag].manualEntry,
              entry.provider == CLIProvider.codex.rawValue || entry.provider == CLIProvider.claude.rawValue ||
                entry.provider == CLIProvider.antigravity.rawValue,
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
                if case .success = result {
                    if entry.provider != CLIProvider.antigravity.rawValue {
                        self.authenticationStates[entry.id] = .notAuthenticated
                    }
                    self.refreshAuthenticationStatuses()
                }
                self.render(.settings)
            }
        }
    }

    @objc private func loginCLI(_ sender: NSButton) {
        guard !storageLoadFailed, let service = installService,
              listItems.indices.contains(sender.tag),
              let entry = listItems[sender.tag].manualEntry,
              entry.provider == CLIProvider.codex.rawValue || entry.provider == CLIProvider.claude.rawValue,
              service.registrationInstallStatus(for: entry) == .installed else { return }

        if isAuthenticationRunningState(authenticationStates[entry.id] ?? .notAuthenticated),
           let process = authenticationProcesses[entry.id], process.isRunning {
            cancelledAuthenticationIDs.insert(entry.id)
            authenticationStates[entry.id] = .cancelled
            process.terminate()
            render(.settings)
            return
        }
        guard canStartAuthentication(for: entry) else { return }
        if entry.provider == CLIProvider.claude.rawValue {
            startClaudeLogin(for: entry, service: service)
            return
        }
        cancelledAuthenticationIDs.remove(entry.id)
        authenticationStates[entry.id] = .starting
        render(.settings)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let session = try service.startAuthentication(for: entry)
                let process = session.process
                DispatchQueue.main.async {
                    guard let self else { process.terminate(); return }
                    self.authenticationProcesses[entry.id] = process
                    self.authenticationStates[entry.id] = .starting
                    if self.settingsButton.state == .on { self.render(.settings) }
                }
                var loginRequestSent = false
                var browserHandoffHandled = false
                var loginCompletedSuccessfully = false
                var activeLoginID: String?
                var appServerRequestFailed = false
                let readerFinished = DispatchGroup()
                readerFinished.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { readerFinished.leave() }
                    var buffered = Data()
                    let handle = session.output.fileHandleForReading
                    while true {
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { break }
                        buffered.append(chunk)
                        while let newline = buffered.firstIndex(of: 0x0A) {
                            let line = Data(buffered[..<newline])
                            buffered.removeSubrange(...newline)
                            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                            else { continue }
                            let responseID = message["id"] as? Int
                            if responseID == 1, !loginRequestSent {
                                if message["error"] != nil {
                                    appServerRequestFailed = true
                                    if process.isRunning { process.terminate() }
                                } else {
                                    session.input.fileHandleForWriting.write(
                                        CLIAppServerLoginProtocol.notification(method: "initialized") ?? Data())
                                    session.input.fileHandleForWriting.write(
                                        CLIAppServerLoginProtocol.startRequest() ?? Data())
                                    loginRequestSent = true
                                }
                            } else if responseID == 2,
                                      !browserHandoffHandled,
                                      let authURL = CLIAppServerLoginProtocol.authURL(from: message) {
                                browserHandoffHandled = true
                                activeLoginID = CLIAppServerLoginProtocol.loginID(from: message)
                                DispatchQueue.main.sync {
                                    guard process.isRunning,
                                          self?.cancelledAuthenticationIDs.contains(entry.id) == false else { return }
                                    let opened = (try? service.openBrowserAuthenticationPage(for: entry,
                                                                                           authURL: authURL)) == true
                                    guard let self else { return }
                                    self.authenticationStates[entry.id] = .awaitingBrowserAuthorization(pageOpened: opened)
                                    if self.settingsButton.state == .on { self.render(.settings) }
                                }
                            } else if (responseID == 1 || responseID == 2), message["error"] != nil {
                                appServerRequestFailed = true
                                if process.isRunning { process.terminate() }
                            } else if responseID == 2 {
                                appServerRequestFailed = true
                                if process.isRunning { process.terminate() }
                            } else if message["method"] as? String == "account/login/completed",
                                      let params = message["params"] as? [String: Any],
                                      params["loginId"] as? String == activeLoginID,
                                      params["success"] as? Bool == true {
                                loginCompletedSuccessfully = true
                                if process.isRunning { process.terminate() }
                            }
                        }
                    }
                }
                process.waitUntilExit()
                readerFinished.wait()
                session.releaseOperationLock()
                let verifiedAuthenticationStatus: Result<CLIAuthenticationStatus, Error>
                do { verifiedAuthenticationStatus = .success(try service.authenticationStatus(for: entry)) }
                catch { verifiedAuthenticationStatus = .failure(error) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authenticationProcesses.removeValue(forKey: entry.id)
                    if case .failure = verifiedAuthenticationStatus {
                        self.authenticationStates[entry.id] = .statusError(
                            "O estado do login não pôde ser confirmado após o fluxo do navegador.")
                    } else if case .success(.authenticated) = verifiedAuthenticationStatus {
                        self.authenticationStates[entry.id] = .authenticated
                    } else if self.cancelledAuthenticationIDs.remove(entry.id) != nil {
                        self.authenticationStates[entry.id] = .cancelled
                    } else if !browserHandoffHandled {
                        self.authenticationStates[entry.id] = .failed("A CLI não iniciou o login normal pelo navegador. Tente novamente.")
                    } else if !loginCompletedSuccessfully {
                        self.authenticationStates[entry.id] = .failed(appServerRequestFailed
                            ? "A CLI não aceitou o pedido de autenticação. Tente novamente."
                            : "A autorização não foi confirmada pela CLI.")
                    } else if process.terminationStatus == 0 {
                        self.authenticationStates[entry.id] = .failed("A CLI encerrou sem confirmar a autenticação.")
                    } else {
                        self.authenticationStates[entry.id] = .failed("O código expirou ou o fluxo oficial terminou sem autenticação confirmada.")
                    }
                    if self.settingsButton.state == .on { self.render(.settings) }
                }
            } catch let error as CLIInstallError {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authenticationStates[entry.id] = .failed(error.errorDescription ?? "Login não iniciado.")
                    if self.settingsButton.state == .on { self.render(.settings) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authenticationStates[entry.id] = .failed("Não foi possível iniciar o login isolado.")
                    if self.settingsButton.state == .on { self.render(.settings) }
                }
            }
        }
    }

    private func startClaudeLogin(for entry: CLIEntry, service: CLIInstallService) {
        cancelledAuthenticationIDs.remove(entry.id)
        authenticationStates[entry.id] = .starting
        render(.settings)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let session = try service.startClaudeAuthentication(for: entry)
                let process = session.process
                DispatchQueue.main.async {
                    guard let self else { process.terminate(); return }
                    self.authenticationProcesses[entry.id] = process
                    self.authenticationStates[entry.id] = .awaitingClaudeBrowser
                    if self.settingsButton.state == .on { self.render(.settings) }
                }
                let drained = DispatchGroup()
                drained.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { drained.leave() }
                    while !session.output.fileHandleForReading.readData(ofLength: 4096).isEmpty {}
                }
                process.waitUntilExit()
                drained.wait()
                session.releaseOperationLock()
                let verified: Result<ClaudeCLIAuthenticationStatus, Error>
                do { verified = .success(try service.claudeAuthenticationStatus(for: entry)) }
                catch { verified = .failure(error) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authenticationProcesses.removeValue(forKey: entry.id)
                    switch verified {
                    case .success(.authenticated): self.authenticationStates[entry.id] = .authenticated
                    case .success(.notAuthenticated) where self.cancelledAuthenticationIDs.remove(entry.id) != nil:
                        self.authenticationStates[entry.id] = .cancelled
                    case .success(.notAuthenticated):
                        self.authenticationStates[entry.id] = .failed(
                            "O fluxo oficial terminou sem confirmar a autenticação neste cadastro.")
                    case .success(.unsupportedMethod):
                        self.authenticationStates[entry.id] = .statusError(
                            "O método de login não é compatível com o isolamento deste cadastro.")
                    case .failure:
                        self.authenticationStates[entry.id] = .statusError(
                            "O estado do login não pôde ser confirmado após o fluxo oficial.")
                    }
                    if self.settingsButton.state == .on { self.render(.settings) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authenticationStates[entry.id] = .failed(error.localizedDescription)
                    if self.settingsButton.state == .on { self.render(.settings) }
                }
            }
        }
    }

    @objc private func logoutCLI(_ sender: NSButton) {
        guard !storageLoadFailed, let service = installService,
              listItems.indices.contains(sender.tag),
              let entry = listItems[sender.tag].manualEntry,
              authenticationUIState(for: entry) == .authenticated,
              registrationInstallState(for: entry) == .installed,
              !installingRegistrationIDs.contains(entry.id),
              !checkingAuthenticationIDs.contains(entry.id),
              authenticationProcesses[entry.id]?.isRunning != true else { return }

        let alert = NSAlert()
        alert.messageText = "Sair deste cadastro?"
        alert.informativeText = entry.provider == CLIProvider.claude.rawValue
            ? "A CLI executará o logout oficial usando somente a configuração deste UUID. O provedor pode invalidar a credencial; esta ação não garante a revogação de todas as sessões remotas."
            : "A CLI vai limpar as credenciais locais deste cadastro (CODEX_HOME). Isso não revoga a sessão remotamente."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sair")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        activeLogoutIDs.insert(entry.id)
        authenticationStates[entry.id] = .loggingOut
        render(.settings)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<CLIAuthenticationStatus, Error>
            do {
                if entry.provider == CLIProvider.claude.rawValue {
                    let status = try service.logoutClaude(for: entry)
                    result = .success(status == .authenticated ? .authenticated : .notAuthenticated)
                } else {
                    result = .success(try service.logout(for: entry))
                }
            }
            catch { result = .failure(error) }
            let verifiedStatus: CLIAuthenticationStatus?
            if entry.provider == CLIProvider.claude.rawValue {
                do {
                    switch try service.claudeAuthenticationStatus(for: entry) {
                    case .authenticated: verifiedStatus = .authenticated
                    case .notAuthenticated: verifiedStatus = .notAuthenticated
                    case .unsupportedMethod: verifiedStatus = nil
                    }
                } catch { verifiedStatus = nil }
            } else {
                verifiedStatus = try? service.authenticationStatus(for: entry)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeLogoutIDs.remove(entry.id)
                switch verifiedStatus {
                case .authenticated?: self.authenticationStates[entry.id] = .authenticated
                case .notAuthenticated?: self.authenticationStates[entry.id] = .notAuthenticated
                case nil: self.authenticationStates[entry.id] = .statusError(
                    "A saída não pôde ser confirmada. O estado das credenciais é indeterminado.")
                }
                if case .failure = result {
                    self.showStoreFailure("A CLI não confirmou a saída deste cadastro. O estado exibido vem de uma nova verificação isolada.")
                }
                if self.settingsButton.state == .on { self.render(.settings) }
            }
        }
    }

    @objc private func uninstallCLI(_ sender: NSButton) {
        guard !storageLoadFailed, let service = installService,
              listItems.indices.contains(sender.tag),
              let entry = listItems[sender.tag].manualEntry,
              canUninstall(entry), !activeLogoutIDs.contains(entry.id) else { return }

        let alert = NSAlert()
        let providerName = CLIProvider(rawValue: entry.provider)?.catalogTitle ?? entry.provider
        alert.messageText = "Desinstalar \(providerName) deste cadastro?"
        if entry.provider == CLIProvider.claude.rawValue {
            alert.informativeText = "O Claude Code executará o logout oficial neste UUID e confirmará a saída antes de remover o pacote. Configurações, histórico e cache ficam para reinstalação, mas será necessário fazer login novamente. A ação não garante revogação de todas as sessões remotas. Se o logout falhar, o pacote e o cadastro serão mantidos."
        } else if entry.provider == CLIProvider.antigravity.rawValue {
            alert.informativeText = "Somente o binário Antigravity deste UUID será removido. Configuração, cache, dados e temporários exclusivos do cadastro ficam para reinstalação. Nenhum login, logout, navegador ou sessão global será iniciado ou alterado."
        } else {
            alert.informativeText = "Somente o pacote gerenciado por este UUID será removido. Configuração, histórico e credenciais locais serão preservados."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Desinstalar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        installingRegistrationIDs.insert(entry.id)
        render(.settings)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do { try service.uninstall(entry: entry); result = .success(()) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.installingRegistrationIDs.remove(entry.id)
                switch result {
                case .success:
                    self.installationFailures.removeValue(forKey: entry.id)
                    if entry.provider == CLIProvider.claude.rawValue {
                        self.authenticationStates[entry.id] = .notAuthenticated
                    } else {
                        self.authenticationStates.removeValue(forKey: entry.id)
                    }
                case .failure(let error):
                    self.showStoreFailure("O pacote deste cadastro não foi removido integralmente. \(error.localizedDescription)")
                }
                self.refreshCLIEntries()
                if self.settingsButton.state == .on { self.render(.settings) }
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
