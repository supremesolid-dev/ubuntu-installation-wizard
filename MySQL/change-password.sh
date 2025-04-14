#!/usr/bin/env bash

set -euo pipefail

# === Variáveis Globais ===
TARGET_MYSQL_USER=""
NEW_MYSQL_PASSWORD=""
MYSQL_HOST="localhost"
AUTH_PLUGIN="mysql_native_password"
readonly ROOT_MY_CNF="/root/.my.cnf"

# === Funções ===
error_exit() {
  echo "ERRO: ${1}" >&2
  exit 1
}

usage() {
  echo "Uso: ${0} --mysql-user=<USUARIO> --mysql-password=<NOVA_SENHA> [--mysql-host=<HOST>] [--auth-plugin=<PLUGIN>]"
  echo "  Modifica a senha de um usuário MySQL existente."
  echo "  Se o usuário for 'root'@'localhost', tenta atualizar ${ROOT_MY_CNF}."
  echo
  echo "  Parâmetros Obrigatórios:"
  echo "    --mysql-user=<USUARIO>        Nome do usuário MySQL cuja senha será alterada."
  echo "    --mysql-password=<NOVA_SENHA> A nova senha para o usuário."
  echo
  echo "  Parâmetros Opcionais:"
  echo "    --mysql-host=<HOST>           O host associado ao usuário MySQL (padrão: 'localhost')."
  echo "                                  Use '%' para qualquer host (requer aspas: '--mysql-host=%')."
  echo "    --auth-plugin=<PLUGIN>        Plugin de autenticação a ser usado (padrão: 'mysql_native_password')."
  echo
  echo "  AVISO DE SEGURANÇA: Passar a nova senha via argumento é inseguro."
  echo "  REQUISITO: Este script deve ser executado com privilégios (ex: sudo)."
  echo "  REQUISITO: Para autenticar, um arquivo ${ROOT_MY_CNF} geralmente é necessário,"
  echo "             contendo as credenciais de um usuário MySQL com permissão para ALTER USER."
  echo "             Exemplo de ${ROOT_MY_CNF}:"
  echo "               [client]"
  echo "               user=root"
  echo "               password=SENHA_ATUAL_DO_ROOT_MYSQL"
  echo "             Certifique-se de que 'sudo chmod 600 ${ROOT_MY_CNF}'."
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
    NEW_MYSQL_PASSWORD="${1#*=}"
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

# === Validação dos Parâmetros Obrigatórios ===
if [[ -z "${TARGET_MYSQL_USER}" ]]; then
  echo "ERRO: Parâmetro --mysql-user é obrigatório." >&2
  usage
fi
if [[ -z "${NEW_MYSQL_PASSWORD}" ]]; then
  echo "ERRO: Parâmetro --mysql-password é obrigatório." >&2
  usage
fi

# === Verificação de Privilégios ===
if [[ ${EUID} -ne 0 ]]; then
  error_exit "Este script precisa ser executado como root (ou com sudo) para ler/modificar ${ROOT_MY_CNF} e executar comandos MySQL."
fi

# === Verificação da Existência do .my.cnf (Opcional, mas útil) ===
# A autenticação pode falhar se não existir, mas o script continua
if [[ ! -f "${ROOT_MY_CNF}" ]]; then
  echo "AVISO: Arquivo ${ROOT_MY_CNF} não encontrado." >&2
  echo "       A autenticação MySQL pode falhar se for necessária senha." >&2
fi

# === Lógica Principal ===
echo ">>> Tentando alterar a senha para o usuário '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}'..."
echo ">>> (Usando credenciais de ${ROOT_MY_CNF} se presente para autenticação)"

SQL_COMMAND="ALTER USER '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}' IDENTIFIED WITH ${AUTH_PLUGIN} BY '${NEW_MYSQL_PASSWORD}'; FLUSH PRIVILEGES;"

echo ">>> Executando comando SQL (ocultado por segurança)..."

if mysql --execute="${SQL_COMMAND}"; then
  echo ">>> Senha para '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}' alterada com sucesso no MySQL (usando plugin ${AUTH_PLUGIN})."

  # --- INÍCIO: Bloco para atualizar .my.cnf ---
  if [[ "${TARGET_MYSQL_USER}" == "root" && "${MYSQL_HOST}" == "localhost" ]]; then
    echo ">>> Usuário 'root'@'localhost' modificado. Tentando atualizar ${ROOT_MY_CNF}..."
    if [[ -f "${ROOT_MY_CNF}" ]]; then
      # Tenta encontrar e substituir a linha 'password = ...' dentro da seção [client]
      # Usamos | como delimitador no sed para evitar problemas se a senha tiver /
      # Este sed procura pela linha [client] e, até a próxima linha [ ou fim do arquivo,
      # substitui a primeira linha que começa com 'password' (com espaços opcionais)
      if grep -qE "^\s*\[client\]" "${ROOT_MY_CNF}"; then
        # Verifica se a linha password existe na seção client
        if sed -n '/^\s*\[client\]/,/^\s*\[/p' "${ROOT_MY_CNF}" | grep -q '^\s*password\s*='; then
          # Linha existe, vamos substituí-la
          sed -i.bak "/^\s*\[client\]/,/^\s*\[/ s|^\s*password\s*=.*|password = ${NEW_MYSQL_PASSWORD}|" "${ROOT_MY_CNF}"
          echo ">>> Linha 'password' atualizada em ${ROOT_MY_CNF} (backup criado como ${ROOT_MY_CNF}.bak)."
        else
          # Linha password não existe, vamos adicioná-la após [client]
          sed -i.bak "/^\s*\[client\]/a password = ${NEW_MYSQL_PASSWORD}" "${ROOT_MY_CNF}"
          echo ">>> Linha 'password' adicionada em ${ROOT_MY_CNF} sob [client] (backup criado como ${ROOT_MY_CNF}.bak)."
        fi
      else
        echo "AVISO: Seção [client] não encontrada em ${ROOT_MY_CNF}. Não foi possível atualizar a senha automaticamente." >&2
      fi
    else
      echo "AVISO: Arquivo ${ROOT_MY_CNF} não encontrado. Não foi possível atualizar a senha automaticamente." >&2
    fi
  fi
  # --- FIM: Bloco para atualizar .my.cnf ---

else
  # Mensagem de erro da falha do comando SQL
  error_exit "Falha ao executar o comando SQL para alterar a senha. Verifique:"$'\n'"  - Se o usuário '${TARGET_MYSQL_USER}'@'${MYSQL_HOST}' existe."$'\n'"  - Se o arquivo ${ROOT_MY_CNF} existe, tem permissões corretas (600) e contém credenciais válidas de um usuário com privilégios (ex: root do MySQL).""$'\n'" - Se a senha contém caracteres que quebram a sintaxe SQL."$'\n'\"  - Logs do MySQL para mais detalhes (/var/log/mysql/error.log)."
fi

exit 0
