#Requires -Version 7.0
<#
.SYNOPSIS
    Мини-TUI для SSH-подключений (для запуска из Logitech Actions Ring).

.DESCRIPTION
    Подключения хранятся в connections.yml рядом со скриптом.
    Пароли шифруются Windows DPAPI: расшифровать их может только текущий пользователь на этом ПК.
    Пароль передаётся в ssh через SSH_ASKPASS (askpass.cmd), в командной строке он не виден.

.EXAMPLE
    pwsh -File ssh-menu.ps1
    pwsh -File ssh-menu.ps1 -CreateShortcut   # создать ssh-menu.lnk для Actions Ring
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'connections.yml'),
    [switch]$CreateShortcut
)

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    [Console]::InputEncoding = [Text.Encoding]::UTF8
}
catch { }   # нет консоли (запуск из GUI) — кодировка не нужна

$E = [char]27
$PassPrefix = 'dpapi:'
$AskPassPath = Join-Path $PSScriptRoot 'askpass.cmd'
$script:Status = ''
$script:GroupColors = @{}   # имя группы -> '#rrggbb'

#region Цвета

function ConvertFrom-Hex([string]$Hex) {
    if ($Hex -match '^#?([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})$') {
        return @([Convert]::ToInt32($Matches[1], 16), [Convert]::ToInt32($Matches[2], 16), [Convert]::ToInt32($Matches[3], 16))
    }
    return $null
}

function ConvertTo-Hex([int]$R, [int]$G, [int]$B) { '#{0:x2}{1:x2}{2:x2}' -f $R, $G, $B }

# HSL (H 0..360, S/L 0..1) -> '#rrggbb'
function Format-Hsl([double]$H, [double]$S, [double]$L) {
    $c = (1 - [Math]::Abs(2 * $L - 1)) * $S
    $hp = ($H % 360) / 60
    $x = $c * (1 - [Math]::Abs($hp % 2 - 1))
    $rgb = switch ([int][Math]::Floor($hp)) {
        0 { $c, $x, 0 }
        1 { $x, $c, 0 }
        2 { 0, $c, $x }
        3 { 0, $x, $c }
        4 { $x, 0, $c }
        default { $c, 0, $x }
    }
    $m = $L - $c / 2
    ConvertTo-Hex ([Math]::Round(($rgb[0] + $m) * 255)) ([Math]::Round(($rgb[1] + $m) * 255)) ([Math]::Round(($rgb[2] + $m) * 255))
}

function Get-Hue([string]$Hex) {
    $rgb = ConvertFrom-Hex $Hex
    if (-not $rgb) { return $null }
    $r = $rgb[0] / 255; $g = $rgb[1] / 255; $b = $rgb[2] / 255
    $max = [Math]::Max($r, [Math]::Max($g, $b))
    $d = $max - [Math]::Min($r, [Math]::Min($g, $b))
    if ($d -eq 0) { return $null }
    $h = if ($max -eq $r) { 60 * ((($g - $b) / $d) % 6) }
    elseif ($max -eq $g) { 60 * (($b - $r) / $d + 2) }
    else { 60 * (($r - $g) / $d + 4) }
    if ($h -lt 0) { $h += 360 }
    return $h
}

# Текст цветом: "$E[38;2;r;g;bm"
function Get-Fg([string]$Hex) {
    $rgb = ConvertFrom-Hex $Hex
    if (-not $rgb) { return '' }
    "$E[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m"
}

# Случайный цвет, оттенок которого максимально далёк от уже занятых групп.
function New-GroupColor {
    $used = @($script:GroupColors.Values | ForEach-Object { Get-Hue $_ } | Where-Object { $null -ne $_ })
    $best = 0.0
    $bestScore = -1.0
    for ($n = 0; $n -lt 40; $n++) {
        $h = Get-Random -Minimum 0.0 -Maximum 360.0
        $score = 360.0
        foreach ($u in $used) {
            $d = [Math]::Abs($u - $h)
            $score = [Math]::Min($score, [Math]::Min($d, 360 - $d))
        }
        if ($score -gt $bestScore) { $best = $h; $bestScore = $score }
    }
    Format-Hsl $best 0.65 0.62
}

# Назначает случайный цвет группам без цвета и убирает цвета исчезнувших групп.
function Initialize-GroupColors($List) {
    $groups = @($List.Group | Sort-Object -Unique)
    foreach ($g in $groups) {
        if (-not $script:GroupColors.ContainsKey($g)) { $script:GroupColors[$g] = New-GroupColor }
    }
    foreach ($key in @($script:GroupColors.Keys)) {
        if ($key -notin $groups) { $script:GroupColors.Remove($key) }
    }
}

