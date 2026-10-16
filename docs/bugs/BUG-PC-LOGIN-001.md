# BUG-PC-LOGIN-001 — fluxo de login sem terminal não abria o Chrome isolado

- Detectado no teste de CodexCLI 0, 2026-10-15.
- Estado: correção e teste de inicialização reais passaram; autenticação aguarda ação do usuário no Chrome isolado.
- Escopo: cadastro manual CodexCLI 0 no `develop`.

## Reprodução e causa

1. Instalar Codex no cadastro manual CodexCLI 0.
2. Acionar login pelo app AppKit, que inicia subprocessos sem TTY.
3. Observar que o subprocesso segue sem marcador do perfil Chrome.

A versão instalada usa o modo de login por código quando executada sem TTY. A implementação anterior descartava stdout e esperava o marcador de um launcher de navegador; como não havia URL de browser nesse modo, o login ficava sem interação e era interrompido pelo timeout. A presença de um perfil Chrome vazio não provava o início do OAuth.

## Correção

- Executa explicitamente `codex login --device-auth`; este comando não tenta abrir o navegador padrão.
- Lê stdout em memória, mantendo buffer limitado e aceitando somente o URL fixo `https://auth.openai.com/codex/device` e o código de uso único no formato impresso pela CLI. A saída não é registrada em arquivo ou log.
- Abre o URL fixo no Google Chrome com `--user-data-dir` apontando para o `CODEX_HOME/browser-profile` do UUID. Espera um processo Chrome que contenha exatamente esse perfil antes de exibir o código na interface.
- O usuário completa autenticação no Chrome isolado e digita o código gerado pelo próprio CLI. A UI só declara autenticado após o processo terminar com sucesso, `codex login status` confirmar o estado nesse `CODEX_HOME`, e existir um `auth.json` regular com modo privado.

## Regressão e reteste

REGRESSION_TEST: `Tests/main.swift` cobre parsing sintético do prompt oficial, rejeita origem/rota não permitidas, e verifica argumentos e ambiente UUID-scoped; `Tests/manual_install_ui_contract.py` garante que login use device auth, Chrome isolado e verificação de status. Nenhum código real é colocado nos testes.
TEST_COMMAND: `scripts/ci-check.sh` e `git diff --check`.
BEFORE_FIX: build `.24`, tentativa real do Codex CLI 0.163.0 iniciada sem TTY; a saída de device auth era descartada, nenhum Chrome isolado foi iniciado e nenhum `auth.json` foi criado. A UI parou a tentativa sem digitar credenciais.
AFTER_FIX: build `.25`; `git diff --check` e `scripts/ci-check.sh` PASS. O teste real gerou o prompt oficial, abriu Chrome com `--user-data-dir` do UUID e a UI passou a exibir o estado de código pendente. O código não é registrado em arquivos ou logs. A autenticação permanece pendente de João inserir o código exibido no PainelCli no Chrome isolado; ainda não há `auth.json`. Só marcar concluído após o processo oficial encerrar e `codex login status` confirmar autenticação nesse UUID.
