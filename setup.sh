#!/bin/bash

# Cores
verde="\e[32m"
vermelho="\e[31m"
amarelo="\e[33m"
azul="\e[34m"
roxo="\e[35m"
reset="\e[0m"

## Função para verificar se é root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${vermelho}Este script precisa ser executado como root${reset}"
        exit
    fi
}

## Função para detectar o sistema operacional
detect_os() {
    if [ -f /etc/debian_version ]; then
        echo -e "${azul}Sistema Debian/Ubuntu detectado${reset}"
        OS="debian"
    else
        echo -e "${vermelho}Sistema operacional não suportado${reset}"
        exit 1
    fi
}

## Função para instalar o Docker
install_docker() {
    echo -e "${azul}Instalando Docker...${reset}"
    
    # Remove versões antigas
    apt-get remove -y docker docker-engine docker.io containerd runc
    
    # Instala dependências
    apt-get update
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release
    
    if [ "$OS" = "debian" ]; then
        # Adiciona repositório Docker para Debian/Ubuntu
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        
        echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi
    
    # Instala Docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Inicia e habilita o Docker
    systemctl start docker
    systemctl enable docker
    
    echo -e "${verde}Docker instalado com sucesso!${reset}"
}

## Função para inicializar o Swarm
init_swarm() {
    echo -e "${azul}Inicializando Docker Swarm...${reset}"
    if ! docker info | grep -q "Swarm: active"; then
        docker swarm init
        echo -e "${verde}Swarm inicializado com sucesso!${reset}"
    else
        echo -e "${amarelo}Swarm já está ativo${reset}"
    fi
}

## Função para coletar informações
get_inputs() {
    # Nome da rede
    clear
    echo -e "${azul}Configuração da Rede${reset}"
    echo ""
    echo -e "\e[97mPasso${amarelo} 1/3${reset}"
    echo -en "${amarelo}Digite o nome da rede Docker (ex: traefik-public): ${reset}"
    read NETWORK_NAME
    
    # Email
    clear
    echo -e "${azul}Configuração do Email${reset}"
    echo ""
    echo -e "\e[97mPasso${amarelo} 2/3${reset}"
    echo -en "${amarelo}Digite o email para certificados SSL (ex: seu.email@dominio.com): ${reset}"
    read TRAEFIK_EMAIL
    
    # URL
    clear
    echo -e "${azul}Configuração do Portainer${reset}"
    echo ""
    echo -e "\e[97mPasso${amarelo} 3/3${reset}"
    echo -en "${amarelo}Digite a URL para o Portainer (ex: portainer.seudominio.com): ${reset}"
    read PORTAINER_URL
    
    # Confirma
    clear
    echo -e "${azul}Confirme as informações:${reset}"
    echo ""
    echo -e "${amarelo}Nome da rede:${reset} $NETWORK_NAME"
    echo -e "${amarelo}Email:${reset} $TRAEFIK_EMAIL"
    echo -e "${amarelo}URL do Portainer:${reset} $PORTAINER_URL"
    echo ""
    read -p "As informações estão corretas? (Y/N): " confirmacao
    
    if [ "$confirmacao" = "Y" ] || [ "$confirmacao" = "y" ]; then
        return 0
    else
        get_inputs
    fi
}

## Função para criar rede Docker
create_network() {
    echo -e "${azul}Criando rede Docker...${reset}"
    if ! docker network ls | grep -q "$NETWORK_NAME"; then
        docker network create -d overlay --attachable "$NETWORK_NAME"
        echo -e "${verde}Rede $NETWORK_NAME criada com sucesso!${reset}"
    else
        echo -e "${amarelo}Rede $NETWORK_NAME já existe${reset}"
    fi
}

## Função para instalar Traefik
install_traefik() {
    echo -e "${azul}Instalando Traefik...${reset}"
    
    mkdir -p /opt/traefik
    
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
      - "--certificatesresolvers.letsencrypt.acme.email=${TRAEFIK_EMAIL}"
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
) traefik

    echo -e "${verde}Traefik instalado com sucesso!${reset}"
}

## Função para instalar Portainer
install_portainer() {
    echo -e "${azul}Instalando Portainer...${reset}"
    
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
        - "traefik.http.routers.portainer.rule=Host(\`${PORTAINER_URL}\`)"
        - "traefik.http.routers.portainer.entrypoints=websecure"
        - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"
        - "traefik.http.services.portainer.loadbalancer.server.port=9000"

volumes:
  portainer_data:

networks:
  ${NETWORK_NAME}:
    external: true
EOF
) portainer

    echo -e "${verde}Portainer instalado com sucesso!${reset}"
}

## Função principal
main() {
    check_root
    detect_os
    get_inputs
    install_docker
    init_swarm
    create_network
    install_traefik
    install_portainer
    
    echo -e "${verde}Instalação concluída!${reset}"
    echo -e "${verde}Acesse o Portainer em: https://${PORTAINER_URL}${reset}"
}

# Executa o script
main 
