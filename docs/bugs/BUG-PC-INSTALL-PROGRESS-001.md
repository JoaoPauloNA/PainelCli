# BUG-PC-INSTALL-PROGRESS-001 — ausência de carregamento visual

- Reportado por João em 2026-10-16, screenshot `codex-clipboard-04739e13-ff19-4f5d-a7a8-7a584a1bb040.png` fornecido no chat.
- Baseline: versão 0.0.0.29. Estado observado na imagem: CodexCLI 2, instalação isolada em andamento, ação apenas apagada sem indicador animado.
- Estado: correção técnica aplicada; aceitação visual/interativa pendente de João.

## Reprodução / esperado / observado

1. Usuário inicia uma instalação manual Codex.
2. Enquanto o estado existente é `.installing`, observar a linha.

Esperado: indicador de operação em andamento no espaço da ação, sem habilitar cliques extras ou sugerir conclusão.
Observado: texto de instalação em andamento e símbolo estático desabilitado. Inspeção estática confirma ausência de `NSProgressIndicator` na linha. Mac_Layout não iniciou instalação real nem reproduziu por interação.

## Correção

- Spinner nativo `.spinning`, indeterminado, 16 pt dentro do espaço de ação de 28 pt.
- Aparece apenas quando `state == .installing`; o botão estático fica oculto nesse estado.
- Sem porcentagem, tempo estimado, alteração em lock, target/action, status, regras de habilitação ou serviços.
- O estado do backend também cobre desinstalação; tooltip descreve ambas as operações, sem afirmar instalação quando for remoção.

## Regressão

REGRESSION_TEST: `Tests/manual_install_ui_contract.py`, bloco BUG-PC-INSTALL-PROGRESS-001.
INITIAL_STATE: fonte baseline sem spinner; contrato estático, sem arquivos/credenciais reais.
TEST_COMMAND: `python3 Tests/manual_install_ui_contract.py`; suíte `bash scripts/ci-check.sh`.
BEFORE_FIX: FAIL nas quatro asserções de feedback visual; log `before-fix.txt` em DadosTeste da rodada .30.
AFTER_FIX: PASS no mesmo contrato e na suíte existente; resultados em `DadosTeste/2075-PainelCli-0.0.0.30-IndicadorInstalacao`.
AFFECTED_SUITE: suíte sintética existente de armazenamento/instalador/auth, compilação AppKit e contratos de UI/ícones.
AUTOMATION_LIMITATIONS: asserções estáticas não verificam animação renderizada; teste de usuário fica com João. Nenhuma CLI real foi executada por Mac_Layout.
RETEST_VERDICT: pendente de João.
