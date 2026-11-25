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
# O con doble clic en scripts\instalar-estable.cmd, instalar-beta.cmd o
# borrar-credencial.cmd (publicados junto a este script).
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

# CmdletBinding: un parametro desconocido (un .cmd mas nuevo que el script, o
# al reves) es un error, no se ignora en silencio.
[CmdletBinding()]
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
    [switch]$NoAbrir,
    # No instala: borra la credencial guardada de este usuario (por ejemplo,
    # cuando Informatica la cambia) y abre el agente para ingresar la nueva.
    [switch]$BorrarCredencial,
    # Permite correrlo como administrador (equipos sin UAC, o cuando el
    # usuario del agente es el propio administrador).
    [switch]$PermitirAdmin,
    # Instala aunque el Control inteligente de aplicaciones de Windows 11
    # este activado o en evaluacion (bloqueara el agente; solo para pruebas).
    [switch]$IgnorarControlInteligente
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

# Elevado, %APPDATA% y la credencial serian los del administrador, no los de
# la persona que usa el agente. El permiso de administrador se pide solo
# cuando hace falta (paso 4).
if ((Test-Admin) -and -not $PermitirAdmin) {
    throw 'Corre esto sin "Ejecutar como administrador", con la sesion de la persona que usara el agente: el permiso de administrador se pide cuando hace falta.'
}

# Solo borrar la credencial: el agente la vuelve a pedir al abrir.
if ($BorrarCredencial) {
    if ($Canal -ne '' -or $SinExclusion -or $SinAccesos) {
        Write-Warning 'Con -BorrarCredencial no se instala nada: se ignoran -Canal, -SinExclusion y -SinAccesos.'
    }
    $abiertos = @(Get-Process impresor -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe })
    if ($abiertos.Count -gt 0) {
        Write-Paso 'Cerrando el agente'
        $abiertos | Stop-Process -Force
        $abiertos | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    }
    $credencial = Join-Path $ConfigDir 'credential.bin'
    if (Test-Path $credencial) {
        Remove-Item $credencial -Force
        Write-Paso 'Credencial borrada'
    } else {
        Write-Paso 'No habia una credencial guardada para este usuario'
    }
    $variable = @('User', 'Machine') | Where-Object { [Environment]::GetEnvironmentVariable('PRINT_SERVICE_CREDENTIAL', $_) }
    if ($variable) {
        Write-Warning "La variable PRINT_SERVICE_CREDENTIAL ($($variable -join ', ')) tiene una credencial y el agente la usa antes que la guardada: no pedira la nueva. Pide a Informatica que la corrija o la borre."
        return
    }
    if (-not (Test-Path $Exe)) {
        Write-Warning "El agente no esta instalado en $Carpeta."
        return
    }
    if (@(Get-Process impresor -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Warning 'Queda un agente abierto que este script no pudo cerrar. Cierralo y abre el agente desde el escritorio para pegar la credencial.'
        return
    }
    if (-not $NoAbrir) { Start-Process $Exe -WorkingDirectory $Carpeta }
    Write-Host 'Listo: al abrir, el agente pide la credencial. Pega la vigente.' -ForegroundColor Green
    return
}

# 1. Otro agente abierto: se cierra a mano antes de seguir.
$otros = @(Get-OtrosAgentes)
if ($otros.Count -gt 0) {
    $lista = ($otros | ForEach-Object { "  - $($_.Name) (PID $($_.ProcessId)) $($_.ExecutablePath)" }) -join "`n"
    throw "Hay otro agente de impresion abierto; si siguen los dos, los documentos se imprimen dos veces. Cierralo (y quitalo del inicio de Windows) y vuelve a correr el script:`n$lista"
}

