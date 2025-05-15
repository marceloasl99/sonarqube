#!/bin/bash

# =============================================================================
# Script de Instalação Automatizada do SonarQube Community Edition no Ubuntu
# Versão do SonarQube: 25.5.0.107428
# Data: 15 de maio de 2025 - Rev 3.10
#Salve o conteúdo abaixo em um arquivo chamado instalar_sonarqube.sh, torne-o executável com chmod +x instalar_sonarqube.sh e execute com sudo ./instalar_sonarqube.sh.
# =============================================================================

# --- DEFINIÇÕES ---
SONARQUBE_ZIP_URL="https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-25.5.0.107428.zip"
SONARQUBE_ZIP_FILE=$(basename "$SONARQUBE_ZIP_URL")
SONARQUBE_INSTALL_DIR="/opt/sonarqube"
SONARQUBE_USER="sonar"
SONARQUBE_GROUP="sonar"
PG_USER="sonarqube_user" # Nome do usuário do PostgreSQL para SonarQube
PG_DB="sonarqube"       # Nome do banco de dados PostgreSQL para SonarQube

# --- SOLICITAR ENTRADAS DO USUÁRIO ---
echo "--- Configuração Inicial ---"
read -p "Digite a porta web desejada para o SonarQube (ex: 9000, 40706): " SONARQUBE_WEB_PORT
read -s -p "Digite a senha forte para o usuário do banco de dados PostgreSQL ('$PG_USER'): " PG_PASSWORD
echo # Adiciona uma nova linha após a entrada da senha

# --- VERIFICAR SE ESTÁ RODANDO COMO ROOT ---
if [[ $EUID -ne 0 ]]; then
   echo "Este script deve ser executado com privilégios root (usando sudo)."
   exit 1
fi

echo "--- Início da instalação ---"

# --- PASSO 1: Atualizar o Sistema ---
echo "--- Atualizando o sistema ---"
apt update
apt upgrade -y
echo "--- Sistema atualizado ---"

# --- PASSO 2: Instalar o OpenJDK 17 ---
echo "--- Instalando OpenJDK 17 ---"
apt install openjdk-17-jdk -y
# Tenta determinar JAVA_HOME
JAVA_HOME=$(readlink -f /usr/bin/java | sed "s:bin/java::")
echo "JAVA_HOME detectado: $JAVA_HOME"
echo "--- OpenJDK 17 instalado ---"

# --- PASSO 3: Instalar e Configurar o PostgreSQL ---
echo "--- Instalando e configurando PostgreSQL ---"
apt install postgresql postgresql-contrib -y
systemctl start postgresql
systemctl enable postgresql

# Configura usuário e banco de dados no PostgreSQL (automático)
echo "--- Criando usuário '$PG_USER' e banco de dados '$PG_DB' no PostgreSQL ---"
sudo -u postgres psql <<EOF
-- Cria o usuário com a senha fornecida
CREATE USER $PG_USER WITH ENCRYPTED password '$PG_PASSWORD';
-- Cria o banco de dados e define o proprietário
CREATE DATABASE $PG_DB OWNER $PG_USER;
-- Concede todos os privilégios (garantia extra)
GRANT ALL PRIVILEGES ON DATABASE $PG_DB TO $PG_USER;
EOF
echo "--- Usuário e banco de dados PostgreSQL configurados ---"

# --- PASSO 4: Baixar e Extrair o SonarQube ---
echo "--- Baixando e extraindo SonarQube ---"
wget "$SONARQUBE_ZIP_URL" -O "/tmp/$SONARQUBE_ZIP_FILE"
mkdir -p "$SONARQUBE_INSTALL_DIR"
unzip "/tmp/$SONARQUBE_ZIP_FILE" -d "$SONARQUBE_INSTALL_DIR"

# Encontra o diretório extraído (pode variar ligeiramente)
SONARQUBE_EXTRACTED_DIR=$(find "$SONARQUBE_INSTALL_DIR" -maxdepth 1 -type d -name "sonarqube-*" -print -quit)