# Палитра: оттенок по горизонтали, яркость по вертикали, внизу — серая шкала.
# ←→↑↓ — выбор, Enter — применить, # или Tab — ввести hex, Esc — отмена ($null).
function Select-Color([string]$Title, [string]$Current) {
    $cols = 36
    $lights = 0.90, 0.81, 0.72, 0.63, 0.54, 0.45, 0.36, 0.27, 0.18
    $grid = @()
    foreach ($l in $lights) {
        $grid += , @(0..($cols - 1) | ForEach-Object { Format-Hsl ($_ * 10) 0.80 $l })
    }
    $grid += , @(0..($cols - 1) | ForEach-Object { Format-Hsl 0 0 (0.03 + $_ * 0.94 / ($cols - 1)) })
    $rows = $grid.Count
    # Размер ячейки подстраивается под окно: шире (2..4 символа) и, если хватает высоты, в две строки.
    $cellW = [Math]::Max(2, [Math]::Min(4, [Math]::Floor(([Console]::WindowWidth - 4) / $cols)))
    $cellH = if ([Console]::WindowHeight -ge $rows * 2 + 9) { 2 } else { 1 }

    $picked = if (ConvertFrom-Hex $Current) { $Current.ToLower() } else { '#7aa2f7' }
    $original = $picked
    $row = 0; $col = 0

    $setNearest = {
        param([string]$Hex)
        $t = ConvertFrom-Hex $Hex
        $bestD = [double]::MaxValue
        for ($r = 0; $r -lt $rows; $r++) {
            for ($c = 0; $c -lt $cols; $c++) {
                $p = ConvertFrom-Hex $grid[$r][$c]
                $d = [Math]::Pow($p[0] - $t[0], 2) + [Math]::Pow($p[1] - $t[1], 2) + [Math]::Pow($p[2] - $t[2], 2)
                if ($d -lt $bestD) { $bestD = $d; $script:pickRow = $r; $script:pickCol = $c }
            }
        }
    }
    & $setNearest $picked
    $row = $script:pickRow; $col = $script:pickCol

    [Console]::CursorVisible = $false
    [Console]::Write("$E[2J$E[3J$E[H")
    while ($true) {
        $sb = [Text.StringBuilder]::new("$E[H")
        [void]$sb.Append("$E[1m Цвет группы: $Title$E[0m$E[K`n$E[K`n")
        $marker = '[' + (' ' * ($cellW - 2)) + ']'
        $blank = ' ' * $cellW
        for ($r = 0; $r -lt $rows; $r++) {
            for ($h = 0; $h -lt $cellH; $h++) {
                [void]$sb.Append('  ')
                for ($c = 0; $c -lt $cols; $c++) {
                    $rgb = ConvertFrom-Hex $grid[$r][$c]
                    $bg = "$E[48;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m"
                    if ($r -eq $row -and $c -eq $col) {
                        $fg = if (0.299 * $rgb[0] + 0.587 * $rgb[1] + 0.114 * $rgb[2] -gt 140) { "$E[30m" } else { "$E[97m" }
                        [void]$sb.Append("$bg$fg$marker$E[0m")
                    }
                    else { [void]$sb.Append("$bg$blank$E[0m") }
                }
                [void]$sb.Append("$E[K`n")
            }
        }
        $cur = ConvertFrom-Hex $picked
        $old = ConvertFrom-Hex $original
        [void]$sb.Append("$E[K`n  Выбрано: $E[48;2;$($cur[0]);$($cur[1]);$($cur[2])m        $E[0m $picked")
        [void]$sb.Append("     Было: $E[48;2;$($old[0]);$($old[1]);$($old[2])m    $E[0m $original$E[K`n")
        [void]$sb.Append("$E[90m  ←→↑↓ выбор   Enter применить   # / Tab ввести hex   Esc отмена$E[0m$E[K`n")
        [void]$sb.Append("$E[90m  внизу — оттенки серого; для большего размера увеличьте окно$E[0m$E[K`n")
        [Console]::Write($sb.ToString())

        $k = [Console]::ReadKey($true)
        $ctrl = [bool]($k.Modifiers -band [ConsoleModifiers]::Control)
        if ($k.Key -eq 'Enter') { [Console]::CursorVisible = $true; return $picked }
        elseif ($k.Key -eq 'Escape' -or ($ctrl -and $k.Key -eq 'C')) { [Console]::CursorVisible = $true; return $null }
        elseif ($k.Key -in 'LeftArrow', 'RightArrow', 'UpArrow', 'DownArrow') {
            if ($k.Key -eq 'LeftArrow') { $col = [Math]::Max(0, $col - 1) }
            elseif ($k.Key -eq 'RightArrow') { $col = [Math]::Min($cols - 1, $col + 1) }
            elseif ($k.Key -eq 'UpArrow') { $row = [Math]::Max(0, $row - 1) }
            else { $row = [Math]::Min($rows - 1, $row + 1) }
            $picked = $grid[$row][$col]
        }
        elseif ($k.KeyChar -eq '#' -or $k.Key -eq 'Tab') {
            $inputRow = 2 + $rows * $cellH + 4
            [Console]::SetCursorPosition(0, $inputRow)
            [Console]::CursorVisible = $true
            $text = Read-Field 'Hex' $picked -Hint 'формат #rrggbb (Esc — отмена)'
            [Console]::CursorVisible = $false
            [Console]::SetCursorPosition(0, $inputRow)
            [Console]::Write("$E[0J")
            if ($text -and (ConvertFrom-Hex $text)) {
                $picked = '#' + $text.TrimStart('#').ToLower()
                & $setNearest $picked
                $row = $script:pickRow; $col = $script:pickCol
            }
        }
    }
}

#endregion

#region Хранилище (YAML)

function ConvertFrom-YamlScalar([string]$Text) {
    $s = $Text.Trim()
    if ($s.StartsWith("'")) {
        $end = $s.LastIndexOf("'")
        if ($end -lt 1) { throw "незакрытая кавычка: $Text" }
        return $s.Substring(1, $end - 1).Replace("''", "'")
    }
    if ($s.StartsWith('"')) {
        $end = $s.LastIndexOf('"')
        if ($end -lt 1) { throw "незакрытая кавычка: $Text" }
        return [regex]::Unescape($s.Substring(1, $end - 1))
    }
    $s = ($s -replace '\s+#.*$', '').Trim()
    if ($s -in '', '~', 'null') { return $null }
    return $s
}

function ConvertTo-YamlScalar($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return 'null' }
    if ($Value -is [int]) { return "$Value" }
    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function New-Connection($Data) {
    [pscustomobject]@{
        Name     = [string]$Data.name
        Group    = if ($Data.group) { [string]$Data.group } else { 'Default' }
        Address  = [string]$Data.address
        Port     = if ($Data.port) { [int]$Data.port } else { 22 }
        Login    = [string]$Data.login
        Password = if ($Data.password) { [string]$Data.password } else { $null }
    }
}

