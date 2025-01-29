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

# Cria rede overlay
create_network() {
    print_message "Configurando rede..."
    
    while true; do
        read -p "Digite o nome da rede: " NETWORK_NAME
        
        # Verifica se a rede já existe
        if docker network ls | grep -q "$NETWORK_NAME"; then
            print_message "Rede $NETWORK_NAME já existe"
            break
        else
            # Cria a rede overlay
            if docker network create -d overlay --attachable "$NETWORK_NAME"; then
                print_success "Rede $NETWORK_NAME criada com sucesso!"
                break
            else
                print_error "Falha ao criar a rede. Tente outro nome."
            fi
        fi
    done
}

# Instala o Traefik
install_traefik() {
    print_message "Configurando Traefik..."
    read -p "Digite seu email para o Let's Encrypt: " email
    
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
}

# Instala o Portainer
install_portainer() {
    print_message "Configurando Portainer..."
    read -p "Digite a URL para acesso ao Portainer (ex: portainer.seudominio.com): " portainer_url
    
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
}

# Função principal
main() {
    clear
    check_root
    
    print_message "Iniciando instalação..."
    
    install_docker
    init_swarm
    create_network
    install_traefik
    install_portainer
    
    print_success "Instalação concluída!"
    echo -e "${GREEN}Acesse o Portainer em: https://${portainer_url}${NC}"
}

# Executa o script
main 
