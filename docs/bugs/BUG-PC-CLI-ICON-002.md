# BUG-PC-CLI-ICON-002 — ícone de cadastro manual difere da CLI detectada

- Reportado por: João, via Mac_Layout, 2026-10-15.
- Baseline: `e315c65` (`style: prepare labeled manual install control`), versão 0.0.0.22.
- Estado: correção visual restrita implementada junto ao `BUG-PC-MANUAL-INSTALL-001`; reteste visual de João pendente.
- Responsável pela implementação: Dev. Teste visual de usuário: João.

## Reprodução e resultado

1. Criar uma linha manual CodexCLI com Codex original detectado.
2. Comparar o primeiro símbolo de identidade nas linhas manual e detectada.

Esperado: símbolo/cor do provedor iguais nas duas linhas. O segundo símbolo continua identificando a origem (app ou computador).

Observado pelo usuário: linha detectada Codex usa `</>` azul; linha manual usa terminal cinza. Inspeção estática confirmou que o ramo manual usa `cliSymbol()` e `secondaryLabelColor`, enquanto o ramo detectado usa `detectedAppearance(for:)`.

## Regressão

REGRESSION_TEST: `Tests/cli_icon_contract.py` (`manual and detected rows share provider symbol and tint`).
INITIAL_STATE: linha manual Codex e detecção Codex sintéticas no mesmo provedor.
TEST_COMMAND: `python3 Tests/cli_icon_contract.py`; suíte: `scripts/ci-check.sh`.
BEFORE_FIX: commit `e315c65`. Execução automatizada do contrato estático saiu com código 1: ramo manual não mapeia `entry.provider` para `CLIDiscoveryTarget`, não reutiliza `detectedAppearance`, e ainda chama terminal cinza genérico.
AFTER_FIX: candidata `.23`; `Tests/cli_icon_contract.py` PASS e `scripts/ci-check.sh` PASS. Evidência sanitizada: `DadosTeste/2069-PainelCli-BUG-PC-MANUAL-INSTALL-001-R2-CodexIsolation/` .
AFFECTED_SUITE: `git diff --check` e `scripts/ci-check.sh` PASS antes do bundle.
AUTOMATION_LIMITATIONS: contrato estático verifica a reutilização do mapeador em código; não instancia AppKit nem substitui inspeção visual. João fará o teste de usuário.
RETEST_VERDICT: desenvolvimento automatizado PASS; reteste visual de João pendente.