function Read-Connections {
    $list = [Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return , $list }

    $script:GroupColors = @{}
    $groupItems = [Collections.Generic.List[object]]::new()
    $section = 'connections'
    $current = $null
    $lineNo = 0
    foreach ($line in Get-Content -LiteralPath $ConfigPath -Encoding utf8) {
        $lineNo++
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -match '^(connections|groups):\s*(\[\s*\])?\s*$') { $section = $Matches[1]; $current = $null; continue }
        if ($line -notmatch '^\s*(-\s+)?([A-Za-z_]+)\s*:\s?(.*)$') {
            throw "${ConfigPath}:${lineNo}: не удалось разобрать строку: $line"
        }
        $isItem = [bool]$Matches[1]
        $key = $Matches[2].ToLower()
        $value = ConvertFrom-YamlScalar $Matches[3]
        if ($isItem) {
            $current = @{}
            if ($section -eq 'groups') { $groupItems.Add($current) } else { $list.Add($current) }
        }
        elseif ($null -eq $current) {
            throw "${ConfigPath}:${lineNo}: поле вне элемента списка: $line"
        }
        $current[$key] = $value
    }

    foreach ($g in $groupItems) {
        if ($g.name -and (ConvertFrom-Hex $g.color)) { $script:GroupColors[[string]$g.name] = ([string]$g.color).ToLower() }
    }
    $result = [Collections.Generic.List[object]]::new()
    foreach ($item in $list) { $result.Add((New-Connection $item)) }
    return , $result
}

function Save-Connections($List) {
    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Подключения для ssh-menu.ps1')
    [void]$sb.AppendLine("# password: '${PassPrefix}...' — зашифрован Windows DPAPI (только этот пользователь на этом ПК);")
    [void]$sb.AppendLine('#           можно вписать пароль открытым текстом — при запуске скрипта он будет зашифрован;')
    [void]$sb.AppendLine('#           null — без пароля (ключ или ввод вручную).')
    Initialize-GroupColors $List
    if ($script:GroupColors.Count -eq 0) {
        [void]$sb.AppendLine('groups: []')
    }
    else {
        [void]$sb.AppendLine('groups:')
        foreach ($name in $script:GroupColors.Keys | Sort-Object) {
            [void]$sb.AppendLine("  - name: $(ConvertTo-YamlScalar $name)")
            [void]$sb.AppendLine("    color: $(ConvertTo-YamlScalar $script:GroupColors[$name])")
        }
    }
    if ($List.Count -eq 0) {
        [void]$sb.AppendLine('connections: []')
    }
    else {
        [void]$sb.AppendLine('connections:')
    }
    foreach ($c in $List | Sort-Object Group, Name) {
        if ($c.Password -and -not $c.Password.StartsWith($PassPrefix)) {
            $c.Password = Protect-Password $c.Password
        }
        [void]$sb.AppendLine("  - name: $(ConvertTo-YamlScalar $c.Name)")
        [void]$sb.AppendLine("    group: $(ConvertTo-YamlScalar $c.Group)")
        [void]$sb.AppendLine("    address: $(ConvertTo-YamlScalar $c.Address)")
        [void]$sb.AppendLine("    port: $(ConvertTo-YamlScalar ([int]$c.Port))")
        [void]$sb.AppendLine("    login: $(ConvertTo-YamlScalar $c.Login)")
        [void]$sb.AppendLine("    password: $(ConvertTo-YamlScalar $c.Password)")
    }
    $tmp = "$ConfigPath.tmp"
    [IO.File]::WriteAllText($tmp, $sb.ToString(), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
}

function Protect-Password([string]$Plain) {
    $PassPrefix + (ConvertTo-SecureString -String $Plain -AsPlainText -Force | ConvertFrom-SecureString)
}

function Unprotect-Password([string]$Stored) {
    if (-not $Stored) { return $null }
    if (-not $Stored.StartsWith($PassPrefix)) { return $Stored }
    ConvertTo-SecureString -String $Stored.Substring($PassPrefix.Length) | ConvertFrom-SecureString -AsPlainText
}

#endregion

#region Ввод

# Разбирает «host», «user@host:port» или вставленную команду «ssh -l user -p 22 host».
function Split-SshTarget([string]$Text) {
    $r = @{ Address = $null; Login = $null; Port = $null }
    $tokens = @($Text.Trim() -split '\s+' | Where-Object { $_ })
    $flagsWithArg = 'BbcDEeFIiJLlmOoPpQRSWw'
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $t = $tokens[$i]
        if ($i -eq 0 -and $t -match '^ssh(\.exe)?$') { continue }
        if ($t -cmatch '^-([A-Za-z])(.*)$') {
            $flag = $Matches[1]
            $inline = $Matches[2]
            if ($flagsWithArg.Contains($flag)) {
                $arg = if ($inline) { $inline } else { $i++; $tokens[$i] }
                if ($flag -ceq 'l') { $r.Login = $arg }
                elseif ($flag -ceq 'p') { $r.Port = $arg }
            }
            continue
        }
        $target = $t -replace '^ssh://', ''
        if ($target -match '^(.+)@(.+)$') { $r.Login = $Matches[1]; $target = $Matches[2] }
        if ($target -match '^([^:\[\]]+):(\d+)$') { $r.Address = $Matches[1]; $r.Port = $Matches[2] }
        else { $r.Address = $target }
        break
    }
    return $r
}

