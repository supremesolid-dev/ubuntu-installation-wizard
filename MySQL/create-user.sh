#!/usr/bin/env bash

set -euo pipefail

# === Variáveis Globais ===
TARGET_MYSQL_USER=""
TARGET_MYSQL_PASSWORD=""
PERMISSION_LEVEL=""
TARGET_DATABASE=""
MYSQL_HOST="localhost"
AUTH_PLUGIN="mysql_native_password" # Definido para auth_socket como padrão

# === Funções ===
error_exit() {
  echo "ERRO: ${1}" >&2
  exit 1
}

usage() {
  echo "Uso: ${0} --mysql-user=<USUARIO> [--mysql-password=<SENHA>] --permission-level=<NIVEL> [--database=<DB>] [--mysql-host=<HOST>] [--auth-plugin=<PLUGIN>]"
  echo "  Cria um novo usuário MySQL com um nível de permissão predefinido."
  echo
  echo "  Parâmetros Obrigatórios:"
  echo "    --mysql-user=<USUARIO>        Nome do novo usuário MySQL."
  echo "    --permission-level=<NIVEL>    Nível de permissão ('administrator' ou 'default')."
  echo
  echo "  Parâmetros Condicionais:"
  echo "    --database=<DB>               Banco de dados alvo. OBRIGATÓRIO se --permission-level=default."
  echo
  echo "  Parâmetros Opcionais:"
  echo "    --mysql-password=<SENHA>      Senha para o novo usuário (não utilizada com auth_socket)."
  echo "    --mysql-host=<HOST>           Host de onde o novo usuário poderá se conectar (padrão: 'localhost'). Use '%' para qualquer host."
  echo "    --auth-plugin=<PLUGIN>        Plugin de autenticação a ser usado (padrão: 'mysql_native_password')."
  echo
  echo "  Níveis de Permissão Definidos:"
  echo "    administrator:  ALL PRIVILEGES ON *.* WITH GRANT OPTION (Acesso total. MUITO CUIDADO!)."
  echo "    default:        SELECT, INSERT, UPDATE, DELETE, EXECUTE, CREATE TEMPORARY TABLES no banco de dados especificado (--database)."
  echo
  echo "  AVISO DE SEGURANÇA: Passar a senha via argumento é inseguro."
  echo "  REQUISITO: Executar com sudo."
  exit 1
}

# === Processamento dos Argumentos ===
if [[ $# -eq 0 ]]; then
  usage
fi

while [[ $# -gt 0 ]]; do
  case "${1}" in
  --mysql-user=*)
    TARGET_MYSQL_USER="${1#*=}"
    shift
    ;;
  --mysql-password=*)
    TARGET_MYSQL_PASSWORD="${1#*=}"
    shift
    ;;
  --permission-level=*)
    PERMISSION_LEVEL=$(echo "${1#*=}" | tr '[:upper:]' '[:lower:]') # Converte para minúsculas
    shift
    ;;
  --database=*)
    TARGET_DATABASE="${1#*=}"
    shift
    ;;
  --mysql-host=*)
    MYSQL_HOST="${1#*=}"
    shift
    ;;
  --auth-plugin=*)
    AUTH_PLUGIN="${1#*=}"
    shift
    ;;
  *)
    error_exit "Argumento desconhecido: ${1}"
    ;;
  esac
done

# === Validação dos Parâmetros ===
if [[ -z "${TARGET_MYSQL_USER}" ]]; then
  error_exit "Parâmetro --mysql-user é obrigatório."
fi

# Se o plugin de autenticação não for auth_socket, a senha é obrigatória.
if [[ "${AUTH_PLUGIN}" != "auth_socket" && -z "${TARGET_MYSQL_PASSWORD}" ]]; then
  error_exit "Parâmetro --mysql-password é obrigatório para o plugin '${AUTH_PLUGIN}'."
fi

if [[ -z "${PERMISSION_LEVEL}" ]]; then
  error_exit "Parâmetro --permission-level é obrigatório."
fi

