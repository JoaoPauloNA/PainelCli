# BUG-PC-MANUAL-DELETE-003 — lixeira remove cadastro sem desinstalar o CLI

- Reportado durante validação funcional em 2026-10-16.
- Estado: fluxo básico validado no build `0.0.0.29`; follow-up de auditoria aberto em 2026-10-16 para um socket Unix do perfil de browser.
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

## Follow-up de auditoria — socket local no browser-profile

BUG_ID: BUG-PC-MANUAL-DELETE-003 (mesmo fluxo; cenário adicional, sem duplicar o defeito).
PROJECT: PainelCli.
SNAPSHOT: `develop`, commit `a3b7e71`, bundle `0.0.0.29`.
QA_GATE: auditoria técnica real somente leitura, em três registros CodexCLI.
SEVERITY: P2 — o cadastro afetado não pode completar a remoção definitiva enquanto o verificador rejeitar este link de IPC.
EXPECTED: a lixeira pode remover com segurança um link local a um socket Unix do perfil de browser sem seguir/apagar o socket; links para dados/arquivos fora do UUID continuam bloqueando a remoção.
OBSERVED: CodexCLI 0 possui um symlink `installation/codex-home/browser-profile/SingletonSocket` cujo alvo é um socket Unix pertencente ao usuário fora da raiz UUID. `symlinksStayInside` em `Sources/CLIInstaller.swift` rejeita qualquer alvo fora da raiz antes da limpeza; logo, `removeRegistration` deixa o cadastro visível e retorna estado incompleto. Nenhuma tentativa de remoção real foi feita.
REPRODUCTION: auditoria sem mutação identificou o link por nome relativo dentro da raiz, confirmou somente tipo socket e proprietário; não imprimiu nem persistiu UUID, caminho absoluto, segredo ou conteúdo de arquivo.
EVIDENCE: `DadosTeste/2083-PainelCli-readonly-codex-audit/audit-report.txt`.
FILES_RELATED: `Sources/CLIInstaller.swift` (`removeRegistration`, `symlinksStayInside`).
CONSTRAINTS: auditoria autorizada somente leitura; sem alteração nas três instalações, sem browser, sem login/logout, sem CLI global, sem build adicional e sem teste destrutivo.
ACCEPTANCE_FOR_FIX: adicionar fixture sintética em diretório temporário contendo symlink externo para socket Unix do usuário e sentinel externo: a lixeira deve remover só o UUID e o link, preservar o socket/sentinel; manter a recusa para symlink externo de arquivo/diretório, validar falha parcial e save, executar regressões/CI e retestar em uma tarefa de correção autorizada.
REGRESSION_TEST: pendente — fixture discriminante antes da correção; não executada nesta auditoria para respeitar o limite de somente leitura/sem novo build.
INITIAL_STATE: instalação real CodexCLI 0, pacote/config/auth privados e autenticada; um socket IPC em `browser-profile` é a única referência symlink observada fora do UUID.
TEST_COMMAND: auditoria isolada `--version` e `login status` executada uma vez em cada UUID, mais inspeção de metadata/path sem ações mutantes; saída integral de CLI nunca foi persistida.
BEFORE_FIX: audit follow-up observado no `.29`; comportamento do handler foi estabelecido por inspeção do código, sem acionar a lixeira. Log sanitizado no pacote de evidência acima.
AFTER_FIX: N/D — não corrigido nesta tarefa.
AFFECTED_SUITE: N/D nesta auditoria; os testes sintéticos existentes verificam recusa de symlink externo, não o caso de symlink para socket.
AUTOMATION_LIMITATIONS: teste automatizado e correção ficam para tarefa autorizada; nenhuma remoção/login/logout real foi realizada.
RETEST_VERDICT: N/D.
