# Políticas do MinIO — como funcionam e como verificar

O MinIO é o segundo ponto de controle de acesso do lakehouse: o Trino decide o
que cada **pessoa** enxerga; o MinIO decide o que cada **serviço** pode fazer
com os arquivos.

## Como o MinIO decide o acesso

1. Existe uma **política nomeada** (documento IAM: Effect + Action + Resource).
2. A **conta** (access key) recebe essa política anexada.
3. Cada requisição S3 é avaliada: o que não estiver em um `Allow` é negado
   com `AccessDenied`.

Criar a conta não basta: sem política anexada, ela não lê nem grava nada.

## Buckets

Criados pelo `scripts/minio/init.sh`:

| Bucket | Uso | Versionamento |
|--------|-----|---------------|
| `bronze`, `silver`, `gold` | Camadas medalhão (tabelas Delta) | Ligado; versões antigas expiram em 10 dias (`MINIO_LIFECYCLE_NONCURRENT_DAYS`) |
| `landing` | Arquivos recebidos, antes da ingestão | Ligado; versões antigas expiram em 30 dias (`MINIO_LIFECYCLE_SUPPORT_NONCURRENT_DAYS`) |
| `markers` | Marcadores de controle dos pipelines | Ligado; versões antigas expiram em 30 dias (`MINIO_LIFECYCLE_SUPPORT_NONCURRENT_DAYS`) |

## Dois tipos de política

| Tipo | Onde fica | Para quem | Como é criada |
|------|-----------|-----------|---------------|
| **Interna** | JSON versionado: `policies/trino-read.json`, `policies/hive-meta.json` | Contas de serviço do Trino e do Hive Metastore | Registrada pelo `init.sh`; a conta sai de `set-user.sh trino\|hive` |
| **Sob demanda** | Gerada pelo script na hora — não vai para o Git | Cargas, outros serviços e pessoas | `set-user.sh <access_key> --read/--write` |

O `init.sh` (ou `bootstrap.sh`, que o reexecuta) cuida só da infraestrutura:
buckets, versionamento e políticas internas. Ele **não cria contas**.

`spark-ingest.json` e `spark-process.json` são **modelos de referência** para
as contas de ingestão e de processamento. Não são registrados na inicialização.

## Contas internas

```bash
./scripts/minio/set-user.sh trino --write-secrets   # gera e grava em .env_secrets/
./scripts/minio/set-user.sh hive  --write-secrets
./scripts/minio/set-user.sh hive  --from-secrets    # reaplica credenciais que já existem
```

As duas políticas internas só têm leitura (`GetObject`, `ListBucket`): nem o
Trino nem o Hive Metastore conseguem gravar ou apagar objetos.

## Contas novas

O escopo é passado por parâmetro; o script monta a política e a anexa.

```bash
# Leitura de um prefixo
./scripts/minio/set-user.sh <access_key> --read <bucket>/<prefix>

# Leitura em vários caminhos
./scripts/minio/set-user.sh <access_key> --read <bucket>/<p1>,<bucket>/<p2>

# Bucket inteiro — só quando o papel exigir
./scripts/minio/set-user.sh <access_key> --read bronze,silver,gold

# Serviço com escrita, gravando as credenciais em .env_secrets/
./scripts/minio/set-user.sh <access_key> --read bronze --write silver \
  --write-secrets --secrets-name <nome_logico>
```

| Parâmetro | Permissões concedidas |
|-----------|-----------------------|
| `--read` | `GetObject` + `ListBucket` (restrito ao prefixo, quando informado) |
| `--write` | `PutObject` + `AbortMultipartUpload` + `ListBucket` no mesmo escopo |

- O escopo é `bucket` ou `bucket/prefixo`; vários, separados por vírgula.
- **Sem `DeleteObject`**: uma conta criada assim não apaga objetos.
- A política fica registrada como `policy-user-<access_key>` e é recriada a
  cada execução — rodar de novo com outro escopo substitui o anterior.
- A chave secreta aparece uma única vez no terminal, a menos que se use
  `--write-secrets`.

## Como verificar

| Verificação | Resultado esperado |
|-------------|--------------------|
| `mc admin user info local <access_key>` | A conta existe e mostra a política anexada |
| `mc admin policy info local <policy>` | O documento lista só os buckets/prefixos pedidos |
| Conta do Trino tentando gravar em qualquer bucket | `AccessDenied` |
| Conta com `--read <bucket>/<prefix>` listando outro prefixo | `AccessDenied` |
| Conta criada pelo `set-user.sh` tentando apagar um objeto | `AccessDenied` |

Ver também: [`../trino/ACL-VERIFICACAO.md`](../trino/ACL-VERIFICACAO.md), o
controle de acesso por pessoa.
