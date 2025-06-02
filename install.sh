#!/bin/bash

# Service Installation Script

# Install only nginx
# Usage: ./install.sh [nginx-only]

# Install Docker and setup NocoBase
# ./install.sh docker

# Setup NocoBase only (requires Docker already installed)
# ./install.sh nocobase

# Install all services (keepalived, haproxy, nginx)
#sudo ./install.sh

set -e

# Global server configuration
MASTER_SERVER="rpi1"
BACKUP_SERVER="rpi2"

# SSL Certificate configuration
SSL_CERT_DAYS="365"
SSL_KEY_SIZE="2048"
SSL_CERT_PATH="/etc/ssl/private/haproxy.pem"

# NocoBase configuration
NOCOBASE_DIR="./nocobase"
STORAGE_DIR="storage"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Function to detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    else
        print_error "Cannot detect OS"
        exit 1
    fi
    
    print_status "Detected OS: $OS $VER"
}

# Function to install packages based on OS
install_packages() {
    local packages="$1"
    
    if [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Debian"* ]]; then
        print_status "Updating package list..."
        apt-get update
        print_status "Installing packages: $packages"
        apt-get install -y $packages
    elif [[ "$OS" == *"CentOS"* ]] || [[ "$OS" == *"Red Hat"* ]] || [[ "$OS" == *"Rocky"* ]] || [[ "$OS" == *"AlmaLinux"* ]]; then
        print_status "Installing packages: $packages"
        yum install -y $packages
    elif [[ "$OS" == *"Fedora"* ]]; then
        print_status "Installing packages: $packages"
        dnf install -y $packages
    else
        print_error "Unsupported OS: $OS"
        exit 1
    fi
}

# Function to copy nginx config files
copy_nginx_config() {
    print_status "Copying nginx configuration files..."
    
    # Create sites-available directory if it doesn't exist
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    
    if [ -f "./nginx/default" ]; then
        cp ./nginx/default /etc/nginx/sites-available/
        print_status "nginx default site configuration copied successfully"
        
        # Enable the site by creating symlink if it doesn't exist
        if [ ! -L "/etc/nginx/sites-enabled/default" ]; then
            ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
            print_status "nginx default site enabled"
        fi
    else
        print_warning "./nginx/default not found, skipping nginx site configuration"
    fi
    
    # Copy any other nginx config files
    if [ -d "./nginx" ]; then
        # Copy other files except 'default' (already handled above)
        find ./nginx -type f ! -name "default" -exec cp {} /etc/nginx/ \; 2>/dev/null || true
    fi
}

# Function to copy haproxy config files
copy_haproxy_config() {
    print_status "Copying haproxy configuration files..."
    
    mkdir -p /etc/haproxy
    
    if [ -f "./haproxy/haproxy.cfg" ]; then
        cp ./haproxy/haproxy.cfg /etc/haproxy/
        print_status "haproxy configuration copied successfully"
    else
        print_warning "./haproxy/haproxy.cfg not found, skipping haproxy configuration"
    fi
}

# Function to generate SSL certificate for HAProxy
generate_ssl_certificate() {
    print_status "Generating SSL certificate for HAProxy..."
    
    # Create SSL directory if it doesn't exist
    mkdir -p /etc/ssl/private
    
    # Generate certificate and key
    print_status "Creating self-signed certificate (valid for $SSL_CERT_DAYS days)..."
    openssl req -x509 -nodes -days "$SSL_CERT_DAYS" -newkey rsa:"$SSL_KEY_SIZE" \
        -keyout /tmp/haproxy.key -out /tmp/haproxy.crt \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=haproxy-lb" 2>/dev/null
    
    # Combine certificate and key for HAProxy
    print_status "Combining certificate and key for HAProxy..."
    cat /tmp/haproxy.crt /tmp/haproxy.key > /tmp/haproxy.pem
    
    # Move to proper location with correct permissions
    cp /tmp/haproxy.pem "$SSL_CERT_PATH"
    chmod 600 "$SSL_CERT_PATH"
    chown root:root "$SSL_CERT_PATH"
    
    print_status "SSL certificate created at: $SSL_CERT_PATH"
    
    # Clean up temporary files
    rm -f /tmp/haproxy.key /tmp/haproxy.crt /tmp/haproxy.pem
}

# Function to copy SSL certificate to backup server
copy_ssl_to_backup() {
    local backup_ip="$1"
    local backup_user="rpi"
    
    if [ -z "$backup_ip" ]; then
        print_warning "No backup server IP provided, skipping SSL certificate copy"
        return 0
    fi
    
    print_status "Copying SSL certificate to backup server ($backup_ip)..."
    
    # Check if certificate exists
    if [ ! -f "$SSL_CERT_PATH" ]; then
        print_error "SSL certificate not found at $SSL_CERT_PATH"
        return 1
    fi
    
    # Copy certificate to backup server
    if scp "$SSL_CERT_PATH" "$backup_user@$backup_ip:/tmp/haproxy.pem" 2>/dev/null; then
        print_status "Certificate copied to backup server"
        print_status "Run the following commands on the backup server ($backup_ip):"
        echo "  sudo cp /tmp/haproxy.pem $SSL_CERT_PATH"
        echo "  sudo chmod 600 $SSL_CERT_PATH"
        echo "  sudo chown root:root $SSL_CERT_PATH"
        echo "  sudo rm /tmp/haproxy.pem"
    else
        print_warning "Failed to copy certificate to backup server"
        print_warning "You can manually copy the certificate using:"
        echo "  scp $SSL_CERT_PATH $backup_user@$backup_ip:/tmp/haproxy.pem"
    fi
}

# Function to install Docker and Docker Compose
install_docker() {
    print_status "Installing Docker and Docker Compose..."
    
    if command -v docker >/dev/null 2>&1; then
        print_status "Docker is already installed"
    else
        print_status "Installing Docker..."
        
        if [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Debian"* ]]; then
            # Install Docker on Ubuntu/Debian
            apt-get update
            apt-get install -y ca-certificates curl gnupg lsb-release
            
            # Add Docker's official GPG key
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            
            # Set up repository
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Install Docker Engine
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            
        elif [[ "$OS" == *"CentOS"* ]] || [[ "$OS" == *"Red Hat"* ]] || [[ "$OS" == *"Rocky"* ]] || [[ "$OS" == *"AlmaLinux"* ]]; then
            # Install Docker on CentOS/RHEL
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            
        elif [[ "$OS" == *"Fedora"* ]]; then
            # Install Docker on Fedora
            dnf -y install dnf-plugins-core
            dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        fi
        
        # Start and enable Docker
        systemctl enable docker
        systemctl start docker
        
        print_status "Docker installed successfully"
    fi
    
    # Check if docker-compose command exists (standalone version)
    if ! command -v docker-compose >/dev/null 2>&1; then
        # Install standalone docker-compose if not available
        print_status "Installing standalone docker-compose..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    fi
    
    # Verify Docker installation
    if docker --version && (docker-compose --version || docker compose version); then
        print_status "Docker and Docker Compose are ready"
    else
        print_error "Docker installation verification failed"
        exit 1
    fi
}

# Function to setup NocoBase
setup_nocobase() {
    print_status "Setting up NocoBase..."
    
    # Check if NocoBase directory exists
    if [ ! -d "$NOCOBASE_DIR" ]; then
        print_error "NocoBase directory '$NOCOBASE_DIR' not found"
        print_error "Make sure the nocobase directory exists with docker-compose.yml"
        return 1
    fi
    
    # Change to NocoBase directory
    cd "$NOCOBASE_DIR"
    
    # Create storage directory
    print_status "Creating storage directory..."
    mkdir -p "$STORAGE_DIR"
    
    # Check if docker-compose.yml exists
    if [ ! -f "docker-compose.yml" ] && [ ! -f "docker-compose.yaml" ]; then
        print_error "docker-compose.yml not found in $NOCOBASE_DIR"
        return 1
    fi
    
    print_status "Starting NocoBase with Docker Compose..."
    
    # Use docker compose (new syntax) or docker-compose (legacy)
    if docker compose version >/dev/null 2>&1; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    if [ $? -eq 0 ]; then
        print_status "NocoBase started successfully"
        print_status "Storage directory created at: $NOCOBASE_DIR/$STORAGE_DIR"
        
        # Show running containers
        print_status "Running containers:"
        if docker compose version >/dev/null 2>&1; then
            docker compose ps
        else
            docker-compose ps
        fi
    else
        print_error "Failed to start NocoBase"
        return 1
    fi
    
    # Return to original directory
    cd - >/dev/null
}
setup_ssl_certificate() {
    local server_role="$1"
    local backup_ip="$2"
    
    # Only generate certificate on master server or if explicitly requested
    if [[ "$server_role" == "MASTER" ]] || [ ! -f "$SSL_CERT_PATH" ]; then
        generate_ssl_certificate
        
        # If this is master and backup IP is provided, copy to backup
        if [[ "$server_role" == "MASTER" ]] && [ -n "$backup_ip" ]; then
            copy_ssl_to_backup "$backup_ip"
        fi
    else
        print_status "SSL certificate already exists at: $SSL_CERT_PATH"
        print_status "Skipping certificate generation (not master server)"
    fi
}
copy_keepalived_config() {
    print_status "Copying keepalived configuration files..."
    
    mkdir -p /etc/keepalived
    
    # Get hostname to determine which config to use
    local hostname=$(hostname)
    local config_file=""
    local server_role=""
    
    print_status "Detected hostname: $hostname"
    print_status "Master server: $MASTER_SERVER, Backup server: $BACKUP_SERVER"
    
    # Determine server role and config file
    if [[ "$hostname" == *"$MASTER_SERVER"* ]] || [[ "$hostname" == "$MASTER_SERVER" ]]; then
        config_file="./keepalive/$MASTER_SERVER/keepalived.conf"
        server_role="MASTER"
        print_status "Identified as MASTER server ($MASTER_SERVER)"
    elif [[ "$hostname" == *"$BACKUP_SERVER"* ]] || [[ "$hostname" == "$BACKUP_SERVER" ]]; then
        config_file="./keepalive/$BACKUP_SERVER/keepalived.conf"
        server_role="BACKUP"
        print_status "Identified as BACKUP server ($BACKUP_SERVER)"
    elif [ -f "./keepalive/$hostname/keepalived.conf" ]; then
        config_file="./keepalive/$hostname/keepalived.conf"
        server_role="CUSTOM"
        print_status "Using hostname-specific config for $hostname"
    else
        print_warning "Hostname '$hostname' doesn't match master ($MASTER_SERVER) or backup ($BACKUP_SERVER)"
        print_warning "Available keepalived configs:"
        ls -la ./keepalive/ 2>/dev/null || echo "No keepalive directory found"
        
        # Ask user to choose
        echo -e "\nSelect server role:"
        echo "1) Master ($MASTER_SERVER)"
        echo "2) Backup ($BACKUP_SERVER)"
        read -p "Enter choice (1 or 2): " choice
        
        case $choice in
            1)
                config_file="./keepalive/$MASTER_SERVER/keepalived.conf"
                server_role="MASTER"
                print_status "Manually selected as MASTER server"
                ;;
            2)
                config_file="./keepalive/$BACKUP_SERVER/keepalived.conf"
                server_role="BACKUP"
                print_status "Manually selected as BACKUP server"
                ;;
            *)
                print_error "Invalid choice. Exiting."
                return 1
                ;;
        esac
    fi
    
    # Copy the configuration file
    if [ -n "$config_file" ] && [ -f "$config_file" ]; then
        cp "$config_file" /etc/keepalived/keepalived.conf
        print_status "keepalived configuration copied successfully"
        print_status "Server role: $server_role"
        print_status "Config source: $config_file"
    else
        print_error "Configuration file not found: $config_file"
        print_error "Make sure the keepalived config exists for your server role"
        return 1
    fi
}

