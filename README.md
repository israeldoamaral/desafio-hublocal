# 🚀 Stack de Produção: Traefik + Chatwoot + EspoCRM

> **Implantação containerizada de plataforma de atendimento multicanal e CRM em ambiente AWS EC2, com proxy reverso Traefik, SSL via ACM/Route53 e práticas de segurança DevOps.**

---

## 📋 Índice

- [Arquitetura](#-arquitetura)
- [Pré-requisitos](#-pré-requisitos)
- [Estrutura do Projeto](#-estrutura-do-projeto)
- [Instalação Passo a Passo](#-instalação-passo-a-passo)
- [Configuração de Segurança](#-configuração-de-segurança)
- [Backup e Restore](#-backup-e-restore)
- [Monitoramento e Logs](#-monitoramento-e-logs)
- [Decisões Técnicas](#-decisões-técnicas)
- [Firewall — Portas Abertas](#-firewall--portas-abertas)
- [Problemas Conhecidos e Soluções](#-problemas-conhecidos-e-soluções)
- [Uso de IA no Projeto](#-uso-de-ia-no-projeto)

---

## 🏗️ Arquitetura

### Diagrama de Alto Nível

```
                         INTERNET
                            │
                    ┌───────▼───────┐
                    │   Route 53    │  DNS: *.seudominio.com
                    └───────┬───────┘
                            │
                    ┌───────▼───────┐
                    │  AWS ALB/EC2  │  Portas 80 / 443
                    └───────┬───────┘
                            │
              ┌─────────────▼──────────────┐
              │         TRAEFIK v3          │  Reverse Proxy HTTP
              │   traefik.seudominio.com    │  TLS terminado no ALB (ACM)
              └──────┬──────────┬───────────┘
                     │          │
       ┌─────────────▼──┐  ┌───▼──────────────┐
       │    CHATWOOT     │  │     ESPOCRM       │
       │ chat.dominio... │  │  crm.dominio...   │
       └────────┬────────┘  └────────┬──────────┘
                │                    │
   ┌────────────▼────────┐  ┌────────▼─────────┐
   │  ┌──────────────┐   │  │  ┌────────────┐  │
   │  │  Rails Web   │   │  │  │  EspoCRM   │  │
   │  │  Port 3000   │   │  │  │  Port 80   │  │
   │  ├──────────────┤   │  │  ├────────────┤  │
   │  │   Sidekiq    │   │  │  │   Daemon   │  │
   │  │  (workers)   │   │  │  │ Websocket  │  │
   │  ├──────────────┤   │  │  └────────────┘  │
   │  │  PostgreSQL  │   │  │                  │
   │  │  Port 5432   │   │  │  ┌────────────┐  │
   │  ├──────────────┤   │  │  │  MariaDB   │  │
   │  │    Redis     │   │  │  │ Port 3306  │  │
   │  │  Port 6379   │   │  │  └────────────┘  │
   │  └──────────────┘   │  └──────────────────┘
   └─────────────────────┘
```

### Redes Docker

```
┌─────────────────────────────────────────────────────────────┐
│                     traefik-public                          │
│  (Traefik ↔ chatwoot-web ↔ espocrm)                        │
└─────────────────────────────────────────────────────────────┘
┌──────────────────────────┐  ┌──────────────────────────────┐
│    chatwoot-backend       │  │       espocrm-backend        │
│  (web ↔ sidekiq ↔ redis) │  │  (app ↔ daemon ↔ websocket)  │
└──────────────────────────┘  └──────────────────────────────┘
┌──────────────────────────┐  ┌──────────────────────────────┐
│      chatwoot-db          │  │         espocrm-db           │
│  (web/sidekiq ↔ postgres) │  │  (app/daemon ↔ mariadb)      │
└──────────────────────────┘  └──────────────────────────────┘
```

> As redes `*-db` e `*-backend` são **internas** (`internal: true`), sem acesso à internet direta. Apenas `traefik-public` possui roteamento externo.

### Volumes Docker

| Volume                   | Serviço    | Conteúdo                          |
|--------------------------|------------|-----------------------------------|
| `chatwoot-postgres-data` | PostgreSQL | Banco de dados do Chatwoot        |
| `chatwoot-redis-data`    | Redis      | Cache e filas do Sidekiq          |
| `chatwoot-storage`       | Chatwoot   | Arquivos enviados pelos usuários  |
| `espocrm-mariadb-data`   | MariaDB    | Banco de dados do EspoCRM         |
| `espocrm-data`           | EspoCRM    | Arquivos, configurações e uploads |

---

## ✅ Pré-requisitos

### Infraestrutura AWS

- **EC2**: Ubuntu 22.04 LTS, mínimo `t3.medium` (2 vCPU, 4 GB RAM), recomendado `t3.large`
- **Storage EBS**: Mínimo 40 GB SSD (gp3)
- **Route 53**: Domínio configurado com zona hospedada
- **ACM**: Certificado SSL wildcard para `*.seudominio.com` emitido na região correta
- **Security Group**: Portas 22, 80 e 443 abertas

---

## 📁 Estrutura do Projeto

```
.
├── docker-compose.yml          # Orquestração completa da stack
├── .env                        # Domínios para interpolação do Compose (sem segredos)
├── .gitignore                  # Arquivos ignorados pelo Git
│
├── traefik/
│   └── config/
│       ├── traefik.yml         # Configuração estática do Traefik
│       └── dynamic.yml         # Middlewares, headers de segurança
│
└── scripts/
    ├── backup.sh               # Script de backup automatizado
    └── restore.sh              # Script de restore
```

### Separação de responsabilidades dos arquivos `.env`

O Docker Compose tem dois contextos distintos de leitura de variáveis:

- **Interpolação do `docker-compose.yml`** (labels, image tags, etc.): o Compose lê automaticamente o `.env` na raiz do projeto. Por isso `TRAEFIK_DOMAIN`, `CHATWOOT_DOMAIN` e `ESPOCRM_DOMAIN` ficam ali — eles são usados nas labels dos serviços, não dentro dos containers.

- **Variáveis injetadas dentro do container** (senhas, URLs, tokens): essas são declaradas via `env_file` em cada serviço e ficam nos `.env` de cada pasta.

| Arquivo               | Contém                     | Commitar?            |
|-----------------------|----------------------------|----------------------|
| `.env` (raiz)         | Domínios, senha etc        | ❌ Não (com senhas)  |
| `traefik/traefik.yml` | Configurações Estáticas    | ✅ Sim (sem segredos)|
| `scripts/dynamic.yml` | Configurações Dinâmicas    | ✅ Sim (sem segredos)|
| `scripts/backup.sh`   | Comandos Shell             | ✅ Sim (sem segredos)|
| `scripts/restore.sh`  | Comandos Shell             | ✅ Sim (sem segredos)|
| `docker-compose.yml`  | Comandos docker-compose    | ✅ Sim (sem segredos)|
| `.gitignore`          | Regras para o repositório  | ✅ Sim (sem segredos)|
| `READMME.md`          | Documentação               | ✅ Sim (sem segredos)|
---

## 🛠️ Instalação Passo a Passo

### 1. Preparação do servidor EC2

```bash
# Atualizar o sistema
sudo apt-get update && sudo apt-get upgrade -y

# Instalar ferramentas
sudo apt-get install -y apache2-utils curl git unzip ufw

# Instalar Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker


# Verificar instalações
docker --version
docker compose version
```

### 2. Configurar Security Groups na AWS

O controle de acesso é feito inteiramente via Security Groups da AWS — não é necessário instalar UFW na instância.

**Security Group do ALB:**
- Porta 443 TCP — origem `0.0.0.0/0`
- Porta 80 TCP — origem `0.0.0.0/0` (o listener redireciona para 443)

**Security Group da EC2:**
- Porta 22 TCP — origem: seu IP de gestão
- Porta 80 TCP — origem: Security Group do ALB (não da internet)

> Para referenciar o Security Group do ALB como origem na regra da EC2, use o ID do SG do ALB no campo "Source" — ex: `sg-0abc123def456`. Isso garante que apenas o ALB pode encaminhar tráfego para a instância.

### 3. Configurar autenticação SSH (desabilitar senha)

```bash
# Adicionar chave pública do avaliador
mkdir -p ~/.ssh
echo "ssh-rsa CHAVE_PUBLICA_DO_AVALIADOR" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

# Desabilitar autenticação por senha
sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

### 4. Clonar e configurar o projeto

```bash
# Clonar repositório
git clone https://github.com/israeldoamaral/desafio-hublocal.git stack
cd stack

# Renomeie o .env.exemplo para .env
mv .env.exemplo .env

# .env raiz — ajustar os valores das variaveis (não contém segredos)
nano .env

```

### 5. Gerar valores seguros para as variáveis

```bash
# SECRET_KEY_BASE para o Chatwoot
openssl rand -hex 64

# Senhas dos bancos de dados (gerar individualmente)
openssl rand -base64 32
#openssl rand -hex 32

# Hash de senha para o dashboard do Traefik
htpasswd -nb admin 'SUA_SENHA_AQUI' | sed -e 's/\$/\$\$/g'
# Cole o resultado em TRAEFIK_DASHBOARD_PASSWORD_HASH e em dynamic.yml
```

### 7. Subir a stack

```bash
cd stack

# Criar redes externas (se necessário)
docker network create traefik-public 2>/dev/null || true

# Subir todos os serviços
docker compose up -d

# Acompanhar logs (aguardar inicialização completa ~2 min)
docker compose logs -f --tail=50
```

### 9. Verificar saúde dos serviços

```bash
# Status de todos os containers
docker compose ps

# Health check individual
docker inspect --format='{{.State.Health.Status}}' chatwoot-web
docker inspect --format='{{.State.Health.Status}}' chatwoot-postgres
docker inspect --format='{{.State.Health.Status}}' espocrm
docker inspect --format='{{.State.Health.Status}}' espocrm-mariadb
docker inspect --format='{{.State.Health.Status}}' traefik
```

### 10. Configurar EspoCRM (pós-instalação)

1. **SMTP**: configure nas Configurações → Email → Configurações de envio

---

## 🔒 Configuração de Segurança

### Nenhum container roda como root

Todos os containers utilizam usuários não-privilegiados:

| Container | Usuário |
|-----------|---------|
| `chatwoot-postgres` | `70:70` (postgres) |
| `chatwoot-redis` | `999:999` (redis) |
| `espocrm-mariadb` | `999:999` (mysql) |
| `traefik` | Processo sem privilégios + `no-new-privileges` |

### Headers HTTP de segurança (via Traefik middleware)

- `Strict-Transport-Security` (HSTS) com 63072000s + preload
- `X-Frame-Options: SAMEORIGIN`
- `X-Content-Type-Options: nosniff`
- `X-XSS-Protection`
- `Referrer-Policy: strict-origin-when-cross-origin`
- Remoção de `X-Powered-By` e `Server`

### TLS 1.2+ com cipher suites modernas

Configurado em `traefik/config/dynamic.yml`:
- Apenas TLS 1.2 e 1.3
- Cipher suites com Forward Secrecy (ECDHE)
- `sniStrict: true`

### 2FA no Chatwoot

O Chatwoot suporta TOTP nativo. Para habilitar:
1. Acesse: **Perfil → Segurança → Autenticação de dois fatores**
2. Escaneie o QR Code com Google Authenticator ou Authy
3. Salve os códigos de backup

---

## 💾 Backup e Restore

### Configurar backup automático via Cron

```bash
# Tornar scripts executáveis
chmod +x stack/scripts/backup.sh
chmod +x stack/scripts/restore.sh

# Criar diretório de backups
sudo mkdir -p /opt/backups/docker-volumes
sudo chown $USER:$USER /opt/backups/docker-volumes

# Criar arquivo de log
sudo touch /var/log/backup.log
sudo chown $USER:$USER /var/log/backup.log

# Adicionar cron job (backup diário às 02:00)
crontab -e
```

Adicione ao crontab:

```cron
# Backup completo da stack — diário às 02:00
0 2 * * * /opt/stack/scripts/backup.sh >> /var/log/backup.log 2>&1

# Backup apenas do Chatwoot — diário às 02:30
# 30 2 * * * /opt/stack/scripts/backup.sh chatwoot >> /var/log/backup.log 2>&1

# Backup apenas do EspoCRM — diário às 02:45
# 45 2 * * * /opt/stack/scripts/backup.sh espocrm >> /var/log/backup.log 2>&1
```

### Executar backup manualmente

```bash
# Backup completo
./scripts/backup.sh

# Backup apenas do Chatwoot
./scripts/backup.sh chatwoot

# Backup apenas do EspoCRM
./scripts/backup.sh espocrm
```

### Listar backups disponíveis

```bash
./scripts/restore.sh --list
```

Saída de exemplo:
```
ARQUIVO                                      TAMANHO    DATA
─────────────────────────────────────────────────────────────────
chatwoot-postgres_20250101_020000.sql.gz      45.2 MB   2025-01-01 02:00
chatwoot-storage_20250101_020001.tar.gz      128.7 MB   2025-01-01 02:00
espocrm-mariadb_20250101_020005.sql.gz        12.3 MB   2025-01-01 02:00
espocrm-data_20250101_020006.tar.gz           31.5 MB   2025-01-01 02:00
```

### Procedimento de Restore

> ⚠️ **ATENÇÃO**: O restore **sobrescreve** os dados atuais. Execute apenas em manutenção planejada.

```bash
# Restaurar Chatwoot a partir de backup de 01/01/2025 às 02:00
./scripts/restore.sh --service chatwoot --date 20250101_020000

# Restaurar EspoCRM
./scripts/restore.sh --service espocrm --date 20250101_020000
```

O script irá:
1. Exibir um aviso e solicitar confirmação digitando `CONFIRMAR`
2. Parar os containers do serviço selecionado
3. Restaurar o banco de dados (dump SQL)
4. Restaurar o volume de dados (tar.gz)
5. Reiniciar os containers automaticamente

### Restore manual (banco de dados)

```bash
# PostgreSQL (Chatwoot)
zcat /opt/backups/docker-volumes/chatwoot-postgres_TIMESTAMP.sql.gz \
  | docker exec -i chatwoot-postgres psql -U chatwoot -d chatwoot_production

# MariaDB (EspoCRM)
zcat /opt/backups/docker-volumes/espocrm-mariadb_TIMESTAMP.sql.gz \
  | docker exec -i espocrm-mariadb mysql -u espocrm -pSENHA espocrm
```

### Restore manual (volume)

```bash
# Parar os serviços que usam o volume
docker compose stop chatwoot-web chatwoot-sidekiq

# Restaurar volume
docker run --rm \
  -v chatwoot-storage:/data \
  -v /opt/backups/docker-volumes:/backup:ro \
  alpine:latest \
  tar xzf /backup/chatwoot-storage_TIMESTAMP.tar.gz -C /data

# Reiniciar serviços
docker compose start chatwoot-web chatwoot-sidekiq
```

---

## 📊 Monitoramento e Logs

### Ver logs em tempo real

```bash
# Todos os serviços
docker compose logs -f

# Serviço específico
docker compose logs -f chatwoot-web
docker compose logs -f traefik

# Últimas 100 linhas
docker compose logs --tail=100 chatwoot-web
```

### Verificar uso de recursos

```bash
# Uso de CPU e memória (tempo real)
docker stats

# Status e health de todos os containers
docker compose ps
```

### Inspecionar health checks

```bash
# Status de saúde detalhado
docker inspect --format='
Container: {{.Name}}
Status: {{.State.Health.Status}}
FailingStreak: {{.State.Health.FailingStreak}}
' $(docker compose ps -q)
```

---

## 🧠 Decisões Técnicas

### Por que Ubuntu 22.04 LTS?

Ubuntu 22.04 LTS (Jammy) foi escolhido por ser o sistema suportado oficialmente até **Abril de 2027**, com amplo suporte da comunidade, repositórios atualizados do Docker Engine e compatibilidade total com todas as imagens utilizadas. O Debian 12 seria igualmente adequado, mas a documentação da AWS EC2 é mais abrangente para Ubuntu.

### Por que Traefik v3 ao invés de Nginx Proxy Manager?

| Critério                 | Traefik v3                       | Nginx Proxy Manager |
|--------------------------|----------------------------------|---------------------|
| Auto-discovery Docker    | ✅ Nativo via labels             | ❌ Manual           |
| Integração ACM/ALB       | ✅ Transparente (HTTP interno)   | ✅ Via UI           |
| Configuração como código | ✅ YAML + Labels                 | ❌ GUI-driven       |
| Métricas Prometheus      | ✅ Nativo                        | ❌ Plugin           |
| Overhead de memória      | ~30 MB                           | ~150 MB             |

O Traefik v3 se integra nativamente ao Docker via socket, detecta novos containers automaticamente por labels e opera como proxy HTTP puro atrás do ALB — que termina o TLS com o certificado ACM.

### Por que ACM + ALB para o SSL?

Os certificados ACM da AWS são gerenciados nativamente pelo ALB — renovação automática, sem custo adicional e sem necessidade de armazenar ou expor chaves privadas nos containers. O ALB termina o TLS e encaminha o tráfego como HTTP para o Traefik na porta 80, mantendo a stack simples e segura. O Security Group da EC2 é configurado para aceitar tráfego na porta 80 apenas do ALB, nunca diretamente da internet.

### Por que PostgreSQL 15 para o Chatwoot?

O Chatwoot é desenvolvido e testado oficialmente com PostgreSQL. O uso de versão 15 (alpine) garante menor footprint de imagem, suporte a longo prazo e compatibilidade com as migrations do Rails.

### Por que MariaDB 10.11 para o EspoCRM?

A documentação oficial do EspoCRM recomenda MySQL/MariaDB. O MariaDB 10.11 é a versão LTS mais recente, com suporte até 2028, e oferece melhor desempenho em queries de CRM com índices Full-Text.

### Segmentação de redes Docker

A criação de redes separadas (`chatwoot-db`, `espocrm-db` como `internal: true`) garante que os containers de banco de dados **não possuem acesso à internet** e só são alcançáveis pelos containers de aplicação autorizados. Isso segue o princípio de least privilege em nível de rede.

---

## 🔥 Firewall — Portas Abertas

### Por que não usar UFW na instância EC2?

Em ambientes AWS com ALB, o controle de tráfego é feito em duas camadas gerenciadas pela própria AWS, tornando o UFW redundante e desnecessário:

- **Security Group do ALB**: controla o que entra da internet para o ALB (portas 80 e 443)
- **Security Group da EC2**: controla o que o ALB pode encaminhar para a instância

O UFW opera no nível do sistema operacional, depois que o pacote já chegou na instância. Com Security Groups, o pacote nem chega — é bloqueado na borda da infraestrutura AWS, o que é mais eficiente e seguro.

Adicionar UFW em cima dos Security Groups criaria dupla camada de regras para manter sincronizadas, aumentando o risco de erro humano sem ganho real de segurança.

### Security Group — ALB

| Porta | Protocolo | Origem | Justificativa |
|-------|-----------|--------|---------------|
| 80 | TCP | 0.0.0.0/0 | HTTP — redireciona para HTTPS no listener do ALB |
| 443 | TCP | 0.0.0.0/0 | HTTPS — tráfego principal com certificado ACM |

### Security Group — EC2

| Porta | Protocolo | Origem | Justificativa |
|-------|-----------|--------|---------------|
| 22 | TCP | IP do gestor | SSH — acesso administrativo direto |
| 80 | TCP | Security Group do ALB | Tráfego HTTP encaminhado pelo ALB para o Traefik |

> A porta 80 da EC2 só aceita tráfego originado do Security Group do ALB — nunca diretamente da internet. Isso garante que todo o tráfego passa obrigatoriamente pelo ALB e pelo certificado ACM.

**Portas fechadas intencionalmente:**

| Porta | Serviço | Motivo |
|-------|---------|--------|
| 443 | HTTPS direto na EC2 | TLS é terminado no ALB, não na instância |
| 5432 | PostgreSQL | Acessível apenas via rede Docker interna |
| 6379 | Redis | Acessível apenas via rede Docker interna |
| 3306 | MariaDB | Acessível apenas via rede Docker interna |
| 8080 | Traefik API | Dashboard acessível apenas via roteamento interno do Traefik com autenticação |

---

## 🐞 Problemas Conhecidos e Soluções

### 1. Chatwoot: `PG::ConnectionBad` na inicialização

**Causa**: O container da aplicação sobe antes do PostgreSQL estar pronto.

**Solução**: O `depends_on` com `condition: service_healthy` e o healthcheck do PostgreSQL resolvem isso. Se persistir:

```bash
docker compose restart chatwoot-web
```

### 2. Traefik: serviço retorna 404 ou Bad Gateway

**Causa**: Label de roteamento incorreta ou container não conectado à rede `traefik-public`.

**Diagnóstico**:
```bash
docker compose logs traefik | grep -i "error\|404\|gateway"
# Verificar se o container está na rede correta
docker inspect chatwoot-web | grep -A 10 Networks
```

**Solução**: Confirme que o serviço tem `traefik.enable=true` nas labels e está na rede `traefik-public` no `docker-compose.yml`.


### 3. Redis: `WRONGPASS` no Chatwoot

**Causa**: Senha do Redis no `.env` não corresponde à configurada no container.

**Solução**: Confirme que `REDIS_PASSWORD` e `REDIS_URL` usam a mesma senha, e que o container foi recriado após a mudança:

```bash
docker compose up -d --force-recreate chatwoot-redis
```


## 🤖 Uso de IA no Projeto

Este projeto utilizou **Claude (Anthropic)** como ferramenta de auxílio no desenvolvimento. A IA foi usada para:

- **Geração de boilerplate**: estrutura inicial do `docker-compose.yml`, scripts de backup/restore e configurações do Traefik
- **Revisão de segurança**: verificação de boas práticas (usuários não-root, redes internas, headers HTTP)
- **Documentação**: estruturação do README e diagramas ASCII
- **Troubleshooting**: sugestões para cenários de erro conhecidos

**Como a IA foi usada na prática**:
> "Gerei os arquivos de configuração com Claude, revisei cada bloco individualmente, ajustei para o contexto específico (AWS EC2 + Route53 + ACM) e validei contra a documentação oficial de cada ferramenta (Traefik, Chatwoot, EspoCRM). Nenhum arquivo foi copiado sem revisão crítica."

O uso responsável de IA em DevOps significa usar como **acelerador de produtividade**, não como substituto do entendimento técnico.

---

## 📜 Licença

Este projeto é de uso livre para fins educacionais e de avaliação técnica.

---

*Desenvolvido com ☕ e assistência de IA para o Desafio Técnico DevOps*
