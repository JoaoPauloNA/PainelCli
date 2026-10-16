# BUG-PC-MANUAL-INSTALL-001 — instalação de cadastro manual indisponível

- Reportado por: João, via coordenador, 2026-10-15.
- Baseline: `8c9df51`, versão local 0.0.0.22.
- Estado: ABERTO; apresentação preparada, correção funcional pendente do Dev.
- Responsáveis: Mac_Layout — apresentação; Dev — isolamento, disponibilidade, handlers e regressão; João — teste de usuário.

## Reprodução e evidência

1. Com instalação original de Codex detectada, abrir Configurações → Adicionar.
2. Criar registro manual CodexCLI 0 pelo catálogo.
3. Observar controle de instalação na linha manual.

Observado pelo usuário: símbolo apagado e não acionável; status inclui instalação encontrada no sistema. Confirmado por inspeção estática do baseline: botão com imagem apenas, `target/action == nil`, `isEnabled = false`. Não houve reprodução interativa por Mac_Layout.

Esperado: ação reconhecível como **Instalar**, com seta de download; Dev deve habilitar somente quando houver instalação/configuração por cadastro isolado, sem usar ou modificar `~/.codex` nem o executável original. A existência de uma CLI original não comprova a instalação isolada do cadastro.

## Contrato visual entregue

- `Sources/main.swift`: `makeInstallButton(displayName:tag:) -> NSButton`.
- Visual: botão nativo AppKit arredondado, controle pequeno, título **Instalar**, símbolo `arrow.down.circle`, fonte do sistema 12 medium, largura mínima 92 pt / altura 28 pt.
- Continua somente em `if isManualEntry`.
- O chamador ainda define `isEnabled = false`, tint cinza, tooltip e valor acessível sobre indisponibilidade do isolamento. Nenhum target/action foi conectado.
- Quando o Dev conectar a ação real, reutilizar o helper e definir disponibilidade/target/action conforme o contrato de isolamento. Não retirar guardas para fazer o botão parecer funcional.
- Nenhuma alteração em status, descoberta, login, lixeira, persistência, navegação ou detecções.
- Não houve incremento de versão, compilação/abertura de bundle ou promoção de entrega parcial.

## Regressão funcional obrigatória — pendente

REGRESSION_TEST: a definir pelo Dev em `Tests/main.swift`, na suíte existente.
INITIAL_STATE: fixture sintética com Codex original detectado e cadastro manual CodexCLI 0 sem instalação isolada.
TEST_COMMAND: suíte existente `scripts/ci-check.sh`, após o Dev adicionar o caso.
BEFORE_FIX: evidência automatizada pendente do Dev; inspeção estática acima não é prova funcional antes/depois.
AFTER_FIX: pendente do Dev.
AFFECTED_SUITE: não executada por Mac_Layout nesta preparação visual.
AUTOMATION_LIMITATIONS: correção funcional e teste antes/depois delegados ao Dev; proibido declarar bug resolvido por esta etapa visual.
RETEST_VERDICT: pendente; teste de usuário com João.

## Verificação desta etapa

Somente parse Swift e `git diff --check`, com resultados sanitizados em DadosTeste. Nenhum npm/CLI, login, instalação ou exclusão foi acionado.