# Однострочный ввод с курсором: ←/→ (Ctrl — по словам), Home/End, Backspace/Del, Ctrl+U — очистить.
# Enter — принять, Esc — отмена ($null).
function Read-Field {
    param(
        [string]$Label,
        [string]$Value = '',
        [string]$Hint = '',
        [switch]$Required,
        [switch]$Mask
    )
    while ($true) {
        if ($Hint) { [Console]::WriteLine("  $E[90m$Hint$E[0m") }
        [Console]::Write("  $E[36m$($Label.PadRight(9))$E[0m ")
        $left = [Console]::CursorLeft
        $top = [Console]::CursorTop
        $chars = [Collections.Generic.List[char]]::new($Value.ToCharArray())
        $pos = $chars.Count
        $scroll = 0

        :read while ($true) {
            # Перерисовка только когда нет очереди нажатий — вставка из буфера не мерцает.
            if (-not [Console]::KeyAvailable) {
                $avail = [Math]::Max(5, [Console]::WindowWidth - $left - 1)
                $scroll = [Math]::Min($scroll, [Math]::Max(0, $chars.Count - $avail + 1))
                if ($pos -lt $scroll) { $scroll = $pos }
                if ($pos - $scroll -ge $avail) { $scroll = $pos - $avail + 1 }
                $text = if ($Mask) { '*' * $chars.Count } else { -join $chars }
                $shown = $text.Substring($scroll, [Math]::Min($avail, $text.Length - $scroll))
                [Console]::SetCursorPosition($left, $top)
                [Console]::Write("$shown$E[K")
                [Console]::SetCursorPosition($left + $pos - $scroll, $top)
            }

            $k = [Console]::ReadKey($true)
            $ctrl = [bool]($k.Modifiers -band [ConsoleModifiers]::Control)
            if ($k.Key -eq 'Enter') { break read }
            elseif ($k.Key -eq 'Escape' -or ($ctrl -and $k.Key -eq 'C')) {
                [Console]::WriteLine()
                return $null
            }
            elseif ($k.Key -eq 'LeftArrow') {
                if ($ctrl) {
                    while ($pos -gt 0 -and $chars[$pos - 1] -eq ' ') { $pos-- }
                    while ($pos -gt 0 -and $chars[$pos - 1] -ne ' ') { $pos-- }
                }
                elseif ($pos -gt 0) { $pos-- }
            }
            elseif ($k.Key -eq 'RightArrow') {
                if ($ctrl) {
                    while ($pos -lt $chars.Count -and $chars[$pos] -ne ' ') { $pos++ }
                    while ($pos -lt $chars.Count -and $chars[$pos] -eq ' ') { $pos++ }
                }
                elseif ($pos -lt $chars.Count) { $pos++ }
            }
            elseif ($k.Key -eq 'Home') { $pos = 0 }
            elseif ($k.Key -eq 'End') { $pos = $chars.Count }
            elseif ($k.Key -eq 'Backspace') {
                if ($pos -gt 0) { $pos--; $chars.RemoveAt($pos) }
            }
            elseif ($k.Key -eq 'Delete') {
                if ($pos -lt $chars.Count) { $chars.RemoveAt($pos) }
            }
            elseif ($ctrl -and $k.Key -eq 'U') { $chars.Clear(); $pos = 0 }
            elseif (-not [char]::IsControl($k.KeyChar)) { $chars.Insert($pos, $k.KeyChar); $pos++ }
        }
        [Console]::WriteLine()

        $text = if ($Mask) { -join $chars } else { (-join $chars).Trim() }
        if ($Required -and -not $text) {
            [Console]::WriteLine("  $E[31mОбязательное поле$E[0m")
            $Hint = ''
            continue
        }
        return $text
    }
}

# Выбор группы из списка: ↑/↓, Home/End, Enter — выбрать, Esc — отмена ($null).
# Последний пункт «+ Новая группа…» переходит к вводу названия.
function Select-Group([string[]]$Groups, [string]$Default) {
    $items = @($Groups) + '+ Новая группа…'
    $newIndex = $items.Count - 1
    $sel = [Math]::Max(0, [array]::IndexOf($items, $Default))

    while ($true) {
        [Console]::WriteLine("  $E[36m$('Группа*'.PadRight(9))$E[0m $E[90m↑↓ — выбор, Enter — подтвердить, Esc — отмена$E[0m")
        $visible = [Math]::Min($items.Count, [Math]::Max(3, [Math]::Min(10, [Console]::WindowHeight - [Console]::CursorTop - 3)))
        for ($i = 0; $i -lt $visible; $i++) { [Console]::WriteLine() }
        $top = [Console]::CursorTop - $visible
        $offset = 0
        $choice = -1
        [Console]::CursorVisible = $false

        while ($true) {
            if ($sel -lt $offset) { $offset = $sel }
            if ($sel -ge $offset + $visible) { $offset = $sel - $visible + 1 }
            $w = [Math]::Max(20, [Console]::WindowWidth) - 1
            for ($i = 0; $i -lt $visible; $i++) {
                $idx = $offset + $i
                $style = if ($idx -eq $sel) { "$E[7m" } elseif ($idx -eq $newIndex) { "$E[32m" } else { '' }
                $mark = if ($idx -eq $sel) { '   ❯ ' } else { '     ' }
                [Console]::SetCursorPosition(0, $top + $i)
                $swatch = if ($idx -eq $newIndex) { ' ' } else { (Get-Fg $script:GroupColors[$items[$idx]]) + '■' + "$E[39m" }
                [Console]::Write("$style$mark$swatch $(Format-Cell $items[$idx] ($w - 7))$E[0m")
            }

            $k = [Console]::ReadKey($true)
            $ctrl = [bool]($k.Modifiers -band [ConsoleModifiers]::Control)
            if ($k.Key -eq 'Enter') { $choice = $sel; break }
            elseif ($k.Key -eq 'Escape' -or ($ctrl -and $k.Key -eq 'C')) { break }
            elseif ($k.Key -eq 'UpArrow') { $sel = [Math]::Max(0, $sel - 1) }
            elseif ($k.Key -eq 'DownArrow') { $sel = [Math]::Min($newIndex, $sel + 1) }
            elseif ($k.Key -eq 'Home') { $sel = 0 }
            elseif ($k.Key -eq 'End') { $sel = $newIndex }
        }

        for ($i = -1; $i -lt $visible; $i++) {
            [Console]::SetCursorPosition(0, $top + $i)
            [Console]::Write("$E[2K")
        }
        [Console]::SetCursorPosition(0, $top - 1)
        [Console]::CursorVisible = $true

        if ($choice -lt 0) { return $null }
        if ($choice -ne $newIndex) {
            [Console]::WriteLine("  $E[36m$('Группа*'.PadRight(9))$E[0m $($items[$choice])")
            return $items[$choice]
        }
        $new = Read-Field 'Группа*' '' -Required -Hint 'название новой группы (Esc — назад к списку)'
        if ($null -ne $new) { return $new }
    }
}