# Function to enable and start service
enable_start_service() {
    local service="$1"
    
    print_status "Enabling and starting $service..."
    systemctl enable "$service"
    systemctl start "$service"
    
    if systemctl is-active --quiet "$service"; then
        print_status "$service is running successfully"
    else
        print_error "$service failed to start"
        systemctl status "$service"
    fi
}

# Function to install nginx
install_nginx() {
    print_status "Installing nginx..."
    install_packages "nginx"
    
    # Copy nginx configuration
    copy_nginx_config
    
    # Test nginx configuration
    print_status "Testing nginx configuration..."
    if nginx -t; then
        print_status "nginx configuration is valid"
        enable_start_service "nginx"
    else
        print_error "nginx configuration test failed"
        exit 1
    fi
}

# Function to install haproxy
install_haproxy() {
    print_status "Installing haproxy..."
    install_packages "haproxy openssl"
    
    # Copy haproxy configuration
    copy_haproxy_config
    
    # Check if SSL certificate is needed for HAProxy
    if grep -q "ssl" ./haproxy/haproxy.cfg 2>/dev/null; then
        print_status "SSL configuration detected in haproxy.cfg"
        if [ ! -f "$SSL_CERT_PATH" ]; then
            print_status "Generating SSL certificate for HAProxy..."
            generate_ssl_certificate
        else
            print_status "SSL certificate already exists at: $SSL_CERT_PATH"
        fi
    fi
    
    # Test haproxy configuration
    print_status "Testing haproxy configuration..."
    if haproxy -c -f /etc/haproxy/haproxy.cfg; then
        print_status "haproxy configuration is valid"
        enable_start_service "haproxy"
    else
        print_error "haproxy configuration test failed"
        exit 1
    fi
}

