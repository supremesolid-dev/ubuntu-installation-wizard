#!/usr/bin/env bash

# === Configuração de Segurança e Robustez ===
# -e: Sair imediatamente se um comando falhar.
# -u: Tratar variáveis não definidas como erro.
# -o pipefail: Status de saída do pipeline é o do último comando com falha.
set -euo pipefail

# === Constantes ===
readonly PMA_VERSION="5.2.2" # Considere verificar a última versão se necessário
readonly PMA_BASE_URL="https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}"
readonly PMA_ZIP_FILE="phpMyAdmin-${PMA_VERSION}-all-languages.zip"
readonly PMA_URL="${PMA_BASE_URL}/${PMA_ZIP_FILE}"
readonly INSTALL_DIR="/usr/share"            # Diretório base comum
readonly PMA_DIR="${INSTALL_DIR}/phpmyadmin" # Nome final do diretório
readonly PMA_TMP_DIR_NAME="tmp"              # Nome relativo do diretório temp dentro de PMA_DIR
readonly PMA_CONFIG_FILE="${PMA_DIR}/config.inc.php"
readonly WEB_USER="www-data"  # Usuário padrão do servidor web no Debian/Ubuntu
readonly WEB_GROUP="www-data" # Grupo padrão do servidor web

# === Cores para Terminal ===
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

# === Funções de Log ===
log() { echo -e "${GREEN}[✔]${RESET} $1"; }
warn() { echo -e "${YELLOW}[⚠]${RESET} $1"; }
error_exit() {
  echo -e "${RED}[✖]${RESET} $1"
  exit 1
}
info() { echo -e "${BLUE}[ℹ]${RESET} $1"; }

# === Funções Auxiliares ===

# Verifica execução como root
check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error_exit "Este script precisa ser executado como root. Use: sudo $0"
  fi
}

# Verifica e instala dependências do sistema
check_system_deps() {
  info "Verificando dependências do sistema (wget, unzip, openssl)..."
  local missing_pkgs=()
  local required_pkgs=("wget" "unzip" "openssl")

  for pkg in "${required_pkgs[@]}"; do
    # Usar dpkg-query é mais robusto que 'command -v' para pacotes instalados
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
      missing_pkgs+=("$pkg")
    fi
  done

  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    warn "Dependências faltando: ${missing_pkgs[*]}"
    info "Tentando instalar dependências faltantes..."
    # Atualizar antes de instalar
    apt-get update -y || error_exit "Falha ao executar apt update."
    apt-get install -y "${missing_pkgs[@]}" || error_exit "Falha ao instalar dependências: ${missing_pkgs[*]}"
    log "Dependências instaladas com sucesso."
  else
    log "Dependências do sistema OK."
  fi
}

