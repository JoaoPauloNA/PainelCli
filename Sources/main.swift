import AppKit

private enum Screen { case home, settings }
private enum SettingsSection { case add, cliProxy }
private enum CLIPackageCatalog {
    static let candidates = ["CodexCLI", "ClaudeCLI", "GeminiCLI"]
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
    private var storageLoadFailed = false
    private var installingProviders = Set<String>()
    private var installMessages: [String: String] = [:]

    private func navigationButton(_ title: String, symbol: String, action: Selector,
                                  selected: Bool) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol,
                              accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .left
        button.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        button.bezelStyle = .recessed
        button.setButtonType(.pushOnPushOff)
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
        window.minSize = NSSize(width: 740, height: 480)
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
            sidebar.widthAnchor.constraint(equalToConstant: 196),
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
        let navigation = Surface(.controlBackgroundColor)
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        let divider = Surface(.separatorColor)
        [navigation, body, divider].forEach { contentView.addSubview($0) }
        let heading = label("Configurações", size: 15, weight: .semibold)
        let add = navigationButton("Adicionar", symbol: "plus.square", action: #selector(showAddCLICatalog),
                                   selected: selectedSettingsSection == .add)
        let proxy = navigationButton("CLIProxy", symbol: "network", action: #selector(showCLIProxy),
                                     selected: selectedSettingsSection == .cliProxy)
        [heading, add, proxy].forEach { navigation.addSubview($0) }
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            navigation.topAnchor.constraint(equalTo: contentView.topAnchor),
            navigation.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            navigation.widthAnchor.constraint(equalToConstant: 188),
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
        body.addSubview(addButton)
        NSLayoutConstraint.activate([
            addButton.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            addButton.topAnchor.constraint(equalTo: body.topAnchor, constant: 16),
            addButton.widthAnchor.constraint(equalToConstant: 36),
            addButton.heightAnchor.constraint(equalToConstant: 32)
        ])
        renderEntryList(in: body)
    }

    private func renderEntryList(in body: NSView) {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        body.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: body.topAnchor, constant: 60),
            scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])

        if storageLoadFailed {
            stack.addArrangedSubview(label("Não foi possível carregar os registros salvos. O arquivo foi preservado e novos registros estão indisponíveis."))
        } else if entries.isEmpty {
            stack.addArrangedSubview(label("Nenhuma CLI adicionada."))
        } else {
            for entry in entries {
                let row = Surface(.quaternaryLabelColor.withAlphaComponent(0.07), radius: 10)
                row.heightAnchor.constraint(equalToConstant: 72).isActive = true
                let name = label(entry.displayName, size: 14, weight: .semibold)
                let statusText = entryStatus(for: entry)
                let status = label(statusText, size: 12, color: .secondaryLabelColor)
                row.addSubview(name)
                row.addSubview(status)
                let installing = installingProviders.contains(entry.provider)
                let install = NSButton(title: installing ? "Instalando…" : "Instalar",
                                       target: self, action: #selector(installCLI(_:)))
                install.bezelStyle = .rounded
                install.tag = entries.firstIndex(where: { $0.id == entry.id }) ?? 0
                install.isEnabled = !installing && !statusText.hasPrefix("Instalada") && !statusText.hasPrefix("Encontrada")
                install.setAccessibilityLabel("Instalar \(entry.provider)")
                let remove = NSButton(title: "Remover", target: self, action: #selector(removeCLI(_:)))
                remove.bezelStyle = .rounded
                remove.tag = install.tag
                remove.setAccessibilityLabel("Remover \(entry.displayName) da lista")
                [install, remove].forEach {
                    $0.translatesAutoresizingMaskIntoConstraints = false
                    row.addSubview($0)
                }
                NSLayoutConstraint.activate([
                    name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                    name.topAnchor.constraint(equalTo: row.topAnchor, constant: 13),
                    name.trailingAnchor.constraint(lessThanOrEqualTo: install.leadingAnchor, constant: -12),
                    status.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                    status.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 4),
                    status.trailingAnchor.constraint(lessThanOrEqualTo: install.leadingAnchor, constant: -12),
                    install.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                    install.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    install.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),
                    remove.trailingAnchor.constraint(equalTo: install.leadingAnchor, constant: -8),
                    remove.centerYAnchor.constraint(equalTo: row.centerYAnchor)
                ])
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    private func entryStatus(for entry: CLIEntry) -> String {
        if let message = installMessages[entry.provider] {
            if entry.provider == CLIProvider.gemini.rawValue && !message.contains("contas individuais") {
                return "\(message) · contas individuais não atendidas"
            }
            return message
        }
        guard let provider = CLIProvider(rawValue: entry.provider), let installService else {
            return entry.statusText
        }
        if let executable = installService.installedExecutable(for: provider) {
            let managed = installService.installDirectory(for: provider).appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(provider.executableName)
            let detected = executable.standardizedFileURL == managed.standardizedFileURL
                ? "Instalada pelo PainelCli" : "Encontrada no sistema · \(executable.path)"
            return provider == .gemini ? "\(detected) · contas individuais não atendidas" : detected
        }
        if provider == .gemini { return "Registrada · serviço indisponível para contas individuais" }
        return "Registrada · CLI ainda não instalada"
    }

    @objc private func removeCLI(_ sender: NSButton) {
        guard !storageLoadFailed, let entryStore, entries.indices.contains(sender.tag) else { return }
        let id = entries[sender.tag].id
        do {
            entries = try entryStore.remove(id: id)
            render(.settings)
        } catch {
            showStoreFailure("Não foi possível remover o registro. Os dados existentes foram preservados.")
        }
    }

    @objc private func installCLI(_ sender: NSButton) {
        guard !storageLoadFailed, entries.indices.contains(sender.tag), let installService else { return }
        let providerName = entries[sender.tag].provider
        guard let provider = CLIProvider(rawValue: providerName), installingProviders.insert(providerName).inserted else { return }
        installMessages[providerName] = "Instalação iniciada pelo usuário…"
        render(.settings)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: String
            do {
                try installService.install(provider: provider)
                outcome = "Instalada pelo PainelCli"
            } catch CLIInstallError.runtimeMissing {
                outcome = "Instalação indisponível · Node.js e npm são necessários"
            } catch CLIInstallError.alreadyInstalled(let path) {
                outcome = "Encontrada no sistema · \(path)"
            } catch {
                outcome = "Falha na instalação · verifique Node.js, npm e conexão"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.installingProviders.remove(providerName)
                self.installMessages[providerName] = outcome
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

    private func catalogRow(_ name: String, index: Int) -> NSView {
        let row = Surface(.quaternaryLabelColor.withAlphaComponent(0.07), radius: 10)
        let nameLabel = label(name, size: 14, weight: .semibold)
        let maker = label(name == "CodexCLI" ? "OpenAI" : name == "ClaudeCLI" ? "Anthropic" : "Google",
                          size: 12, color: .secondaryLabelColor)
        row.addSubview(nameLabel)
        row.addSubview(maker)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 66),
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 13),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -16),
            maker.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            maker.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4)
        ])
        let selectButton = NSButton(title: "", target: self, action: #selector(selectCatalogCandidate(_:)))
        selectButton.isBordered = false
        selectButton.tag = index
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
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 420),
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
        let notice = NSTextField(wrappingLabelWithString: "Selecionar uma CLI cria um registro na lista. Isso não instala a CLI pelo PainelCli.")
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
        render(.settings)
    }
    @objc private func showAddCLICatalog() {
        selectedSettingsSection = .add
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
