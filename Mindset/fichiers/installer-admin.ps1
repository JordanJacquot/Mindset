<#
    Mindset : ce qui se fait dans Program Files\Mindset, lancé en administrateur par Mindset (une demande de Windows).
    Program Files n'est modifiable que par un administrateur : un programme sans droits ne peut pas y glisser un
    fichier que Nevermind (ou Mindset plus tard) exécuterait ensuite en administrateur.

    -Action appli           installe une appli à partir de son zip signé (vérifié ici, sur le contenu lu en mémoire)
                            -Zip -Signature -Destination -DossierZip -Exe [-AncienExe]
    -Action mindset         installe Mindset lui-même : copie -Source dans Program Files\Mindset\Mindset
                            et l'inscrit dans « Applications installées » de Windows (-Version)
    -Action supprimer       supprime une appli gérée (-Destination, -Exe) ou Mindset lui-même (-Destination ...\Mindset)
                            après avoir attendu la fin du processus -AttendrePid
    Toujours : -Resultat <fichier de réponse> (JSON { ok, message }).

    Seuls des dossiers directement dans Program Files\Mindset sont acceptés.
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('appli', 'mindset', 'supprimer')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Resultat,
    [string]$Zip, [string]$Signature, [string]$Destination, [string]$DossierZip, [string]$Exe, [string]$AncienExe,
    [string]$Source, [string]$Version, [int]$AttendrePid
)
$ErrorActionPreference = 'Stop'
$CleDesinstall = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Mindset'

function Write-Resultat([bool]$Ok, [string]$Message) {
    try { [IO.File]::WriteAllText($Resultat, (@{ ok = $Ok; message = $Message } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) } catch {}
}

# Un dossier directement dans Program Files\Mindset (jamais ailleurs, jamais plus profond)
function Test-DossierMindset([string]$Dossier) {
    $base = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Mindset')) + '\'
    $d = [IO.Path]::GetFullPath($Dossier.TrimEnd('\'))
    if (-not $d.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or $d.Substring($base.Length) -match '[\\/]' -or -not $d.Substring($base.Length)) { throw "Dossier refusé : $Dossier" }
    $d
}

function Stop-Programme([string]$Nom) {
    if ($Nom -notmatch '^[^\\/:*?"<>|]+\.exe$') { throw 'Nom de programme refusé.' }
    Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Nom)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

try {
    . (Join-Path $PSScriptRoot 'modules\signature.ps1')
    . (Join-Path $PSScriptRoot 'modules\paquets.ps1')

    switch ($Action) {
        'appli' {
            $dest = Test-DossierMindset $Destination
            if ($DossierZip -match '[\\/:*?"<>|]') { throw 'Nom de dossier refusé.' }
            $octets = [IO.File]::ReadAllBytes($Zip)
            $sig = [IO.File]::ReadAllBytes($Signature)
            Stop-Programme $Exe   # Mindset a demandé confirmation avant de fermer l'appli
            $installe = Install-Paquet -Zip $octets -Signature $sig -ClePublique (Join-Path $PSScriptRoot 'cle-publique.xml') -Destination $dest -DossierZip $DossierZip -Exe $Exe
            # Prise en charge : les tâches planifiées qui lançaient l'ancienne copie (en administrateur, que Mindset
            # sans droits ne peut pas modifier) lancent désormais la nouvelle
            if ($AncienExe) {
                $nouveau = Join-Path $installe $Exe
                foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
                    $act = @($t.Actions)[0]
                    if ($act -and ([string]$act.Execute).Trim('"') -ieq $AncienExe) {
                        $act.Execute = "`"$nouveau`""
                        Set-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Action $act | Out-Null
                    }
                }
            }
            Write-Resultat $true $installe
        }
        'mindset' {
            $dest = Test-DossierMindset (Join-Path $env:ProgramFiles 'Mindset\Mindset')
            $src = [IO.Path]::GetFullPath($Source.TrimEnd('\'))
            if (-not (Test-Path -LiteralPath (Join-Path $src 'Mindset.exe')) -or -not (Test-Path -LiteralPath (Join-Path $src 'fichiers\Mindset.ps1'))) { throw "Ce dossier ne contient pas Mindset : $Source" }
            # Préparé à côté puis échangé, comme une appli
            $tmp = "$dest.nouveau-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
            New-Item -ItemType Directory -Force -Path $tmp | Out-Null
            Copy-Item -LiteralPath (Join-Path $src 'Mindset.exe') -Destination $tmp
            Copy-Item -LiteralPath (Join-Path $src 'fichiers') -Destination $tmp -Recurse
            foreach ($f in 'LISEZMOI.txt') { if (Test-Path -LiteralPath (Join-Path $src $f)) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination $tmp } }
            if (Test-Path -LiteralPath $dest) {
                $ancien = "$dest.ancien-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
                Move-Item -LiteralPath $dest -Destination $ancien
                Move-Item -LiteralPath $tmp -Destination $dest
                try { Remove-Item -LiteralPath $ancien -Recurse -Force } catch {}
            } else { Move-Item -LiteralPath $tmp -Destination $dest }
            # « Applications installées » de Windows : Mindset s'y désinstalle comme un vrai programme
            $exe = Join-Path $dest 'Mindset.exe'
            New-Item -Path $CleDesinstall -Force | Out-Null
            foreach ($p in @{ DisplayName = 'Mindset'; DisplayVersion = $Version; Publisher = 'Jordan Jacquot'; InstallLocation = $dest
                              DisplayIcon = "`"$exe`",0"; UninstallString = "`"$exe`" -Desinstaller"; NoModify = 1; NoRepair = 1 }.GetEnumerator()) {
                if ($p.Value -is [int]) { New-ItemProperty -Path $CleDesinstall -Name $p.Key -Value $p.Value -PropertyType DWord -Force | Out-Null }
                else { New-ItemProperty -Path $CleDesinstall -Name $p.Key -Value ([string]$p.Value) -PropertyType String -Force | Out-Null }
            }
            Write-Resultat $true $dest
        }
        'supprimer' {
            $dest = Test-DossierMindset $Destination
            if ($AttendrePid) { try { Wait-Process -Id $AttendrePid -Timeout 30 -ErrorAction Stop } catch {} }
            if ($Exe) { Stop-Programme $Exe }
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            if ((Split-Path $dest -Leaf) -eq 'Mindset') { Remove-Item -Path $CleDesinstall -Recurse -Force -ErrorAction SilentlyContinue }
            # Program Files\Mindset vide : retiré aussi
            $base = Join-Path $env:ProgramFiles 'Mindset'
            if ((Test-Path -LiteralPath $base) -and -not @(Get-ChildItem -LiteralPath $base -Force).Count) { Remove-Item -LiteralPath $base -Force }
            Write-Resultat $true $dest
        }
    }
} catch {
    Write-Resultat $false $_.Exception.Message
}
