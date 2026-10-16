# BUG-PC-LOGIN-001 — abertura do Chrome isolado não confirmada no login Codex

- Reportado durante implementação e teste acompanhado, 2026-10-15.
- Estado: diagnóstico reproduzido; login interativo não concluído. A UI agora termina com falha clara se o CLI não confirmar o lançamento do perfil Chrome isolado.
- Escopo: somente cadastro manual CodexCLI 0 no ramo `develop`.

## Reprodução e resultado

1. Instalar Codex no cadastro manual CodexCLI 0.
2. Acionar o login do cadastro.
3. Observar que o CLI permanece ativo sem confirmar a abertura do perfil Chrome isolado.

Esperado: o fluxo oficial abre uma janela do Chrome usando o `CODEX_HOME/browser-profile` do UUID, aguarda o usuário completar a autenticação e só mostra sucesso após `codex login status` retornar sucesso e um `auth.json` privado existir nesse mesmo `CODEX_HOME`.

Observado: Codex CLI 0.163.0 instalou e `codex login status` no ambiente UUID retornou não autenticado. A tentativa via UI não criou o marcador de abertura do Chrome isolado; foi encerrada sem inserir credenciais ou concluir OAuth. Não foi criado `auth.json`. O app mostra falha e permite nova tentativa.

## Proteções e correção de estado

- O app só autentica a instalação do UUID selecionado, exige política local/MDM compatível com armazenamento `file` e mantém o `CODEX_HOME` isolado.
- O launcher aceita somente URLs HTTPS dos domínios oficiais OpenAI/ChatGPT e solicita uma janela em perfil Chrome separado, sem alterar o navegador padrão.
- A UI só mostra “Aguardando autenticação” após o marcador privado ser criado pelo launcher depois de o Chrome aceitar a abertura. Sem marcador, encerra e mostra falha; sucesso requer a verificação documentada do CLI e o arquivo privado.
- A chamada real parou antes de qualquer autenticação; o teste automatizado cobre estado, isolamento e confirmação do marcador, sem credenciais ou OAuth real.

## Regressão e limitações

REGRESSION_TEST: `Tests/manual_install_ui_contract.py` garante que a UI verifique o marcador antes do estado de espera; `Tests/main.swift` testa ambiente isolado, status do CLI, permissões e políticas com fixtures sintéticas.
TEST_COMMAND: `scripts/ci-check.sh`.
AUTOMATION_LIMITATIONS: os testes não executam OAuth. O teste real confirmou instalação e status inicial não autenticado, mas não confirmou que Codex CLI 0.163.0 invoque o launcher `open` por PATH nem que o perfil isolado abra. Requer novo reteste funcional após diagnóstico da rota de abertura de navegador.
