#!/bin/bash

# Gestionnaire de déploiement SFTP avec sauvegarde et restauration
# Auteur: Script généré pour déploiement Git vers SFTP

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_BASENAME="deploy.conf"
# Stocke le chemin de config effectivement utilisé (défini par load_config)
CONFIG_FILE_PATH=""
# Répertoire courant d'exécution (résolu physiquement)
CWD="$(pwd -P)"
# Dossier de sauvegarde local (dans le répertoire courant d'exécution)
SAVE_DIR="$CWD/save-deploy"

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


# Vérifie la présence des dépendances critiques et suggère une installation Homebrew
check_prerequisites() {
    local context="$1"
    local -a required=()

    case "$context" in
        deploy|restore)
            required=("git" "sftp" "mktemp" "awk" "sed" "grep" "tail" "find" "sort" "wc" "date" "dirname" "cat" "chmod" "mkdir" "ln")
            ;;
        list)
            required=("find" "sort")
            ;;
        init)
            return 0
            ;;
        *)
            required=("git" "sftp")
            ;;
    esac

    [ ${#required[@]} -gt 0 ] || return 0

    local -a missing=()
    local cmd
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    [ ${#missing[@]} -eq 0 ] && return 0

    log_error "Prérequis manquants détectés: ${missing[*]}"

    if ! command -v brew >/dev/null 2>&1; then
        log_warning "Homebrew introuvable. Installez-le d'abord via https://brew.sh"
        exit 1
    fi

    log_info "Commandes Homebrew suggérées :"
    local tips=""
    local tip

    for cmd in "${missing[@]}"; do
        case "$cmd" in
            git)
                tip="brew install git"
                ;;
            ssh|sftp)
                tip="brew install openssh"
                ;;
            mktemp|tail|wc|date|dirname|cat|chmod|mkdir|ln)
                tip="brew install coreutils"
                ;;
            awk)
                tip="brew install gawk"
                ;;
            sed)
                tip="brew install gnu-sed"
                ;;
            grep)
                tip="brew install grep"
                ;;
            find)
                tip="brew install findutils"
                ;;
            *)
                tip="brew search $cmd"
                ;;
        esac
        if ! grep -qxF "$tip" <<< "$tips"; then
            tips="$tips
$tip"
        fi
    done

    while IFS= read -r tip; do
        [ -z "$tip" ] && continue
        log_info "  $tip"
    done <<< "$tips"

    exit 1
}

# Résoudre une référence Git (HEAD/branche/tag/sha) en SHA complet
resolve_commit_ref() {
    local ref="$1"
    if [ -z "$ref" ]; then
        log_error "Référence git manquante"
        exit 1
    fi
    if ! git rev-parse --verify "$ref^{commit}" >/dev/null 2>&1; then
        log_error "Référence git invalide: $ref"
        exit 1
    fi
    git rev-parse "$ref^{commit}"
}

# Afficher l'aide
show_help() {
    cat << EOF
Usage: $0 [OPTION] [ARGUMENTS]

COMMANDES:
  init [config-file]             Initialise un fichier de configuration template
  deploy <commit> [config]       Déploie les changements (A/M/D) d'un commit avec sauvegarde
  restore [backup-dir] [config]  Restaure depuis une sauvegarde
  list [config]                  Liste les sauvegardes disponibles

CONFIGURATION:
  Le fichier de configuration permet de définir:
  - SSH_HOST: nom de la config SSH (définie dans ~/.ssh/config)
  - REMOTE_PATH: répertoire de destination sur le serveur
  - LOCAL_ROOT: racine locale pour calculer les chemins relatifs (optionnel)
  - Par défaut, si [config] est omis, ./deploy.conf est utilisé
  
  Exemple avec LOCAL_ROOT="src/web":
  - Commit modifie: src/web/index.html, src/web/css/style.css, README.md
  - Fichiers déployés: index.html, css/style.css (README.md ignoré)

SUPPRESSIONS (D):
  - Seules les suppressions présentes dans le commit ciblé sont propagées
  - Avant suppression distante, le fichier est sauvegardé localement (restaurable)
  - Une suppression non commitée (simple effacement local) n'est JAMAIS synchronisée

SAUVEGARDES:
  - Les sauvegardes sont créées dans ./save-deploy (répertoire courant)
  - Un fichier .gitignore y est généré pour éviter toute inclusion Git

EXEMPLES:
  $0 init                      # Crée deploy.conf
  $0 init prod.conf            # Crée prod.conf
  $0 deploy HEAD               # Déploie le dernier commit (utilise ./deploy.conf si présent)
  $0 deploy abc123             # Déploie le commit abc123 (utilise ./deploy.conf si présent)
  $0 deploy HEAD ./prod.conf   # Déploie en utilisant un fichier de config explicite
  $0 restore                   # Sélecteur interactif de sauvegarde (config par défaut: ./deploy.conf)
  $0 restore save-deploy/<sha-commit>/2024-01-15_14-30-25  # Restaure une sauvegarde spécifique (alias HEAD disponible)

OPTIONS:
  -h, --help                   Affiche cette aide
EOF
}