# Function to install keepalived
install_keepalived() {
    print_status "Installing keepalived..."
    install_packages "keepalived"
    
    # Copy keepalived configuration and get server role
    local server_role=$(copy_keepalived_config)
    
    # Setup SSL certificate based on server role
    read -p "Enter backup server IP (or press Enter to skip SSL setup): " backup_ip
    if [ -n "$backup_ip" ] || [[ "$server_role" == "MASTER" ]]; then
        setup_ssl_certificate "$server_role" "$backup_ip"
    fi
    
    enable_start_service "keepalived"
}

# Function to backup existing configurations
backup_configs() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="/tmp/service_configs_backup_$timestamp"
    
    print_status "Creating backup of existing configurations..."
    mkdir -p "$backup_dir"
    
    # Backup existing configs if they exist
    [ -d "/etc/nginx" ] && cp -r /etc/nginx "$backup_dir/" 2>/dev/null || true
    [ -d "/etc/haproxy" ] && cp -r /etc/haproxy "$backup_dir/" 2>/dev/null || true
    [ -d "/etc/keepalived" ] && cp -r /etc/keepalived "$backup_dir/" 2>/dev/null || true
    
    print_status "Backup created at: $backup_dir"
}

# Function to show service status
show_status() {
    print_status "Service Status:"
    echo "----------------------------------------"
    
    if command -v nginx >/dev/null 2>&1; then
        echo -n "nginx: "
        systemctl is-active nginx || echo "inactive"
    fi
    
    if [[ "$1" != "nginx-only" ]]; then
        if command -v haproxy >/dev/null 2>&1; then
            echo -n "haproxy: "
            systemctl is-active haproxy || echo "inactive"
        fi
        
        if command -v keepalived >/dev/null 2>&1; then
            echo -n "keepalived: "
            systemctl is-active keepalived || echo "inactive"
        fi
    fi
    echo "----------------------------------------"
}

