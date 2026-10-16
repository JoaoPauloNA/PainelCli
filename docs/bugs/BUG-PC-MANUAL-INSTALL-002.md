# BUG-PC-MANUAL-INSTALL-002 — instalação concluída não oferece desinstalação do cadastro

- Reportado por João após teste manual do build `0.0.0.27`, em 2026-10-16.
- Estado: corrigido e validado por regressão sintética em 2026-10-16; aguarda validação visual no Mac_Layout.
- Escopo: alternância Instalar/Desinstalar e remoção da instalação gerenciada por cadastro UUID.

## Reprodução e causa

1. Instalar Codex no cadastro manual CodexCLI 0.
2. Observar o estado de instalação concluída.
3. Observar que a ação “Instalar” continua visível, porém desabilitada, sem alternativa de desinstalação.

A ação da UI estava fixa em `installCLI` e a disponibilidade só habilitava novas instalações. Não havia operação de serviço para remover o pacote de um UUID.

## Comportamento esperado

- O estado instalado troca a ação Instalar por Desinstalar para o mesmo UUID.
- A confirmação explica que somente o pacote gerenciado é removido; `CODEX_HOME`, configuração, histórico e credenciais locais são preservados. Desinstalar não significa logout ou revogação remota.
- Instalar novamente no mesmo UUID preserva esses dados. Cadastros com UUIDs diferentes e instalações detectadas/globalmente instaladas nunca são alterados.
- Estados incompletos/indeterminados não são apresentados como não instalados nem autorizam remoções abrangentes.

## Regressão e reteste

REGRESSION_TEST: `Tests/manual_install_ui_contract.py` verifica a troca de ação. `Tests/main.swift` cria instalações sintéticas e valida remoção do pacote/manifeste somente daquele UUID, retenção de configuração/credencial/histórico sintéticos, reinstalação que preserva os dados e preservação de outra instalação e do Codex global sintético.
TEST_COMMAND: `scripts/ci-check.sh` e `git diff --check`.
BEFORE_FIX: no baseline `0.0.0.27`, o contrato falhou: nenhuma ação de desinstalação estava ligada ao status `.installed` e não existia operação de serviço `uninstall(entry:)`. Evidência sanitizada em `DadosTeste/2069-PainelCli-BUG-PC-MANUAL-INSTALL-001-R2-CodexIsolation/state-actions-before-fix.txt`.
AFTER_FIX: passou o compile AppKit, testes do instalador isolado, contrato estático de UI, contrato de ícones e `git diff --check`. Fixtures confirmaram que só o pacote/manifest daquele UUID são removidos, dados sintéticos voltam com a reinstalação e UUID irmão e Codex global permanecem intactos. Evidência sanitizada em `DadosTeste/2069-PainelCli-BUG-PC-MANUAL-INSTALL-001-R2-CodexIsolation/state-actions-after-fix.txt`.
AUTOMATION_LIMITATIONS: desinstalação real do CodexCLI 0 não será executada nesta correção; o usuário validará a interação. Os testes usam fixtures em `tmp` e não executam npm ou Codex.
