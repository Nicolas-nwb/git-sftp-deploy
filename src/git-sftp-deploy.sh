#!/bin/bash

# Gestionnaire de déploiement SFTP avec sauvegarde et restauration
# Auteur: Script généré pour déploiement Git vers SFTP

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/deploy.conf"
SAVE_DIR="$SCRIPT_DIR/save-deploy"

# Couleurs pour l'affichage
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonctions utilitaires
log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✅${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}❌${NC} $1"; }

# Afficher l'aide
show_help() {
    cat << EOF
Usage: $0 [OPTION] [ARGUMENTS]

COMMANDES:
  init [config-file]           Initialise un fichier de configuration template
  deploy <commit> [config]     Déploie les fichiers d'un commit avec sauvegarde
  restore [backup-dir] [config] Restaure depuis une sauvegarde
  list [config]                Liste les sauvegardes disponibles

CONFIGURATION:
  Le fichier de configuration permet de définir:
  - SSH_HOST: nom de la config SSH (définie dans ~/.ssh/config)
  - REMOTE_PATH: répertoire de destination sur le serveur
  - LOCAL_ROOT: racine locale pour calculer les chemins relatifs (optionnel)
  
  Exemple avec LOCAL_ROOT="src/web":
  - Commit modifie: src/web/index.html, src/web/css/style.css, README.md
  - Fichiers déployés: index.html, css/style.css (README.md ignoré)

EXEMPLES:
  $0 init                      # Crée deploy.conf
  $0 init prod.conf            # Crée prod.conf
  $0 deploy HEAD               # Déploie le dernier commit
  $0 deploy abc123             # Déploie le commit abc123
  $0 restore                   # Sélecteur interactif de sauvegarde
  $0 restore save-deploy/HEAD/2024-01-15_14-30-25  # Restaure une sauvegarde spécifique

OPTIONS:
  -h, --help                   Affiche cette aide
EOF
}

# Initialiser un fichier de configuration template
init_config() {
    local config_file="${1:-$DEFAULT_CONFIG}"
    
    if [ -f "$config_file" ]; then
        log_warning "Le fichier $config_file existe déjà"
        read -p "Voulez-vous l'écraser ? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Opération annulée"
            return 0
        fi
    fi

    cat > "$config_file" << 'EOF'
# Configuration de déploiement SFTP
# Nom de la configuration SSH définie dans ~/.ssh/config
SSH_HOST="nom-du-host-ssh"

# Chemin distant où déployer les fichiers
REMOTE_PATH="/var/www/html"

# Racine locale à partir de laquelle calculer les chemins relatifs
# Si vide ou ".", utilise la racine du projet Git
# Exemple: "src/web" pour déployer seulement le contenu de src/web/
LOCAL_ROOT=""

# Optionnel: utilisateur SSH (si différent de celui dans .ssh/config)
# SSH_USER="username"

# Optionnel: port SSH (si différent de celui dans .ssh/config)
# SSH_PORT="22"

# Optionnel: clé SSH spécifique (si différente de celle dans .ssh/config)
# SSH_KEY="~/.ssh/id_rsa_specific"
EOF

    log_success "Fichier de configuration créé: $config_file"
    log_info "Editez ce fichier avec vos paramètres avant le premier déploiement"
}

# Charger la configuration
load_config() {
    local config_file="${1:-$DEFAULT_CONFIG}"
    
    if [ ! -f "$config_file" ]; then
        log_error "Fichier de configuration non trouvé: $config_file"
        log_info "Utilisez '$0 init' pour créer un fichier de configuration"
        exit 1
    fi
    
    source "$config_file"
    
    if [ -z "$SSH_HOST" ] || [ -z "$REMOTE_PATH" ]; then
        log_error "Configuration incomplète. SSH_HOST et REMOTE_PATH sont requis"
        exit 1
    fi
    
    # Normaliser LOCAL_ROOT
    if [ -z "$LOCAL_ROOT" ] || [ "$LOCAL_ROOT" = "." ]; then
        LOCAL_ROOT=""
    else
        # Supprimer le slash final s'il existe
        LOCAL_ROOT="${LOCAL_ROOT%/}"
    fi
}

