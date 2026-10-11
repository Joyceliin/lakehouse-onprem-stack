"""
Utilitario transversal de reconciliacao entre fonte e Delta Lake.

Fontes suportadas por dataset: JDBC, arquivo (CSV/Parquet/JSON) ou Delta.
Cada projeto fornece um YAML com datasets, origem, destino e tolerancias.
"""
import argparse
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

for root in ("/opt/scripts", "/opt/airflow/dags", "/opt/spark/jobs"):
    if os.path.isdir(root) and root not in sys.path:
        sys.path.insert(0, root)

import yaml
from pyspark.sql import DataFrame, SparkSession
from pyspark.sql.functions import max as spark_max


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Reconciliacao JDBC x Delta")
    parser.add_argument(
        "--config",
        required=True,
        help="Caminho do arquivo de configuracao do projeto.",
    )
    return parser.parse_args()


def load_config(path: str) -> dict[str, Any]:
    config_path = Path(path)
    if not config_path.exists():
        raise FileNotFoundError(f"Configuracao nao encontrada: {path}")

    with config_path.open("r", encoding="utf-8") as file:
        config = yaml.safe_load(file) or {}

    if not config.get("datasets"):
        raise ValueError("Configuracao deve conter a chave 'datasets'.")

    return config


def env_value(name: str | None, default: str | None = None) -> str | None:
    if not name:
        return default
    return os.getenv(name, default)


def jdbc_options(config: dict[str, Any]) -> dict[str, str]:
    jdbc = config.get("source", {}).get("jdbc", {})

    url = jdbc.get("url")
    if not url:
        host = jdbc.get("host") or os.getenv("POSTGRES_HOST", "postgres")
        port = str(jdbc.get("port") or os.getenv("POSTGRES_PORT", "5432"))
        database = jdbc.get("database") or os.getenv("POSTGRES_DB")
        if not database:
            raise ValueError("Informe source.jdbc.database ou POSTGRES_DB.")
        url = f"jdbc:postgresql://{host}:{port}/{database}"

    user = jdbc.get("user") or env_value(jdbc.get("user_env"), os.getenv("POSTGRES_USER"))
    password = jdbc.get("password") or env_value(
        jdbc.get("password_env"),
        os.getenv("POSTGRES_PASSWORD"),
    )

    if not user or not password:
        raise ValueError("Credenciais JDBC devem vir da configuracao ou do ambiente.")

    return {
        "url": url,
        "user": user,
        "password": password,
        "driver": jdbc.get("driver", "org.postgresql.Driver"),
    }


def source_table(dataset: dict[str, Any]) -> str:
    source = dataset.get("source", {})
    if source.get("query"):
        return f"({source['query']}) reconciliation_source"
    if source.get("table"):
        return source["table"]
    raise ValueError(f"Dataset {dataset.get('name')} sem source.table ou source.query.")


def read_file_source(spark: SparkSession, file_cfg: dict[str, Any]) -> DataFrame:
    path = file_cfg.get("path")
    if not path:
        raise ValueError("source.file.path e obrigatorio.")

    fmt = file_cfg.get("format", "csv")
    reader = spark.read.format(fmt)
    if fmt == "csv":
        reader = reader.option("header", str(file_cfg.get("header", True)).lower())
        if file_cfg.get("infer_schema", True):
            reader = reader.option("inferSchema", "true")
    return reader.load(path)


def read_source(
    spark: SparkSession,
    dataset: dict[str, Any],
    jdbc_options_map: dict[str, str] | None,
) -> DataFrame:
    source = dataset.get("source", {})

    if source.get("file"):
        return read_file_source(spark, source["file"])

    if source.get("delta"):
        delta_cfg = source["delta"]
        path = delta_cfg.get("path")
        if not path:
            raise ValueError(f"Dataset {dataset.get('name')} sem source.delta.path.")
        return spark.read.format(delta_cfg.get("format", "delta")).load(path)

    if not jdbc_options_map:
        raise ValueError(
            f"Dataset {dataset.get('name')} usa JDBC, mas source.jdbc nao foi configurado."
        )

    return (
        spark.read.format("jdbc")
        .option("url", jdbc_options_map["url"])
        .option("dbtable", source_table(dataset))
        .option("user", jdbc_options_map["user"])
        .option("password", jdbc_options_map["password"])
        .option("driver", jdbc_options_map["driver"])
        .load()
    )


