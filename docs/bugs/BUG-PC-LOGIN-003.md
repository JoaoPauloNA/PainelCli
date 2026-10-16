# BUG-PC-LOGIN-003 — cadastro autenticado não oferece ação Sair

- Reportado por João após teste manual do build `0.0.0.27`, em 2026-10-16.
- Estado: corrigido e validado por regressão sintética em 2026-10-16; aguarda validação visual no Mac_Layout.
- Escopo: alternância de ação de autenticação por estado do cadastro manual CodexCLI e UUID.

## Reprodução e causa

1. Autenticar o cadastro manual CodexCLI 0.
2. Observar o estado “Autenticado neste cadastro”.
3. Observar que o controle permanece como ação de login e não oferece saída.

A UI não mapeava o estado autenticado para um comando logout. O estado era conhecido, mas só havia handler de início/cancelamento de login.

## Comportamento esperado

- Enquanto o status isolado confirmar autenticação, o controle de conta oferece a ação Sair para esse mesmo UUID.
- Sair executa `codex logout` com o binário, `HOME` e `CODEX_HOME` desse cadastro e só muda a UI para desconectado após `codex login status` confirmar a limpeza local.
- Erro ou estado indeterminado permanece explícito e não é apresentado como desconectado.
- A operação remove credenciais armazenadas localmente nesse `CODEX_HOME`; não promete revogação remota da sessão do ChatGPT.

## Regressão e reteste

REGRESSION_TEST: `Tests/manual_install_ui_contract.py` verifica a ação por estado e o handler logout; `Tests/main.swift` usa runner injetado para validar argumentos/ambiente isolados, confirmação por status e preservação de outros UUIDs e do `~/.codex` sintético.
TEST_COMMAND: `scripts/ci-check.sh` e `git diff --check`.
BEFORE_FIX: no baseline `0.0.0.27`, o contrato falhou: cadastro autenticado não oferecia ação Logout e não havia operação/status pós-logout isolados. Evidência sanitizada em `DadosTeste/2069-PainelCli-BUG-PC-MANUAL-INSTALL-001-R2-CodexIsolation/state-actions-before-fix.txt`.
AFTER_FIX: passou o compile AppKit, testes do instalador isolado, contrato estático de UI, contrato de ícones e `git diff --check`. Runner sintético confirmou a sequência `login status` → `logout` → `login status` usando o mesmo `CODEX_HOME`; um status ainda autenticado gera `logoutNotConfirmed`. Evidência sanitizada em `DadosTeste/2069-PainelCli-BUG-PC-MANUAL-INSTALL-001-R2-CodexIsolation/state-actions-after-fix.txt`.
AUTOMATION_LIMITATIONS: logout real do CodexCLI 0 não será executado nesta correção; o usuário validará a interação. Credenciais sintéticas e runners injetados cobrem somente o contrato local e UUID-scoped.
