# Controle de acesso do Trino — como funciona e como verificar

O Trino é o ponto de controle de acesso por **pessoa**: quem consulta, e quais
camadas enxerga. Vale para a VM2 (`docker-compose.lakehouse-vm2.yml`); o
ambiente local de desenvolvimento roda sem autenticação.

## Peças

| Peça | Arquivo | Papel |
|------|---------|-------|
| Autenticação | `config.properties` | Senha obrigatória, só por HTTPS (porta 8443 do container) |
| Senhas | `.env_secrets/trino_password.db` | `usuario:hash` bcrypt — nunca senha em claro |
| Grupos | `.env_secrets/trino_groups.txt`, lido por `group-provider.properties` | `grupo:usuario1,usuario2` |
| Regras | `rules.json`, lido por `access-control.properties` | O que cada grupo pode fazer |
| Provisionamento | `scripts/trino/set-user.sh <user> <nivel>` | Cria usuário, gera senha e define o grupo |

Os arquivos de senha e de grupo ficam fora do Git. O Trino relê os dois e as
regras a cada 5 segundos: criar usuário ou trocar de nível não exige reinício.

## Níveis

O usuário não aparece em `rules.json`. As regras são por **grupo**, e mudar o
nível de alguém é mudar o grupo.

| Grupo | Consulta | DDL e administração | `register_table` |
|-------|----------|---------------------|------------------|
| `admin` | `bronze`, `silver`, `gold` | Sim | Sim |
| `engenharia` | `bronze`, `silver`, `gold` | Não | Não |
| `analista` | `silver`, `gold` — **sem `bronze`** | Não | Não |

## O que as regras garantem

- **Analista não vê dado bruto.** O grupo `analista` não tem regra de schema
  nem de tabela para `bronze`.
- **Só `admin` administra.** Encerrar consultas de outros, alterar propriedades
  de sessão do sistema e executar `register_table` / `unregister_table` são
  exclusivos do grupo.
- **`register_table` fica ligado no catálogo**
  (`delta.register-table-procedure.enabled=true`) e é contido pelas regras: a
  restrição a `admin` existe só em `rules.json`.
- **O catálogo `delta` é visível a todos os grupos.** Sem isso, clientes como
  o DBeaver não listam o catálogo.
- **Não há regra aberta** do tipo "qualquer usuário, qualquer catálogo".
- **`execute` e `view` ficam na mesma regra por grupo.** No Trino a primeira
  regra que casa vence; separadas, o cliente falha com `Cannot view query`.

```json
"queries": [
  { "group": "admin", "allow": ["execute", "view", "kill"] },
  { "group": "engenharia", "allow": ["execute", "view"] },
  { "group": "analista", "allow": ["execute", "view"] }
]
```

## Como verificar

Criar um usuário de teste por nível:

```bash
./scripts/trino/set-user.sh usr_k4t9 admin
./scripts/trino/set-user.sh usr_m2x7 engenharia
./scripts/trino/set-user.sh usr_p8d3 analista
```

Na primeira execução os arquivos de senha e de grupo são criados; nesse caso
recrie o Trino para montá-los:
`docker compose -f docker-compose.lakehouse-vm2.yml up -d --force-recreate trino`.

| Quem | Consulta | Resultado esperado |
|------|----------|--------------------|
| `analista` | `SELECT count(*) FROM delta.bronze.<tabela>` | `Access Denied` |
| `analista` | `SELECT count(*) FROM delta.silver.<tabela>` | Retorna a contagem |
| `engenharia` | `SELECT count(*) FROM delta.bronze.<tabela>` | Retorna a contagem |
| `engenharia` | `CALL delta.system.register_table(...)` | `Access Denied` |
| Sem usuário e senha | Qualquer conexão | Recusada |

## Controles de plataforma

- O host publica só a porta HTTPS do Trino. A porta HTTP interna (8080) fica
  restrita à rede Docker.
- O segredo de comunicação interna e a senha do keystore chegam por arquivo em
  `.env_secrets/`, nunca por `.env`.
- `.env_secrets/` tem permissão `700`; segredos e truststore, `600`. Os
  arquivos de senha e de grupo são `644` porque o processo do Trino precisa
  lê-los — eles só contêm hashes e nomes.
- A conta de serviço do Trino no MinIO é somente leitura. Mesmo que uma regra
  SQL fosse aberta por engano, o Trino não conseguiria gravar nos buckets.

Ver também: [`../minio/POLICIES-VERIFICACAO.md`](../minio/POLICIES-VERIFICACAO.md),
o controle de acesso por serviço.