# Initialiser un fichier de configuration template
init_config() {
    # Toujours créer dans le répertoire d'exécution courant si non spécifié
    local config_file="${1:-$CWD/$DEFAULT_CONFIG_BASENAME}"
    
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
# Si vide ou ".", utilise le dossier courant d'exécution (CWD)
# Exemple: "src/web" pour déployer seulement le contenu de src/web/
LOCAL_ROOT=""

# Optionnel: utilisateur SSH (si différent de celui dans .ssh/config)
# SSH_USER="username"

# Optionnel: port SSH (si différent de celui dans .ssh/config)
# SSH_PORT="22"

# Optionnel: clé SSH spécifique (si différente de celle dans .ssh/config)
# SSH_KEY="~/.ssh/id_rsa_specific"

# Optionnel: fichier de configuration SSH spécifique (par défaut: ~/.ssh/config)
# Utile si vous souhaitez pointer vers un fichier alternatif
# SSH_CONFIG_FILE="~/.ssh/config"
EOF

    log_success "Fichier de configuration créé: $config_file"
    log_info "Editez ce fichier avec vos paramètres avant le premier déploiement"
}

# Charger la configuration
load_config() {
    local input_config="${1:-}"
    local config_file
    if [ -n "$input_config" ]; then
        config_file="$input_config"
    else
        # Par défaut, utiliser la config dans le CWD
        config_file="$CWD/$DEFAULT_CONFIG_BASENAME"
    fi
    
    if [ ! -f "$config_file" ]; then
        log_error "Fichier de configuration non trouvé: $config_file"
        log_info "Utilisez '$0 init' pour créer un fichier de configuration"
        exit 1
    fi
    
    CONFIG_FILE_PATH="$config_file"
    local config_to_source="$config_file"
    local sanitized_tmp=""
    local bom_prefix
    bom_prefix=$(LC_ALL=C head -c 3 "$config_file" 2>/dev/null || true)
    local has_bom=0
    if [ "$bom_prefix" = $'\357\273\277' ]; then
        has_bom=1
    fi
    local has_cr=0
    if LC_ALL=C grep -q $'\r' "$config_file"; then
        has_cr=1
    fi

    if [ $has_bom -eq 1 ] || [ $has_cr -eq 1 ]; then
        sanitized_tmp=$(mktemp) || { log_error "Impossible de préparer un fichier temporaire"; exit 1; }
        if [ $has_bom -eq 1 ]; then
            if ! tail -c +4 "$config_file" > "$sanitized_tmp"; then
                log_error "Nettoyage BOM impossible dans $config_file"
                rm -f "$sanitized_tmp"
                exit 1
            fi
            log_warning "BOM détecté dans $config_file. Conversion temporaire appliquée"
        else
            if ! cat "$config_file" > "$sanitized_tmp"; then
                log_error "Lecture impossible de $config_file"
                rm -f "$sanitized_tmp"
                exit 1
            fi
        fi

        if [ $has_cr -eq 1 ]; then
            local sanitized_no_cr
            sanitized_no_cr=$(mktemp) || { log_error "Impossible de préparer un fichier temporaire"; rm -f "$sanitized_tmp"; exit 1; }
            if ! tr -d '\r' < "$sanitized_tmp" > "$sanitized_no_cr"; then
                log_error "Conversion CRLF impossible pour $config_file"
                rm -f "$sanitized_tmp" "$sanitized_no_cr"
                exit 1
            fi
            mv "$sanitized_no_cr" "$sanitized_tmp" || { log_error "Nettoyage CRLF impossible pour $config_file"; rm -f "$sanitized_tmp" "$sanitized_no_cr"; exit 1; }
            log_warning "Fins de ligne Windows détectées dans $config_file. Conversion temporaire appliquée"
        fi

        config_to_source="$sanitized_tmp"
    fi

    set +e
    # shellcheck disable=SC1090
    source "$config_to_source"
    local source_rc=$?
    set -e

    if [ -n "$sanitized_tmp" ]; then
        rm -f "$sanitized_tmp" || true
    fi

    if [ $source_rc -ne 0 ]; then
        log_error "Configuration invalide: $config_file"
        exit 1
    fi
    
    if [ -z "$SSH_HOST" ] || [ -z "$REMOTE_PATH" ]; then
        log_error "Configuration incomplète. SSH_HOST et REMOTE_PATH sont requis"
        exit 1
    fi
    
    # Normaliser LOCAL_ROOT
    # Si vide ou '.', utiliser le dossier courant d'exécution (relatif à la racine Git)
    local cwd_prefix
    cwd_prefix=""
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        cwd_prefix="$(git rev-parse --show-prefix 2>/dev/null || true)"
        cwd_prefix="${cwd_prefix%/}"
    fi
    if [ -z "$LOCAL_ROOT" ] || [ "$LOCAL_ROOT" = "." ]; then
        LOCAL_ROOT="$cwd_prefix"
    else
        # Supprimer le slash final s'il existe
        LOCAL_ROOT="${LOCAL_ROOT%/}"
    fi
}

