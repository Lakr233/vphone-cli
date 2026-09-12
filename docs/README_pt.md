<div align="right"><strong><a href="./README_ko.md">🇰🇷한국어</a></strong> | <strong><a href="./README_ja.md">🇯🇵日本語</a></strong> | <strong><a href="./README_zh.md">🇨🇳中文</a></strong> | <strong><a href="./README_ru.md">🇷🇺Русский</a></strong> | <strong><a href="../README.md">🇬🇧English</a></strong> | <strong>🇧🇷Português</strong></div>

# vphone-cli

Inicie um iPhone virtual usando o Virtualization.framework da Apple com a infraestrutura de VMs de pesquisa PCC.

![poc](./demo.jpeg)

## Pré-requisitos

**Host:**

- Apple Silicon
- macOS 15+ (Sequoia)
- Xcode + iOS SDK (para compilação cruzada do daemon guest)
- [Relaxamento de SIP/AMFI para permitir entitlements privados PV=3 com binário não assinado](#relaxamento-sipamfi)

**Dependências:**

```bash
brew install python@3.13 aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone cmake libusb ipsw zstd
```

## Instalação

```bash
brew install zqxwce/tap/vphone-cli
```

## Compilação

```bash
git clone --recurse-submodules https://github.com/Lakr233/vphone-cli.git

./scripts/setup_tools.sh      # instala dependências, compila submodules do toolchain, cria o venv Python
./scripts/build.sh            # compila + assina vphone-cli, empacota o .app, compila vphoned para iOS

cd .build/vphone-cli.app/Contents/MacOS/
vphone-cli --help
```

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
| `~/.vphone/venv/` | Ambiente Python provisionado automaticamente; substitua com `$VPHONE_VENV_DIR`. |

Precedência: as substituições por item (`$VPHONE_LIBRARY_ROOT`, `$VPHONE_VENV_DIR`) têm prioridade sobre `$VPHONE_ROOT`, que tem prioridade sobre o padrão `~/.vphone`. Os caches `ipsws/`, `tools/` e `debs/` sempre ficam diretamente sob qualquer raiz ativa.

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

**Opção B — manter SIP ligado (relaxado apenas para debug), depois allowlist o binário com amfidont** (mantém AMFI habilitado em todo o sistema).

No Recovery:

```bash
csrutil enable --without debug
csrutil allow-research-guests enable
```

Depois reinicie no macOS e:

```bash
vphone-amfidont         # .build/vphone-cli.app/Contents/Resources/vphone-amfidont para builds locais
```

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

**`zsh: killed ./vphone-cli`** — Restrições de AMFI/debug não foram desativadas; veja [Pré-requisitos](#pré-requisitos) (`amfi_get_out_of_my_way=1` ou `amfidont`).

**`Virtualization is not available on this hardware`** — Seu Mac é uma VM; boot de guest PV=3 não pode ser aninhado. Use um host macOS 15+ não-virtualizado.

**Travado em "Press home to continue"** — Conecte via VNC e clique com botão direito (clique com dois dedos) para simular o botão home.

**Apps do sistema não instalam** — Durante a configuração do iOS, não escolha Japão ou UE como região (verificações regulatórias extras que a VM não consegue satisfazer); escolha por exemplo Estados Unidos.

**App trava ao iniciar com `EXC_GUARD` / `GUARD_TYPE_MACH_PORT`** — Reaplique patches com `vphone-cli fw patch <nome> --variant <v> --force-exc-guard`, depois re-restore/install ([#291](https://github.com/Lakr233/vphone-cli/issues/291)). Sempre ativo para bases iOS 18.

**Instalar um `.ipa`/`.tipa`** — Use o menu Install da VM em execução (arrastar-soltar ou seletor de arquivos).

**`cfw install` trava re-assinando um binário de sistema (ex: `Campo`), memória crescendo indefinidamente** — Bug conhecido no `ldid-procursus` até `2.1.5-procursus7` (o `stable` atual do Homebrew): `bytes(uint64_t)` chama `__builtin_clzll(0)` sem verificação de zero, que é comportamento indefinido, e neste build resolve para um length `0` que causa underflow em um contador de loop unsigned — `ldid` fica em loop escrevendo um byte por vez em um buffer crescente ao invés de terminar. Acionado por *qualquer* plist de entitlements contendo um valor inteiro exatamente `0` (alguns binários reais de sistema Apple têm isso). Corrigido upstream mas ainda não em uma release tagged; recompile do fonte: `brew install --HEAD ldid-procursus && brew link --overwrite ldid-procursus`. Mate o processo `ldid` travado primeiro (`sudo kill -9 <pid>`) se já tiver sido afetado.

## Automação

`vphone-cli` expõe um socket de controle no host (`<bundle>/vphone.sock`) para controle programático — screenshots, touch, swipes, teclas de hardware, clipboard — cada ação retornando um screenshot inline para testes E2E orientados por IA. Veja [vphone-mcp](https://github.com/pluginslab/vphone-mcp) para um servidor MCP que o encapsula.

## Agradecimentos

- [wh1te4ever/super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
