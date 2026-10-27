# Construit le dossier de Mindset prêt à partager, puis release\Mindset.zip.
# (Mindset doit être fermé : son .exe est remplacé.)
#
#   Mindset\
#     Mindset.exe                 <- à lancer
#     Desinstaller Mindset.exe    <- le désinstalleur autonome (outils\desinstalleur.cs)
#     MindsetInstallateur.exe     <- le mini-installateur (Rust) : jamais construit ici, voir plus bas
#
# Passage en Rust (plan 3.6) : ce script construit le désinstalleur en C#, pour les essais sur ce PC. La version livrée
# est celle en Rust (rust\desinstalleur), avec MindsetInstallateur.exe (rust\mindset-installateur) : construits
# seulement par GitHub (.github\workflows\release.yml), attestés, puis mis à leur place par outils\publier.ps1
# (outils\exe-rust.ps1, qui vérifie l'attestation) et par release.yml pour l'artefact à signer.
#     fichiers\Mindset.ps1        <- le point d'entrée
#     fichiers\apps.json          <- la liste des applis de la suite
#     fichiers\modules\           <- le code découpé par partie

$ErrorActionPreference = 'Stop'
$racine  = Split-Path $PSScriptRoot -Parent
$app     = Join-Path $racine 'Mindset'
$icones  = Join-Path $PSScriptRoot 'icones'
$csc     = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$source  = Join-Path $PSScriptRoot 'lanceur.cs'
$manif   = Join-Path $PSScriptRoot 'lanceur.manifest'

# L'icône (le M glitché), pour Mindset.exe, la fenêtre, la barre des tâches et le raccourci
& (Join-Path $PSScriptRoot 'icone.ps1') -OutDir $icones | Out-Null
Copy-Item (Join-Path $icones 'Mindset.ico') (Join-Path $app 'fichiers\Mindset.ico') -Force
# Fichiers d'autres auteurs : chacun doit avoir l'empreinte et la signature notées dans son SOURCES.md, sinon rien
# n'est construit (un fichier remplacé par erreur ou par un tiers ne part jamais chez les utilisateurs)
$tiers = @(
    ,@('lib\webview2\\Microsoft.Web.WebView2.Core.dll', 'D60E6E94245078CB56E44EBD5F360DC04BF18E460136BE93BFC4CFCA43B98505', 'Microsoft Corporation')
    ,@('lib\webview2\\Microsoft.Web.WebView2.Wpf.dll', 'F05A06BBC03AFCB83DC98168B8D343D9015B2A533EDBFAC90C52D88894B653E4', 'Microsoft Corporation')
    ,@('lib\webview2\\WebView2Loader.dll', '3426DCC55FDFB8B5E7AC623CF33B4CCF283FBF68A0C5A65BDDFDB4D749A8ABEE', 'Microsoft Corporation')
)
foreach ($t in $tiers) {
    $f = Join-Path (Join-Path $app 'fichiers') $t[0]
    if (-not (Test-Path -LiteralPath $f)) { throw "Fichier tiers absent : $($t[0])" }
    $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
    if ($h -ne $t[1]) { throw "Fichier tiers modifié : $($t[0]) (empreinte $h, attendue $($t[1]) : voir son SOURCES.md)" }
    $s = Get-AuthenticodeSignature -LiteralPath $f
    if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch "CN=$([regex]::Escape($t[2]))(,|$)") { throw "Fichier tiers mal signé : $($t[0]) ($($s.Status), $($s.SignerCertificate.Subject))" }
}

$exe = Join-Path $app 'Mindset.exe'
# Mindset.exe exécute le code lui même : il a besoin du moteur PowerShell de Windows
$sma = [psobject].Assembly.Location
& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/win32icon:$(Join-Path $icones 'Mindset.ico')" "/win32manifest:$manif" /reference:System.Windows.Forms.dll "/reference:$sma" "/out:$exe" $source
if ($LASTEXITCODE) { throw "Échec de compilation de $exe" }

# Le désinstalleur autonome, à côté de Mindset.exe (« Applications installées » le lance) : il ne dépend ni de
# Mindset.exe ni du code PowerShell, pour retirer Mindset même quand celui-ci ne démarre plus. Il porte le numéro de
# version de Mindset.ps1 (ajouté à la compilation, pour que publier.ps1 n'ait qu'un numéro à changer).
$desinst = Join-Path $app 'Desinstaller Mindset.exe'
$version = if ([IO.File]::ReadAllText((Join-Path $app 'fichiers\Mindset.ps1'), [Text.Encoding]::UTF8) -match "(?m)^\`$AppVersion = '([\d.]+)'") { $Matches[1] } else { '0.0.0' }
$infos = Join-Path $env:TEMP "mindset-desinstalleur-$PID.cs"
[IO.File]::WriteAllText($infos, "[assembly: System.Reflection.AssemblyVersion(`"$version.0`")]`n[assembly: System.Reflection.AssemblyFileVersion(`"$version.0`")]`n", (New-Object Text.UTF8Encoding $true))
try {
    & $csc /nologo /target:winexe /optimize+ /platform:anycpu "/win32icon:$(Join-Path $icones 'Mindset.ico')" "/win32manifest:$(Join-Path $PSScriptRoot 'desinstalleur.manifest')" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:Microsoft.CSharp.dll /reference:System.Core.dll "/out:$desinst" (Join-Path $PSScriptRoot 'desinstalleur.cs') $infos
    if ($LASTEXITCODE) { throw "Échec de compilation de $desinst" }
} finally { Remove-Item -LiteralPath $infos -Force -ErrorAction SilentlyContinue }

$release = Join-Path $racine 'release'
New-Item -ItemType Directory -Force -Path $release | Out-Null
$zip = Join-Path $release 'Mindset.zip'
Compress-Archive -Path $app -DestinationPath $zip -Force
"OK : $zip"