def read_target(spark: SparkSession, dataset: dict[str, Any]) -> DataFrame:
    target = dataset.get("target", {})
    path = target.get("path")
    if not path:
        raise ValueError(f"Dataset {dataset.get('name')} sem target.path.")

    return spark.read.format(target.get("format", "delta")).load(path)


def max_value(df: DataFrame, column_name: str | None) -> Any:
    if not column_name:
        return None
    if column_name not in df.columns:
        raise ValueError(f"Coluna de freshness nao encontrada: {column_name}")
    return df.agg(spark_max(column_name)).collect()[0][0]


def dataset_uses_jdbc(dataset: dict[str, Any]) -> bool:
    source = dataset.get("source", {})
    return bool(source.get("table") or source.get("query"))


def reconcile_dataset(
    spark: SparkSession,
    dataset: dict[str, Any],
    jdbc_options_map: dict[str, str] | None,
    default_tolerance: int,
) -> dict[str, Any]:
    name = dataset.get("name") or dataset.get("target", {}).get("path") or "dataset"
    tolerance = int(dataset.get("tolerance", default_tolerance))
    freshness_column = dataset.get("freshness_column")

    source_df = read_source(spark, dataset, jdbc_options_map)
    target_df = read_target(spark, dataset)

    source_count = source_df.count()
    target_count = target_df.count()
    diff = abs(source_count - target_count)
    status = "OK" if diff <= tolerance else "ALERTA"

    return {
        "name": name,
        "source_count": source_count,
        "target_count": target_count,
        "diff": diff,
        "tolerance": tolerance,
        "status": status,
        "source_freshness": max_value(source_df, freshness_column),
        "target_freshness": max_value(target_df, freshness_column),
    }


def main() -> None:
    args = parse_args()
    config = load_config(args.config)

    spark = SparkSession.builder.appName("Delta Stack Reconciliation").getOrCreate()
    spark.sparkContext.setLogLevel("ERROR")

    needs_jdbc = any(dataset_uses_jdbc(ds) for ds in config["datasets"])
    jdbc_options_map = jdbc_options(config) if needs_jdbc else None
    default_tolerance = int(config.get("defaults", {}).get("tolerance", 0))
    results = []
    alerts = []

    for dataset in config["datasets"]:
        try:
            result = reconcile_dataset(spark, dataset, jdbc_options_map, default_tolerance)
            results.append(result)
            if result["status"] != "OK":
                alerts.append(
                    f"[{result['name']}] source={result['source_count']} "
                    f"target={result['target_count']} diff={result['diff']} "
                    f"tolerance={result['tolerance']}"
                )
        except Exception as exc:
            dataset_name = dataset.get("name", "dataset")
            alerts.append(f"[{dataset_name}] erro: {exc}")

    print("\n" + "=" * 80)
    print(f"RECONCILIACAO - {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    print("=" * 80)

    for result in results:
        print(
            f"[{result['status']}] {result['name']} | "
            f"source={result['source_count']} target={result['target_count']} "
            f"diff={result['diff']} tolerance={result['tolerance']} "
            f"source_freshness={result['source_freshness']} "
            f"target_freshness={result['target_freshness']}"
        )

    if alerts:
        print("\nALERTAS:")
        for alert in alerts:
            print(f"  - {alert}")
        raise RuntimeError(f"Reconciliacao falhou: {len(alerts)} alerta(s)")

    print("\nTodos os datasets reconciliados com sucesso.")


if __name__ == "__main__":
    main()
