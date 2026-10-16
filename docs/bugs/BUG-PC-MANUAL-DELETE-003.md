# BUG-PC-MANUAL-DELETE-003 — lixeira remove cadastro sem desinstalar o CLI

- Reportado durante validação funcional em 2026-10-16.
- Estado: corrigido e validado sinteticamente no build de desenvolvimento `0.0.0.29` em 2026-10-16.
- Escopo: ação de lixeira em cadastro manual CodexCLI. A ação separada Desinstalar mantém o cadastro e os dados locais.

## Reprodução e causa

1. Instalar um Codex sintético para um cadastro manual.
2. Acionar a lixeira da linha.
3. A entrada desaparece da lista enquanto o executável gerenciado continua no diretório UUID.

`removeCLI` chamava diretamente `CLIEntryStore.remove`, sem coordenar a remoção do pacote. Isso podia deixar uma instalação gerenciada sem cadastro visível.

## Comportamento esperado

- Para um Codex instalado, a lixeira pede confirmação de remoção definitiva dos dados daquele UUID.
- A operação mantém o cadastro visível até apagar e verificar o diretório UUID inteiro; só então persiste a exclusão da linha.
- Falha, estado parcial/indeterminado ou lock ocupado mantém a entrada visível e informa que a remoção não foi concluída.
- Instalações originais/detectadas/global e outros UUIDs não são tocados. Nenhum logout ou revogação remota ocorre.
- Configuração, histórico, cache e login local exclusivos do UUID são apagados; não se cria uma cópia residual. Instalações globais, outros UUIDs, `~/.codex` original, browser pessoal e dependências compartilhadas ficam intactos.
- Se o save do cadastro falhar depois da limpeza, a linha permanece visível sem instalação e permite repetir a remoção. Não reinstalar automaticamente.

## Regressão e reteste

REGRESSION_TEST: contrato estático da lixeira e fixtures sintéticas cobrem ordem cleanup-before-store-delete, sucesso com auth/config/histórico/cache falsos, falha do save, symlink escape, não instalado com dados residuais, lock concorrente e UUID novo com ordinal reutilizado. O lease do login sintético também bloqueia a lixeira até o processo terminar.
TEST_COMMAND: `scripts/ci-check.sh` e `git diff --check`.
BEFORE_FIX: contrato vermelho sobre baseline `700553b`; lixeira não chamava operação UUID-scoped, não tinha confirmação irreversível, não compartilhava o lock nem verificava diretório ausente antes do save. Evidência sanitizada em `DadosTeste/2073-PainelCli-BUG-PC-MANUAL-DELETE-003/trash-before-fix.txt`.
AFTER_FIX: `scripts/ci-check.sh` e `git diff --check` passaram. `python3 scripts/build-open.py` compilou e abriu `0.0.0.29`; assinatura validada; exatamente os bundles atual/anterior permanecem e há uma instância. Evidência sanitizada em `DadosTeste/2073-PainelCli-BUG-PC-MANUAL-DELETE-003/trash-after-fix.txt`.
AUTOMATION_LIMITATIONS: nenhum Codex real, login/logout ou instalação real fora de `tmp` foi executado. O teste de cancelamento verifica a ordem e o código de retorno do alerta estaticamente; o usuário pode validar a interação. O app foi aberto sem acionar lixeira ou outros controles.
