# BUG-PC-LOGIN-002 — código de dispositivo não era copiado automaticamente

- Detectado em 2026-10-16 durante validação manual do login do CodexCLI 0.
- Estado: corrigido no build de desenvolvimento `0.0.0.27`; teste real de autenticação não repetido nesta validação.
- Escopo: login browser-first e handoff do device-code no cadastro manual CodexCLI 0.
- Relação: extensão de UX do fluxo coberto por `BUG-PC-LOGIN-001.md`; não substitui seu diagnóstico de inicialização sem TTY.

## Reprodução e causa

1. Acionar login no cadastro manual CodexCLI 0.
2. No build `.26`, observar que o app iniciava `codex login --device-auth`, abria a página de código no Safari e mostrava o código na UI.
3. Observar que o código não estava pronto para colar e que não havia uma ação para preferir OAuth browser-first.

O app forçava device-code mesmo quando a pessoa acionava o login normal. O fluxo lia o código em memória e abria o Safari, mas não escrevia o código no pasteboard do macOS. A pessoa precisava copiar ou digitar manualmente.

## Correção

- O login padrão usa o método oficial `account/login/start` do app-server com o tipo `chatgpt`; o app abre em Safari o URL HTTPS validado devolvido pela CLI e aguarda `account/login/completed`.
- Uma ação separada “Código” seleciona explicitamente `chatgptDeviceCode`; ela nunca é fallback automático.
- No prompt device-code ativo, a UI chama um handoff de uso único que grava o código recebido em memória no `NSPasteboard` antes de abrir o URL fixo oficial no Safari.
- A aplicação não lê nem registra o conteúdo do clipboard.
- A interface só informa que o código foi copiado quando a escrita do pasteboard retorna sucesso. Se a cópia falha, mantém a instrução para digitação manual; se a abertura da página falha, ainda deixa o código disponível na UI e no clipboard quando a escrita funciona.
- Cancelamento, processo já encerrado e saídas repetidas não iniciam novo handoff.

## Regressão e reteste

REGRESSION_TEST: `Tests/main.swift` valida que o login padrão envia tipo `chatgpt`, device-code só é enviado por modo explicitamente escolhido, o URL auth usa host oficial, e o handoff sintético copia uma vez antes de abrir a página, ignora cancelamento/CLI encerrada e preserva recuperação manual em falha de cópia. `Tests/manual_install_ui_contract.py` garante o uso do pasteboard sem leituras do clipboard e separação das ações na UI. Nenhum código, URL de autenticação ou token real foi usado ou gravado nos registros.
TEST_COMMAND: `scripts/ci-check.sh` e `git diff --check`; inicialização isolada do app-server v2 do CLI `0.163.0` com `HOME`/`CODEX_HOME` temporários vazios. Build local via `python3 scripts/build-open.py`.
BEFORE_FIX: o contrato original falhou com três comportamentos de clipboard ausentes. O baseline `.26` também forçava `login --device-auth` sem permitir browser-first; o teste de regressão browser-first registra essa seleção incorreta. Registros sanitizados em `DadosTeste/2069-PainelCli-BUG-PC-MANUAL-INSTALL-001-R2-CodexIsolation/clipboard-regression-before-fix.txt` e `browser-login-regression-before-fix.txt`.
AFTER_FIX: teste de instalação isolada, contrato app-server, seleção browser/device, teste de handoff, contratos da UI e ícone passaram; inicialização do app-server confirmou resposta sem enviar `account/login/start`; `git diff --check` passou. Nenhum login real foi iniciado; a tentativa anterior, associada ao UUID do CodexCLI 0, foi encerrada antes da reconstrução. Registro sanitizado em `DadosTeste/2069-PainelCli-BUG-PC-MANUAL-INSTALL-001-R2-CodexIsolation/clipboard-regression-after-fix.txt`.
