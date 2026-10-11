# Políticas versionadas

## Internas — registradas na inicialização

| Arquivo | Política no MinIO | Conta |
|---------|-------------------|-------|
| `trino-read.json` | `policy-trino-read` | Conta de serviço do Trino (só leitura) |
| `hive-meta.json` | `policy-hive-meta` | Conta de serviço do Hive Metastore (só leitura) |

As contas são criadas por `scripts/minio/set-user.sh trino|hive`.

## Modelos de referência — não registrados na inicialização

| Arquivo | Papel |
|---------|-------|
| `spark-ingest.json` | Conta de ingestão: escreve em `bronze` e `landing` |
| `spark-process.json` | Conta de processamento: lê `bronze` e `landing`, escreve em `silver` e `gold` |

Os dois modelos incluem `s3:DeleteObject`: reescrita e VACUUM de tabela Delta
apagam arquivos. As políticas geradas pelo `set-user.sh` não incluem.

## Contas novas

Não precisam de JSON aqui: o escopo é passado por parâmetro.

```bash
./scripts/minio/set-user.sh <access_key> --read bucket[/prefix] [--write ...]
```

Detalhes e verificação: [`../POLICIES-VERIFICACAO.md`](../POLICIES-VERIFICACAO.md).
