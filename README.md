# anon-up · privacidade no máximo realista com um comando

Com um comando, o `anon-up` liga no **Linux** (Debian/Ubuntu, Arch, Fedora) e no **Termux** (Android):

| Recurso | Linux com root/sudo | Termux com root | Termux sem root |
|---|---|---|---|
| VPN WireGuard (Proton VPN / Mullvad) | sim (`wg-quick`) | sim (experimental) | não: usa o app da VPN |
| Kill switch (sem VPN, sem internet) | sim (`nftables`, ou `iptables` se faltar) | sim (`iptables`) | não: usa "Bloquear conexões sem VPN" do Android |
| Bloqueio de rastreadores (ATP local) | sim (`dnsmasq` + StevenBlack/Hagezi/OISD) | não | não: usa ATP do DuckDuckGo |
| DNS criptografado (DoH) | sim (`dnscrypt-proxy`) | não: DNS privado do Android | não: DNS privado do Android |
| IPv6 bloqueado | sim | não | não |
| MAC aleatório, sem mDNS/LLMNR/Avahi, hostname genérico | sim | não | não |
| Tor (`--tor`) | sim | sim | sim (sempre) |

Quando um recurso não roda no ambiente, o script avisa e explica o que fazer à mão. Ele nunca diz que ativou algo que não ativou.

## Instalação

```bash
git clone https://github.com/Hats444/vpn-all.git && cd vpn-all
chmod +x anon-up.sh anon-down.sh anon-status.sh
```

1. Baixe o arquivo WireGuard (`.conf`) no site do provedor:
   - **Proton VPN:** Account → Downloads → WireGuard configuration.
   - **Mullvad:** Account → WireGuard configuration.
2. Coloque o arquivo num lugar protegido (`chmod 600 arquivo.conf`) e aponte para ele em `config.env`:
   ```bash
   VPN_CONFIG_PATH="/root/vpn/proton-br.conf"
   ```
3. Ligue:
   ```bash
   sudo ./anon-up.sh          # Linux
   ./anon-up.sh               # Termux (usa su se tiver root)
   ```

O script instala sozinho o que faltar (`apt`, `pacman`, `dnf` ou `pkg`): `wireguard-tools`, `nftables`, `dnsmasq`, `dnscrypt-proxy`, `tor`, `torsocks` e `proxychains-ng`.

## Uso

```bash
sudo ./anon-up.sh                 # liga tudo
sudo ./anon-up.sh --tor           # liga tudo e mais o Tor (SOCKS 127.0.0.1:9050)
sudo ./anon-up.sh --no-block      # sem as listas de bloqueio
sudo ./anon-up.sh --update-lists  # só atualiza as listas e recarrega o DNS
sudo ./anon-up.sh --dry-run       # mostra o que faria, sem mudar nada
./anon-status.sh                  # IP, país, DNS, VPN, kill switch e teste de vazamento
sudo ./anon-down.sh               # desfaz tudo
```

Rodar duas vezes não quebra nada. O que já está ligado continua como está, e o kill switch é recriado.

Para atualizar as listas todo dia, coloque no `crontab -e` do root:
```
0 4 * * * /caminho/vpn-all/anon-up.sh --update-lists >/dev/null 2>&1
```

## Como funciona

```
apps → 127.0.0.1:53 dnsmasq ──(rastreador? → 0.0.0.0)──► dnscrypt-proxy 127.0.0.1:5353 ──DoH──┐
apps → tráfego ────────────────────────────────────────────────────────────────► wg (anon0) ─┴─► servidor VPN → internet
                                                         nftables: tudo fora de anon0/lo = DROP
```

- **VPN:** o `.conf` do provedor sobe com `wg-quick`. A linha `DNS=` é ignorada, porque quem resolve nomes é o DNS local.
- **Kill switch:** a tabela `inet anon_up` do nftables bloqueia, por padrão, todo tráfego de saída. Só passam a loopback, a interface da VPN, o handshake com o servidor (IP e porta do `Endpoint`) e o DHCP. Se a VPN cair, a internet cai junto e o IP real não aparece.
- **ATP local (bloqueio de rastreadores):** funciona como o App Tracking Protection do DuckDuckGo, só que pra máquina inteira. O `dnsmasq` responde `0.0.0.0` para os domínios das listas (Google Ads, Facebook, Amazon etc.). O resto ele repassa ao `dnscrypt-proxy`, que pergunta via DoH (Quad9/Mullvad) através do túnel.
- **Anti-vazamento:** IPv6 desligado e bloqueado no firewall, o `resolv.conf` aponta só para `127.0.0.1`, o NetworkManager não sobrescreve o DNS (`dns=none`) e o DNS em texto puro não tem como sair fora da VPN.
- **Hardening:** MAC aleatório pelo NetworkManager (vale na próxima conexão), Avahi/mDNS/LLMNR desligados e hostname `anon-host`.
- **Tor (`--tor`):** SOCKS em `127.0.0.1:9050`. Use `torsocks curl ...` ou o navegador apontando para o SOCKS. O Tor sai pelo túnel da VPN.
- **Desfazer:** tudo que é alterado fica anotado em `/var/lib/anon-up` (ou `~/.anon-up` no Termux), e o `anon-down.sh` volta cada item ao estado anterior. Se o `anon-up` falhar no meio, um `trap` chama o `anon-down` sozinho.

## Termux sem root

Sem root não existe `/dev/tun` nem firewall. Nesse caso o script liga o Tor + `torsocks`/`proxychains` e mostra o passo a passo do Android:

1. **DNS privado:** Configurações → Rede → DNS privado → `dns.mullvad.net` (ou `dns.adguard-dns.com`, que também bloqueia anúncios).
2. Instale e conecte o **Proton VPN** ou o **DuckDuckGo VPN**.
3. **Kill switch:** Configurações → VPN → (app) → **VPN sempre ativa** + **Bloquear conexões sem VPN**.
4. Para rastreadores dentro dos apps: **App Tracking Protection** do DuckDuckGo. Ele ocupa o slot de VPN, então não funciona junto com outra VPN.

## Testes

```bash
bash tests/run-tests.sh   # sintaxe, endpoint, listas, nft -c, dnsmasq --test, dry-run Linux e Termux
```

Nenhum teste mexe na rede. O CI pronto está em `ci/github-actions.yml`: para ligar, mova o arquivo para `.github/workflows/ci.yml`. Ele roda o ShellCheck e esses testes em todo push e PR.

## O que isto NÃO garante

- **Não existe anonimato total.** O provedor da VPN vê seu tráfego. A política de não guardar logs depende de confiar nele.
- **Fingerprinting do navegador** (canvas, fontes, tamanho de tela, WebRTC) continua identificando você. Use Tor Browser ou Mullvad Browser para isso.
- **Contas logadas, cookies e o próprio comportamento** (Google, redes sociais, e-mail) revelam quem você é, com ou sem VPN.
- **Malware, phishing e apps espiões** não são bloqueados.
- **Adversário global** que vê os dois lados da conexão pode correlacionar o tráfego, mesmo com Tor.
- As listas de bloqueio não pegam todos os rastreadores, e alguns apps podem quebrar. Nesse caso use `--no-block`.
- No Android, o script não muda as configurações do sistema por você.

## 🎵 Trilha

Para longas sessões de terminal: *Unethical* (Faouzia), na versão épica instrumental, que também toca no [hats444.github.io](https://hats444.github.io).

