# 🚀 git-sftp-deploy

> Outil de déploiement SFTP basé sur Git, avec sauvegarde et restauration automatique

[![Docker](https://img.shields.io/badge/Docker-Ready-blue.svg)](https://docker.com)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)

## 🤔 Pourquoi ?

**git-sftp-deploy** offre une approche intelligente du déploiement :

✅ **Déploiement intelligent** : uniquement les fichiers modifiés d'un commit  
✅ **Sauvegarde automatique** : état distant préservé avant chaque déploiement  
✅ **Restauration précise** : retour à l'état antérieur en un clic  
✅ **Suppression ciblée** : seules les suppressions du commit sont propagées (avec sauvegarde)  
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

Notes:
- Uniquement les changements du commit ciblé sont pris en compte (A/M/D).
- Les suppressions (D) du commit sont supprimées côté serveur APRÈS sauvegarde.
- Une suppression locale non commitée n'est jamais synchronisée.

#### 🔄 Restauration
```bash
# Restaurer depuis une sauvegarde
src/git-sftp-deploy.sh restore [save-deploy/<commit>/<timestamp>] [chemin/config]

# Lister toutes les sauvegardes disponibles
src/git-sftp-deploy.sh list
```

Note: en fin de déploiement, la commande exacte de restauration est affichée pour faciliter un rollback immédiat.

#### 🔐 Restauration stricte (garanties)
- Aucune restauration depuis Git: seules les données présentes dans le dossier de sauvegarde sont utilisées.
- Cas des statuts du commit déployé:
  - A (ajout): le fichier est supprimé lors d’une restauration (pas de backup attendu).
  - M (modifié): la restauration exige la présence du fichier dans la sauvegarde, sinon échec immédiat.
  - D (supprimé): la restauration exige la présence du fichier dans la sauvegarde, sinon échec immédiat.
- Les suppressions distantes de fichiers déjà absents sont tolérées (non bloquant).

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
./src/git-sftp-deploy.sh init [chemin/config]
```

```bash
# Configuration SSH
SSH_HOST="mon-serveur"          # Alias SSH (~/.ssh/config)
SSH_USER="deploy"               # Utilisateur (optionnel)
SSH_PORT="22"                   # Port SSH (optionnel)
SSH_KEY="~/.ssh/id_rsa"         # Clé SSH (optionnel)
SSH_CONFIG_FILE="~/.ssh/config" # Fichier de config SSH (optionnel)

# Chemins
REMOTE_PATH="/var/www/html"      # Dossier distant
LOCAL_ROOT=""                   # Racine locale (vide/"." = dossier courant)
```

**Paramètres détaillés :**
- `SSH_HOST` : alias SSH défini dans `~/.ssh/config`
- `REMOTE_PATH` : dossier de destination sur le serveur
- `LOCAL_ROOT` : racine locale à déployer (vide/"." = dossier courant d'exécution)
- `SSH_USER`, `SSH_PORT`, `SSH_KEY` : paramètres SSH optionnels

### Sauvegardes

- Lieu: `./save-deploy` dans le répertoire courant d'exécution.
- Un fichier `.gitignore` est généré dans `save-deploy/` pour éviter toute synchro Git.
- Le déploiement est annulé si la sauvegarde échoue (droits/SSH, etc.).
- Contenu: la sauvegarde contient les fichiers nécessaires à la restauration de l’état précédent (modifiés et supprimés), ainsi qu’un `am_status.txt` (A/M du commit) et la liste `deployed_files.txt`.

## 🗑️ Synchronisation des suppressions (D)

- Portée stricte: seules les suppressions présentes dans le commit déployé sont propagées.
- Sauvegarde préalable: chaque fichier à supprimer est d'abord copié vers `save-deploy/<commit>/<timestamp>/`.
- Restauration: un `restore` ré-upload ces fichiers supprimés pour revenir à l'état précédent.
- Respect de `LOCAL_ROOT`: seules les suppressions situées sous `LOCAL_ROOT` sont considérées.

Exemple rapide:
```bash
# v1
echo "A" > web/a.txt && git add -A && git commit -m "v1"
git-sftp-deploy deploy HEAD ./deploy.conf   # a.txt est uploadé

# v2: suppression commitée
git rm web/a.txt && git commit -m "v2 delete a.txt"
git-sftp-deploy deploy HEAD ./deploy.conf   # a.txt est SUPPRIMÉ côté serveur (sauvegardé localement)

# Restauration
# (ré-upload de a.txt depuis la sauvegarde)
git-sftp-deploy restore save-deploy/HEAD/<timestamp> ./deploy.conf
```

## 🧪 Tests

### Suite de tests complète

```bash
./scripts/test-docker.sh
```

**Ce que fait le script de test :**

🔧 **Préparation** : build images, démarrage containers  
📁 **Création** : mini-projet web avec sous-dossiers  
🚀 **Déploiement v1** : déploiement initial  
📝 **Mise à jour** : modifications + nouveau fichier (v2)  
🔄 **Restauration** : retour à v1  
✅ **Vérification** : contenus et restauration validés  

### Contenu de test

Le contenu simulé du serveur provient de `tests/remote-www/` (copié dans l'image SFTP)

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

## 🔧 Installation (macOS)

```bash
# Installer la commande globale git-sftp-deploy
# (copie du script dans /usr/local/bin et rendu exécutable)
sudo install -m 0755 ./src/git-sftp-deploy.sh /usr/local/bin/git-sftp-deploy

# Vérification
which git-sftp-deploy && git-sftp-deploy --help
```

```bash
# Utilisation dans n'importe quel projet (depuis la racine du repo)
# 1) Initialiser la config
git-sftp-deploy init ./deploy.conf

# 2) Déployer le dernier commit
git-sftp-deploy deploy HEAD ./deploy.conf
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