# 1b. Control inteligente de aplicaciones (Smart App Control, Windows 11):
# bloquea los programas sin firma de codigo que Microsoft no conoce, y cada
# version del agente es un .exe nuevo. No admite excepciones por programa:
# hay que desactivarlo, y eso lo decide una persona, no este script. En
# "evaluacion" puede activarse solo mas adelante. Sin Defender o en Windows
# 10 no existe: no se revisa.
$control = $null
try { $control = (Get-MpComputerStatus).SmartAppControlState } catch { }
if ($control -in @('On', 'Eval') -and -not $IgnorarControlInteligente) {
    $estado = if ($control -eq 'On') { 'activado' } else { 'en evaluacion (puede activarse solo mas adelante)' }
    throw ("El Control inteligente de aplicaciones de Windows esta $estado y bloquearia el agente en cada actualizacion. No se instalo nada.`n" +
        "Desactivalo y vuelve a correr el instalador:`n" +
        "  1. Seguridad de Windows > Control de aplicaciones y navegador > Configuracion de Control inteligente de aplicaciones.`n" +
        "  2. Elige Desactivado (Windows puede no permitir volver a activarlo sin reinstalar; Defender sigue protegiendo el equipo).")
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

# 6b. Herramientas en la carpeta del agente, para dejarles un acceso directo:
# abrir la carpeta del log y desinstalar. Van aca y no en scripts\ porque el
# pipeline publica scripts\*.cmd como lanzadores del instalador. Se escriben
# en ASCII con CRLF: cmd.exe y PowerShell 5.1 leen sin BOM como ANSI/OEM.
function Save-Herramienta([string]$Nombre, [string]$Texto) {
    $Texto = $Texto -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText((Join-Path $Carpeta $Nombre), $Texto, (New-Object Text.ASCIIEncoding))
}

Save-Herramienta 'Abrir carpeta del log.cmd' @'
@echo off
rem Abre la carpeta del log del agente de impresion con impresor.log seleccionado, para
rem adjuntarlo al correo o chat con Informatica. Lo crea install.ps1.
set "DIR=%APPDATA%\repuestos_miranda\impresiones"
if exist "%DIR%\impresor.log" goto log
if exist "%DIR%" goto dir
echo Aun no hay log: el agente de impresion no se ha abierto con este usuario de Windows.
pause
exit /b
:log
start "" explorer.exe /select,"%DIR%\impresor.log"
exit /b
:dir
start "" explorer.exe "%DIR%"
'@

# La ultima linea va entera en una: cmd.exe lee el .cmd a medida que avanza y
# la carpeta se borra mientras corre ("cd" sale de ella para poder borrarla).
Save-Herramienta 'Desinstalar agente.cmd' @'
@echo off
rem Desinstala el agente de impresion de este equipo (corre desinstalar.ps1). Lo crea install.ps1.
title Desinstalar el agente de impresion
cd /d "%TEMP%" & powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0desinstalar.ps1" & pause & exit
'@

$desinstalar = @'
# Desinstala el agente de impresion: lo cierra y quita sus accesos directos, la carpeta
# del programa y su exclusion de Windows Defender. La configuracion y el log
# (%APPDATA%\repuestos_miranda\impresiones) se borran solo si se pide. Lo crea
# install.ps1; se corre con "Desinstalar agente.cmd".
$ErrorActionPreference = 'Stop'
$Carpeta = '@CARPETA@'
$Exe = Join-Path $Carpeta 'impresor.exe'
$ConfigDir = Join-Path $env:APPDATA 'repuestos_miranda\impresiones'

function Write-Paso([string]$Texto) { Write-Host "-> $Texto" -ForegroundColor Cyan }

Write-Host "Esto quita el agente de impresion de este equipo ($Carpeta)." -ForegroundColor Yellow
if ((Read-Host 'Escribe S y aprieta Enter para desinstalar') -notmatch '^\s*[sS]') {
    Write-Host 'No se desinstalo nada.'
    return
}
$borrarConfig = (Read-Host 'Borrar tambien la configuracion y el log de este usuario? (S/N; si no sabes, N)') -match '^\s*[sS]'

$abiertos = @(Get-Process impresor -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe })
if ($abiertos.Count -gt 0) {
    Write-Paso 'Cerrando el agente'
    $abiertos | Stop-Process -Force
    $abiertos | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
}

foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Startup'))) {
    Remove-Item -LiteralPath (Join-Path $dir 'Agente de impresion.lnk') -Force -ErrorAction SilentlyContinue
}
Write-Paso 'Accesos directos del escritorio y de Inicio quitados'

# La exclusion del antivirus pide administrador; la carpeta (y su carpeta
# padre, si queda vacia) se borra en el mismo paso.
Write-Paso "Borrando $Carpeta y su exclusion de Windows Defender (pide permiso de administrador)"
$c = [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Carpeta)
$comando = "`$r = 0; " +
    "try { Remove-MpPreference -ExclusionPath '$c' -ErrorAction Stop } catch { `$r = 1 }; " +
    "try { if (Test-Path -LiteralPath '$c') { Remove-Item -LiteralPath '$c' -Recurse -Force -ErrorAction Stop } } catch { exit 2 }; " +
    "`$padre = Split-Path -Parent '$c'; " +
    "if (`$padre -and (Test-Path -LiteralPath `$padre) -and -not (Get-ChildItem -LiteralPath `$padre -Force)) { Remove-Item -LiteralPath `$padre -Force -ErrorAction SilentlyContinue }; " +
    "exit `$r"
$codificado = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($comando))
$elevado = $true
try {
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-EncodedCommand', $codificado
    $codigo = $p.ExitCode
} catch {
    # Sin permiso de administrador: la carpeta la puede borrar el usuario
    # (install.ps1 le da permiso de modificar), la exclusion no.
    $elevado = $false
    try { Remove-Item -LiteralPath $Carpeta -Recurse -Force -ErrorAction Stop; $codigo = 1 } catch { $codigo = 2 }
}
if ($codigo -eq 2) {
    Write-Warning "No se pudo borrar $Carpeta. Cierra el agente y vuelve a desinstalar, o borra la carpeta a mano."
} elseif ($codigo -eq 1 -and -not $elevado) {
    Write-Warning "No se dio el permiso de administrador: queda la exclusion de Windows Defender de $Carpeta. Pidele a Informatica que la quite."
} elseif ($codigo -eq 1) {
    Write-Warning "No se pudo quitar la exclusion de Windows Defender de $Carpeta (si el equipo usa otro antivirus, quitala en el)."
}

if ($borrarConfig) {
    Remove-Item -LiteralPath $ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Paso "Configuracion y log borrados ($ConfigDir)"
} elseif (Test-Path -LiteralPath $ConfigDir) {
    Write-Paso "Quedan la configuracion y el log en $ConfigDir"
}

if ($codigo -ne 2) {
    Write-Host 'Listo: el agente de impresion se desinstalo.' -ForegroundColor Green
}
'@
Save-Herramienta 'desinstalar.ps1' $desinstalar.Replace('@CARPETA@', [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Carpeta))
Write-Paso "En $Carpeta quedaron 'Abrir carpeta del log.cmd' y 'Desinstalar agente.cmd'"

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
