# Bloc « données » : les différences voulues avec Mindset 2.18 (PowerShell)

Référence : `Mindset/fichiers/modules/donnees.ps1` et `modules/suite.ps1` (2.18.0). Les juges
(`outils/exporter-juges-donnees.ps1` -> `tests/juges/donnees.json`, 211 cas) prouvent que tout le reste est pareil.
Chaque différence ci-dessous est soit sans effet pour l'utilisateur, soit un défaut corrigé (aucune donnée perdue).
Dans `tests/juges.rs`, elles sont permises une par une (`ECARTS`, `selon_json_sur`), jamais en bloc.

## 1. Venues de `suite_commun::json_sur` (Read-JsonSur, Save-JsonSur déjà portés, voir `rust/suite-commun/src/json_sur.rs`)

- Une copie `.bak` illisible est mise de côté (`<fichier>.bak.abime-<date>`, une ligne de plus au journal :
  « X.bak mis de côté dans ... ») au lieu de rester `.bak`. PowerShell la remplaçait à l'écriture suivante (elle était
  perdue) ; Rust la garde de côté. Preuve : juges « reglages.json et copie abîmés », « JSON sûr : fichier et copie
  abîmés », « hasard réglages 12, 16, 22, 33, 39 ».
- Un fichier en place vide ou abîmé n'est jamais copié dans `.bak` à l'écriture (il aurait remplacé la bonne copie) :
  vide, il est simplement remplacé ; abîmé, il est d'abord mis de côté (`.abime-<date>`).
- Deux mises de côté dans la même seconde ne s'écrasent plus (`-2`, `-3`...).
- Une copie `.bak` prise par un autre programme est une erreur « pris » (PowerShell la traitait comme illisible).

## 2. La forme du JSON écrit (`json_ps`, comme `ConvertTo-Json` de PowerShell 5.1)

- L'ordre des clés : celui du fichier lu, puis des ajouts. PowerShell écrivait une table (`@{}`) dans l'ordre de ses
  cases de hachage (un ordre sans règle). Le contenu est le même ; les juges comparent la forme à l'ordre près (le
  texte de Rust, remis dans l'ordre de PowerShell, est identique octet pour octet).
- Un nombre décimal relu ne garde pas son écriture : PowerShell 5.1 relit `1.50` ou `3.0` en `[decimal]` et les
  réécrit tels quels ; Rust les relit en nombre à virgule et écrit `1.5` et `3`. Même valeur. Un nombre à virgule très
  grand ou très petit relu (`1e-7`) s'écrit `1E-07` chez Rust, `0.0000001` chez PowerShell. Mindset n'écrit que des
  entiers et des secondes à 0,1 près (`Ouverture-<id>`), qui s'écrivent pareil. Preuve : juges « reglages.json : très
  grand nombre et nombre décimal », « forme JSON de {"n":[...]} ».
- La profondeur : `ConvertTo-Json -Depth 5` (réglages) ou `-Depth 4` (suite.json) écrivait un objet plus profond en
  texte (« @{a=1} »), donc perdu. Rust écrit tous les niveaux.

## 3. Le journal

- Le message d'erreur de Windows entre parenthèses (« reglages.json ne peut pas être lu (...) ») est celui de Rust
  (« Le processus ne peut pas accéder au fichier car ce fichier est utilisé par un autre processus. (os error 32) »)
  au lieu de celui de .NET. Le début de la ligne est le même.
- La date de « Ancien dossier console-webview (pas servi depuis le 18/10/2026) supprimé » est toujours au format
  français jj/mm/aaaa (`ToString('d')` suivait la langue de Windows).
- Les lignes sont écrites une par une sous un verrou (plusieurs fils peuvent écrire en même temps) ; PowerShell
  n'avait qu'un fil.

## 4. Cas impossibles en vrai, traités sans erreur

- `Get-RacinesDepuis` sur une racine (« C:\ ») : PowerShell s'arrêtait sur une erreur (`Split-Path` d'un texte vide) ;
  Rust rend les racines par défaut. Sur un disque qui n'existe pas, `Join-Path` de PowerShell refusait de construire le
  dossier des données (vide) ; Rust le construit. Mindset tourne toujours depuis un disque qui existe.
- Une copie `.bak` dont deux clés ne diffèrent que par les majuscules, lue quand le fichier lui-même est absent ou
  abîmé : Rust la prend (la dernière clé gagne), PowerShell la jugeait illisible. Pour le fichier lui-même, Rust fait
  exactement comme PowerShell (abîmé, mis de côté, repris de sa copie : juge « reglages.json : la même clé en
  majuscules »).
- La reprise d'un reglages.json abîmé suit les motifs de `Read-Reglages` caractère pour caractère ; seul `\b` (fin de
  mot après `true` / `false`) compte les lettres et chiffres de Unicode comme Rust (`is_alphanumeric`) et non comme
  .NET (qui y ajoute les accents isolés et les traits de liaison de Unicode, et retire les chiffres romains). Sans effet sur un
  fichier écrit par Mindset.

## 5. Essais

- `Set-Setting` n'écrivait rien en test (`$EnTest`) ; Rust écrit, mais seulement dans le dossier d'essai.
- Construction d'essai (`Environnement::essai`) : tout est sous le dossier d'essai (`Dossiers::sous`), le registre
  n'est jamais lu, et le disque refuse de lire ou d'écrire un fichier JSON hors de ce dossier (une ligne au journal,
  une erreur pour l'appelant). C'est une garde de plus, sans équivalent dans la version PowerShell.
