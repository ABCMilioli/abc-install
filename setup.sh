#!/bin/bash

# Cores para output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# Variável global para o nome da rede
NETWORK_NAME=""

# Função para imprimir mensagens com cores
print_message() {
    echo -e "${BLUE}[SETUP]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Verifica se o script está sendo executado como root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "Este script precisa ser executado como root"
        exit 1
    fi
}

# Verifica se o Docker está instalado
check_docker() {
    if ! command -v docker &> /dev/null; then
        return 1
    fi
    return 0
}

# Instala o Docker
install_docker() {
    print_message "Verificando instalação do Docker..."
    
    if check_docker; then
        print_message "Docker já está instalado"
        return 0
    fi
    
    print_message "Instalando Docker..."
    
    # Remove versões antigas se existirem
    apt-get remove -y docker docker-engine docker.io containerd runc || true
    
    # Atualiza os pacotes
    apt-get update
    
    # Instala dependências
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Detecta o sistema operacional
    if [ -f /etc/debian_version ]; then
        # Instalação para Debian
        print_message "Detectado sistema Debian"
        
        # Adiciona a chave GPG oficial do Docker
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Configura o repositório
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
    else
        # Instalação para Ubuntu
        print_message "Detectado sistema Ubuntu"
        
        # Adiciona a chave GPG oficial do Docker
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Configura o repositório
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi

    # Atualiza o apt com o novo repositório
    apt-get update

    # Tenta instalar o Docker Engine
    if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        print_error "Falha na instalação via apt. Tentando método alternativo..."
        
        # Método alternativo usando script get.docker.com
        curl -fsSL https://get.docker.com | sh
    fi

    # Verifica se o Docker foi instalado corretamente
    if ! systemctl is-active --quiet docker; then
        systemctl start docker || true
    fi
    
    if ! systemctl is-enabled --quiet docker; then
        systemctl enable docker || true
    fi

    # Verifica se o Docker está funcionando
    if ! docker info &> /dev/null; then
        print_error "Falha na instalação do Docker"
        exit 1
    fi

    print_success "Docker instalado com sucesso!"
    
    # Pequena pausa para garantir que o serviço está totalmente iniciado
    sleep 5
}

# Inicializa o Docker Swarm
init_swarm() {
    print_message "Inicializando Docker Swarm..."
    
    # Verifica se já está no modo swarm
    if docker info | grep -q "Swarm: active"; then
        print_message "Swarm já está ativo"
    else
        docker swarm init || {
            print_error "Falha ao inicializar o Swarm"
            exit 1
        }
        print_success "Swarm inicializado com sucesso!"
    fi
}