# Форма создания/редактирования. Возвращает подключение или $null при отмене.
function Edit-Connection($Existing, $AllConnections, [string]$DefaultGroup) {
    [Console]::CursorVisible = $true
    [Console]::Write("$E[2J$E[3J$E[H")
    $title = if ($Existing) { "Редактирование: $($Existing.Name)" } else { 'Новое подключение' }
    [Console]::WriteLine(" $E[1m$title$E[0m   $E[90mEsc — отмена, Enter — дальше$E[0m`n")

    $addressText = Read-Field 'Адрес*' $Existing.Address -Required `
        -Hint 'host, user@host:port или вставьте целиком «ssh -l user -p 22 host»'
    if ($null -eq $addressText) { return $null }
    $parsed = Split-SshTarget $addressText
    if (-not $parsed.Address) { $parsed.Address = $addressText }

    $portDefault = if ($parsed.Port) { $parsed.Port } elseif ($Existing) { "$($Existing.Port)" } else { '22' }
    $port = $null
    while ($true) {
        $portText = Read-Field 'Порт' $portDefault
        if ($null -eq $portText) { return $null }
        if (-not $portText) { $portText = '22' }
        if ($portText -match '^\d+$' -and [int]$portText -in 1..65535) { $port = [int]$portText; break }
        [Console]::WriteLine("  $E[31mПорт — число 1..65535$E[0m")
    }

    $loginDefault = if ($parsed.Login) { $parsed.Login } else { $Existing.Login }
    $login = Read-Field 'Логин' $loginDefault -Hint 'необязательно (Enter — без логина, Ctrl+U — очистить)'
    if ($null -eq $login) { return $null }

    $passHint = if ($Existing.Password) { 'Enter — оставить текущий, «-» — убрать пароль' } else { 'Enter — без пароля' }
    $passText = Read-Field 'Пароль' -Mask -Hint $passHint
    if ($null -eq $passText) { return $null }
    $password = if ($passText -eq '-') { $null }
    elseif ($passText) { Protect-Password $passText }
    elseif ($Existing) { $Existing.Password }
    else { $null }

    $nameDefault = if ($Existing) { $Existing.Name } else { $parsed.Address }
    $name = Read-Field 'Название*' $nameDefault -Required
    if ($null -eq $name) { return $null }

    $groups = @($AllConnections.Group | Sort-Object -Unique)
    $groupDefault = if ($Existing) { $Existing.Group } elseif ($DefaultGroup) { $DefaultGroup } else { 'Default' }
    $group = if ($groups.Count) { Select-Group $groups $groupDefault }
    else { Read-Field 'Группа*' $groupDefault -Required -Hint 'например Work/Prod' }
    if ($null -eq $group) { return $null }

    return New-Connection @{
        name = $name; group = $group; address = $parsed.Address
        port = $port; login = $login; password = $password
    }
}

#endregion

#region SSH

# Экран перед подключением: логин и пароль. Возвращает @{ Login; Password } или $null (Esc).
function Read-Credentials($Conn) {
    [Console]::TreatControlCAsInput = $true
    [Console]::CursorVisible = $true
    [Console]::Write("$E[2J$E[3J$E[H")
    [Console]::WriteLine(" $E[1mПодключение: $($Conn.Name)$E[0m   $E[90m$($Conn.Address):$($Conn.Port)   Esc — в меню$E[0m`n")

    $login = Read-Field 'Логин' $Conn.Login -Hint 'Enter — продолжить; пустое поле — без логина'
    if ($null -eq $login) { return $null }

    $passHint = if ($Conn.Password) { 'Enter — сохранённый пароль' } else { 'Enter — без пароля' }
    $password = Read-Field 'Пароль' -Mask -Hint $passHint
    if ($null -eq $password) { return $null }
    if (-not $password -and $Conn.Password) {
        try { $password = Unprotect-Password $Conn.Password }
        catch {
            $script:Status = 'Сохранённый пароль не расшифровать (другой пользователь или ПК?) — введите его вручную или задайте через F2'
            return $null
        }
    }
    return @{ Login = $login; Password = $password }
}

