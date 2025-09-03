# 🚀 git-sftp-deploy

> Outil de déploiement SFTP basé sur Git, avec sauvegarde et restauration automatique

[![Docker](https://img.shields.io/badge/Docker-Ready-blue.svg)](https://docker.com)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)

## 🤔 Pourquoi ?

**git-sftp-deploy** offre une approche intelligente du déploiement :

✅ **Déploiement intelligent** : uniquement les fichiers modifiés d'un commit  
✅ **Sauvegarde automatique** : état distant préservé avant chaque déploiement  
✅ **Restauration précise** : retour à l'état antérieur en un clic  
✅ **Gestion des sous-dossiers** : structure complète préservée  

## 💻 Utilisation
Voir la section [⚙️ Configuration](#-configuration) pour les détails complets de configuration.

### Commandes principales

#### 📤 Déploiement
```bash
# Déployer un commit spécifique
src/git-sftp-deploy.sh deploy <commit-ish> [chemin/config]

# Déployer le dernier commit
src/git-sftp-deploy.sh deploy HEAD
```

#### 🔄 Restauration
```bash
# Restaurer depuis une sauvegarde
src/git-sftp-deploy.sh restore [save-deploy/<commit>/<timestamp>] [chemin/config]

# Lister toutes les sauvegardes disponibles
src/git-sftp-deploy.sh list
```

### Exemples d'usage

```bash
# Déploiement du dernier commit
./src/git-sftp-deploy.sh deploy HEAD

# Restauration de la dernière sauvegarde
./src/git-sftp-deploy.sh restore

# Liste des sauvegardes
./src/git-sftp-deploy.sh list
```

## ⚙️ Configuration
Dans votre projet cible **Cette commande crée un fichier de configuration template** (`deploy.conf` par défaut) que vous devrez personnaliser avec vos paramètres SSH avant de pouvoir déployer.
```bash
./git-sftp-deploy.sh init [chemin/config]
```

```bash
# Configuration SSH
SSH_HOST="mon-serveur"          # Alias SSH (~/.ssh/config)
SSH_USER="deploy"               # Utilisateur (optionnel)
SSH_PORT="22"                   # Port SSH (optionnel)
SSH_KEY="~/.ssh/id_rsa"         # Clé SSH (optionnel)

# Chemins
REMOTE_PATH="/var/www/html"      # Dossier distant
LOCAL_ROOT=""                   # Racine locale (vide = racine Git)
```

**Paramètres détaillés :**
- `SSH_HOST` : alias SSH défini dans `~/.ssh/config`
- `REMOTE_PATH` : dossier de destination sur le serveur
- `LOCAL_ROOT` : racine locale à déployer (vide = racine du repo Git)
- `SSH_USER`, `SSH_PORT`, `SSH_KEY` : paramètres SSH optionnels

## 🧪 Tests

### Suite de tests complète

```bash
# Lancement automatique des tests
./scripts/test-docker.sh
```

**Ce que fait le script de test :**

🔧 **Préparation** : génération clés, build images, démarrage containers  
📁 **Création** : mini-projet web avec sous-dossiers  
🚀 **Déploiement v1** : déploiement initial  
📝 **Mise à jour** : modifications + nouveau fichier (v2)  
🔄 **Restauration** : retour à v1  
✅ **Vérification** : contenus et restauration validés  

### Contenu de test

Le contenu simulé du serveur est monté dans `tests/remote-www/`

## 🏗️ Structure du projet

```
git-sftp-deploy/
├── 📁 src/
│   ├── 🔧 git-sftp-deploy.sh     # Script principal
│   └── 📄 deploy.conf            # Configuration exemple
├── 🐳 docker/
│   ├── 📁 dev/                   # Conteneur client
│   └── 📁 sftp/                  # Conteneur serveur
├── 📜 docker-compose.yml         # Stack de test
├── 📁 scripts/                   # Scripts d'orchestration
├── 🧪 tests/                     # Suite de tests
└── 📖 README.md                  # Cette documentation
```

## 🔒 Sécurité

### Gestion des erreurs

- 👤 **Erreurs utilisateur** : affichées clairement
- 🖥️ **Erreurs serveur** : journalisées pour debug
- ⚡ **Fail fast** : échec rapide et retours précoces

### Bonnes pratiques

- 🔐 Clés SSH dédiées au déploiement
- 📋 Validation des configurations
- 🔄 Sauvegarde systématique avant déploiement
- 📊 Logs détaillés pour audit

---

**💡 Conseil** : Testez toujours avec l'environnement Docker avant déploiement en production !
