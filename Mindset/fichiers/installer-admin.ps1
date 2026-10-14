<#
    Mindset : installation d'une appli dans Program Files, lancée en administrateur par Mindset (une demande de Windows).
    Program Files n'est modifiable que par un administrateur : un programme sans droits ne peut pas y glisser
    un fichier que Nevermind exécuterait ensuite en administrateur.

    installer-admin.ps1 -Zip <zip téléchargé> -Signature <zip.sig> -Destination <dossier> -DossierZip <OptiGame>
                        -Exe <Nevermind.exe> -Resultat <fichier de réponse> [-AncienExe <ancien Nevermind.exe>]

    La signature est vérifiée ici, en administrateur, sur le contenu lu en mémoire.
#>
param(
    [Parameter(Mandatory = $true)][string]$Zip,
    [Parameter(Mandatory = $true)][string]$Signature,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$DossierZip,
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Resultat,
    [string]$AncienExe
)
$ErrorActionPreference = 'Stop'

function Write-Resultat([bool]$Ok, [string]$Message) {
    try { [IO.File]::WriteAllText($Resultat, (@{ ok = $Ok; message = $Message } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch {}
}

try {
    . (Join-Path $PSScriptRoot 'modules\signature.ps1')
    . (Join-Path $PSScriptRoot 'modules\paquets.ps1')

    # Uniquement dans Program Files\Mindset, et uniquement un nom de programme simple
    $base = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Mindset')) + '\'
    $dest = [IO.Path]::GetFullPath($Destination.TrimEnd('\'))
    if (-not $dest.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or $dest.Substring($base.Length) -match '[\\/]') { throw "Dossier d'installation refusé : $Destination" }
    if ($Exe -notmatch '^[^\\/:*?"<>|]+\.exe$' -or $DossierZip -match '[\\/:*?"<>|]') { throw 'Nom de programme refusé.' }

    $octets = [IO.File]::ReadAllBytes($Zip)
    $sig = [IO.File]::ReadAllBytes($Signature)

    # L'appli tourne peut-être en administrateur : on la ferme (Mindset a demandé confirmation avant)
    $nom = [IO.Path]::GetFileNameWithoutExtension($Exe)
    Get-Process -Name $nom -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800

    $installe = Install-Paquet -Zip $octets -Signature $sig -ClePublique (Join-Path $PSScriptRoot 'cle-publique.xml') -Destination $dest -DossierZip $DossierZip -Exe $Exe

    # Prise en charge d'une installation existante : son lancement au démarrage (tâche planifiée en administrateur,
    # que Mindset sans droits ne peut pas modifier) pointe désormais vers la nouvelle copie
    if ($AncienExe) {
        $nouveau = Join-Path $installe $Exe
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            $act = @($t.Actions)[0]
            if ($act -and ([string]$act.Execute).Trim('"') -ieq $AncienExe) {
                $act.Execute = "`"$nouveau`""
                $act.WorkingDirectory = $env:USERPROFILE
                Set-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Action $act | Out-Null
            }
        }
    }
    Write-Resultat $true $installe
} catch {
    Write-Resultat $false $_.Exception.Message
}