# Construire la commande SSH/SFTP avec les paramètres
build_ssh_command() {
    local cmd_type="$1"  # ssh ou sftp
    #
    # Construction robuste des options pour ssh/sftp
    # - sftp: pas de '-p <port>' (collision avec 'preserve') -> utiliser -o Port
    # - sftp: pas de '-l <user>' (limite bande passante)     -> utiliser -o User
    # - support optionnel d'un fichier de config SSH dédié via SSH_CONFIG_FILE
    #
    local parts=()
    
    # Fichier de config SSH spécifique
    if [ -n "$SSH_CONFIG_FILE" ]; then
        parts+=("-F" "$SSH_CONFIG_FILE")
    fi
    
    # Clé privée explicite
    if [ -n "$SSH_KEY" ]; then
        parts+=("-i" "$SSH_KEY")
    fi
    
    # Options communes de sécurité/verbosité/fiabilité
    parts+=("-o" "LogLevel=ERROR" "-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null" \
            "-o" "BatchMode=yes" "-o" "ConnectTimeout=10" "-o" "ServerAliveInterval=15" "-o" "ServerAliveCountMax=3")
    
    # Forcer User/Port via -o (fonctionne pour ssh et sftp)
    if [ -n "$SSH_USER" ]; then
        parts+=("-o" "User=$SSH_USER")
    fi
    if [ -n "$SSH_PORT" ]; then
        parts+=("-o" "Port=$SSH_PORT")
    fi
    
    if [ "$cmd_type" = "ssh" ]; then
        # Important: -n pour ne pas consommer stdin dans les boucles
        echo "ssh -n ${parts[*]} $SSH_HOST"
    else
        # sftp: retourner la commande SANS destination; l'appelant ajoutera '-b <file> HOST'
        echo "sftp -q ${parts[*]}"
    fi
}