# Validar nível de permissão
if [[ "${PERMISSION_LEVEL}" != "administrator" && "${PERMISSION_LEVEL}" != "default" ]]; then
  error_exit "Valor inválido para --permission-level. Use 'administrator' ou 'default'."
fi

# Validar --database se nível for 'default'
if [[ "${PERMISSION_LEVEL}" == "default" && -z "${TARGET_DATABASE}" ]]; then
  error_exit "Parâmetro --database é obrigatório quando --permission-level=default."
fi

# === Verificação de Privilégios ===
if [[ ${EUID} -ne 0 ]]; then
  error_exit "Este script precisa ser executado como root (ou com sudo)."
fi

# === Aviso adicional para auth_socket ===
if [[ "${AUTH_PLUGIN}" == "auth_socket" ]]; then
  echo ">>> AVISO: Usando auth_socket. A senha informada será ignorada."
fi

# === Lógica Principal ===
echo ">>> Iniciando criação do usuário '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}' com nível '${PERMISSION_LEVEL}'..."

# 1. Criar o usuário
if [[ "${AUTH_PLUGIN}" == "auth_socket" ]]; then
  SQL_CREATE_USER="CREATE USER IF NOT EXISTS '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}' IDENTIFIED WITH ${AUTH_PLUGIN};"
else
  SQL_CREATE_USER="CREATE USER IF NOT EXISTS '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}' IDENTIFIED WITH ${AUTH_PLUGIN} BY '${TARGET_MYSQL_PASSWORD}';"
fi

echo ">>> Executando: CREATE USER..."
if ! mysql --execute="${SQL_CREATE_USER}"; then
  error_exit "Falha ao executar CREATE USER. Verifique:"$'\n'"  - Se o usuário já existe com plugin/host diferente."$'\n'"  - Logs do MySQL."
fi
echo ">>> Usuário '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}' criado ou já existente."

# 2. Conceder permissões baseadas no nível
SQL_GRANT=""
echo ">>> Definindo permissões para nível '${PERMISSION_LEVEL}'..."
case "${PERMISSION_LEVEL}" in
administrator)
  # CUIDADO: ALL PRIVILEGES é extremamente poderoso.
  SQL_GRANT="GRANT ALL PRIVILEGES ON *.* TO '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}' WITH GRANT OPTION;"
  ;;
default)
  # Permissões básicas no banco de dados especificado. Adicionar/Remover conforme necessário.
  # Usar backticks ` ao redor do nome do banco de dados para segurança caso contenha caracteres especiais.
  SQL_GRANT="GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE, CREATE TEMPORARY TABLES ON \`${TARGET_DATABASE}\`.* TO '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}';"
  ;;
esac

# 3. Executar GRANT
if [[ -n "${SQL_GRANT}" ]]; then
  echo ">>> Executando: GRANT..."
  if ! mysql --execute="${SQL_GRANT}"; then
    error_exit "Falha ao executar GRANT. Verifique:"$'\n'"  - Se o banco de dados '${TARGET_DATABASE}' existe (para nível default)."$'\n'"  - Permissões do usuário MySQL."$'\n'"  - Logs do MySQL."
  fi
  echo ">>> Permissões concedidas com sucesso."
else
  error_exit "Falha interna: Nenhuma instrução GRANT foi definida."
fi

# 4. Aplicar privilégios
echo ">>> Executando: FLUSH PRIVILEGES..."
if ! mysql --execute="FLUSH PRIVILEGES;"; then
  echo "AVISO: Falha ao executar FLUSH PRIVILEGES. As permissões podem levar um tempo para serem aplicadas ou exigir reinício do serviço." >&2
fi

echo ">>> Usuário '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}' criado e configurado com sucesso!"
if [[ "${PERMISSION_LEVEL}" == "default" ]]; then
  echo ">>> Permissões (default) aplicadas ao banco de dados: '${TARGET_DATABASE}'"
fi
if [[ "${PERMISSION_LEVEL}" == "administrator" ]]; then
  echo ">>> ATENÇÃO: Usuário criado com privilégios de ADMINISTRADOR TOTAL!"
fi

exit 0
