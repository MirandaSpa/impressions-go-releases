# Instala o reinstala el agente de impresion en este equipo, desde los
# releases publicos de MirandaSpa/impressions-go-releases.
#
# Se corre en PowerShell normal (no como administrador), con el usuario de
# Windows que usara el agente: su credencial queda cifrada para ese usuario.
# Solo la carpeta y su exclusion del antivirus piden permiso de administrador
# (UAC).
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/MirandaSpa/impressions-go-releases/main/install.ps1)))
#
# Con parametros, por ejemplo un equipo del canal beta:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/MirandaSpa/impressions-go-releases/main/install.ps1))) -Canal beta
#
# No usar "irm ... | iex": Invoke-Expression no acepta el bloque param y
# dejaria la configuracion del script en la sesion.
#
# Confianza: el .exe se comprueba contra el SHA-256 del manifiesto, que esta en
# el mismo repo que este script; la firma ed25519 la comprueba el agente en
# cada actualizacion, no este script (PowerShell 5.1 no trae ed25519). Por eso
# solo el pipeline de release debe poder escribir en ese repo.
#
# El texto va sin tildes a proposito: Windows PowerShell 5.1 lee un .ps1 sin
# BOM como ANSI.

param(
    # Canal de actualizaciones: estable o beta. Si no se indica, se mantiene
    # el que tenga el equipo, o estable si es nuevo.
    [string]$Canal = '',
    # Carpeta del agente.
    [string]$Carpeta = 'C:\Impresiones\agente',
    # No agrega la exclusion de Windows Defender (si el equipo usa otro
    # antivirus, la exclusion de la carpeta se hace a mano en el).
    [switch]$SinExclusion,
    # No crea los accesos directos del escritorio y de Inicio.
    [switch]$SinAccesos,
    # No abre el agente al terminar.
    [switch]$NoAbrir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # la barra de progreso hace lentisima la descarga en PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if ($Canal -ne '' -and $Canal -notin @('estable', 'beta')) {
    throw "Canal no valido: '$Canal'. Usa estable o beta."
}
$Repo = 'MirandaSpa/impressions-go-releases'
$Carpeta = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Carpeta).TrimEnd('\')
$Exe = Join-Path $Carpeta 'impresor.exe'
$ConfigDir = Join-Path $env:APPDATA 'repuestos_miranda\impresiones'
$ConfigPath = Join-Path $ConfigDir 'config.json'

function Write-Paso([string]$Texto) { Write-Host "-> $Texto" -ForegroundColor Cyan }

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { return [pscustomobject]@{} }
    $texto = [IO.File]::ReadAllText($ConfigPath)
    if ($texto.Trim() -eq '') { return [pscustomobject]@{} }
    try {
        return $texto | ConvertFrom-Json
    } catch {
        throw "$ConfigPath no es un JSON valido. Corrigelo o borralo (se pierden las impresoras y el usuario elegidos) y vuelve a correr el script."
    }
}

# El agente lee config.json con Go, que no acepta el BOM: UTF-8 sin BOM.
function Save-Config($Config) {
    New-Item -ItemType Directory -Force $ConfigDir | Out-Null
    $json = $Config | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($ConfigPath, $json, (New-Object Text.UTF8Encoding($false)))
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Otro agente abierto (el antiguo, o este en otra carpeta) tomaria los mismos
# trabajos: se imprimirian dos veces.
function Get-OtrosAgentes {
    Get-CimInstance Win32_Process | Where-Object {
        $ruta = "$($_.ExecutablePath) $($_.CommandLine)"
        $_.ExecutablePath -ne $Exe -and (
            $_.Name -match '^(impresor|impresions_go)' -or
            ($ruta -match '\\Impresiones\\' -and $_.Name -match '^(node|impres)')
        )
    }
}

# Accesos directos de Inicio que abren otro agente al encender.
function Get-InicioAntiguo {
    $shell = New-Object -ComObject WScript.Shell
    $dirs = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))
    foreach ($dir in $dirs) {
        Get-ChildItem $dir -Filter *.lnk -ErrorAction SilentlyContinue | Where-Object {
            $l = $shell.CreateShortcut($_.FullName)
            $destino = "$($l.TargetPath) $($l.Arguments) $($l.WorkingDirectory)"
            $l.TargetPath -ne $Exe -and $destino -match '\\Impresiones\b|impresor|impresions_go'
        }
    }
}

# 1. Otro agente abierto: se cierra a mano antes de seguir.
$otros = @(Get-OtrosAgentes)
if ($otros.Count -gt 0) {
    $lista = ($otros | ForEach-Object { "  - $($_.Name) (PID $($_.ProcessId)) $($_.ExecutablePath)" }) -join "`n"
    throw "Hay otro agente de impresion abierto; si siguen los dos, los documentos se imprimen dos veces. Cierralo (y quitalo del inicio de Windows) y vuelve a correr el script:`n$lista"
}

# 2. El canal: el indicado, o el que ya tenga el equipo.
$config = Read-Config
if ($Canal -eq '') {
    $Canal = 'estable'
    if ($config.PSObject.Properties['canal'] -and $config.canal -eq 'beta') { $Canal = 'beta' }
}
Write-Paso "Canal: $Canal"

