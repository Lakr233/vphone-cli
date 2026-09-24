<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="./README_ru.md">🇷🇺Русский</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong> | <strong>🇧🇷Português</strong></div>

# vphone-cli

Inicie um iPhone virtual usando o Virtualization.framework da Apple com a infraestrutura de VMs de pesquisa PCC.

![poc](./demo.jpeg)

## Pré-requisitos

**Para executar:**

- Apple Silicon
- macOS 15+ (Sequoia)
- [Relaxamento de SIP/AMFI para permitir entitlements privados PV=3 com binário não assinado](#relaxamento-sipamfi)

**E nada mais.** Nenhum pacote do Homebrew, nenhum interpretador, nenhum ambiente de
pacotes, nenhum Xcode. Tudo o que o vphone-cli executa é um binário do sistema em
`/usr/bin`, `/bin`, `/usr/sbin` ou `/sbin`, ou está dentro do próprio `.app` — o assinador
(substituiu o `ldid`), a leitura de arquivos compactados (`gtar`, `zstd`, `unzip`), o
catálogo de firmwares e o tratamento de IM4P/AEA (`ipsw`), e os cinco binários iOS que os
instaladores de CFW colocam no guest, que são compilados cruzadamente no build e
distribuídos prontos, não compilados na sua máquina. `make check-aux` é o portão que mantém
isso assim.

**Para compilar a partir do código-fonte**, acrescente o Xcode (o iOS SDK dele é contra o
que esses cinco binários são compilados) e o `git-lfs` (o `git clone` precisa dele para os
arquivos em `scripts/resources`).

## Instalação

```bash
brew install zqxwce/tap/vphone-cli
```

## Compilação

```bash
brew install git-lfs
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/build.sh            # compila + assina vphone-cli, compila os binários guest, empacota o .app

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

`./scripts/setup_tools.sh` é opcional e compila uma coisa só: `insert_dylib`, a referência
independente contra a qual um teste Mach-O compara o injetor de dylib em Swift, byte a byte.
Nada do que é distribuído o executa.

## Início Rápido

Um único comando cria a VM do início ao fim (download → patch → restore DFU → instalação CFW → primeiro boot):

```bash
vphone-cli vm create meuiphone -V jb        # -V / --variant

vphone-cli vm launch meuiphone
```

## Comandos

`vphone-cli vm create` executa todo o pipeline; os passos individuais abaixo permitem executar manualmente ou repetir uma etapa.

### Gerenciamento

```bash
vphone-cli vm list                         # lista VMs (--json para scripts)
vphone-cli vm info meuiphone               # mostra uma VM
vphone-cli vm new meuiphone                # cria um bundle vazio (opções cpu/mem/disk)
vphone-cli vm config meuiphone --cpu 8 --memory 8192
vphone-cli vm clone meuiphone meuiphone-2  # clone APFS rápido, nova identidade de dispositivo
vphone-cli vm export meuiphone --out meuiphone.tzst   # zstd rápido por padrão (--max = xz -9); --out pode ser diretório (auto-nomeia <vm>.tzst/.txz); ignora diretório restore + arquivos staging
vphone-cli vm import meuiphone.tzst --name restaurado
vphone-cli vm rename meuiphone iphone16
vphone-cli vm delete iphone16
```

### Construir uma VM manualmente (o que `vm create` automatiza)

```bash
vphone-cli vm new meuiphone                            # 1. bundle vazio
vphone-cli fw prepare meuiphone --iphone-version 26.1  # 2. baixa + mescla IPSWs
vphone-cli fw patch meuiphone --variant jb             # 3. aplica patches na cadeia de boot

vphone-cli vm launch meuiphone --dfu &                 # 4. inicia em modo DFU (background)
vphone-cli restore meuiphone --get-shsh                #    obtém SHSH
vphone-cli restore meuiphone                           #    restore DFU
vphone-cli vm stop meuiphone                           #    para o boot DFU

vphone-cli cfw install meuiphone --variant jb          # 5. instala CFW (host-mount; pede sudo)
vphone-cli vm launch meuiphone                         # 6. primeiro boot
```

Atualize para um iOS mais novo apontando `fw prepare` para um IPSW: `--iphone-source /caminho/para.ipsw --cloudos-source /caminho/para.ipsw`.

Os passos 4 e 5 rodam no próprio processo do `vphone-cli`. O `restore` controla
diretamente as cópias embutidas de libirecovery e idevicerestore — sem ferramenta
externa de restauração e sem nenhum passo de preparação antes da primeira
execução. Com `--offline`, a restauração usa um `.shsh` já salvo ao lado da VM em
vez de pedir um novo à Apple.

## Variantes de Firmware

Cinco variantes de patch com bypass de segurança crescente — passe uma para `--variant`:

| Variante     | Boot Chain  | CFW       | Notas                                                              |
| ------------ | ----------- | --------- | ------------------------------------------------------------------ |
| `less`       | 4 patches   | 2 fases   | Patchless — mantém mitigações do iOS habilitadas                   |
| `regular`    | 42 patches  | 10 fases  | Bypass de AMFI/SSV/Img4/TXM                                        |
| `dev`        | 53 patches  | 12 fases  | + bypass de entitlements/debug do TXM                              |
| `jb`         | 113 patches | 14 fases  | + jailbreak completo (Sileo, TrollStore auto-instalados no boot)   |
| `exp`        | 141 patches | 18 fases  | Superset do JB + patches de pesquisa anti-detecção-de-VM           |

Veja [`research/0_binary_patch_comparison.md`](../research/0_binary_patch_comparison.md) para o detalhamento por componente.

## Execução & Conexão

- **SSH (jailbreak):** `ssh -p 22222 mobile@<vm-ip>` (senha `alpine`)
- **SSH (regular/dev):** `ssh -p 22222 root@<vm-ip>`
- **VNC:** `vnc://<vm-ip>:5901`

## Localizações

Tudo que o vphone-cli cria fica em `~/.vphone/` — fora do repo e do `.app` para que o bundle assinado continue portátil. Redirecione toda a árvore com `$VPHONE_ROOT`:

| Caminho           | Conteúdo                                                                                      |
| ----------------- | --------------------------------------------------------------------------------------------- |
| `~/.vphone/`      | Raiz de dados por usuário — substitua toda a localização com `$VPHONE_ROOT`.                  |
| `~/.vphone/VMs/`  | Bundles de VM — um diretório por VM. Esta é a biblioteca; substitua com `$VPHONE_LIBRARY_ROOT`. |
| `~/.vphone/ipsws/`| IPSWs de iPhone + cloudOS baixados, em cache e reutilizados entre VMs.                        |
| `~/.vphone/tools/`| Artefatos de seal-volume APFS em cache (`apfs_sealvolume_<versão>`) obtidos durante `fw prepare`. |
| `~/.vphone/debs/` | Pacotes `.deb` em cache que o CFW `jb`/`exp` instala no guest (Sileo, apt, …).                |

Precedência: a substituição por item `$VPHONE_LIBRARY_ROOT` tem prioridade sobre `$VPHONE_ROOT`, que tem prioridade sobre o padrão `~/.vphone`. Os caches `ipsws/`, `tools/` e `debs/` sempre ficam diretamente sob qualquer raiz ativa.

## Relaxamento SIP/AMFI

**Opção A — desabilitar SIP completamente, depois desabilitar AMFI via boot-arg (mais permissivo).**

No Recovery (pressione e segure power → Terminal):

```bash
csrutil disable
csrutil allow-research-guests enable
```

Depois reinicie no macOS e configure o boot-arg do AMFI (requer SIP completamente desligado para funcionar):

```bash
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"   # reinicie após
```

Esse ainda é o caminho mais simples, e o único que não exige nada rodando ao lado da VM: com o AMFI relaxado, o `vphone-vm` inicia sozinho.

**Opção B — manter SIP ligado (relaxado apenas para debug) e colocar esta build na allowlist** (o AMFI continua habilitado no resto do tempo e para todo binário que você não liberar).

No Recovery:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

Depois reinicie no macOS e rode:

```bash
make amfi_allow     # pede root; rode de novo depois de cada build
make amfi_status    # mostra a allowlist e se este host consegue carregá-la
make amfi_off       # remove a allowlist e reinicia o amfid limpo
```

Isso executa o `vphone-amfi-allow`, compilado do C deste próprio repositório e distribuído dentro do `.app`. Ele escreve duas coisas:

* os cdhashes das **duas** cópias do `vphone-vm` em
  `/Library/Preferences/com.apple.security.coderequirements.plist`, um arquivo que o AMFI
  já lê — é um recurso que ele traz, não um buraco;
* **um byte do heap** do amfid, para virar a flag `_isRunningInternalBuild` que faz ele
  consultar esse arquivo.

As duas, porque o `make boot` inicia as duas: o `boot_binary_check` roda
`.build/release/vphone-vm` e o boot em si roda a que está dentro do `.app`. Elas são
assinadas sob identificadores diferentes e têm hashes diferentes, então liberar uma cobre
exatamente metade do fluxo.

**Rode de novo depois de cada build.** A allowlist é por cdhash, e qualquer assinatura muda o cdhash — inclusive um `swift build` puro.

O binário a liberar é o `vphone-vm`. O `vphone-cli` não carrega entitlements e sempre inicia, então não é o cdhash dele que você quer.

> **Seja claro sobre o que isso libera.** É uma allowlist por cdhash: o amfid continua validando todo binário que você não listou. `make amfi_off` apaga o arquivo e reinicia o amfid.
>
> Esse um byte fica no **heap** do amfid, não no `__TEXT` dele, e é isso que faz a coisa funcionar. As tentativas anteriores alteravam código — o `vphone-letmein` sobrescrevia o `ldrb` em `-[AMFIPathValidator_macos validateWithError:]`, e ferramentas baseadas em LLDB plantam um `BRK` para o breakpoint. As duas deixam uma página executável suja e não assinada, e num host onde `sysctl vm.cs_system_enforcement` vale 1 — medido no macOS 27.0 (26A428), arm64e, exatamente com as configurações de `csrutil` acima — o kernel valida essa página na próxima falta, mata o amfid e leva o guest junto. O sysctl é somente leitura em runtime, então "corrigir o código" não sobrevive por mais cuidado que se tenha. Heap não é código, e o enforcement não tem do que reclamar.

## Ambientes Testados

| Host            | iPhone                | CloudOS         |
| --------------- | --------------------- | --------------- |
| Mac16,11 27.0b2 | `17,3_18.6.2_22G100`  | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0_23A341`    | `26.1-23B85`    |
| Mac16,8 26.5.1  | `17,3_26.0.1_23A355`  | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.1_23B85`     | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.1-23B85`    |
| Mac16,12 26.3   | `17,3_26.3_23D127`    | `26.3-23D128`   |
| Mac16,12 26.3   | `17,3_26.3.1_23D8133` | `26.3-23D128`   |
| Mac16,11 26.2   | `17,3_26.4_23E246`    | `26.4-23E5207q` |
| Mac16,11 26.2   | `17,3_26.5_23F77`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.5.2_23F84`   | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_26.6_23G71`     | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_26.6.1_23G83`   | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_26.6.2_23G90`   | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5380h`  | `26.4-23E5207q` |
| Mac16,6 26.4.1  | `17,3_27.0_24A5390f`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A5408d`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5418b`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5424a`  | `26.4-23E5207q` |
| Mac16,11 27.0b2 | `17,3_27.0_24A5430a`  | `26.4-23E5207q` |
| Mac16,6 26.6.1  | `17,3_27.0_24A435`    | `26.4-23E5207q` |

## FAQ

**`zsh: killed ./vphone-vm`** — Restrições de AMFI/debug não foram desativadas; veja [Relaxamento SIP/AMFI](#relaxamento-sipamfi) (`amfi_get_out_of_my_way=1`, a Opção A, ou `make amfi_allow` para esta build, a Opção B). Se você rodou *antes* da última build, rode de novo: a allowlist é por cdhash, e assinar muda o cdhash. Note que isso não pode acontecer com o próprio `vphone-cli`: ele não carrega entitlements, então se *ele* está sendo morto, algo mais está errado.

**`Virtualization is not available on this hardware`** — Seu Mac é uma VM; boot de guest PV=3 não pode ser aninhado. Use um host macOS 15+ não-virtualizado.

**Travado em "Press home to continue"** — Conecte via VNC e clique com botão direito (clique com dois dedos) para simular o botão home.

**Apps do sistema não instalam** — Durante a configuração do iOS, não escolha Japão ou UE como região (verificações regulatórias extras que a VM não consegue satisfazer); escolha por exemplo Estados Unidos.

**App trava ao iniciar com `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`** — Reaplique patches com `vphone-cli fw patch <nome> --variant <v> --force-exc-guard`, depois re-restore/install ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). Sempre ativo para bases iOS 18.

**Instalar um `.ipa`/`.tipa`** — Use o menu Install da VM em execução (arrastar-soltar ou seletor de arquivos).

**Preciso de Homebrew, ou de Xcode, para usar isto?** — Não. O `vphone-cli` roda num macOS 15+ limpo: tudo o que ele chama está em `/usr/bin`, `/bin`, `/usr/sbin` ou `/sbin`, e todo o resto está dentro do `.app`. `make check-aux` é o portão que mantém isso. Compilar do código-fonte é outra história: aí são necessários o Xcode (o iOS SDK contra o qual os binários guest são compilados) e o `git-lfs` (para `scripts/resources`).

**`cfw install` trava re-assinando um binário de sistema (ex: `Campo`), memória crescendo indefinidamente** — Era um bug no `ldid-procursus` até `2.1.5-procursus7`: `bytes(uint64_t)` chamava `__builtin_clzll(0)` sem verificação de zero, que é comportamento indefinido, e naquele build resolvia para um length `0` que causava underflow num contador de loop unsigned — o `ldid` ficava em loop escrevendo um byte por vez num buffer crescente em vez de terminar. Qualquer plist de entitlements com um valor inteiro exatamente `0` acionava isso, e alguns binários de sistema reais da Apple têm um. Não pode mais acontecer: a assinatura é `vphone-cli sign`, no próprio processo, e o `ldid` não é instalado, invocado nem distribuído.

## Automação

`vphone-cli` expõe um socket de controle no host (`<bundle>/vphone.sock`) para controle programático — screenshots, touch, swipes, teclas de hardware, clipboard — cada ação retornando um screenshot inline para testes E2E orientados por IA. Veja [vphone-mcp](https://github.com/pluginslab/vphone-mcp) para um servidor MCP que o encapsula.

## Agradecimentos

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