# Main installation function
main() {
    local install_mode="$1"
    
    print_status "Starting service installation..."
    print_status "Install mode: ${install_mode:-full}"
    
    # Check prerequisites
    check_root
    detect_os
    backup_configs
    
    # Install services based on mode
    if [[ "$install_mode" == "nginx-only" ]]; then
        print_status "Installing nginx only..."
        install_nginx
    elif [[ "$install_mode" == "docker" ]]; then
        print_status "Installing Docker and setting up NocoBase..."
        install_docker
        setup_nocobase
    elif [[ "$install_mode" == "nocobase" ]]; then
        print_status "Setting up NocoBase only..."
        setup_nocobase
    else
        print_status "Installing all services (keepalived, haproxy, nginx)..."
        install_keepalived
        install_haproxy
        install_nginx
    fi
    
    # Show final status (skip for docker-only modes)
    if [[ "$install_mode" != "docker" ]] && [[ "$install_mode" != "nocobase" ]]; then
        show_status "$install_mode"
    fi
    
    print_status "Installation completed successfully!"
    if [[ "$install_mode" != "docker" ]] && [[ "$install_mode" != "nocobase" ]]; then
        print_status "Configuration backups are available in /tmp/"
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "$1" in
        "nginx-only")
            main "nginx-only"
            ;;
        "docker")
            install_docker
            setup_nocobase
            ;;
        "nocobase")
            setup_nocobase
            ;;
        "")
            main "full"
            ;;
        *)
            echo "Usage: $0 [nginx-only|docker|nocobase]"
            echo "  nginx-only: Install only nginx"
            echo "  docker:     Install Docker and setup NocoBase"
            echo "  nocobase:   Setup NocoBase only (requires Docker)"
            echo "  (no args):  Install keepalived, haproxy, and nginx"
            exit 1
            ;;
    esac
fi