# ВАЖНО: вызывать только отдельной инструкцией, не внутри if/присваивания —
# иначе PowerShell перехватит stdout ssh и вывод сервера не появится на экране.
# Результат — в $script:SessionFinished.
# Открывает ssh в НОВОЙ вкладке Windows Terminal (если wt.exe нет — в отдельном окне консоли).
# Пароль в командную строку попадает только в зашифрованном DPAPI виде и расшифровывается внутри новой сессии.
function Start-TerminalSsh($Conn) {
    $sshArgs = @('-o', 'ConnectTimeout=10')
    $setup = @()
    if ($Conn.Password) {
        $sshArgs += '-o', 'StrictHostKeyChecking=accept-new', '-o', 'NumberOfPasswordPrompts=1'
        $q0 = { param([string]$s) "'" + $s.Replace("'", "''") + "'" }
        $askPass = "@echo off`r`nsetlocal EnableDelayedExpansion`r`necho(!SSHMENU_PASS!`r`n"
        if (-not (Test-Path -LiteralPath $AskPassPath) -or (Get-Content -LiteralPath $AskPassPath -Raw) -ne $askPass) {
            [IO.File]::WriteAllText($AskPassPath, $askPass, [Text.Encoding]::ASCII)
        }
        $setup += if ($Conn.Password.StartsWith($PassPrefix)) {
            "`$env:SSHMENU_PASS = ConvertTo-SecureString $(& $q0 $Conn.Password.Substring($PassPrefix.Length)) | ConvertFrom-SecureString -AsPlainText"
        }
        else { "`$env:SSHMENU_PASS = $(& $q0 $Conn.Password)" }
        $setup += "`$env:SSH_ASKPASS = $(& $q0 $AskPassPath)"
        $setup += "`$env:SSH_ASKPASS_REQUIRE = 'force'"
    }
    if ($Conn.Login) { $sshArgs += '-l', $Conn.Login }
    $sshArgs += '-p', "$($Conn.Port)", $Conn.Address

    $q = { param([string]$s) "'" + $s.Replace("'", "''") + "'" }
    $script = @(
        $setup
        "`$Host.UI.RawUI.WindowTitle = $(& $q "SSH · $($Conn.Name)")"
        "& ssh.exe $(($sshArgs | ForEach-Object { & $q $_ }) -join ' ')"
        '$code = $LASTEXITCODE'
        'if ($code -eq 255) { Write-Host "`nСоединение не удалось (код 255). Проверьте адрес, порт, логин, пароль и сеть (VPN)." -ForegroundColor Red; Write-Host "Любая клавиша — закрыть"; [void][Console]::ReadKey($true) }'
    ) -join '; '
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $pwsh = (Get-Command pwsh.exe).Source

    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) {
        Start-Process -FilePath $wt.Source -ArgumentList @('-w', '0', 'new-tab', '--title', "SSH · $($Conn.Name)", $pwsh, '-NoLogo', '-NoProfile', '-EncodedCommand', $encoded) | Out-Null
        return 'вкладка Windows Terminal'
    }
    $psi = [Diagnostics.ProcessStartInfo]::new($env:ComSpec)
    $psi.Arguments = "/c start `"`" `"$pwsh`" -NoLogo -NoProfile -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void][Diagnostics.Process]::Start($psi)
    return 'окно консоли'
}

function Invoke-Ssh($Conn, [string]$Login, [string]$Password) {
    $script:SessionFinished = $false
    $script:Status = ''
    $pass = $Password

    $sshArgs = @('-o', 'ConnectTimeout=10')
    if ($pass) { $sshArgs += '-o', 'StrictHostKeyChecking=accept-new', '-o', 'NumberOfPasswordPrompts=1' }
    if ($Login) { $sshArgs += '-l', $Login }
    $sshArgs += '-p', "$($Conn.Port)", $Conn.Address

    [Console]::TreatControlCAsInput = $false
    [Console]::CursorVisible = $true
    [Console]::Write("$E[2J$E[3J$E[H")
    $Host.UI.RawUI.WindowTitle = "SSH · $($Conn.Name)"
    [Console]::WriteLine("$E[90mssh $($sshArgs -join ' ')$(if ($pass) { '   (с паролем)' })$E[0m")

    if ($pass) {
        $askPass = "@echo off`r`nsetlocal EnableDelayedExpansion`r`necho(!SSHMENU_PASS!`r`n"
        if (-not (Test-Path -LiteralPath $AskPassPath) -or (Get-Content -LiteralPath $AskPassPath -Raw) -ne $askPass) {
            [IO.File]::WriteAllText($AskPassPath, $askPass, [Text.Encoding]::ASCII)
        }
        $env:SSHMENU_PASS = $pass
        $env:SSH_ASKPASS = $AskPassPath
        $env:SSH_ASKPASS_REQUIRE = 'force'
    }
    try {
        & ssh.exe @sshArgs
        $code = $LASTEXITCODE
    }
    finally {
        Remove-Item Env:SSHMENU_PASS, Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
        $pass = $null
    }

    if ($code -eq 255) {
        while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
        [Console]::WriteLine("`n$E[31mСоединение не удалось (код 255).$E[0m Проверьте адрес, порт, логин, пароль и сеть (VPN).")
        [Console]::WriteLine('Любая клавиша — вернуться в меню')
        [void][Console]::ReadKey($true)
        $script:Status = "Не удалось подключиться: $($Conn.Name)"
        return
    }
    $script:SessionFinished = $true
}

#endregion

#region Меню