# Verifica extensões PHP necessárias
check_php_extensions() {
  info "Verificando extensões PHP necessárias..."
  # Extensões comuns e importantes para phpMyAdmin
  local required_extensions=("json" "mbstring" "session" "openssl" "xml" "zip" "gd")
  # MySQLi ou PDO são necessários, verificamos pelo menos um
  local mysql_ext_found=false
  local missing_extensions=()
  local installed_modules

  # Obter módulos PHP carregados (ignora erros se php não estiver instalado - pego antes)
  installed_modules=$(php -m || true)

  for ext in "${required_extensions[@]}"; do
    # Usar grep -q com word boundary (\b) para match exato
    if ! echo "$installed_modules" | grep -qiw "\b$ext\b"; then
      missing_extensions+=("$ext")
    fi
  done

  # Verificar extensão MySQL
  if ! echo "$installed_modules" | grep -qiw "\bmysqli\b" && ! echo "$installed_modules" | grep -qiw "\bpdo_mysql\b"; then
    missing_extensions+=("mysqli ou pdo_mysql")
    mysql_ext_found=false # Redundante, mas claro
  else
    mysql_ext_found=true
  fi

  if [[ ${#missing_extensions[@]} -gt 0 ]]; then
    error_exit "Extensões PHP necessárias faltando: ${missing_extensions[*]}. Instale-as (ex: sudo apt install php-json php-mbstring php-mysql ...)."
  else
    log "Extensões PHP necessárias OK."
  fi
}

# Download e extração
download_and_extract() {
  # Criar diretório temporário seguro para download e extração
  local temp_dir
  temp_dir=$(mktemp -d) || error_exit "Falha ao criar diretório temporário."
  # Garantir limpeza do diretório temporário na saída do script (mesmo em erro)
  trap 'rm -rf -- "$temp_dir"' EXIT

  info "Baixando phpMyAdmin v${PMA_VERSION} para diretório temporário..."
  wget -q --show-progress "${PMA_URL}" -O "${temp_dir}/${PMA_ZIP_FILE}" || error_exit "Falha ao baixar ${PMA_URL}."

  info "Extraindo phpMyAdmin no diretório temporário..."
  unzip -q "${temp_dir}/${PMA_ZIP_FILE}" -d "${temp_dir}" || error_exit "Falha ao extrair ${PMA_ZIP_FILE}."

  # Diretório extraído geralmente é phpMyAdmin-VERSION-all-languages
  local extracted_dir="${temp_dir}/phpMyAdmin-${PMA_VERSION}-all-languages"

  if [[ ! -d "${extracted_dir}" ]]; then
    error_exit "Diretório extraído '${extracted_dir}' não encontrado após unzip."
  fi

  info "Movendo para ${PMA_DIR}..."
  # -T evita mover temp_dir/subdir para dentro de PMA_DIR se PMA_DIR existir
  mv -T "${extracted_dir}" "${PMA_DIR}" || error_exit "Falha ao mover ${extracted_dir} para ${PMA_DIR}."

  # Limpeza do trap cuidará do temp_dir e do zip dentro dele
  log "Download e extração concluídos."
}

# Configuração do phpMyAdmin
configure_pma() {
  info "Criando arquivo de configuração: ${PMA_CONFIG_FILE}..."
  if [[ -f "${PMA_CONFIG_FILE}" ]]; then
    warn "Arquivo de configuração ${PMA_CONFIG_FILE} já existe. Pulando criação."
    # Poderia fazer backup e sobrescrever, mas pular é mais seguro para execuções repetidas.
    # Se você *quiser* sobrescrever, remova este bloco 'if' ou adicione lógica de backup.
    # No entanto, se o blowfish_secret for diferente, isso causará problemas com cookies existentes.
    return 0
  fi

  # Cria o diretório pai se não existir (caso raro, mas seguro)
  mkdir -p "$(dirname "$PMA_CONFIG_FILE")" || error_exit "Falha ao criar diretório pai para config."

  local blowfish_secret
  # --- CORREÇÃO APLICADA AQUI ---
  # Gera 16 bytes randômicos e converte para hexadecimal (32 caracteres)
  blowfish_secret=$(openssl rand -hex 16) || error_exit "Falha ao gerar blowfish_secret (hex)."
  # --- FIM DA CORREÇÃO ---

  local pma_tmp_abs_path="${PMA_DIR}/${PMA_TMP_DIR_NAME}" # Caminho absoluto para config

  # Cria diretório temporário do PMA
  mkdir -p "${pma_tmp_abs_path}" || error_exit "Falha ao criar diretório temporário do PMA: ${pma_tmp_abs_path}"

  # Usar Heredoc para criar o arquivo de configuração
  cat >"${PMA_CONFIG_FILE}" <<EOF || error_exit "Falha ao escrever em ${PMA_CONFIG_FILE}."
<?php
/* Gerado por script em $(date) */
declare(strict_types=1);

/**
 * Chave secreta Blowfish - Exatamente 32 caracteres.
 * NÃO ALTERE ISSO APÓS A CONFIGURAÇÃO INICIAL
 */
\$cfg['blowfish_secret'] = '${blowfish_secret}'; /* YOU MUST FILL IN THIS FOR COOKIE AUTH! */

/**
 * Diretório temporário para uploads, cache, etc.
 * Deve ter permissão de escrita pelo usuário do servidor web (www-data).
 */
\$cfg['TempDir'] = '${pma_tmp_abs_path}';

/**
 * Configurações do Servidor
 */
\$i = 0;

/**
 * Primeiro Servidor - localhost
 */
\$i++;
/* Autenticação (cookie é recomendado) */
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
/* Host do Servidor MySQL */
\$cfg['Servers'][\$i]['host'] = 'localhost'; // Ou IP/hostname se diferente
/* Usar compressão entre phpMyAdmin e MySQL? */
\$cfg['Servers'][\$i]['compress'] = false;
/* Permitir login sem senha? (Não recomendado) */
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
/* Ocultar bancos de dados de sistema */
\$cfg['Servers'][\$i]['hide_db'] = '^(information_schema|performance_schema|mysql|sys|phpmyadmin)\$';

/**
 * Diretórios de Upload/Save (geralmente deixados vazios)
 */
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';

/**
 * Configurações Adicionais (Exemplos)
 */
// \$cfg['MaxRows'] = 50; // Número de linhas exibidas por padrão
// \$cfg['LoginCookieValidity'] = 14400; // Tempo de validade do cookie (4 horas)

/* Fim do Arquivo de Configuração */
EOF

  log "Arquivo de configuração ${PMA_CONFIG_FILE} criado."
}

# Define permissões corretas
set_permissions() {
  info "Definindo permissões para ${PMA_DIR}..."
  local pma_tmp_abs_path="${PMA_DIR}/${PMA_TMP_DIR_NAME}" # Caminho absoluto

  # Define dono/grupo recursivamente
  chown -R "${WEB_USER}:${WEB_GROUP}" "${PMA_DIR}" || error_exit "Falha ao definir dono/grupo para ${PMA_DIR}."

  # Permissões mais restritivas onde possível
  # Diretório principal: leitura/execução para todos (necessário para web server), escrita só para dono
  find "${PMA_DIR}" -type d -exec chmod 755 {} \;
  # Arquivos: leitura para todos, escrita só para dono
  find "${PMA_DIR}" -type f -exec chmod 644 {} \;

  # Permissões específicas mais seguras
  # Apenas dono/grupo podem ler config.inc.php
  chmod 640 "${PMA_CONFIG_FILE}" || error_exit "Falha ao definir permissões para ${PMA_CONFIG_FILE}."
  # Diretório tmp: Leitura/escrita/execução para dono/grupo (www-data precisa escrever)
  chmod 770 "${pma_tmp_abs_path}" || error_exit "Falha ao definir permissões para ${pma_tmp_abs_path}." # Alterado para 770
  # Reafirmar dono/grupo no config e tmp após chmod geral (segurança extra)
  chown "${WEB_USER}:${WEB_GROUP}" "${PMA_CONFIG_FILE}" "${pma_tmp_abs_path}" || error_exit "Falha ao reafirmar dono/grupo no config/tmp."

  log "Permissões definidas com sucesso."
}

# === Função Principal ===
main() {
  check_root
  check_system_deps
  check_php_extensions # Verifica se PHP e extensões necessárias estão presentes

  # Verifica se já está instalado
  if [[ -d "${PMA_DIR}" ]]; then
    # Verifica se o diretório parece ser uma instalação válida (contém index.php)
    if [[ -f "${PMA_DIR}/index.php" ]]; then
      warn "Diretório ${PMA_DIR} já existe e parece conter uma instalação do phpMyAdmin."
      info "Pulando download e extração. Verificando configuração e permissões..."
      # Mesmo que exista, garantir que o tmp dir e config existam e tenham permissões
      configure_pma   # Tentará criar config se não existir (e usará o novo método de geração se criar)
      set_permissions # Reaplicará permissões
      log "Verificação concluída para instalação existente."
      print_final_instructions
      exit 0
    else
      warn "Diretório ${PMA_DIR} existe, mas não parece ser uma instalação válida do phpMyAdmin."
      warn "Remova ou renomeie este diretório manualmente se desejar reinstalar: sudo rm -rf ${PMA_DIR}"
      error_exit "Instalação abortada devido à existência de diretório ambíguo."
    fi
  fi

  download_and_extract
  configure_pma # Usará o novo método de geração de chave
  set_permissions

  print_final_instructions
}

print_final_instructions() {
  # ... (restante da função print_final_instructions permanece igual) ...
  echo ""
  log "Instalação/Verificação do phpMyAdmin v${PMA_VERSION} concluída!"
  echo ""
  info "Localização da instalação: ${PMA_DIR}"
  info "Arquivo de configuração: ${PMA_CONFIG_FILE}"
  info "Diretório temporário: ${PMA_DIR}/${PMA_TMP_DIR_NAME}"
  echo ""
  info "${YELLOW}Próximos Passos Essenciais:${RESET}"
  info "  1. ${YELLOW}Configurar seu Servidor Web (Nginx ou Apache) para servir '${PMA_DIR}'.${RESET}"
  info "     Exemplo Nginx (adicionar em um server block):"
  info "       location /phpmyadmin {"
  info "         root ${INSTALL_DIR}; # Ou /usr/share"
  info "         index index.php;"
  info "         try_files \$uri \$uri/ /phpmyadmin/index.php?\$args;"
  info ""
  info "         location ~ ^/phpmyadmin/(.+\.php)\$ {"
  info "           # Ajuste o socket/porta do PHP-FPM conforme sua configuração"
  info "           fastcgi_pass unix:/run/php/php8.2-fpm.sock; # Exemplo PHP 8.2"
  info "           fastcgi_index index.php;"
  info "           fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;"
  info "           include fastcgi_params;"
  info "         }"
  info ""
  info "         location ~* ^/phpmyadmin/(.+\.(jpg|jpeg|gif|png|ico|css|js))\$ {"
  info "           expires max;"
  info "           log_not_found off;"
  info "         }"
  info "       }"
  info "       location ~ /\.ht {"
  info "           deny all;"
  info "       }"
  info "     Exemplo Apache (criar /etc/apache2/conf-available/phpmyadmin.conf):"
  info "       Alias /phpmyadmin ${PMA_DIR}"
  info "       <Directory ${PMA_DIR}>"
  info "         Options FollowSymLinks"
  info "         DirectoryIndex index.php"
  info "         AllowOverride All"
  info "         Require all granted # Para Apache 2.4+"
  info "         # Para Apache 2.2 use:"
  info "         # Order allow,deny"
  info "         # Allow from all"
  info "       </Directory>"
  info "     Ativar conf: sudo a2enconf phpmyadmin && sudo systemctl reload apache2"
  info "  2. ${YELLOW}Reiniciar/Recarregar seu servidor web${RESET} após a configuração."
  info "  3. Acessar o phpMyAdmin pelo navegador no endereço configurado (ex: http://seu_servidor/phpmyadmin)."
  info "  4. Certifique-se que o usuário MySQL que você usará para login tem permissões adequadas."
}

# === Execução ===
main "$@"

exit 0
