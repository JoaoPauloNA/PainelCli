# BUG-PC-MANUAL-INSTALL-001 — instalação de cadastro manual indisponível

- Reportado por: João, via coordenador, 2026-10-15.
- Baseline visual: `e315c65`, versão 0.0.0.22. Antes da apresentação, `8c9df51` não tinha rótulo no controle.
- Estado: correção e regressões automatizadas implementadas em `develop`; aguardando teste de usuário de João na `.23`.
- Responsáveis: Mac_Layout — apresentação; Dev — isolamento, disponibilidade, handlers e regressão; João — teste de usuário.

## Reprodução e evidência

1. Com instalação original de Codex detectada, abrir Configurações → Adicionar.
2. Criar registro manual CodexCLI 0 pelo catálogo.
3. Observar controle de instalação na linha manual.

Observado pelo usuário: símbolo apagado e não acionável; status inclui instalação encontrada no sistema. Confirmado por inspeção estática do baseline: botão com imagem apenas, `target/action == nil`, `isEnabled = false`. Não houve reprodução interativa por Mac_Layout.

Esperado: a linha de uma instalação original continua detectada; o registro manual mostra **Cadastro manual · não instalado** e ação **Instalar** disponível. O clique instala o pacote Codex em prefixo por UUID, sem usar ou modificar `~/.codex`, o executável original ou outro cadastro. A existência de uma CLI original não comprova instalação do registro.

## Contrato visual entregue

- `Sources/main.swift`: `makeInstallButton(displayName:tag:) -> NSButton`.
- Visual: botão nativo AppKit arredondado, controle pequeno, título **Instalar**, símbolo `arrow.down.circle`, fonte do sistema 12 medium, largura mínima 92 pt / altura 28 pt.
- Continua com o helper visual fornecido por Mac_Layout, somente para o cadastro Codex.
- O helper agora recebe `target/action`; disponibilidade e estado vêm da instalação UUID-scoped. Outros provedores continuam sem botão de instalação.
- O estado manual ignora a detecção global. O código da instalação usa prefixo local, configuração e cache próprios, ambiente de subprocesso em allowlist, staging atômico e lock por UUID.
- O ícone manual usa o mesmo mapeador símbolo/cor da linha detectada; o segundo ícone continua indicando origem.
- Login permanece indisponível e nenhuma autenticação inicia durante a instalação.

## Regressão funcional

REGRESSION_TEST: `Tests/manual_install_ui_contract.py` (`manual status is per-registration and install button is actionable`) e casos em `Tests/main.swift` (`Codex installation tests inject a recorder instead of executing npm or Codex`, UUID isolation, missing prerequisite, process failure, incomplete package, concurrency, row removal).
INITIAL_STATE: synthetic Codex executable detected globally; manual CodexCLI entry has a UUID and no UUID-scoped installation; no real registration data is used.
TEST_COMMAND: `scripts/ci-check.sh` (inclui as duas verificações estáticas de UI/ícone e os testes Swift isolados).
BEFORE_FIX: commit `e315c65` (`style: prepare labeled manual install control`), version 0.0.0.22. Automated red run exited 1 with six contract failures: manual status lacked registration install state, provider discovery affected status, button target/action were absent, availability was not per entry, and control was hard-disabled. No CLI was run.
AFTER_FIX: versão de desenvolvimento 0.0.0.23; `scripts/ci-check.sh` PASS. Testes injetam um runner sintético e não executam npm ou Codex reais.
AFFECTED_SUITE: `git diff --check` e `scripts/ci-check.sh` PASS antes do build; sem instalação ou login real.
AUTOMATION_LIMITATIONS: a verificação do botão/estado e do mapeamento de ícone é estática; backend usa fixtures e runner sintéticos. Nenhum comando real npm/Codex foi executado. Requisitos gerenciados de dispositivo podem impor outro backend de credenciais; conferir a política efetiva antes de habilitar login. João fará o teste de usuário.
RETEST_VERDICT: desenvolvimento automatizado PASS; reteste visual e clique real de instalação pendentes com João.

## Verificação desta etapa

Resultados sanitizados em `DadosTeste/2069-PainelCli-BUG-PC-MANUAL-INSTALL-001-R2-CodexIsolation/`. Não houve interação de UI, instalação real, autenticação ou leitura de credenciais.