# Construire la commande SSH/SFTP avec les paramètres
build_ssh_command() {
    local cmd_type="$1"  # ssh ou sftp
    local ssh_opts=""
    
    if [ -n "$SSH_USER" ]; then
        ssh_opts="$ssh_opts -l $SSH_USER"
    fi
    
    if [ -n "$SSH_PORT" ]; then
        ssh_opts="$ssh_opts -p $SSH_PORT"
    fi
    
    if [ -n "$SSH_KEY" ]; then
        ssh_opts="$ssh_opts -i $SSH_KEY"
    fi
    
    echo "$cmd_type $ssh_opts $SSH_HOST"
}

# Filtrer les fichiers selon LOCAL_ROOT et calculer les chemins relatifs
filter_and_relativize_files() {
    local files_list="$1"
    local filtered_files=""
    
    for file in $files_list; do
        if [ -n "$LOCAL_ROOT" ]; then
            # Vérifier si le fichier est dans LOCAL_ROOT
            if [[ "$file" == "$LOCAL_ROOT"/* ]]; then
                # Calculer le chemin relatif en supprimant LOCAL_ROOT/
                local relative_file="${file#$LOCAL_ROOT/}"
                filtered_files="$filtered_files$relative_file\n"
            fi
        else
            # Pas de LOCAL_ROOT, utiliser le fichier tel quel
            filtered_files="$filtered_files$file\n"
        fi
    done
    
    # Supprimer le dernier \n et retourner
    echo -e "$filtered_files" | sed '/^$/d'
}

# Obtenir le chemin complet d'un fichier depuis la racine du projet
get_full_file_path() {
    local relative_file="$1"
    
    if [ -n "$LOCAL_ROOT" ]; then
        echo "$LOCAL_ROOT/$relative_file"
    else
        echo "$relative_file"
    fi
}

# Créer une sauvegarde des fichiers distants
create_backup() {
    local commit_ref="$1"
    local files_list="$2"
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_dir="$SAVE_DIR/$commit_ref/$timestamp"
    
    log_info "Création de la sauvegarde dans: $backup_dir"
    mkdir -p "$backup_dir"
    
    # Sauvegarder chaque fichier via une session SFTP indépendante
    local sftp_cmd=$(build_ssh_command "sftp")
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        # Créer le répertoire local si nécessaire
        local local_dir="$backup_dir/$(dirname "$file")"
        if [ "$local_dir" != "$backup_dir/." ]; then
            mkdir -p "$local_dir"
        fi

        # Batch temporaire pour un fichier
        local one_cmd
        one_cmd=$(mktemp)
        echo "cd $REMOTE_PATH" > "$one_cmd"
        echo "lcd $backup_dir" >> "$one_cmd"
        echo "get $file $file" >> "$one_cmd"
        echo "quit" >> "$one_cmd"
        # Ignorer les erreurs si le fichier distant n'existe pas
        $sftp_cmd -b "$one_cmd" 2>/dev/null || true
        rm -f "$one_cmd"
    done <<< "$files_list"
    
    # Sauvegarder la liste des fichiers déployés (chemins relatifs)
    echo "$files_list" > "$backup_dir/deployed_files.txt"
    
    # Sauvegarder aussi la configuration LOCAL_ROOT utilisée
    echo "LOCAL_ROOT=\"$LOCAL_ROOT\"" > "$backup_dir/deploy_config.txt"
    
    # Rien à nettoyer: scripts temporaires déjà supprimés
    echo "$backup_dir"
}

# Déployer un commit avec sauvegarde
deploy_commit() {
    local commit_hash="$1"
    local config_file="$2"
    
    if [ -z "$commit_hash" ]; then
        log_error "Hash de commit requis"
        show_help
        exit 1
    fi
    
    load_config "$config_file"
    
    log_info "Récupération des fichiers modifiés dans le commit $commit_hash..."
    
    # Récupérer les fichiers modifiés/ajoutés dans le commit
    local all_files=$(git diff-tree --no-commit-id --name-only --diff-filter=AM -r "$commit_hash")
    
    if [ -z "$all_files" ]; then
        log_warning "Aucun fichier modifié dans ce commit"
        exit 0
    fi
    
    # Filtrer selon LOCAL_ROOT et calculer les chemins relatifs
    local files=$(filter_and_relativize_files "$all_files")
    
    if [ -z "$files" ]; then
        if [ -n "$LOCAL_ROOT" ]; then
            log_warning "Aucun fichier à déployer dans $LOCAL_ROOT pour ce commit"
        else
            log_warning "Aucun fichier à déployer dans ce commit"
        fi
        exit 0
    fi
    
    log_info "Racine locale: ${LOCAL_ROOT:-"(racine du projet)"}"
    log_info "Fichiers à déployer:"
    echo "$files"
    
    # Créer la sauvegarde avant déploiement (avec les chemins relatifs)
    local backup_dir=$(create_backup "$commit_hash" "$files")
    log_success "Sauvegarde créée: $backup_dir"
    
    # Créer un dossier temporaire pour exporter les fichiers
    local temp_dir=$(mktemp -d)
    log_info "Export des fichiers vers $temp_dir..."
    
    # Exporter chaque fichier à sa version du commit
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        local full_file_path=$(get_full_file_path "$file")
        
        mkdir -p "$temp_dir/$(dirname "$file")"
        
        if git show "$commit_hash:$full_file_path" > "$temp_dir/$file" 2>/dev/null; then
            log_success "Exporté: $full_file_path -> $file"
        else
            log_error "Erreur lors de l'export de: $full_file_path"
            rm -rf "$temp_dir"
            exit 1
        fi
    done <<< "$files"
    
    log_info "Upload vers SFTP..."
    
    # Créer le script SFTP pour l'upload
    local sftp_script="$temp_dir/upload_commands.txt"
    echo "cd $REMOTE_PATH" > "$sftp_script"
    
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        if [ -f "$temp_dir/$file" ]; then
            # Créer le répertoire distant si nécessaire
            if [ "$(dirname "$file")" != "." ]; then
                echo "mkdir -p $(dirname "$file")" >> "$sftp_script"
            fi
            echo "put $temp_dir/$file $file" >> "$sftp_script"
        fi
    done <<< "$files"
    
    echo "quit" >> "$sftp_script"
    
    # Exécuter SFTP
    local sftp_cmd=$(build_ssh_command "sftp")
    if $sftp_cmd -b "$sftp_script"; then
        log_success "Déploiement terminé avec succès!"
        log_info "Sauvegarde disponible dans: $backup_dir"
    else
        log_error "Erreur lors du déploiement SFTP"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Nettoyer
    rm -rf "$temp_dir"
}

# Lister les sauvegardes disponibles
list_backups() {
    local config_file="$1"
    
    if [ ! -d "$SAVE_DIR" ]; then
        log_warning "Aucune sauvegarde trouvée"
        return 0
    fi
    
    log_info "Sauvegardes disponibles:"
    find "$SAVE_DIR" -type d -name "*-*-*_*-*-*" | sort -r | while read -r backup; do
        local relative_path=${backup#$SAVE_DIR/}
        echo "  $relative_path"
    done
}

# Sélecteur interactif de sauvegarde
select_backup() {
    if [ ! -d "$SAVE_DIR" ]; then
        log_error "Aucune sauvegarde trouvée"
        exit 1
    fi
    
    local backups=($(find "$SAVE_DIR" -type d -name "*-*-*_*-*-*" | sort -r))
    
    if [ ${#backups[@]} -eq 0 ]; then
        log_error "Aucune sauvegarde trouvée"
        exit 1
    fi
    
    log_info "Sélectionnez une sauvegarde à restaurer:"
    
    local i=1
    for backup in "${backups[@]}"; do
        local relative_path=${backup#$SAVE_DIR/}
        echo "  $i) $relative_path"
        ((i++))
    done
    
    echo
    read -p "Entrez le numéro de la sauvegarde (1-${#backups[@]}): " -r selection
    
    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
        log_error "Sélection invalide"
        exit 1
    fi
    
    echo "${backups[$((selection-1))]}"
}

# Restaurer depuis une sauvegarde
restore_backup() {
    local backup_dir="$1"
    local config_file="$2"
    
    # Si aucune sauvegarde spécifiée, utiliser le sélecteur
    if [ -z "$backup_dir" ]; then
        backup_dir=$(select_backup)
    fi
    
    # Si le chemin est relatif, le préfixer avec SAVE_DIR
    if [[ ! "$backup_dir" =~ ^/ ]]; then
        backup_dir="$SAVE_DIR/$backup_dir"
    fi
    
    if [ ! -d "$backup_dir" ]; then
        log_error "Répertoire de sauvegarde non trouvé: $backup_dir"
        exit 1
    fi
    
    load_config "$config_file"
    
    log_info "Restauration depuis: $backup_dir"
    
    # Lire la configuration de déploiement sauvegardée
    local backup_config="$backup_dir/deploy_config.txt"
    if [ -f "$backup_config" ]; then
        log_info "Configuration de déploiement trouvée dans la sauvegarde"
        source "$backup_config"
        log_info "LOCAL_ROOT utilisé lors du déploiement: ${LOCAL_ROOT:-"(racine du projet)"}"
    else
        log_warning "Pas de configuration de déploiement dans la sauvegarde (ancienne version)"
    fi
    
    # Lire la liste des fichiers qui avaient été déployés
    local deployed_files_list="$backup_dir/deployed_files.txt"
    if [ ! -f "$deployed_files_list" ]; then
        log_error "Liste des fichiers déployés non trouvée dans la sauvegarde"
        exit 1
    fi
    
    local deployed_files=$(cat "$deployed_files_list")
    
    # Créer le script SFTP pour la restauration
    local temp_dir=$(mktemp -d)
    local sftp_script="$temp_dir/restore_commands.txt"
    echo "cd $REMOTE_PATH" > "$sftp_script"
    
    # Restaurer les fichiers qui existaient (utilise les chemins relatifs sauvegardés)
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        if [ -f "$backup_dir/$file" ]; then
            log_info "Restauration: $file"
            # Créer le répertoire distant si nécessaire
            if [ "$(dirname "$file")" != "." ]; then
                echo "mkdir -p $(dirname "$file")" >> "$sftp_script"
            fi
            echo "put $backup_dir/$file $file" >> "$sftp_script"
        else
            # Le fichier n'existait pas avant le déploiement, le supprimer
            log_info "Suppression: $file (fichier ajouté lors du déploiement)"
            echo "rm $file" >> "$sftp_script"
        fi
    done <<< "$deployed_files"
    
    echo "quit" >> "$sftp_script"
    
    # Exécuter SFTP
    local sftp_cmd=$(build_ssh_command "sftp")
    if $sftp_cmd -b "$sftp_script"; then
        log_success "Restauration terminée avec succès!"
    else
        log_error "Erreur lors de la restauration"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Nettoyer
    rm -rf "$temp_dir"
}

# Parse des arguments
case "${1:-}" in
    "init")
        init_config "$2"
        ;;
    "deploy")
        if [ -z "$2" ]; then
            log_error "Hash de commit requis pour le déploiement"
            show_help
            exit 1
        fi
        deploy_commit "$2" "$3"
        ;;
    "restore")
        restore_backup "$2" "$3"
        ;;
    "list")
        list_backups "$2"
        ;;
    "-h"|"--help"|"help")
        show_help
        ;;
    "")
        show_help
        ;;
    *)
        log_error "Commande inconnue: $1"
        show_help
        exit 1
        ;;
esac
