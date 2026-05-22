<p align="center">
  <img src="assets/icon.png" alt="wacomd ghost mascot" width="200"/>
</p>

<h1 align="center">wacomd</h1>

<p align="center">
  <strong>Pilote open-source pour Wacom Intuos Pro Small (PTH-451) sur macOS 26 Tahoe.</strong>
  <br/>
  Stylet · pression 2048 niveaux · gomme · tilt · tactile multi-doigts (1/2/3 doigts)
  <br/>
  <em>Aucune extension noyau. Aucun DriverKit. Aucun driver Wacom officiel requis.</em>
</p>

<p align="center">
  <a href="https://app.thinkspark.eu/wacom_PTH-405_Driver/"><img src="https://img.shields.io/badge/landing-app.thinkspark.eu-4ea0ff?style=flat-square" alt="Landing"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-MIT-59d28e?style=flat-square" alt="MIT"/></a>
  <a href="#"><img src="https://img.shields.io/badge/macOS-26%20Tahoe-93a3c2?style=flat-square" alt="macOS 26"/></a>
  <a href="#"><img src="https://img.shields.io/badge/Apple-Notarisé-93a3c2?style=flat-square" alt="Notarisé"/></a>
</p>

---

Wacom n'écrit plus de pilote supporté pour la PTH-451 sur macOS récent.
**wacomd** est un démon Swift en espace utilisateur qui la ramène à la vie :
`IOHIDManager` lit les rapports HID bruts, un parseur porté du noyau Linux
décode le protocole vendor Wacom, et `CGEvent` injecte mouvements stylet /
clics / pression / évènements tactiles dans le pipeline du système. Même
approche qu'[OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver)
ou [Hawku](https://github.com/poiuyt9876/hawku-userspace).

> 🌐 Page de présentation : [app.thinkspark.eu/wacom_PTH-405_Driver/](https://app.thinkspark.eu/wacom_PTH-405_Driver/).
> 🇬🇧 English README : [README.md](README.md).

## État actuel — v0.2.0 (testé live sur macOS 26.3 Apple Silicon)

- ~200 évènements/s sustained (= rate natif du HID Wacom)
- position + clic + pression vérifiés à l'écran
- 8 tests unitaires verts sur le parseur

## v0.1.0

| Fonction                                      | État              |
| --------------------------------------------- | ----------------- |
| Détection automatique branchement / débranch. | ✅                 |
| Position stylet → curseur                     | ✅                 |
| Clic stylet (tip switch)                      | ✅                 |
| Pression (2048 niveaux) via champs tablette   | ✅                 |
| Bouton barillet → clic droit                  | ✅                 |
| Inclinaison X/Y                               | ✅ (transmise)     |
| Gomme                                         | ✅ (état signalé)  |
| Multi-écran (mapping configurable)            | ❌ écran principal |
| ExpressKeys (6 touches du pad)                | ❌ TODO            |
| Touch Ring                                    | ❌ TODO            |
| Surface multi-touch                           | ❌ TODO            |
| Interface graphique de configuration          | ❌ TODO            |

Les ExpressKeys, Touch Ring et surface tactile passent par des rapports HID
*vendor-defined* (non standardisés) qu'il faudra parser à la main, à partir
du rapport brut (`IOHIDDeviceRegisterInputReportCallback`) plutôt que des
usages HID. Le squelette est déjà prêt à recevoir ce code.

## Prérequis

- macOS 14+ (testé sur **macOS 26.3 Tahoe**, Apple Silicon)
- Xcode Command Line Tools (`swift --version` doit fonctionner)

## Compilation

```bash
swift build -c release
```

Le binaire se trouve dans `.build/release/wacomd`.

## Permissions (étape obligatoire)

Le démon vérifie ses deux permissions au démarrage et l'affiche :

```
[wacomd] Accessibilité ........... accordée
[wacomd] Surveillance des entrées . accordée
```

S'il manque une des deux :

1. **Réglages Système → Confidentialité et sécurité → Surveillance des entrées**
2. **Réglages Système → Confidentialité et sécurité → Accessibilité**

⚠️ Sur macOS 26 Tahoe ces catégories **n'apparaissent pas dans la barre
latérale principale** : il faut d'abord cliquer sur « Confidentialité et
sécurité », puis faire défiler la grande liste avec les icônes (Localisation,
Contacts, …, Accessibilité, Surveillance des entrées).

Ou bien sauter directement au bon panneau :

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

Si `wacomd` n'apparaît pas dans la liste, utilisez le bouton **+** et
sélectionnez `.build/release/wacomd`. **Relancez le démon après chaque
modification** — macOS ne propage pas les permissions à un process déjà
lancé.

Note : si vous lancez le démon depuis le Terminal et que le Terminal a déjà
ces deux permissions, `wacomd` les hérite. Pas besoin d'enregistrer
spécifiquement `wacomd`.

## Lancement manuel

```bash
.build/release/wacomd
```

Vous devriez voir :

```
[wacomd] En attente d'une tablette…
[wacomd] + Connecté: Wacom Intuos Pro Small (PTH-451)
```

Bouger le stylet déplace le curseur ; appuyer pose un clic gauche avec
pression. Dans Photoshop / Procreate / Krita / Affinity Photo, vous devriez
voir la pression varier l'épaisseur du trait.

`Ctrl+C` arrête proprement.

## Installation en démon (launchd)

Créez `~/Library/LaunchAgents/com.local.wacomd.plist` :

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>com.local.wacomd</string>
    <key>ProgramArguments</key> <array><string>/usr/local/bin/wacomd</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>StandardOutPath</key>  <string>/tmp/wacomd.log</string>
    <key>StandardErrorPath</key><string>/tmp/wacomd.log</string>
</dict>
</plist>
```

Puis :

```bash
sudo cp .build/release/wacomd /usr/local/bin/wacomd
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.wacomd.plist
launchctl enable    gui/$(id -u)/com.local.wacomd
launchctl kickstart -k gui/$(id -u)/com.local.wacomd
```

Pour le désinstaller :

```bash
launchctl bootout gui/$(id -u)/com.local.wacomd
rm ~/Library/LaunchAgents/com.local.wacomd.plist
sudo rm /usr/local/bin/wacomd
```

## Signature & notarisation

Pour usage personnel : la signature ad-hoc générée par `swift build` suffit,
mais le binaire devra être **réautorisé après chaque rebuild** dans les
panneaux de permissions ci-dessus (l'identité change).

Pour distribuer : signer avec un *Developer ID Application* puis notariser
(`xcrun notarytool submit`). Ceci sort du scope de ce projet.

## Architecture

```
Sources/wacomd/
├── main.swift             ── point d'entrée, RunLoop, SIGINT/SIGTERM
├── Permissions.swift      ── prompts Accessibilité + statut Input Monitoring
├── HIDMonitor.swift       ── IOHIDManager, matching VID/PID
├── WacomDevice.swift      ── ouvre l'interface stylet (page 0xff0d) et la lit
├── IntuosProParser.swift  ── décodeur des rapports vendor 10 octets
├── PenState.swift         ── état courant du stylet
├── IntuosPro.swift        ── caractéristiques physiques de la PTH-451
├── EventInjector.swift    ── mapping écran + CGEvent + champs tablette
└── Verbose.swift          ── logs détaillés (WACOMD_VERBOSE=1)
```

⚠️ Point clé du protocole : les Intuos Pro n'exposent **pas** leurs données
sur les pages HID standard (`Digitizer 0x0d`, `GenericDesktop 0x01`). Tout
arrive sur la page **vendor-defined `0xff0d`** sous forme de rapports bruts
de 10 octets. Mon premier essai branchait `IOHIDDeviceRegisterInputValueCallback`
sur des usages standards : **rien n'arrivait**. La v0.2 utilise
`IOHIDDeviceRegisterInputReportCallback` et parse le format documenté dans
`drivers/hid/wacom_wac.c` :

```
data[0] = 0x02  (Report ID)
data[1] = bits status (proximité, boutons, LSB pression)
data[2..3] = X grande partie (combiné avec bit 1 de data[9])
data[4..5] = Y grande partie (combiné avec bit 0 de data[9])
data[6..7] = pression 11 bits (10 high + 1 LSB dans status)
data[7..8] = tilt X, tilt Y (-64..63)
data[9]   = distance (6 bits) + LSB de X/Y (2 bits)
```

Flux des données :

```
USB HID raw report  →  IOHIDDeviceRegisterInputReportCallback
                                ↓
                       IntuosProParser.decode()
                                ↓
                            PenSample
                                ↓
                     WacomDevice.handle(report:)
                                ↓
                            PenState
                                ↓
                     EventInjector.update()
                                ↓
            CGEvent (mouseMoved/Down/Up + tabletEventPoint*)
                                ↓
                          cghidEventTap
                                ↓
                  WindowServer → apps (Photoshop, …)
```

## Identification du périphérique

| Champ         | Valeur                 |
| ------------- | ---------------------- |
| Vendor ID     | `0x056a` (Wacom)       |
| Product ID    | `0x0314`               |
| Nom commercial| Intuos Pro Small       |
| Référence     | PTH-451 / PTH-451/K0   |
| Pression      | 2048 niveaux           |
| Résolution    | 5080 lpi               |
| Surface active| 157 × 98 mm            |
| Coordonnées   | 31496 × 19685          |

## Mode verbose (debug)

```bash
WACOMD_VERBOSE=1 .build/release/wacomd
# ou:
.build/release/wacomd -v
```

Affiche pour chaque interface ouverte la liste des éléments HID, le contenu
hex de chaque rapport brut, et un compteur de débit toutes les 5 s.

## Pistes pour étendre

- **ExpressKeys / Touch Ring** : la 3e interface (page `0xff0d`, rapports
  d'ID 12) porte les données du pad. Parser d'après `wacom_intuos_pad` dans
  `drivers/hid/wacom_wac.c`.
- **Surface multi-touch** : 2e interface, rapports d'ID 13.
- **Aire active / mapping écran** : ajouter un fichier `~/.config/wacomd.toml`
  lu au démarrage pour configurer écran cible, zone active, ratio d'aspect.
- **Profils par application** : observer `NSWorkspace.shared.frontmostApplication`
  et changer le mapping/les raccourcis des boutons selon `bundleIdentifier`.
- **Évènement de proximité** : poster un vrai `.tabletProximity` à l'entrée /
  sortie, pour que les apps "tablet-aware" affichent leur indicateur de stylet.

## Crédits & références

- Linux kernel `drivers/hid/wacom_wac.c` : *source de vérité* pour le
  protocole Wacom Intuos Pro.
- [linuxwacom](https://github.com/linuxwacom/) : projet historique de
  documentation du protocole.
- [OpenTabletDriver](https://github.com/OpenTabletDriver/OpenTabletDriver) :
  référence pour l'approche userspace cross-plateforme.

## Licence

MIT — voir `LICENSE` (à ajouter selon votre préférence).
