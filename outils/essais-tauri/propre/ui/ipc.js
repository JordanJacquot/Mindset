// Le seul fichier des pages qui parle à Rust (docs\regles-tauri.md, règle 1)
export function appeler(commande, donnees) {
  return window.__TAURI_INTERNALS__.invoke(commande, donnees || {});
}