if [ -n "$SONARQUBE_EXTRACTED_DIR" ] && [ "$SONARQUBE_EXTRACTED_DIR" != "$SONARQUBE_INSTALL_DIR" ]; then
  echo "Movendo arquivos de $SONARQUBE_EXTRACTED_DIR para $SONARQUBE_INSTALL_DIR"
  mv "$SONARQUBE_EXTRACTED_DIR"/* "$SONARQUBE_INSTALL_DIR"/
  rm -r "$SONARQUBE_EXTRACTED_DIR"
else
  echo "Diretório extraído não encontrado ou já no local correto."
fi

rm "/tmp/$SONARQUBE_ZIP_FILE"
echo "--- SonarQube baixado e extraído para $SONARQUBE_INSTALL_DIR ---"

# --- PASSO 5: Criar Usuário/Grupo e Definir Permissões ---
echo "--- Criando usuário e grupo '$SONARQUBE_USER' para SonarQube ---"
# Verifica se o grupo e usuário já existem
getent group "$SONARQUBE_GROUP" >/dev/null || groupadd "$SONARQUBE_GROUP"
getent passwd "$SONARQUBE_USER" >/dev/null || useradd -c "User to run SonarQube" -d "/home/$SONARQUBE_USER" -g "$SONARQUBE_GROUP" "$SONARQUBE_USER"

# Define o proprietário do diretório de instalação
chown -R "$SONARQUBE_USER":"$SONARQUBE_GROUP" "$SONARQUBE_INSTALL_DIR"
echo "--- Usuário/Grupo criados e permissões definidas ---"

# --- PASSO 6: Configurar o Arquivo sonar.properties ---
echo "--- Configurando $SONARQUBE_INSTALL_DIR/conf/sonar.properties ---"

# Remove as linhas de configuração de DB e Web existentes (para evitar duplicatas ou comentários)
sed -i '/^sonar\.jdbc\./d' "$SONARQUBE_INSTALL_DIR/conf/sonar.properties"
sed -i '/^sonar\.web\./d' "$SONARQUBE_INSTALL_DIR/conf/sonar.properties"

# Adiciona as novas linhas de configuração de DB e Web
cat <<EOL >> "$SONARQUBE_INSTALL_DIR/conf/sonar.properties"

# === Database Configuration ===
sonar.jdbc.url=jdbc:postgresql://localhost/$PG_DB
sonar.jdbc.username=$PG_USER
sonar.jdbc.password=$PG_PASSWORD

# === Web Server Configuration ===
sonar.web.listenHost=0.0.0.0
sonar.web.port=$SONARQUBE_WEB_PORT
EOL

echo "--- Arquivo sonar.properties configurado ---"

# --- PASSO 7: Configurar SonarQube como Serviço do Sistema (systemd) ---
echo "--- Criando arquivo de serviço systemd ---"
SONARQUBE_SERVICE_FILE="/etc/systemd/system/sonarqube.service"

# Conteúdo do arquivo de serviço
SERVICE_CONTENT="[Unit]
Description=SonarQube service
After=syslog.target network.target postgresql.service

[Service]
Type=forking
ExecStart=$SONARQUBE_INSTALL_DIR/bin/linux-x86-64/sonar.sh start
ExecStop=$SONARQUBE_INSTALL_DIR/bin/linux-x86-64/sonar.sh stop
User=$SONARQUBE_USER
Group=$SONARQUBE_GROUP
Restart=always
Environment=\"JAVA_HOME=$JAVA_HOME\" # Verifique este caminho

[Install]
WantedBy=multi-user.target
"

# Cria o arquivo de serviço com o conteúdo
echo "$SERVICE_CONTENT" | tee "$SONARQUBE_SERVICE_FILE" > /dev/null

# Recarrega o daemon do systemd
systemctl daemon-reload

# Habilita o serviço para iniciar no boot
systemctl enable sonarqube
echo "--- Arquivo de serviço systemd criado e habilitado ---"

# --- PASSO 8: Ajustar Limites do Kernel ---
echo "--- Ajustando limites do kernel para Elasticsearch ---"
# Adiciona as linhas ao sysctl.conf se não existirem
grep -q "vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count=262144" | tee -a /etc/sysctl.conf > /dev/null
grep -q "fs.file-max" /etc/sysctl.conf || echo "fs.file-max=65536" | tee -a /etc/sysctl.conf > /dev/null

# Aplica as mudanças do sysctl
sysctl -p

# Adiciona as linhas ao limits.conf se não existirem para o usuário sonar
grep -q "^$SONARQUBE_USER .* nofile" /etc/security/limits.conf || echo "$SONARQUBE_USER   -   nofile   65536" | tee -a /etc/security/limits.conf > /dev/null
grep -q "^$SONARQUBE_USER .* nproc" /etc/security/limits.conf || echo "$SONARQUBE_USER   -   nproc    4096" | tee -a /etc/security/limits.conf > /dev/null

echo "--- Limites do kernel ajustados ---"

# --- PASSO 9: Iniciar o SonarQube ---
echo "--- Iniciando o serviço SonarQube ---"
systemctl start sonarqube
echo "--- Comando de iniciar o SonarQube executado. Aguardando... ---"

# Aguarda um pouco para o serviço iniciar
sleep 45 # Aumentado o tempo de espera

# --- PASSO 10: Verificar o Status e Acessar ---
echo "--- Verificando o status do serviço ---"
systemctl status sonarqube --no-pager

echo "--- Verificando portas abertas (deve mostrar $SONARQUBE_WEB_PORT LISTEN) ---"
ss -tulnp | grep "$SONARQUBE_WEB_PORT"

echo "--- Fim da execução do script. ---"
echo "Verifique o status acima. Se estiver 'active (running)', o SonarQube provavelmente iniciou."
echo "Aguarde mais alguns minutos para que a interface web fique totalmente disponível."
echo "Tente acessar em seu navegador: http://SEU_ENDERECO_IP_DO_SERVIDOR:$SONARQUBE_WEB_PORT"
echo "Em caso de problemas, verifique os logs em $SONARQUBE_INSTALL_DIR/logs/"