# Filtrer les fichiers selon LOCAL_ROOT et calculer les chemins relatifs
filter_and_relativize_files() {
    local files_list="$1"
    local filtered_files=""
    
    # Parcours ligne par ligne (préserve espaces)
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        if [ -n "$LOCAL_ROOT" ]; then
            # Vérifier si le fichier est dans LOCAL_ROOT
            if [[ "$file" == "$LOCAL_ROOT"/* ]]; then
                # Calculer le chemin relatif en supprimant LOCAL_ROOT/
                local relative_file="${file#$LOCAL_ROOT/}"
                filtered_files+="$relative_file\n"
            fi
        else
            # Pas de LOCAL_ROOT, utiliser le fichier tel quel
            filtered_files+="$file\n"
        fi
    done <<< "$files_list"
    
    # Supprimer les lignes vides et retourner
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

# Calcule la liste ordonnée des dossiers à créer côté distant
collect_remote_directories() {
    local files_list="$1"
    local seen=""
    local result=""

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        local IFS='/'
        local -a parts=()
        read -r -a parts <<< "$path"
        local depth=${#parts[@]}
        if [ "$depth" -le 1 ]; then
            continue
        fi

        local partial=""
        local limit=$((depth-1))
        local i
        for ((i=0; i<limit; i++)); do
            if [ -z "$partial" ]; then
                partial="${parts[i]}"
            else
                partial="$partial/${parts[i]}"
            fi
            if ! printf '%s\n' "$seen" | grep -Fxq "$partial"; then
                result+="$partial\n"
                seen+="$partial\n"
            fi
        done
    done <<< "$files_list"

    printf '%b' "$result"
}

# Vérifie via SFTP que le répertoire distant est accessible
assert_remote_directory() {
    local remote_path="$1"
    local sftp_cmd
    sftp_cmd=$(build_ssh_command "sftp")
    local probe_script
    probe_script=$(mktemp)
    local probe_log
    probe_log=$(mktemp)

    {
        echo "cd $remote_path"
        echo "pwd"
        echo "quit"
    } > "$probe_script"

    if $sftp_cmd -b "$probe_script" "$SSH_HOST" < /dev/null >"$probe_log" 2>&1; then
        rm -f "$probe_script" "$probe_log"
        return 0
    fi

    local probe_output
    probe_output=$(tail -n 20 "$probe_log" 2>/dev/null || true)
    rm -f "$probe_script" "$probe_log"

    if echo "$probe_output" | grep -qiE "(No such file|Couldn't canonicalize|does not exist)"; then
        log_error "Répertoire distant introuvable: $remote_path"
    else
        log_error "Accès SFTP impossible sur: $remote_path"
    fi
    if [ -n "$probe_output" ]; then
        echo "$probe_output" | sed 's/^/  /'
    fi
    exit 1
}

# Créer une sauvegarde des fichiers distants
create_backup() {
    local commit_ref="$1"
    local files_list="$2"
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local backup_dir="$SAVE_DIR/$commit_ref/$timestamp"
    local failed=0
    
    log_info "Création de la sauvegarde dans: $backup_dir"
    mkdir -p "$backup_dir" || { log_error "Impossible de créer $backup_dir"; exit 1; }
    # Assurer la présence d'un .gitignore sous save-deploy (évite la synchro SCM)
    mkdir -p "$SAVE_DIR" || { log_error "Impossible de préparer $SAVE_DIR"; exit 1; }
    if [ ! -f "$SAVE_DIR/.gitignore" ]; then
        echo -e "*\n!.gitignore\n" > "$SAVE_DIR/.gitignore" || { log_error "Impossible d'écrire $SAVE_DIR/.gitignore"; exit 1; }
    fi
    
    # 1) Vérifier que le répertoire distant existe (SFTP-only friendly)
    assert_remote_directory "$REMOTE_PATH"
    local sftp_cmd=$(build_ssh_command "sftp")

    # 2) Pré-créer tous les répertoires locaux requis
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        local local_dir="$backup_dir/$(dirname "$file")"
        if [ "$local_dir" != "$backup_dir/." ]; then
            mkdir -p "$local_dir" || { log_error "Impossible de créer $local_dir"; failed=1; }
        fi
    done <<< "$files_list"

    # 3) Construire un unique batch SFTP avec tous les 'get'
    local files_count
    files_count=$(printf '%s\n' "$files_list" | sed '/^$/d' | wc -l | tr -d ' ')
    log_info "Backup: capture en lot ($files_count fichiers)..."
    local one_cmd
    one_cmd=$(mktemp)
    echo "cd $REMOTE_PATH" > "$one_cmd"
    echo "lcd $backup_dir" >> "$one_cmd"
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        echo "get -p $file $file" >> "$one_cmd"
    done <<< "$files_list"
    echo "quit" >> "$one_cmd"

    # 4) Exécuter une seule session SFTP (rapide). On n'échoue pas pour des 'get' manquants.
    local sftp_log_one="$backup_dir/.sftp_get_batch_$$.log"
    if ! $sftp_cmd -b "$one_cmd" "$SSH_HOST" < /dev/null >"$sftp_log_one" 2>&1; then
        # Déterminer si c'est une erreur réseau/SSH critique
        if grep -E -q "(Connection|Permission denied|Could not resolve|No route to host|timed out)" "$sftp_log_one" 2>/dev/null; then
            log_error "Echec sauvegarde (SFTP critique)"
            tail -n 20 "$sftp_log_one" | sed 's/^/  /' || true
            rm -f "$one_cmd" "$sftp_log_one"
            exit 1
        fi
        # Sinon, considérer comme non bloquant (fichiers absents)
        log_warning "Sauvegarde partielle: certains fichiers n'ont pas été capturés"
    fi
    rm -f "$one_cmd"

    # 5) Vérifier la présence locale. Avertir mais ne pas bloquer si absent.
    local saved_count=0
    local missing_count=0
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        if [ -f "$backup_dir/$file" ]; then
            saved_count=$((saved_count+1))
        else
            log_warning "Sauvegarde manquante pour: $file"
            missing_count=$((missing_count+1))
        fi
    done <<< "$files_list"
    # En cas de manquants, affiche un extrait du log SFTP pour debug
    if [ $missing_count -gt 0 ]; then
        tail -n 20 "$sftp_log_one" 2>/dev/null | sed 's/^/  /' || true
    fi
    rm -f "$sftp_log_one" || true
    
    # Si erreurs, interrompre le déploiement
    if [ $failed -ne 0 ]; then
        log_error "Sauvegarde: erreurs locales détectées"
        exit 1
    fi

    # Sauvegarder la liste des fichiers déployés (chemins relatifs)
    echo "$files_list" > "$backup_dir/deployed_files.txt" || { log_error "Impossible d'écrire deployed_files.txt"; exit 1; }
    
    # Sauvegarder la configuration minimale utilisée + commit
    echo "LOCAL_ROOT=\"$LOCAL_ROOT\"" > "$backup_dir/deploy_config.txt" || { log_error "Impossible d'écrire deploy_config.txt"; exit 1; }
    echo "COMMIT_REF=\"$commit_ref\"" >> "$backup_dir/deploy_config.txt" || { log_error "Impossible d'écrire commit dans deploy_config.txt"; exit 1; }
    
    # Rien à nettoyer: scripts temporaires déjà supprimés
    echo "$backup_dir"
}

# Déployer un commit avec sauvegarde
deploy_commit() {
    local commit_input="$1"
    local config_file="$2"
    
    if [ -z "$commit_input" ]; then
        log_error "Référence de commit requise"
        show_help
        exit 1
    fi

    check_prerequisites "deploy"
    
    # Résoudre la référence en SHA canonique
    local commit_hash
    commit_hash=$(resolve_commit_ref "$commit_input") || { log_error "Impossible de résoudre le commit"; exit 1; }
    log_info "Commit résolu: '$commit_input' -> $commit_hash"
    
    load_config "$config_file"
    assert_remote_directory "$REMOTE_PATH"
    
    log_info "Récupération des changements du commit $commit_hash..."

    # Récupérer listes AM (ajout/modif) et D (suppression) sur le commit ciblé uniquement
    local all_added_modified
    all_added_modified=$(git -c core.quotepath=false diff-tree --no-commit-id --name-only --diff-filter=AM -r "$commit_hash")
    local all_deleted
    all_deleted=$(git -c core.quotepath=false diff-tree --no-commit-id --name-only --diff-filter=D -r "$commit_hash")

    # Filtrer selon LOCAL_ROOT et calculer les chemins relatifs
    local files_am files_del
    files_am=$(filter_and_relativize_files "$all_added_modified")
    files_del=$(filter_and_relativize_files "$all_deleted")

    # Calculer le statut A/M relatif pour la sauvegarde/restore
    local am_status_raw am_status_rel
    am_status_raw=$(git -c core.quotepath=false diff-tree --no-commit-id --name-status --diff-filter=AM -r "$commit_hash")
    am_status_rel=$(echo "$am_status_raw" | while IFS=$'\t' read -r status path; do
        [ -z "$path" ] && continue
        if [ -n "$LOCAL_ROOT" ]; then
            if [[ "$path" == "$LOCAL_ROOT"/* ]]; then
                echo -e "$status\t${path#$LOCAL_ROOT/}"
            fi
        else
            echo -e "$status\t$path"
        fi
    done)

    # Extraire uniquement les M pour la sauvegarde
    local files_am_only_m
    files_am_only_m=$(echo "$am_status_rel" | awk -F "\t" '$1=="M" {print $2}' | sed '/^$/d' || true)

    # Construire la liste unique pour la sauvegarde (M ∪ D)
    local files_for_backup
    files_for_backup=$(printf "%s\n%s\n" "$files_am_only_m" "$files_del" | sed '/^$/d' | awk '!seen[$0]++')

    if [ -z "$files_am" ] && [ -z "$files_del" ]; then
        if [ -n "$LOCAL_ROOT" ]; then
            log_warning "Aucun changement à traiter dans $LOCAL_ROOT pour ce commit"
        else
            log_warning "Aucun changement à traiter dans ce commit"
        fi
        exit 0
    fi

    log_info "Racine locale: ${LOCAL_ROOT:-"(racine du projet)"}"
    if [ -n "$files_am" ]; then
        log_info "Fichiers à déployer (A/M):"
        echo "$files_am"
    else
        log_info "Aucun fichier à déployer (A/M)"
    fi
    if [ -n "$files_del" ]; then
        log_info "Fichiers à supprimer (D):"
        echo "$files_del"
    else
        log_info "Aucun fichier à supprimer (D)"
    fi

    # Créer la sauvegarde avant action (inclut A/M et D)
    log_info "Backup: liste des fichiers à sauvegarder:"; echo "$files_for_backup"
    local backup_dir
    # Ne récupérer que la dernière ligne (chemin), laisser les logs à l'écran
    backup_dir=$(create_backup "$commit_hash" "$files_for_backup" | tail -n1)

    # Alias HEAD -> SHA (compatibilité et déduplication)
    if [ "$commit_input" = "HEAD" ]; then
        mkdir -p "$SAVE_DIR" || { log_error "Impossible de préparer $SAVE_DIR"; exit 1; }
        ln -sfn "$SAVE_DIR/$commit_hash" "$SAVE_DIR/HEAD" || true
    fi

    # Sauver aussi le status A/M pour une restauration plus précise
    echo "$am_status_rel" > "$backup_dir/am_status.txt" || { log_error "Impossible d'écrire am_status.txt"; exit 1; }
    # Remplacer deployed_files.txt par la liste complète (AM ∪ D)
    local deployed_all
    deployed_all=$(printf "%s\n%s\n" "$files_am" "$files_del" | sed '/^$/d' | awk '!seen[$0]++')
    echo "$deployed_all" > "$backup_dir/deployed_files.txt" || { log_error "Impossible d'écrire deployed_files.txt"; exit 1; }
    log_success "Sauvegarde créée: $backup_dir"
    
    # Créer un dossier temporaire pour exporter les fichiers
    local temp_dir=$(mktemp -d)
    log_info "Export des fichiers vers $temp_dir..."
    
    # Exporter chaque fichier à sa version du commit
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        local full_file_path
        full_file_path=$(get_full_file_path "$file")
        
        mkdir -p "$temp_dir/$(dirname "$file")"
        
        if git show "$commit_hash:$full_file_path" > "$temp_dir/$file" 2>/dev/null; then
            # Ajuster les permissions locales selon le mode Git (préservation exécutable)
            local mode
            mode=$(git ls-tree -r "$commit_hash" -- "$full_file_path" | awk '{print $1}' | head -n1 || true)
            if [ "$mode" = "100755" ]; then
                chmod 0755 "$temp_dir/$file" || true
            else
                chmod 0644 "$temp_dir/$file" || true
            fi
            log_success "Exporté: $full_file_path -> $file"
        else
            log_error "Erreur lors de l'export de: $full_file_path"
            rm -rf "$temp_dir"
            exit 1
        fi
    done <<< "$files_am"
    
    log_info "Upload vers SFTP..."
    
    # Préparer le script SFTP (création des dossiers + transferts)
    # Créer le script SFTP pour l'upload
    local sftp_script="$temp_dir/upload_commands.txt"
    echo "cd $REMOTE_PATH" > "$sftp_script"
    echo "lcd $temp_dir" >> "$sftp_script"

    local mkdir_targets=""
    if [ -n "$files_am" ]; then
        mkdir_targets=$(collect_remote_directories "$files_am")
        if [ -n "$mkdir_targets" ]; then
            local dir
            while IFS= read -r dir; do
                [ -z "$dir" ] && continue
                echo "-mkdir \"$dir\"" >> "$sftp_script"
            done <<< "$mkdir_targets"
        fi
    fi
    
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        if [ -f "$temp_dir/$file" ]; then
            echo "put -p \"$file\" \"$file\"" >> "$sftp_script"
        fi
    done <<< "$files_am"

    # Ajouter les suppressions (uniquement celles du commit)
    # Pas de vérification préalable (trop coûteuse). On tolère les 'No such file' ensuite.
    while IFS= read -r dfile; do
        [ -z "$dfile" ] && continue
        echo "rm \"$dfile\"" >> "$sftp_script"
    done <<< "$files_del"
    
    echo "quit" >> "$sftp_script"
    
    # Exécuter SFTP (capture des erreurs pour diagnostic)
    local sftp_cmd=$(build_ssh_command "sftp")
    local sftp_log="$temp_dir/sftp_upload.log"
    if $sftp_cmd -b "$sftp_script" "$SSH_HOST" < /dev/null >"$sftp_log" 2>&1; then
        if [ -n "$mkdir_targets" ]; then
            local dir
            while IFS= read -r dir; do
                [ -z "$dir" ] && continue
                assert_remote_directory "$REMOTE_PATH/$dir"
            done <<< "$mkdir_targets"
        fi
        log_success "Déploiement terminé avec succès!"
        log_info "Sauvegarde disponible dans: $backup_dir"
    else
        # Tolérer les erreurs de type "No such file or directory" (rm sur fichiers absents)
        if grep -E -q "No such file or directory" "$sftp_log" && \
           ! grep -E -q "(Permission denied|Failure|Connection|timed out|Couldn't|cannot|not found|denied)" "$sftp_log"; then
            log_warning "Déploiement: quelques suppressions étaient déjà absentes (ignoré)"
            log_success "Déploiement terminé avec succès!"
            log_info "Sauvegarde disponible dans: $backup_dir"
        else
            log_error "Erreur lors du déploiement SFTP"
            tail -n 20 "$sftp_log" | sed 's/^/  /' || true
            rm -rf "$temp_dir"
            exit 1
        fi
    fi

    # Résumé final
    local count_am count_del count_rm_absent
    count_am=$(printf '%s\n' "$files_am" | sed '/^$/d' | wc -l | tr -d ' ')
    count_del=$(printf '%s\n' "$files_del" | sed '/^$/d' | wc -l | tr -d ' ')
    count_rm_absent=$(grep -Ec "No such file or directory" "$sftp_log" 2>/dev/null || echo 0)
    log_info "Résumé: envoyés A/M=$count_am, suppressions D=$count_del, absents ignorés=$count_rm_absent"
    # Afficher la commande de restauration utile
    local deploy_cmd_restore
    if [ -n "$config_file" ]; then
        deploy_cmd_restore="$0 restore $backup_dir $config_file"
    else
        deploy_cmd_restore="$0 restore $backup_dir"
    fi
    log_info "Restauration: $deploy_cmd_restore"
    
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
    
    check_prerequisites "restore"

    # Charger la configuration (détecte ./deploy.conf si omis)
    load_config "$config_file"
    assert_remote_directory "$REMOTE_PATH"

    # Si aucune sauvegarde spécifiée, utiliser le sélecteur
    if [ -z "$backup_dir" ]; then
        backup_dir=$(select_backup)
    fi
    
    # Résolution du chemin de sauvegarde
    if [[ ! "$backup_dir" =~ ^/ ]]; then
        # 1) Préférer SAVE_DIR courant
        if [ -d "$SAVE_DIR/$backup_dir" ]; then
            backup_dir="$SAVE_DIR/$backup_dir"
        else
            # 2) Sinon, utiliser le dossier de la config effectivement chargée + save-deploy
            local conf_dir
            if [ -n "$CONFIG_FILE_PATH" ]; then
                conf_dir=$(cd "$(dirname "$CONFIG_FILE_PATH")" && pwd)
            else
                conf_dir="$CWD"
            fi
            if [ -d "$conf_dir/save-deploy/$backup_dir" ]; then
                backup_dir="$conf_dir/save-deploy/$backup_dir"
            else
                backup_dir="$SAVE_DIR/$backup_dir" # garde la valeur par défaut (provoquera une erreur claire ensuite)
            fi
        fi
    fi
    
    if [ ! -d "$backup_dir" ]; then
        log_error "Répertoire de sauvegarde non trouvé: $backup_dir"
        exit 1
    fi
    
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
    # Lire le statut A/M si disponible
    local am_status_file="$backup_dir/am_status.txt"
    
    # Créer le script SFTP pour la restauration
    local temp_dir=$(mktemp -d)
    local sftp_script="$temp_dir/restore_commands.txt"
    echo "cd $REMOTE_PATH" > "$sftp_script"

    local restore_files=""
    if [ -n "$deployed_files" ]; then
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            if [ -f "$backup_dir/$file" ]; then
                restore_files+="$file\n"
            fi
        done <<< "$deployed_files"
    fi

    local restore_dirs=""
    if [ -n "$restore_files" ]; then
        restore_dirs=$(collect_remote_directories "$(printf '%b' "$restore_files")")
        if [ -n "$restore_dirs" ]; then
            local dir
            while IFS= read -r dir; do
                [ -z "$dir" ] && continue
                echo "-mkdir \"$dir\"" >> "$sftp_script"
            done <<< "$restore_dirs"
        fi
    fi
    
    # Restaurer les fichiers qui existaient (utilise les chemins relatifs sauvegardés)
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        if [ -f "$backup_dir/$file" ]; then
            log_info "Restauration: $file"
            echo "put -p \"$backup_dir/$file\" \"$file\"" >> "$sftp_script"
        else
            # Aucun rebuild depuis Git: restauration strictement depuis le backup
            local am_kind=""
            if [ -f "$am_status_file" ]; then
                am_kind=$(awk -F $'\t' -v target="$file" '$2==target {print $1; exit}' "$am_status_file" 2>/dev/null || true)
            fi
            if [ "$am_kind" = "A" ]; then
                log_info "Suppression: $file (ajouté, pas de sauvegarde)"
                echo "rm \"$file\"" >> "$sftp_script"
            else
                log_error "Backup manquant pour: $file — restauration impossible (strict)"
                rm -rf "$temp_dir"
                exit 1
            fi
        fi
    done <<< "$deployed_files"
    
    echo "quit" >> "$sftp_script"
    
    # Exécuter SFTP (capture d'erreurs)
    local sftp_cmd=$(build_ssh_command "sftp")
    local sftp_log="$temp_dir/sftp_restore.log"
    if $sftp_cmd -b "$sftp_script" "$SSH_HOST" < /dev/null >"$sftp_log" 2>&1; then
        if [ -n "$restore_dirs" ]; then
            local dir
            while IFS= read -r dir; do
                [ -z "$dir" ] && continue
                assert_remote_directory "$REMOTE_PATH/$dir"
            done <<< "$restore_dirs"
        fi
        log_success "Restauration terminée avec succès!"
    else
        log_error "Erreur lors de la restauration"
        tail -n 20 "$sftp_log" | sed 's/^/  /' || true
        rm -rf "$temp_dir"
        exit 1
    fi
    
    # Résumé restauration
    local count_put count_rm count_rm_absent
    count_put=$(while IFS= read -r f; do [ -z "$f" ] && continue; [ -f "$backup_dir/$f" ] && echo x; done <<< "$deployed_files" | wc -l | tr -d ' ')
    count_rm=$(while IFS= read -r f; do [ -z "$f" ] && continue; [ ! -f "$backup_dir/$f" ] && echo x; done <<< "$deployed_files" | wc -l | tr -d ' ')
    count_rm_absent=$(grep -Ec "No such file or directory" "$sftp_log" 2>/dev/null || echo 0)
    log_info "Résumé restauration: remis=$count_put, supprimés=$count_rm, absents ignorés=$count_rm_absent"

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
        check_prerequisites "list"
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