# Função para coletar todas as informações necessárias
get_user_inputs() {
    clear
    print_message "Configuração Inicial"
    echo ""
    echo -e "${GREEN}Vamos coletar algumas informações antes de iniciar a instalação${NC}"
    echo ""
    
    # Nome da rede
    echo -e "${GREEN}1. Nome da rede Docker${NC}"
    echo -e "A rede será usada para comunicação entre Traefik e Portainer"
    echo -e "Exemplo: traefik-public"
    echo ""
    read -p "Digite o nome da rede: " NETWORK_NAME
    while [ -z "$NETWORK_NAME" ]; do
        print_error "O nome da rede não pode estar vazio"
        read -p "Digite o nome da rede: " NETWORK_NAME
    done
    echo ""
    
    # Email para Traefik
    echo -e "${GREEN}2. Email para certificados SSL${NC}"
    echo -e "O Traefik precisa de um email válido para gerar certificados SSL"
    echo -e "Exemplo: seu.email@dominio.com"
    echo ""
    read -p "Digite seu email: " TRAEFIK_EMAIL
    while [[ ! "$TRAEFIK_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; do
        print_error "Email inválido"
        read -p "Digite seu email: " TRAEFIK_EMAIL
    done
    echo ""
    
    # URL do Portainer
    echo -e "${GREEN}3. URL do Portainer${NC}"
    echo -e "O Portainer precisa de uma URL para acesso via navegador"
    echo -e "Exemplo: portainer.seudominio.com"
    echo ""
    read -p "Digite a URL do Portainer: " PORTAINER_URL
    while [[ ! "$PORTAINER_URL" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; do
        print_error "URL inválida"
        read -p "Digite a URL do Portainer: " PORTAINER_URL
    done
    echo ""
    
    # Confirma todas as informações
    echo -e "${GREEN}Confirme as informações:${NC}"
    echo -e "Nome da rede: ${GREEN}$NETWORK_NAME${NC}"
    echo -e "Email: ${GREEN}$TRAEFIK_EMAIL${NC}"
    echo -e "URL do Portainer: ${GREEN}$PORTAINER_URL${NC}"
    echo ""
    read -p "As informações estão corretas? [y/n]: " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        get_user_inputs
        return
    fi
}

# Instala o Traefik
install_traefik() {
    print_message "Configurando Traefik..."
    echo ""
    echo -e "${GREEN}O Traefik precisa de um email válido para gerar certificados SSL${NC}"
    echo -e "${GREEN}Exemplo: seu.email@dominio.com${NC}"
    echo ""
    
    while true; do
        read -p "Digite seu email para o Let's Encrypt: " email
        echo ""
        
        # Verifica se o email está vazio
        if [ -z "$email" ]; then
            print_error "O email não pode estar vazio"
            continue
        fi
        
        # Validação básica de email
        if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            print_error "Por favor, digite um email válido"
            continue
        fi
        
        # Confirma com o usuário
        read -p "Confirma o email '$email'? (y/n): " confirm
        if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
            break
        else
            echo "Ok, vamos tentar novamente."
            continue
        fi
    done
    
    echo ""
    print_message "Instalando Traefik..."
    
    # Cria diretório para o Traefik
    mkdir -p /opt/traefik
    
    # Deploy Traefik
    docker stack deploy -c <(cat <<EOF
version: '3.8'
services:
  traefik:
    image: traefik:latest
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.swarmMode=true"
      - "--providers.docker.exposedByDefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
      - "--certificatesresolvers.letsencrypt.acme.email=${email}"
      - "--certificatesresolvers.letsencrypt.acme.storage=/certificates/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik-certificates:/certificates
    networks:
      - ${NETWORK_NAME}
    deploy:
      placement:
        constraints:
          - node.role == manager

volumes:
  traefik-certificates:

networks:
  ${NETWORK_NAME}:
    external: true
EOF
) traefik || {
    print_error "Falha ao instalar o Traefik"
    exit 1
}

    print_success "Traefik instalado com sucesso!"
    echo ""
    read -p "Pressione ENTER para continuar com a instalação..."
}

# Instala o Portainer
install_portainer() {
    print_message "Configurando Portainer..."
    echo ""
    echo -e "${GREEN}O Portainer precisa de uma URL para acesso via navegador${NC}"
    echo -e "${GREEN}Exemplo: portainer.seudominio.com${NC}"
    echo ""
    
    while true; do
        read -p "Digite a URL para acesso ao Portainer: " portainer_url
        echo ""
        
        # Verifica se a URL está vazia
        if [ -z "$portainer_url" ]; then
            print_error "A URL não pode estar vazia"
            continue
        fi
        
        # Validação básica de domínio
        if [[ ! "$portainer_url" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            print_error "Por favor, digite uma URL válida"
            continue
        fi
        
        # Confirma com o usuário
        read -p "Confirma a URL '$portainer_url'? (y/n): " confirm
        if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then
            break
        else
            echo "Ok, vamos tentar novamente."
            continue
        fi
    done
    
    echo ""
    print_message "Instalando Portainer..."
    
    # Deploy Portainer
    docker stack deploy -c <(cat <<EOF
version: '3.8'
services:
  portainer:
    image: portainer/portainer-ce:latest
    command: -H unix:///var/run/docker.sock
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    networks:
      - ${NETWORK_NAME}
    deploy:
      placement:
        constraints:
          - node.role == manager
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.portainer.rule=Host(\`${portainer_url}\`)"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"

volumes:
  portainer_data:

networks:
  ${NETWORK_NAME}:
    external: true
EOF
) portainer || {
    print_error "Falha ao instalar o Portainer"
    exit 1
}

    print_success "Portainer instalado com sucesso!"
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# Modifique a função main para usar a nova função
main() {
    clear
    check_root
    
    # Coleta todas as informações primeiro
    get_user_inputs
    
    print_message "Iniciando instalação..."
    
    # Instala Docker e inicializa Swarm
    install_docker
    init_swarm
    
    # Cria a rede
    if ! docker network ls | grep -q "$NETWORK_NAME"; then
        if ! docker network create -d overlay --attachable "$NETWORK_NAME"; then
            print_error "Falha ao criar a rede"
            exit 1
        fi
        print_success "Rede $NETWORK_NAME criada com sucesso!"
    else
        print_message "Rede $NETWORK_NAME já existe"
    fi
    
    # Instala os serviços
    install_traefik
    install_portainer
    
    print_success "Instalação concluída!"
    echo -e "${GREEN}Acesse o Portainer em: https://${PORTAINER_URL}${NC}"
}

# Executa o script
main 
