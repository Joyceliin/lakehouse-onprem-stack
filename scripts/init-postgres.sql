-- Banco usado pelo Hive Metastore.
CREATE DATABASE hive_metastore;

-- Banco tecnico para logs e controles compartilhados da stack.
-- Estruturas especificas de projeto devem ser criadas pelos repositorios
-- de projeto ou pelo orquestrador externo.
CREATE DATABASE logs;