function Get-Rows($List, [string]$Filter) {
    $words = @($Filter -split '\s+' | Where-Object { $_ })
    $matched = $List | Where-Object {
        $hay = "$($_.Name) $($_.Group) $($_.Address) $($_.Login)"
        foreach ($w in $words) {
            if ($hay.IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        }
        return $true
    } | Sort-Object Group, Name

    $rows = [Collections.Generic.List[object]]::new()
    $rows.Add([pscustomobject]@{ Kind = 'new'; Conn = $null; Group = $null })
    $lastGroup = $null
    foreach ($c in $matched) {
        if ($c.Group -ne $lastGroup) {
            $rows.Add([pscustomobject]@{ Kind = 'group'; Conn = $null; Group = $c.Group })
            $lastGroup = $c.Group
        }
        $rows.Add([pscustomobject]@{ Kind = 'conn'; Conn = $c; Group = $c.Group })
    }
    return , $rows
}

function Move-Selection($Rows, [int]$Sel, [int]$Step) {
    $dir = [Math]::Sign($Step)
    $target = [Math]::Max(0, [Math]::Min($Rows.Count - 1, $Sel + $Step))
    while ($target -ge 0 -and $target -lt $Rows.Count -and $Rows[$target].Kind -eq 'group') { $target += $dir }
    if ($target -lt 0 -or $target -ge $Rows.Count) { return $Sel }
    return $target
}

function Format-Cell([string]$Text, [int]$Width) {
    if ($Width -le 0) { return '' }
    if ($Text.Length -gt $Width) { return $Text.Substring(0, [Math]::Max(0, $Width - 1)) + '…' }
    return $Text.PadRight($Width)
}

function Show-Menu($Rows, [int]$Sel, [int]$Offset, [int]$BodyHeight, [string]$Filter, [int]$Total) {
    $w = [Math]::Max(30, [Console]::WindowWidth) - 1
    $conns = @($Rows | Where-Object Kind -eq 'conn')
    $nameW = [Math]::Min(28, [Math]::Max(8, ($conns | ForEach-Object { $_.Conn.Name.Length } | Measure-Object -Maximum).Maximum))
    $addrW = [Math]::Min(26, [Math]::Max(10, ($conns | ForEach-Object { "$($_.Conn.Address):$($_.Conn.Port)".Length } | Measure-Object -Maximum).Maximum))

    $sb = [Text.StringBuilder]::new("$E[H")
    $line = {
        param([string]$Text, [string]$Style = '', [int]$Width = 0)
        if (-not $Width) { $Width = $w }
        [void]$sb.Append("$Style$(Format-Cell $Text $Width)$E[0m`n")
    }

    & $line " SSH  · подключений: $Total" "$E[1m"
    if ($Filter) { & $line " Поиск: $Filter▏" "$E[33m" } else { & $line ' Печатайте для поиска' "$E[90m" }
    & $line ('─' * $w) "$E[90m"

    for ($i = $Offset; $i -lt $Offset + $BodyHeight; $i++) {
        if ($i -ge $Rows.Count) { & $line ''; continue }
        $row = $Rows[$i]
        $selected = $i -eq $Sel
        $cursor = if ($selected) { ' ❯ ' } else { '   ' }
        switch ($row.Kind) {
            'new' { & $line "$cursor+ Новое подключение" $(if ($selected) { "$E[7m" } else { "$E[32m" }) }
            'group' {
                $gFg = Get-Fg $script:GroupColors[$row.Group]
                & $line " ▾ $($row.Group)" $(if ($gFg) { "$E[1m$gFg" } else { "$E[33;1m" })
            }
            'conn' {
                $c = $row.Conn
                $gFg = Get-Fg $script:GroupColors[$c.Group]
                [void]$sb.Append($(if ($gFg) { "$gFg▌$E[0m" } else { ' ' }))
                $text = $cursor + '  ' + (Format-Cell $c.Name $nameW) + '  ' +
                (Format-Cell "$($c.Address):$($c.Port)" $addrW) + '  ' +
                $(if ($c.Password) { '[pw]  ' } else { '      ' }) + $c.Login
                & $line $text $(if ($selected) { "$E[7m" } else { '' }) ($w - 1)
            }
        }
    }

    & $line ('─' * $w) "$E[90m"
    if ($script:Status) {
        [void]$sb.Append("$E[31m$(Format-Cell " $script:Status" $w)$E[0m")
    }
    else {
        [void]$sb.Append("$E[90m$(Format-Cell ' ↑↓ выбор  Enter подключить  Ins/Ctrl+N новое  F2/Ctrl+E изменить  F3 цвет  F5 GUI-меню  Del удалить  Esc' $w)$E[0m")
    }
    [Console]::Write($sb.ToString())
}

function Start-Menu {
    $list = Read-Connections
    $noColor = @($list.Group | Sort-Object -Unique | Where-Object { -not $script:GroupColors.ContainsKey($_) })
    if ($noColor.Count -or @($list | Where-Object { $_.Password -and -not $_.Password.StartsWith($PassPrefix) }).Count) {
        Save-Connections $list
    }

    $filter = ''
    $sel = if ($list.Count) { 2 } else { 0 }
    $offset = 0
    $selectConn = $null
    $lastSize = ''

    while ($true) {
        $Host.UI.RawUI.WindowTitle = 'SSH'
        [Console]::TreatControlCAsInput = $true
        [Console]::CursorVisible = $false
        $size = "$([Console]::WindowWidth)x$([Console]::WindowHeight)"
        if ($size -ne $lastSize) { [Console]::Write("$E[2J"); $lastSize = $size }

        $rows = Get-Rows $list $filter
        if ($selectConn) {
            for ($i = 0; $i -lt $rows.Count; $i++) { if ($rows[$i].Conn -eq $selectConn) { $sel = $i } }
            $selectConn = $null
        }
        $sel = [Math]::Max(0, [Math]::Min($rows.Count - 1, $sel))
        if ($rows[$sel].Kind -eq 'group') { $sel = Move-Selection $rows $sel 1 }

        $bodyHeight = [Math]::Max(3, [Console]::WindowHeight - 5)
        if ($sel -lt $offset) { $offset = $sel }
        if ($sel -ge $offset + $bodyHeight) { $offset = $sel - $bodyHeight + 1 }
        if ($sel -le 1) { $offset = 0 }
        $offset = [Math]::Max(0, [Math]::Min($offset, $rows.Count - 1))

        Show-Menu $rows $sel $offset $bodyHeight $filter $list.Count
        $k = [Console]::ReadKey($true)
        $ctrl = [bool]($k.Modifiers -band [ConsoleModifiers]::Control)
        $current = $rows[$sel]
        $script:Status = ''

        $action = $null
        if ($ctrl -and $k.Key -in 'C', 'Q') { return }
        elseif ($ctrl -and $k.Key -eq 'N') { $action = 'new' }
        elseif ($ctrl -and $k.Key -eq 'E') { $action = 'edit' }
        elseif ($k.Key -eq 'Insert') { $action = 'new' }
        elseif ($k.Key -eq 'F2') { $action = 'edit' }
        elseif ($k.Key -eq 'F3' -or ($ctrl -and $k.Key -eq 'K')) { $action = 'color' }
        elseif ($k.Key -eq 'F5') { $action = 'gui' }
        elseif ($k.Key -eq 'Delete') { $action = 'delete' }
        elseif ($k.Key -eq 'Enter') { $action = if ($current.Kind -eq 'new') { 'new' } else { 'files' } }
        elseif ($k.Key -eq 'UpArrow') { $sel = Move-Selection $rows $sel -1 }
        elseif ($k.Key -eq 'DownArrow') { $sel = Move-Selection $rows $sel 1 }
        elseif ($k.Key -eq 'PageUp') { $sel = Move-Selection $rows $sel (-$bodyHeight) }
        elseif ($k.Key -eq 'PageDown') { $sel = Move-Selection $rows $sel $bodyHeight }
        elseif ($k.Key -eq 'Home') { $sel = 0 }
        elseif ($k.Key -eq 'End') { $sel = Move-Selection $rows ($rows.Count) -1 }
        elseif ($k.Key -eq 'Escape') {
            if ($filter) { $filter = '' } else { return }
        }
        elseif ($k.Key -eq 'Backspace') {
            if ($filter) { $filter = $filter.Substring(0, $filter.Length - 1) }
        }
        elseif (-not $ctrl -and -not [char]::IsControl($k.KeyChar)) {
            $filter += $k.KeyChar
            $sel = if ((Get-Rows $list $filter).Count -gt 1) { 2 } else { 0 }
        }

        if ($action -in 'edit', 'delete', 'connect', 'color', 'files' -and $current.Kind -ne 'conn') {
            if ($action -eq 'edit') { $action = 'new' } else { continue }
        }

        switch ($action) {
            'new' {
                $c = Edit-Connection $null $list $current.Group
                [Console]::Write("$E[2J")
                if ($c) {
                    $list.Add($c)
                    Save-Connections $list
                    $filter = ''
                    $selectConn = $c
                    Invoke-Ssh $c $c.Login (Unprotect-Password $c.Password)
                    if ($script:SessionFinished) { return }
                    [Console]::Write("$E[2J")
                }
            }
            'edit' {
                $c = Edit-Connection $current.Conn $list $null
                [Console]::Write("$E[2J")
                if ($c) {
                    $list[$list.IndexOf($current.Conn)] = $c
                    Save-Connections $list
                    $selectConn = $c
                }
            }
            'color' {
                $g = $current.Conn.Group
                $picked = Select-Color $g $script:GroupColors[$g]
                [Console]::Write("$E[2J")
                if ($picked) {
                    $script:GroupColors[$g] = $picked
                    Save-Connections $list
                }
                $selectConn = $current.Conn
            }
            'files' {
                $c = $current.Conn
                $script:Status = "Открыть «$($c.Name)»:  T/Enter — терминал здесь   G — GUI-рабочий стол   W — вкладка Windows Terminal   Esc — отмена"
                Show-Menu $rows $sel $offset $bodyHeight $filter $list.Count
                $answer = [Console]::ReadKey($true)
                $script:Status = ''
                if ($answer.Key -in 'T', 'Enter') {
                    $cred = Read-Credentials $c
                    if ($cred) {
                        Invoke-Ssh $c $cred.Login $cred.Password
                        if ($script:SessionFinished) { return }
                    }
                    [Console]::Write("$E[2J")
                    $selectConn = $c
                    continue
                }
                if ($answer.Key -eq 'W') {
                    $where = Start-TerminalSsh $c
                    $script:Status = "Открыто ($where): $($c.Name)"
                    $selectConn = $c
                    continue
                }
                if ($answer.Key -ne 'G') { $selectConn = $c; continue }
                $guiArgs = @('-NoLogo','-NoProfile','-STA','-WindowStyle','Hidden','-File',(Join-Path $PSScriptRoot 'ssh-desktop.ps1'),
                    '-ConfigPath',$ConfigPath,'-Name',$c.Name,'-Address',$c.Address,'-Port',"$($c.Port)")
                if ($c.Login) { $guiArgs += '-Login',$c.Login }
                Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList $guiArgs | Out-Null
                $script:Status = "Рабочий стол открыт: $($c.Name)"
                $selectConn = $c
            }
            'gui' {
                Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList @('-NoLogo','-NoProfile','-STA','-WindowStyle','Hidden','-File',(Join-Path $PSScriptRoot 'ssh-menu-gui.ps1'),'-ConfigPath',$ConfigPath) | Out-Null
                $script:Status = 'GUI-меню открыто'
                $selectConn = $current.Conn
            }
            'delete' {
                $script:Status = "Удалить «$($current.Conn.Name)»? Y/Enter — да, любая другая клавиша — нет"
                Show-Menu $rows $sel $offset $bodyHeight $filter $list.Count
                $answer = [Console]::ReadKey($true)
                $script:Status = ''
                if ($answer.Key -in 'Y', 'Enter') {
                    [void]$list.Remove($current.Conn)
                    Save-Connections $list
                }
            }
            'connect' {
                $cred = Read-Credentials $current.Conn
                if ($cred) {
                    Invoke-Ssh $current.Conn $cred.Login $cred.Password
                    if ($script:SessionFinished) { return }
                }
                $selectConn = $current.Conn
                [Console]::Write("$E[2J")
            }
        }
    }
}

#endregion

# Подключён через «. ssh-menu.ps1» (например, из ssh-menu-gui.ps1) — только функции, без запуска меню.
if ($MyInvocation.InvocationName -eq '.') { return }

if ($CreateShortcut) {
    $lnkPath = Join-Path $PSScriptRoot 'ssh-menu.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = (Get-Command wt.exe).Source
    $lnk.Arguments = "-w new --title SSH pwsh.exe -NoLogo -NoProfile -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = (Get-Command pwsh.exe).Source + ',0'
    $lnk.Save()
    Write-Host "Ярлык создан: $lnkPath"
    exit 0
}

try {
    Start-Menu
}
finally {
    [Console]::TreatControlCAsInput = $false
    [Console]::CursorVisible = $true
    [Console]::Write("$E[0m$E[2J$E[3J$E[H")
}
exit 0