# 3. La ultima version del canal, comprobada con el SHA-256 del manifiesto.
try {
    $manifest = Invoke-RestMethod "https://raw.githubusercontent.com/$Repo/main/$Canal/manifest.json" -UseBasicParsing
} catch {
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
        throw "Aun no hay versiones publicadas en el canal $Canal. No se instalo nada."
    }
    throw "No se pudo consultar la ultima version ($($_.Exception.Message)). Revisa la conexion a internet."
}
$version = '^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$'
$url = '^https://github\.com/MirandaSpa/impressions-go-releases/releases/download/v[0-9A-Za-z.\-]+/impresions_go-v[0-9A-Za-z.\-]+\.exe$'
if ("$($manifest.version)" -notmatch $version -or "$($manifest.url)" -notmatch $url -or "$($manifest.url)" -match '\.\.' -or "$($manifest.sha256)" -notmatch '^[0-9a-f]{64}$') {
    throw "El manifiesto del canal $Canal no es valido. No se instalo nada."
}
Write-Paso "Descargando $($manifest.version)"
$descarga = Join-Path $env:TEMP "impresor-$($manifest.version).exe"
Invoke-WebRequest $manifest.url -OutFile $descarga -UseBasicParsing
$sha = (Get-FileHash $descarga -Algorithm SHA256).Hash.ToLower()
if ($sha -ne $manifest.sha256) {
    Remove-Item $descarga -Force
    throw "El archivo descargado no es el publicado (SHA-256 distinto). No se instalo nada."
}

# 4. La carpeta, solo escribible por este usuario y los administradores (el
# antivirus no la revisa y el agente se ejecuta desde ella al encender), y su
# exclusion del antivirus: el agente se reemplaza a si mismo al actualizarse y
# no tiene firma de codigo.
if (-not $SinExclusion) {
    Write-Paso "Preparando $Carpeta y su exclusion de Windows Defender (pide permiso de administrador)"
    $usuario = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $c = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Carpeta)
    $comando = "try { " +
        "New-Item -ItemType Directory -Force '$c' | Out-Null; " +
        "& icacls.exe '$c' /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*$($usuario):(OI)(CI)M' | Out-Null; " +
        "if (`$LASTEXITCODE -ne 0) { exit 2 }; " +
        "Add-MpPreference -ExclusionPath '$c' -ErrorAction Stop; exit 0 } catch { exit 1 }"
    $codificado = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($comando))
    try {
        $p = Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList '-NoProfile', '-EncodedCommand', $codificado
    } catch {
        Remove-Item $descarga -Force
        throw "No se dio el permiso de administrador. No se instalo nada; vuelve a correr el script y acepta el aviso de Windows."
    }
    if ($p.ExitCode -ne 0) {
        Remove-Item $descarga -Force
        if ($p.ExitCode -eq 2) { throw "No se pudieron fijar los permisos de $Carpeta. No se instalo nada." }
        throw "No se pudo excluir $Carpeta de Windows Defender. Si el equipo usa otro antivirus, excluye la carpeta en el y vuelve a correr con -SinExclusion."
    }
} else {
    New-Item -ItemType Directory -Force $Carpeta | Out-Null
}

# 5. El .exe: se cierra este agente si esta abierto y se aparta el anterior
# como .old (Windows deja renombrar un .exe en uso, no sobrescribirlo).
$abiertos = @(Get-Process impresor -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe })
if ($abiertos.Count -gt 0) {
    Write-Paso 'Cerrando el agente abierto'
    $abiertos | Stop-Process -Force
    $abiertos | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
}
try {
    if (Test-Path $Exe) { Move-Item $Exe "$Exe.old" -Force }
    Move-Item $descarga $Exe -Force
} catch {
    throw "No se pudo reemplazar $Exe ($($_.Exception.Message)). Cierra el agente y vuelve a correr el script."
}
Unblock-File $Exe
Remove-Item "$Exe.new" -Force -ErrorAction SilentlyContinue
Write-Paso "Instalado $Exe ($($manifest.version))"

# 6. El canal en config.json, sin tocar lo demas (impresoras, usuario).
$config = Read-Config
$config | Add-Member -NotePropertyName canal -NotePropertyValue $Canal -Force
Save-Config $config

# 7. Accesos directos: escritorio, e Inicio para que abra al encender.
if (-not $SinAccesos) {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Startup'))) {
        $acceso = $shell.CreateShortcut((Join-Path $dir 'Agente de impresion.lnk'))
        $acceso.TargetPath = $Exe
        $acceso.WorkingDirectory = $Carpeta
        $acceso.Save()
    }
    Write-Paso 'Accesos directos en el escritorio y en Inicio'
}
$antiguos = @(Get-InicioAntiguo)
if ($antiguos.Count -gt 0) {
    Write-Warning ("Estos accesos de Inicio abren otro agente al encender; quitalos o se imprimira dos veces:`n" +
        (($antiguos | ForEach-Object { "  - $($_.FullName)" }) -join "`n"))
}

# 8. Abrir el agente: la primera vez pide la credencial, las impresoras y el usuario.
if (-not $NoAbrir) {
    Start-Process $Exe -WorkingDirectory $Carpeta
}
Write-Host "Listo: agente $($manifest.version), canal $Canal." -ForegroundColor Green
