#Requires -Version 7.0
<#
.SYNOPSIS
    «Рабочий стол» сервера: иконки файлов и папок в свободной раскладке, окна папок, виртуальные папки.

.DESCRIPTION
    Работает через sftp.exe (каждое действие — отдельный вызов sftp, пароль — через SSH_ASKPASS).
    Виртуальные папки, ярлыки и положение иконок хранятся ТОЛЬКО на этом ПК (папка desktops рядом
    со скриптом) — на сервере они ничего не меняют. Сервер меняют лишь явные команды меню с пометкой
    «на сервере» (загрузка, переименование, удаление, новая папка) и только после подтверждения.

.EXAMPLE
    pwsh -STA -File ssh-desktop.ps1 -Address 192.168.56.70 -Port 2222 -Login user
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'connections.yml'),
    [string]$Name,
    [string]$Address,
    [int]$Port = 22,
    [string]$Login,
    [string]$StorePath,
    [string]$Screenshot,   # для проверки: снимок рабочего стола и выход
    [string]$TestRemote,   # для проверки: открыть окно сервера по этому пути при старте
    [string]$TestVirtual,  # для проверки: открыть окно виртуальной папки с этим Id при старте
    [string]$TestView      # для проверки: режим отображения large|small|list
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
if (-not ('Win32Owner' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
public class Win32Owner : System.Windows.Forms.IWin32Window {
    public System.IntPtr Handle { get; set; }
}
'@
}

# Хранилище подключений, DPAPI, цвета групп — из консольной версии.
. (Join-Path $PSScriptRoot 'ssh-menu.ps1') -ConfigPath $ConfigPath

#region Подключение и хранилище рабочего стола

$allConns = Read-Connections
$script:Conn = @($allConns | Where-Object { $Address -and $_.Address -eq $Address -and $_.Port -eq $Port -and $_.Login -eq [string]$Login }) | Select-Object -First 1
if (-not $script:Conn -and $Name) { $script:Conn = @($allConns | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1 }
if (-not $script:Conn) {
    [void][Windows.MessageBox]::Show('Подключение не найдено в connections.yml. Запустите рабочий стол из ssh-menu-gui (кнопка «Файлы»).', 'SSH', 'OK', 'Warning')
    exit 1
}

$script:GroupHex = $script:GroupColors[$script:Conn.Group]
if (-not $script:GroupHex) { $script:GroupHex = '#5b8def' }

if (-not $StorePath) {
    $key = ("$($script:Conn.Login)@$($script:Conn.Address)_$($script:Conn.Port)") -replace '[^\w.@-]', '_'
    $StorePath = Join-Path $PSScriptRoot "desktops\$key.json"
}

$script:Items = [Collections.Generic.List[hashtable]]::new()
$script:SavedWindows = @()

function Read-Store {
    $script:Items.Clear()
    if (Test-Path -LiteralPath $StorePath) {
        $data = Get-Content -LiteralPath $StorePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        foreach ($i in @($data.items)) {
            $script:Items.Add(@{
                    Id = [string]$i.Id; Kind = [string]$i.Kind; Name = [string]$i.Name; Parent = $i.Parent
                    X = $i.X; Y = $i.Y; Path = $i.Path; IsDir = [bool]$i.IsDir; Color = $i.Color; View = $i.View
                })
        }
        if ($data.view -and $script:ViewNames.Contains([string]$data.view)) { $script:DesktopView = [string]$data.view }
        if ($data.remoteView -and $script:ViewNames.Contains([string]$data.remoteView)) { $script:RemoteView = [string]$data.remoteView }
        if ($data.sortKey -and $script:SortNames.Contains([string]$data.sortKey)) { $script:SortKey = [string]$data.sortKey }
        $script:SortDesc = [bool]$data.sortDesc
        $script:SavedWindows = @($data.windows | Where-Object { $_ })
    }
    else {
        $script:Items.Add(@{ Id = (New-Id); Kind = 'link'; Name = 'Сервер'; Parent = $null; X = 24; Y = 24; Path = '.'; IsDir = $true; Color = $null })
    }
}

function Save-Store {
    $dir = Split-Path -Parent $StorePath
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $json = @{ version = 2; view = $script:DesktopView; remoteView = $script:RemoteView; sortKey = $script:SortKey; sortDesc = [bool]$script:SortDesc; windows = @($script:SavedWindows); items = @($script:Items) } | ConvertTo-Json -Depth 6
    $tmp = "$StorePath.tmp"
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $StorePath -Force
}

function New-Id { [guid]::NewGuid().ToString('N').Substring(0, 8) }
function Get-VItem([string]$Id) { $script:Items | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }

function Test-Descendant([string]$Id, [string]$AncestorId) {
    while ($Id) {
        if ($Id -eq $AncestorId) { return $true }
        $Id = (Get-VItem $Id).Parent
    }
    return $false
}

#endregion

#region sftp

$script:Ops = [Collections.Generic.List[hashtable]]::new()

# Аргумент команды sftp: в кавычках, с экранированием " \ и символов шаблонов * ? [ ].
function ConvertTo-SftpArg([string]$s) { '"' + ($s -replace '([\\"\[\]\*\?])', '\$1') + '"' }

# Запускает sftp.exe с набором команд (stdin) и по завершении вызывает $Done($result, $State).
# Один вызов = одно соединение: sftp при выводе в pipe буферизует вывод до выхода, постоянный сеанс невозможен.
function Start-SftpOp([string[]]$Commands, [scriptblock]$Done, $State) {
    $pass = $null
    if ($script:Conn.Password) { try { $pass = Unprotect-Password $script:Conn.Password } catch { } }

    $psi = [Diagnostics.ProcessStartInfo]::new('sftp.exe')
    foreach ($a in @('-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new', '-P', "$($script:Conn.Port)")) { $psi.ArgumentList.Add($a) }
    if ($pass) { $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('NumberOfPasswordPrompts=1') }
    else { $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('BatchMode=yes') }
    $psi.ArgumentList.Add($(if ($script:Conn.Login) { "$($script:Conn.Login)@$($script:Conn.Address)" } else { $script:Conn.Address }))
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($pass) {
        $askPass = "@echo off`r`nsetlocal EnableDelayedExpansion`r`necho(!SSHMENU_PASS!`r`n"
        if (-not (Test-Path -LiteralPath $AskPassPath) -or (Get-Content -LiteralPath $AskPassPath -Raw) -ne $askPass) {
            [IO.File]::WriteAllText($AskPassPath, $askPass, [Text.Encoding]::ASCII)
        }
        $psi.EnvironmentVariables['SSHMENU_PASS'] = $pass
        $psi.EnvironmentVariables['SSH_ASKPASS'] = $AskPassPath
        $psi.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
    }

    $p = [Diagnostics.Process]::Start($psi)
    $op = @{ P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); Done = $Done; State = $State }
    try {
        $p.StandardInput.Write((($Commands + 'bye') -join "`n") + "`n")
        $p.StandardInput.Close()
    }
    catch { }
    $script:Ops.Add($op)
    Update-Busy
}

# Выполняет команду на сервере через ssh.exe (нужно для рекурсивного удаления и поиска — в sftp их нет).
function Start-SshExec([string]$Command, [scriptblock]$Done, $State) {
    $pass = $null
    if ($script:Conn.Password) { try { $pass = Unprotect-Password $script:Conn.Password } catch { } }
    $psi = [Diagnostics.ProcessStartInfo]::new('ssh.exe')
    foreach ($a in @('-T', '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new', '-p', "$($script:Conn.Port)")) { $psi.ArgumentList.Add($a) }
    if ($pass) { $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('NumberOfPasswordPrompts=1') }
    else { $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('BatchMode=yes') }
    $psi.ArgumentList.Add($(if ($script:Conn.Login) { "$($script:Conn.Login)@$($script:Conn.Address)" } else { $script:Conn.Address }))
    $psi.ArgumentList.Add($Command)
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($pass) {
        $askPass = "@echo off`r`nsetlocal EnableDelayedExpansion`r`necho(!SSHMENU_PASS!`r`n"
        if (-not (Test-Path -LiteralPath $AskPassPath) -or (Get-Content -LiteralPath $AskPassPath -Raw) -ne $askPass) {
            [IO.File]::WriteAllText($AskPassPath, $askPass, [Text.Encoding]::ASCII)
        }
        $psi.EnvironmentVariables['SSHMENU_PASS'] = $pass
        $psi.EnvironmentVariables['SSH_ASKPASS'] = $AskPassPath
        $psi.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
    }
    $p = [Diagnostics.Process]::Start($psi)
    $op = @{ P = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); Done = $Done; State = $State }
    try { $p.StandardInput.Close() } catch { }
    $script:Ops.Add($op)
    Update-Busy
}

# Аргумент для оболочки сервера: в одинарных кавычках.
function ConvertTo-ShellArg([string]$s) { "'" + $s.Replace("'", "'\''") + "'" }

# Защита от удаления «слишком близко к корню»: только абсолютные пути глубиной от 2 и без . / ..
function Test-SafeRemotePath([string]$p) {
    if (-not $p -or -not $p.StartsWith('/')) { return $false }
    $parts = @($p.Split('/') | Where-Object { $_ })
    if ($parts.Count -lt 2) { return $false }
    if ($parts -contains '..' -or $parts -contains '.') { return $false }
    return $true
}

# Текст ошибки из stderr sftp без служебных строк; $null — ошибок нет.
function Get-SftpError($Res) {
    $lines = @($Res.Err -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^(Connected to |Warning: )' })
    if ($lines.Count) { return ($lines -join ' ') }
    if ($Res.Code -ne 0) { return "sftp завершился с кодом $($Res.Code)" }
    return $null
}

# Разбор вывода «pwd» + «ls -la».
function ConvertFrom-SftpLs([string]$Text) {
    $entries = [Collections.Generic.List[hashtable]]::new()
    $cwd = $null
    foreach ($line in $Text -split "`r?`n") {
        if ($line -match '^Remote working directory:\s*(.+?)\s*$') { $cwd = $Matches[1]; continue }
        if ($line -match '^(?<t>[-dlcbps])[-rwxstST*]{9}[+.@]?\s+[\d?]+\s+\S+\s+\S+\s+(?<size>\d+)\s+(?<mon>\S+)\s+(?<day>\d+)\s+(?<tm>\S+)\s+(?<name>.+?)\s*$') {
            $name = $Matches['name']
            $isLink = $Matches['t'] -eq 'l'
            if ($isLink -and $name -match '^(.+?) -> ') { $name = $Matches[1] }
            if ($name -in '.', '..') { continue }
            $m = $Matches.Clone()
            $date = $null
            try {
                $ci = [Globalization.CultureInfo]::InvariantCulture
                if ($m['tm'] -match ':') {
                    $date = [datetime]::ParseExact("$($m['day']) $($m['mon']) $((Get-Date).Year) $($m['tm'])", 'd MMM yyyy H:mm', $ci)
                    if ($date -gt (Get-Date).AddDays(1)) { $date = $date.AddYears(-1) }
                }
                else { $date = [datetime]::ParseExact("$($m['day']) $($m['mon']) $($m['tm'])", 'd MMM yyyy', $ci) }
            }
            catch { }
            $entries.Add(@{ Name = $name; IsDir = ($m['t'] -eq 'd' -or $isLink); IsLink = $isLink; Size = [long]$m['size']; Date = $date })
        }
    }
    return @{ Cwd = $cwd; Entries = $entries }
}

function Join-Remote([string]$Dir, [string]$Leaf) { if ($Dir -eq '/') { "/$Leaf" } else { "$Dir/$Leaf" } }

#endregion

#region XAML (оформление в духе Linux Mint — Mint-Y-Dark)

$menuStylesXaml = @'
<Style x:Key="NoBtn" TargetType="RepeatButton">
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="BarThumb" TargetType="Thumb">
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Thumb">
        <Border x:Name="t" Background="#6A6A6A" CornerRadius="4" Margin="2"/>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="#8FA876"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ScrollBar">
  <Setter Property="Width" Value="12"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ScrollBar">
        <Grid Background="#18000000">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Style="{StaticResource NoBtn}"/></Track.DecreaseRepeatButton>
            <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Style="{StaticResource NoBtn}"/></Track.IncreaseRepeatButton>
            <Track.Thumb><Thumb Style="{StaticResource BarThumb}"/></Track.Thumb>
          </Track>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="Orientation" Value="Horizontal">
            <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
            <Setter Property="Width" Value="Auto"/>
            <Setter Property="Height" Value="12"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="ContextMenu">
  <Setter Property="Foreground" Value="#DADADA"/>
  <Setter Property="HasDropShadow" Value="False"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="ContextMenu">
        <Border Background="#2F2F2F" BorderBrush="#1A1A1A" BorderThickness="1" CornerRadius="5" Padding="3">
          <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
        </Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="MenuItem">
  <Setter Property="Foreground" Value="#DADADA"/>
  <Setter Property="Padding" Value="6,5"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="MenuItem">
        <Grid>
          <Border x:Name="bd" CornerRadius="3" Background="Transparent" Padding="{TemplateBinding Padding}">
            <Grid MinWidth="190">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="22"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="18"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="chk" Text="&#x2713;" Visibility="Collapsed" Foreground="#8FA876" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              <ContentPresenter Grid.Column="1" ContentSource="Header" RecognizesAccessKey="False" VerticalAlignment="Center"/>
              <TextBlock Grid.Column="2" Text="{TemplateBinding InputGestureText}" Foreground="#8A8A8A" Margin="24,0,0,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="arrow" Grid.Column="3" Text="&#x25B8;" Visibility="Collapsed" HorizontalAlignment="Right" VerticalAlignment="Center"/>
            </Grid>
          </Border>
          <Popup x:Name="pop" Placement="Right" IsOpen="{TemplateBinding IsSubmenuOpen}" AllowsTransparency="True" Focusable="False">
            <Border Background="#2F2F2F" BorderBrush="#1A1A1A" BorderThickness="1" CornerRadius="5" Padding="3">
              <StackPanel IsItemsHost="True"/>
            </Border>
          </Popup>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="Role" Value="SubmenuHeader"><Setter TargetName="arrow" Property="Visibility" Value="Visible"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="chk" Property="Visibility" Value="Visible"/></Trigger>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="bd" Property="Background" Value="#8FA876"/><Setter Property="Foreground" Value="White"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Foreground" Value="#7A7A7A"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="{x:Static MenuItem.SeparatorStyleKey}" TargetType="Separator">
  <Setter Property="Template">
    <Setter.Value><ControlTemplate TargetType="Separator"><Border Height="1" Background="#454545" Margin="6,3"/></ControlTemplate></Setter.Value>
  </Setter>
</Style>
'@

$stylesXaml = @'
<Style TargetType="Button">
  <Setter Property="Foreground" Value="#DADADA"/>
  <Setter Property="Background" Value="#454545"/>
  <Setter Property="BorderBrush" Value="#1F1F1F"/>
  <Setter Property="Padding" Value="14,6"/>
  <Setter Property="Margin" Value="0,0,6,0"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
  <Setter Property="Background" Value="#8FA876"/>
  <Setter Property="BorderBrush" Value="#7B9362"/>
  <Setter Property="Foreground" Value="White"/>
</Style>
<Style x:Key="IconBtn" TargetType="Button">
  <Setter Property="Foreground" Value="#DADADA"/>
  <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
  <Setter Property="FontSize" Value="12"/>
  <Setter Property="Width" Value="30"/>
  <Setter Property="Height" Value="26"/>
  <Setter Property="Margin" Value="0,0,2,0"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="Transparent" CornerRadius="4">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#4F4F4F"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#3A3A3A"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="CloseBtn" TargetType="Button" BasedOn="{StaticResource IconBtn}">
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="Transparent" CornerRadius="4">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#CC4B4B"/><Setter Property="Foreground" Value="White"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="SideBtn" TargetType="Button">
  <Setter Property="Foreground" Value="#DADADA"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Margin" Value="0,0,0,1"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="Transparent" CornerRadius="4" Padding="8,6">
          <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#3E3E3E"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="TaskBtn" TargetType="Button">
  <Setter Property="Foreground" Value="#E4E4E4"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Margin" Value="0,0,4,0"/>
  <Setter Property="MaxWidth" Value="220"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="#3A3A3A" BorderBrush="#8FA876" BorderThickness="0,0,0,2" CornerRadius="3" Padding="12,6" VerticalAlignment="Center">
          <TextBlock Text="{TemplateBinding Content}" TextTrimming="CharacterEllipsis"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#4A4A4A"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style TargetType="TextBox">
  <Setter Property="Background" Value="#2B2B2B"/>
  <Setter Property="Foreground" Value="#DADADA"/>
  <Setter Property="BorderBrush" Value="#1F1F1F"/>
  <Setter Property="CaretBrush" Value="#DADADA"/>
  <Setter Property="SelectionBrush" Value="#8FA876"/>
  <Setter Property="Padding" Value="8,4"/>
  <Setter Property="VerticalContentAlignment" Value="Center"/>
</Style>
<Style TargetType="CheckBox">
  <Setter Property="Foreground" Value="#B7B7B7"/>
  <Setter Property="VerticalAlignment" Value="Center"/>
</Style>
'@ + $menuStylesXaml

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1280" Height="800" MinWidth="720" MinHeight="480"
        WindowStartupLocation="CenterScreen" Background="#161C17" Foreground="#DADADA"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
    <!--STYLES-->
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid x:Name="Stage" Grid.Row="0" ClipToBounds="True">
      <Grid.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
          <GradientStop Color="#2A3A2C" Offset="0"/>
          <GradientStop Color="#18211A" Offset="0.55"/>
          <GradientStop Color="#0F1511" Offset="1"/>
        </LinearGradientBrush>
      </Grid.Background>
      <Rectangle x:Name="Glow"/>
      <Canvas x:Name="Desktop" Background="Transparent"/>
      <Canvas x:Name="Floating"/>
      <Canvas x:Name="Overlay" IsHitTestVisible="False"/>
    </Grid>
    <Border Grid.Row="1" Background="#F2252525" BorderBrush="#141414" BorderThickness="0,1,0,0" Height="42">
      <DockPanel Margin="6,0,10,0">
        <Border x:Name="StartBtn" DockPanel.Dock="Left" Width="42" Height="34" CornerRadius="4" Background="Transparent" Cursor="Hand" Margin="0,0,10,0" ToolTip="Меню">
          <Border Width="28" Height="28" CornerRadius="7" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                <GradientStop Color="#A9C98B" Offset="0"/><GradientStop Color="#6E9450" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="&#x2630;" Foreground="White" FontSize="16" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
        </Border>
        <TextBlock x:Name="Clock" DockPanel.Dock="Right" Foreground="#E4E4E4" FontSize="14" VerticalAlignment="Center" Margin="14,0,0,0"/>
        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="14,0,0,0">
          <Ellipse x:Name="Dot" Width="9" Height="9" Margin="0,0,7,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="Caption" Foreground="#C4C4C4" VerticalAlignment="Center"/>
        </StackPanel>
        <TextBlock x:Name="Status" DockPanel.Dock="Right" MaxWidth="440" TextTrimming="CharacterEllipsis" Foreground="#9A9A9A" FontSize="12" VerticalAlignment="Center" Margin="14,0,0,0"/>
        <StackPanel x:Name="Tasks" Orientation="Horizontal" VerticalAlignment="Center"/>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

$windowXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="720" Height="480" CornerRadius="8" Background="#383838" BorderBrush="#161616" BorderThickness="1">
  <Border.Resources>
    <!--STYLES-->
  </Border.Resources>
  <Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="6" Opacity="0.7"/></Border.Effect>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Border x:Name="TitleBar" Grid.Row="0" Background="#2B2B2B" CornerRadius="7,7,0,0" Height="34">
      <Grid>
        <TextBlock x:Name="TitleText" HorizontalAlignment="Center" VerticalAlignment="Center" FontWeight="SemiBold"
                   TextTrimming="CharacterEllipsis" Margin="110,0" Foreground="#E4E4E4"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,6,0">
          <Button x:Name="BtnMin" Style="{StaticResource IconBtn}" Content="&#xE921;" ToolTip="Свернуть"/>
          <Button x:Name="BtnMax" Style="{StaticResource IconBtn}" Content="&#xE922;" ToolTip="Развернуть"/>
          <Button x:Name="BtnClose" Style="{StaticResource CloseBtn}" Content="&#xE8BB;" ToolTip="Закрыть" Margin="0"/>
        </StackPanel>
      </Grid>
    </Border>
    <Border Grid.Row="1" Background="#323232" Padding="8,6" BorderBrush="#232323" BorderThickness="0,0,0,1">
      <DockPanel>
        <Button x:Name="BtnView" DockPanel.Dock="Right" Style="{StaticResource IconBtn}" Content="&#xE80A;" ToolTip="Вид" Margin="6,0,0,0"/>
        <StackPanel x:Name="NavBar" Orientation="Horizontal" DockPanel.Dock="Left" Margin="0,0,6,0">
          <Button x:Name="BtnBack" Style="{StaticResource IconBtn}" Content="&#xE72B;" ToolTip="Назад"/>
          <Button x:Name="BtnUp" Style="{StaticResource IconBtn}" Content="&#xE74A;" ToolTip="Вверх"/>
          <Button x:Name="BtnReload" Style="{StaticResource IconBtn}" Content="&#xE72C;" ToolTip="Обновить"/>
        </StackPanel>
        <TextBox x:Name="PathBox"/>
      </DockPanel>
    </Border>
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Border x:Name="Side" Grid.Column="0" Width="156" Background="#2D2D2D" BorderBrush="#232323" BorderThickness="0,0,1,0">
        <StackPanel x:Name="SidePanel" Margin="6,8"/>
      </Border>
      <ScrollViewer x:Name="Scroll" Grid.Column="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="Transparent"/>
    </Grid>
    <Border Grid.Row="3" Padding="12,4" Background="#2B2B2B" CornerRadius="0,0,7,7">
      <TextBlock x:Name="WinStatus" Foreground="#9A9A9A" FontSize="12" TextTrimming="CharacterEllipsis"/>
    </Border>
    <Thumb x:Name="Grip" Grid.Row="2" Grid.RowSpan="2" HorizontalAlignment="Right" VerticalAlignment="Bottom" Width="18" Height="18" Cursor="SizeNWSE" Opacity="0.01" Background="White"/>
  </Grid>
</Border>
'@

$iconLargeXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="92" Padding="4,6" CornerRadius="5" Background="Transparent" BorderThickness="1" BorderBrush="Transparent" Margin="4">
  <StackPanel>
    <Viewbox x:Name="Art" Width="54" Height="54" HorizontalAlignment="Center"/>
    <TextBlock x:Name="Label" Margin="0,5,0,0" TextWrapping="Wrap" TextAlignment="Center" FontSize="12" Foreground="#EEEEEE"
               MaxHeight="34" TextTrimming="CharacterEllipsis">
      <TextBlock.Effect><DropShadowEffect ShadowDepth="1" BlurRadius="3" Opacity="0.9"/></TextBlock.Effect>
    </TextBlock>
  </StackPanel>
</Border>
'@

$iconSmallXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="200" Padding="6,3" CornerRadius="4" Background="Transparent" BorderThickness="1" BorderBrush="Transparent" Margin="1">
  <DockPanel>
    <Viewbox x:Name="Art" DockPanel.Dock="Left" Width="22" Height="22" Margin="0,0,8,0"/>
    <TextBlock x:Name="Label" VerticalAlignment="Center" FontSize="12.5" Foreground="#EEEEEE" TextTrimming="CharacterEllipsis">
      <TextBlock.Effect><DropShadowEffect ShadowDepth="1" BlurRadius="3" Opacity="0.8"/></TextBlock.Effect>
    </TextBlock>
  </DockPanel>
</Border>
'@

$iconListXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Padding="8,3" CornerRadius="4" Background="Transparent" BorderThickness="1" BorderBrush="Transparent" Margin="0,1">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="30"/><ColumnDefinition Width="*"/><ColumnDefinition Width="90"/><ColumnDefinition Width="130"/><ColumnDefinition Width="140"/>
    </Grid.ColumnDefinitions>
    <Viewbox x:Name="Art" Grid.Column="0" Width="22" Height="22" HorizontalAlignment="Left"/>
    <TextBlock x:Name="Label" Grid.Column="1" VerticalAlignment="Center" FontSize="12.5" Foreground="#EEEEEE" TextTrimming="CharacterEllipsis">
      <TextBlock.Effect><DropShadowEffect ShadowDepth="1" BlurRadius="3" Opacity="0.8"/></TextBlock.Effect>
    </TextBlock>
    <TextBlock x:Name="SizeText" Grid.Column="2" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="0,0,14,0" FontSize="12" Foreground="#A8A8A8"/>
    <TextBlock x:Name="DateText" Grid.Column="3" VerticalAlignment="Center" FontSize="12" Foreground="#A8A8A8"/>
    <TextBlock x:Name="KindText" Grid.Column="4" VerticalAlignment="Center" FontSize="12" Foreground="#A8A8A8" TextTrimming="CharacterEllipsis"/>
  </Grid>
</Border>
'@

$folderArtXaml = @'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="48" Height="48">
  <Path Fill="{B}" Data="M4,10 Q4,8 6,8 H18 L22,12 H42 Q44,12 44,14 V38 Q44,40 42,40 H6 Q4,40 4,38 Z"/>
  <Path Fill="#F2F2F2" Opacity="0.92" Data="M7,14 H41 V30 H7 Z"/>
  <Path Data="M4,18 Q4,16 6,16 H42 Q44,16 44,18 V38 Q44,40 42,40 H6 Q4,40 4,38 Z">
    <Path.Fill>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="{A}" Offset="0"/><GradientStop Color="{C}" Offset="1"/></LinearGradientBrush>
    </Path.Fill>
  </Path>
  <!--EMBLEM-->
</Canvas>
'@

$fileArtXaml = @'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="48" Height="48">
  <Path Fill="#F5F5F5" Stroke="#9E9E9E" StrokeThickness="1" Data="M11,4.5 H29 L38,13.5 V42 Q38,43.5 36.5,43.5 H11.5 Q9.5,43.5 9.5,42 V6 Q9.5,4.5 11,4.5 Z"/>
  <Path Fill="#CFD8DC" Data="M29,4.5 L38,13.5 H31 Q29,13.5 29,11.5 Z"/>
  <Rectangle Canvas.Left="14" Canvas.Top="18" Width="20" Height="2" Fill="#B0BEC5"/>
  <Rectangle Canvas.Left="14" Canvas.Top="23" Width="20" Height="2" Fill="#B0BEC5"/>
  <Rectangle Canvas.Left="14" Canvas.Top="28" Width="14" Height="2" Fill="#B0BEC5"/>
  <Border Canvas.Left="10" Canvas.Top="33" Width="27.5" Height="10" Background="{A}" CornerRadius="0,0,1.5,1.5">
    <TextBlock Text="{T}" FontSize="7" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
  <!--EMBLEM-->
</Canvas>
'@

$emblemXaml = @'
<Ellipse Canvas.Left="1" Canvas.Top="29" Width="18" Height="18" Fill="#F5F5F5" Stroke="#444444" StrokeThickness="1"/>
<TextBlock Canvas.Left="4.5" Canvas.Top="29.5" Text="&#x2197;" FontSize="13" FontWeight="Bold" Foreground="#2B2B2B"/>
'@

function Read-Xaml([string]$Xaml) { [Windows.Markup.XamlReader]::Parse($Xaml.Replace('<!--STYLES-->', $stylesXaml)) }

$script:MenuRes = [Windows.Markup.XamlReader]::Parse(@"
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
$menuStylesXaml
</ResourceDictionary>
"@)

#endregion

#region Помощники

$script:Accent = '#8fa876'
$script:ViewNames = [ordered]@{ large = 'Крупные значки'; small = 'Мелкие значки'; list = 'Список' }
$script:DesktopView = 'large'
$script:RemoteView = 'large'
$script:SortKey = 'name'
$script:SortDesc = $false
$script:SortNames = [ordered]@{ name = 'По имени'; size = 'По размеру'; date = 'По дате'; type = 'По типу' }

function New-Brush([string]$Hex, [byte]$Alpha = 255) {
    $rgb = ConvertFrom-Hex $Hex
    if (-not $rgb) { $rgb = 0x9A, 0xA0, 0xB2 }
    $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromArgb($Alpha, $rgb[0], $rgb[1], $rgb[2]))
    $b.Freeze()
    return $b
}

# Светлее (T > 0, к белому) или темнее (T < 0, к чёрному) на долю T.
function Get-Shade([string]$Hex, [double]$T) {
    $c = ConvertFrom-Hex $Hex
    if (-not $c) { $c = 0x8F, 0xB3, 0x5A }
    $o = foreach ($v in $c) { if ($T -ge 0) { [int]($v + (255 - $v) * $T) } else { [int]($v * (1 + $T)) } }
    ConvertTo-Hex $o[0] $o[1] $o[2]
}

function Format-Size([long]$Bytes) {
    if ($Bytes -lt 1KB) { return "$Bytes Б" }
    if ($Bytes -lt 1MB) { return ('{0:N1} КБ' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    return ('{0:N2} ГБ' -f ($Bytes / 1GB))
}

function Set-Status([string]$Text) { $script:StatusText.Text = $Text }

function Update-Busy {
    $n = $script:Ops.Count
    if ($n) { Set-Status "⏳ Операций с сервером: $n" }
    elseif ($script:StatusText.Text -like '⏳*') { Set-Status '' }
}

function Show-Warn([string]$Text) { [void][Windows.MessageBox]::Show($script:Main, $Text, 'SSH', 'OK', 'Warning') }

function New-Menu {
    $m = [Windows.Controls.ContextMenu]::new()
    $m.Resources = $script:MenuRes
    return $m
}

function Read-Text([string]$Title, [string]$Prompt, [string]$Default = '') {
    $dlg = Read-Xaml @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="440" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        Background="#383838" Foreground="#DADADA" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources><!--STYLES--></Window.Resources>
  <StackPanel Margin="20">
    <TextBlock x:Name="P" Foreground="#B7B7B7" TextWrapping="Wrap"/>
    <TextBox x:Name="T" Margin="0,8,0,0" Padding="8,7"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
      <Button x:Name="C" Content="Отмена" IsCancel="True"/>
      <Button x:Name="O" Content="OK" Style="{StaticResource Primary}" IsDefault="True" Margin="0"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
    $dlg.Owner = $script:Main
    $dlg.Title = $Title
    $dlg.FindName('P').Text = $Prompt
    $t = $dlg.FindName('T')
    $t.Text = $Default
    $dlg.FindName('O').Add_Click({ $dlg.DialogResult = $true })
    $dlg.Add_ContentRendered({ $t.Focus(); $t.SelectAll() })
    if ($dlg.ShowDialog()) { return $t.Text.Trim() }
    return $null
}

function Select-ColorDialog([string]$Current) {
    $rgb = ConvertFrom-Hex $Current
    if (-not $rgb) { $rgb = 0x4F, 0x9A, 0xD8 }
    $dlg = [Windows.Forms.ColorDialog]::new()
    $dlg.AllowFullOpen = $true
    $dlg.FullOpen = $true
    $dlg.Color = [Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2])
    $wrap = [Win32Owner]::new()
    $wrap.Handle = [Windows.Interop.WindowInteropHelper]::new($script:Main).Handle
    if ($dlg.ShowDialog($wrap) -ne 'OK') { return $null }
    return ConvertTo-Hex $dlg.Color.R $dlg.Color.G $dlg.Color.B
}

function Save-Snapshot($Visual, [string]$Path) {
    $scale = [Windows.Media.VisualTreeHelper]::GetDpi($Visual).DpiScaleX
    $bmp = [Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($Visual.ActualWidth * $scale), [int][Math]::Ceiling($Visual.ActualHeight * $scale), 96 * $scale, 96 * $scale, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($Visual)
    $enc = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}

#endregion

#region Иконки

$script:ExtColors = @{}
foreach ($e in 'png', 'jpg', 'jpeg', 'gif', 'bmp', 'svg', 'webp', 'ico') { $script:ExtColors[$e] = '#7e57c2' }
foreach ($e in 'zip', '7z', 'rar', 'gz', 'tgz', 'tar', 'bz2', 'xz') { $script:ExtColors[$e] = '#ef6c00' }
foreach ($e in 'txt', 'md', 'log', 'conf', 'cfg', 'ini', 'yml', 'yaml', 'json', 'xml', 'env') { $script:ExtColors[$e] = '#546e7a' }
foreach ($e in 'ps1', 'sh', 'py', 'js', 'ts', 'cs', 'php', 'html', 'css', 'sql', 'go', 'rs', 'java') { $script:ExtColors[$e] = '#26a69a' }
foreach ($e in 'pdf') { $script:ExtColors[$e] = '#e53935' }
foreach ($e in 'sqlite', 'db', 'bak', 'dump') { $script:ExtColors[$e] = '#8d6e63' }

# Векторный значок в стиле Mint-Y: папка (зелёная; виртуальная — синяя или своего цвета) или лист с цветной полосой по типу файла.
function New-Art($Item) {
    $isDir = $Item.Kind -eq 'vfolder' -or $Item.IsDir
    $emblem = if ($Item.Kind -eq 'link') { $emblemXaml } else { '' }
    if ($isDir) {
        $base = if ($Item.Kind -eq 'vfolder') { if ($Item.Color) { $Item.Color } else { '#4f9ad8' } } else { '#8fb35a' }
        $xaml = $folderArtXaml.Replace('{A}', (Get-Shade $base 0.14)).Replace('{B}', (Get-Shade $base -0.3)).Replace('{C}', (Get-Shade $base -0.1)).Replace('<!--EMBLEM-->', $emblem)
    }
    else {
        $ext = ([IO.Path]::GetExtension([string]$Item.Name)).TrimStart('.').ToLower()
        $band = if ($script:ExtColors.ContainsKey($ext)) { $script:ExtColors[$ext] } else { '#78909c' }
        $label = ($ext -replace '[^a-z0-9]', '').ToUpper()
        if ($label.Length -gt 4) { $label = $label.Substring(0, 4) }
        $xaml = $fileArtXaml.Replace('{A}', $band).Replace('{T}', $label).Replace('<!--EMBLEM-->', $emblem)
    }
    return [Windows.Markup.XamlReader]::Parse($xaml)
}

function Get-KindText($Item) {
    switch ($Item.Kind) {
        'vfolder' { 'Виртуальная папка' }
        'link' { 'Ярлык' }
        default { if ($Item.IsDir) { 'Папка' } else { 'Файл' } }
    }
}

# Иконка. Tag = @{ Item; Win; Icon }. Win — состояние окна сервера (для remote-иконок) или $null.
function New-Icon($Item, $Win, [string]$Mode = 'large') {
    $icon = Read-Xaml $(switch ($Mode) { 'small' { $iconSmallXaml } 'list' { $iconListXaml } default { $iconLargeXaml } })
    $icon.FindName('Art').Child = New-Art $Item
    $icon.FindName('Label').Text = $Item.Name
    if ($Mode -eq 'list') {
        $size = if ($Item.Kind -eq 'remote' -and -not $Item.IsDir) { Format-Size ([long]$Item.Size) } else { '' }
        $icon.FindName('SizeText').Text = $size
        if ($Item.Date) { $icon.FindName('DateText').Text = ([datetime]$Item.Date).ToString('dd.MM.yyyy HH:mm') }
        $icon.FindName('KindText').Text = Get-KindText $Item
    }
    $icon.ToolTip = if ($Item.Kind -in 'link', 'remote') { "$($Item.Name)`n$($Item.Path)" } else { $Item.Name }
    $icon.Tag = @{ Item = $Item; Win = $Win; Icon = $icon }
    $icon.Add_MouseLeftButtonDown($script:H_IconDown)
    $icon.Add_MouseMove($script:H_IconMove)
    $icon.Add_MouseLeftButtonUp($script:H_IconUp)
    $icon.Add_MouseRightButtonUp($script:H_IconMenu)
    return $icon
}

$script:Sel = [Collections.Generic.List[object]]::new()
$script:SelAnchor = $null

function Set-IconMark($Icon, [bool]$On) {
    if ($On) { $Icon.Background = New-Brush $script:Accent 0x66; $Icon.BorderBrush = New-Brush $script:Accent 0xCC }
    else { $Icon.Background = [Windows.Media.Brushes]::Transparent; $Icon.BorderBrush = [Windows.Media.Brushes]::Transparent }
}

function Clear-Selection {
    foreach ($i in $script:Sel) { Set-IconMark $i $false }
    $script:Sel.Clear()
    $script:SelAnchor = $null
}

# Выделять вместе можно только значки одного контейнера (одного окна).
function Add-ToSelection($Icon) {
    if ($script:Sel.Count -and $script:Sel[0].Parent -ne $Icon.Parent) { Clear-Selection }
    if (-not $script:Sel.Contains($Icon)) { $script:Sel.Add($Icon); Set-IconMark $Icon $true }
    $script:SelAnchor = $Icon
}

function Select-Icon($Icon) {
    Clear-Selection
    if ($Icon) { Add-ToSelection $Icon }
}

function Switch-IconSelection($Icon) {
    if ($script:Sel.Contains($Icon)) { [void]$script:Sel.Remove($Icon); Set-IconMark $Icon $false }
    else { Add-ToSelection $Icon }
}

function Select-IconRange($Icon) {
    $a = $script:SelAnchor
    if (-not $a -or $a.Parent -ne $Icon.Parent) { Select-Icon $Icon; return }
    $kids = @($Icon.Parent.Children)
    $i1 = [Array]::IndexOf($kids, $a); $i2 = [Array]::IndexOf($kids, $Icon)
    if ($i1 -lt 0 -or $i2 -lt 0) { Select-Icon $Icon; return }
    Clear-Selection
    for ($k = [Math]::Min($i1, $i2); $k -le [Math]::Max($i1, $i2); $k++) { Add-ToSelection $kids[$k] }
    $script:SelAnchor = $a
}

function Get-SelTags { @($script:Sel | ForEach-Object { $_.Tag }) }
#endregion

#region Виртуальные контейнеры (рабочий стол и виртуальные папки)

$script:Windows = [Collections.Generic.List[hashtable]]::new()

function Get-ContainerView($ParentId) {
    if ($ParentId) {
        $v = (Get-VItem $ParentId).View
        if ($v -and $script:ViewNames.Contains($v)) { return $v }
        return 'large'
    }
    return $script:DesktopView
}

# Первая свободная ячейка сетки (по столбцам сверху вниз).
function Find-FreeSlot($ParentId, [double]$Height) {
    $used = @($script:Items | Where-Object { $_.Parent -eq $ParentId -and $null -ne $_.X -and $null -ne $_.Y })
    $rows = [Math]::Max(1, [int][Math]::Floor(($Height - 16) / 112))
    for ($i = 0; $i -lt 2000; $i++) {
        $x = 16 + [Math]::Floor($i / $rows) * 104
        $y = 16 + ($i % $rows) * 112
        $busy = $false
        foreach ($u in $used) { if ([Math]::Abs($u.X - $x) -lt 80 -and [Math]::Abs($u.Y - $y) -lt 90) { $busy = $true; break } }
        if (-not $busy) { return @{ X = $x; Y = $y } }
    }
    return @{ X = 16; Y = 16 }
}

# «Крупные значки» — свободная раскладка (X, Y из хранилища); «Мелкие значки» и «Список» — автоматическая, положения не теряются.
function Update-Virtual($Canvas, $ParentId, [double]$ViewHeight) {
    $Canvas.Children.Clear()
    if ($ViewHeight -le 0) { $ViewHeight = 600 }
    $mode = Get-ContainerView $ParentId
    $kids = @($script:Items | Where-Object { $_.Parent -eq $ParentId } | Sort-Object { $_.Kind -ne 'vfolder' }, { $_.Name })
    $changed = $false
    $maxX = 0; $maxY = 0; $idx = 0
    $rowsSmall = [Math]::Max(1, [int][Math]::Floor(($ViewHeight - 16) / 30))
    foreach ($k in $kids) {
        $icon = New-Icon $k $null $mode
        switch ($mode) {
            'large' {
                if ($null -eq $k.X -or $null -eq $k.Y) {
                    $slot = Find-FreeSlot $ParentId $ViewHeight
                    $k.X = $slot.X; $k.Y = $slot.Y
                    $changed = $true
                }
                $x = [double]$k.X; $y = [double]$k.Y; $cw = 110; $ch = 120
            }
            'small' {
                $x = 12 + [Math]::Floor($idx / $rowsSmall) * 204; $y = 8 + ($idx % $rowsSmall) * 30; $cw = 206; $ch = 34
            }
            default {
                $icon.Width = 640
                $x = 12; $y = 8 + $idx * 30; $cw = 654; $ch = 34
            }
        }
        [Windows.Controls.Canvas]::SetLeft($icon, $x)
        [Windows.Controls.Canvas]::SetTop($icon, $y)
        [void]$Canvas.Children.Add($icon)
        $maxX = [Math]::Max($maxX, $x + $cw); $maxY = [Math]::Max($maxY, $y + $ch)
        $idx++
    }
    if ($Canvas -ne $script:Desktop) {
        $Canvas.Width = [Math]::Max(1, $maxX); $Canvas.Height = [Math]::Max(1, $maxY)
    }
    if ($changed) { Save-Store }
}

function Update-AllVirtual {
    Clear-Selection
    Update-Virtual $script:Desktop $null $script:Desktop.ActualHeight
    foreach ($w in @($script:Windows | Where-Object { $_.Type -eq 'virtual' })) {
        $v = Get-VItem $w.Id
        if (-not $v) { Close-FloatWindow $w; continue }
        $w.TitleText.Text = $v.Name
        $w.PathBox.Text = Get-VFolderPath $v
        Update-Virtual $w.Canvas $w.Id $w.Scroll.ActualHeight
    }
    foreach ($w in @($script:Windows | Where-Object { $_.Type -eq 'remote' })) { Initialize-Side $w }
    Update-Taskbar
}

function New-VirtualFolder($ParentId, $Pos) {
    $name = Read-Text 'Новая папка' 'Название виртуальной папки (хранится только на этом ПК):' 'Новая папка'
    if (-not $name) { return }
    $script:Items.Add(@{ Id = (New-Id); Kind = 'vfolder'; Name = $name; Parent = $ParentId; X = $(if ($Pos) { [Math]::Round($Pos.X / 8) * 8 }); Y = $(if ($Pos) { [Math]::Round($Pos.Y / 8) * 8 }); Path = $null; IsDir = $true; Color = $null })
    Save-Store
    Update-AllVirtual
}

function Reset-Positions($ParentId) {
    foreach ($i in @($script:Items | Where-Object { $_.Parent -eq $ParentId })) { $i.X = $null; $i.Y = $null }
    Save-Store
    Update-AllVirtual
}

function Remove-VItem([string]$Id) {
    foreach ($c in @($script:Items | Where-Object { $_.Parent -eq $Id })) { Remove-VItem $c.Id }
    [void]$script:Items.Remove((Get-VItem $Id))
}

function Add-Link($Remote, $ParentId, $Pos, [switch]$Quiet) {
    $script:Items.Add(@{
            Id = (New-Id); Kind = 'link'; Name = $Remote.Name; Parent = $ParentId
            X = $(if ($Pos) { [Math]::Round($Pos.X / 8) * 8 }); Y = $(if ($Pos) { [Math]::Round($Pos.Y / 8) * 8 })
            Path = $Remote.Path; IsDir = [bool]$Remote.IsDir; Color = $null
        })
    if ($Quiet) { return }
    Save-Store
    Update-AllVirtual
    Set-Status "Ярлык «$($Remote.Name)» создан — на сервере ничего не изменилось"
}

#endregion

#region Плавающие окна

$script:Z = 10

function New-FloatWindow([string]$Type) {
    $root = Read-Xaml $windowXaml
    $w = @{ Root = $root; Type = $Type; Closed = $false; Restore = $null }
    $names = 'TitleBar', 'TitleText', 'BtnMin', 'BtnMax', 'BtnClose', 'BtnView', 'NavBar', 'BtnBack', 'BtnUp', 'BtnReload', 'PathBox', 'Side', 'SidePanel', 'Scroll', 'WinStatus', 'Grip'
    foreach ($n in $names) { $w[$n] = $root.FindName($n) }
    foreach ($n in 'TitleBar', 'BtnMin', 'BtnMax', 'BtnClose', 'BtnView', 'BtnBack', 'BtnUp', 'BtnReload', 'PathBox', 'Grip') { $w[$n].Tag = $w }
    $root.Tag = $w

    $n = $script:Windows.Count % 8
    [Windows.Controls.Canvas]::SetLeft($root, 70 + 30 * $n)
    [Windows.Controls.Canvas]::SetTop($root, 30 + 30 * $n)
    [Windows.Controls.Panel]::SetZIndex($root, ++$script:Z)

    $root.Add_PreviewMouseLeftButtonDown($script:H_WinFront)
    $w.TitleBar.Add_MouseLeftButtonDown($script:H_TitleDown)
    $w.TitleBar.Add_MouseMove($script:H_TitleMove)
    $w.TitleBar.Add_MouseLeftButtonUp($script:H_TitleUp)
    $w.BtnMin.Add_Click($script:H_Min)
    $w.BtnMax.Add_Click($script:H_Max)
    $w.BtnClose.Add_Click($script:H_Close)
    $w.BtnView.Add_Click($script:H_ViewBtn)
    $w.Grip.Add_DragDelta($script:H_Grip)

    [void]$script:Floating.Children.Add($root)
    $script:Windows.Add($w)
    Update-Taskbar
    return $w
}

function Close-FloatWindow($w) {
    $w.Closed = $true
    $script:Floating.Children.Remove($w.Root)
    [void]$script:Windows.Remove($w)
    Update-Taskbar
}

function Switch-Maximize($w) {
    $r = $w.Root
    if ($w.Restore) {
        [Windows.Controls.Canvas]::SetLeft($r, $w.Restore.L); [Windows.Controls.Canvas]::SetTop($r, $w.Restore.T)
        $r.Width = $w.Restore.W; $r.Height = $w.Restore.H
        $w.Restore = $null
        $w.BtnMax.Content = [string][char]0xE922
    }
    else {
        $w.Restore = @{ L = [Windows.Controls.Canvas]::GetLeft($r); T = [Windows.Controls.Canvas]::GetTop($r); W = $r.ActualWidth; H = $r.ActualHeight }
        [Windows.Controls.Canvas]::SetLeft($r, 0); [Windows.Controls.Canvas]::SetTop($r, 0)
        $r.Width = $script:Stage.ActualWidth; $r.Height = $script:Stage.ActualHeight
        $w.BtnMax.Content = [string][char]0xE923
    }
    [Windows.Controls.Panel]::SetZIndex($r, ++$script:Z)
}

# Кнопки открытых окон на нижней панели (как в Cinnamon).
function Update-Taskbar {
    if (-not $script:Tasks) { return }
    $script:Tasks.Children.Clear()
    foreach ($w in $script:Windows) {
        $b = [Windows.Controls.Button]::new()
        $b.Style = $script:Main.FindResource('TaskBtn')
        $b.Content = $w.TitleText.Text
        $b.Tag = $w
        if ($w.Root.Visibility -ne 'Visible') { $b.Opacity = 0.55 }
        $b.Add_Click($script:H_TaskClick)
        [void]$script:Tasks.Children.Add($b)
    }
}

function Add-SideButton($w, [int]$Glyph, [string]$Text, [string]$Path) {
    $b = [Windows.Controls.Button]::new()
    $b.Style = $script:Main.FindResource('SideBtn')
    $sp = [Windows.Controls.StackPanel]::new()
    $sp.Orientation = 'Horizontal'
    $g = [Windows.Controls.TextBlock]::new()
    $g.FontFamily = [Windows.Media.FontFamily]::new('Segoe MDL2 Assets')
    $g.Text = [string][char]$Glyph
    $g.Foreground = New-Brush $script:Accent
    $g.Margin = [Windows.Thickness]::new(0, 0, 9, 0)
    $t = [Windows.Controls.TextBlock]::new()
    $t.Text = $Text
    $t.TextTrimming = 'CharacterEllipsis'
    [void]$sp.Children.Add($g); [void]$sp.Children.Add($t)
    $b.Content = $sp
    $b.Tag = @{ W = $w; Path = $Path }
    $b.Add_Click($script:H_SideClick)
    [void]$w.SidePanel.Children.Add($b)
}

function Initialize-Side($w) {
    $w.SidePanel.Children.Clear()
    $h = [Windows.Controls.TextBlock]::new()
    $h.Text = 'МЕСТА'; $h.FontSize = 10.5; $h.FontWeight = 'Bold'; $h.Foreground = New-Brush '#8A8A8A'; $h.Margin = [Windows.Thickness]::new(8, 0, 0, 5)
    [void]$w.SidePanel.Children.Add($h)
    Add-SideButton $w 0xE80F 'Домашняя папка' '.'
    Add-SideButton $w 0xE8B7 'Корень /' '/'
    $links = @($script:Items | Where-Object { $_.Kind -eq 'link' -and $_.IsDir -and -not $_.Parent -and $_.Path -notin '.', '/' })
    if ($links.Count) {
        $h2 = [Windows.Controls.TextBlock]::new()
        $h2.Text = 'ЗАКЛАДКИ'; $h2.FontSize = 10.5; $h2.FontWeight = 'Bold'; $h2.Foreground = New-Brush '#8A8A8A'; $h2.Margin = [Windows.Thickness]::new(8, 14, 0, 5)
        [void]$w.SidePanel.Children.Add($h2)
        foreach ($l in $links) { Add-SideButton $w 0xE718 $l.Name $l.Path }
    }
}

function Open-VirtualWindow($VItem) {
    $existing = $script:Windows | Where-Object { $_.Type -eq 'virtual' -and $_.Id -eq $VItem.Id } | Select-Object -First 1
    if ($existing) { $existing.Root.Visibility = 'Visible'; [Windows.Controls.Panel]::SetZIndex($existing.Root, ++$script:Z); Update-Taskbar; return }
    $w = New-FloatWindow 'virtual'
    $w.Id = $VItem.Id
    $w.NavBar.Visibility = 'Collapsed'; $w.Side.Visibility = 'Collapsed'
    $w.PathBox.IsReadOnly = $true
    $canvas = [Windows.Controls.Canvas]::new()
    $canvas.Background = [Windows.Media.Brushes]::Transparent
    $canvas.HorizontalAlignment = 'Left'
    $canvas.VerticalAlignment = 'Top'
    $canvas.Tag = @{ Container = 'virtual'; Id = $VItem.Id; Canvas = $canvas }
    $canvas.Add_MouseRightButtonUp($script:H_VirtualBgMenu)
    $canvas.Add_MouseLeftButtonDown($script:H_BgClick); $canvas.Add_MouseMove($script:H_BgMove); $canvas.Add_MouseLeftButtonUp($script:H_BgUp)
    $w.Canvas = $canvas
    $w.Scroll.Content = $canvas
    $w.TitleText.Text = $VItem.Name
    $w.PathBox.Text = Get-VFolderPath $VItem
    $w.WinStatus.Text = 'Виртуальная папка: хранится только на этом ПК, сервер не затрагивается'
    Update-Virtual $canvas $VItem.Id 320
    Update-Taskbar
}

function Open-RemoteWindow([string]$Path, [switch]$NoLoad) {
    $w = New-FloatWindow 'remote'
    $w.Path = $Path; $w.Cwd = $null; $w.History = [Collections.Generic.List[string]]::new(); $w.Entries = @(); $w.Loading = $false
    $w.View = $script:RemoteView; $w.ShowHidden = $false
    $panel = [Windows.Controls.WrapPanel]::new()
    $w.Panel = $panel
    $w.Scroll.Content = $panel
    $w.Scroll.HorizontalScrollBarVisibility = 'Disabled'   # иконки переносятся по ширине окна
    $w.Scroll.Tag = @{ Container = 'remote'; Win = $w }
    $w.Scroll.AllowDrop = $true
    $w.Scroll.Add_DragOver($script:H_FileDragOver)
    $w.Scroll.Add_Drop($script:H_FileDrop)
    $w.Scroll.Add_MouseRightButtonUp($script:H_RemoteBgMenu)
    $w.Scroll.Add_MouseLeftButtonDown($script:H_BgClick); $w.Scroll.Add_MouseMove($script:H_BgMove); $w.Scroll.Add_MouseLeftButtonUp($script:H_BgUp)
    $w.BtnBack.Add_Click($script:H_RBack)
    $w.BtnUp.Add_Click($script:H_RUp)
    $w.BtnReload.Add_Click($script:H_RReload)
    $w.PathBox.Add_KeyDown($script:H_RPathKey)
    $w.TitleText.Text = 'Сервер'
    Initialize-Side $w
    if ($NoLoad) { $w.Cwd = $Path } else { Update-Remote $w $Path $true }
    return $w
}

function Update-Remote($w, [string]$Path, [bool]$PushHistory) {
    $w.Loading = $true
    $w.WinStatus.Text = '⏳ Загрузка…'
    Start-SftpOp @("cd $(ConvertTo-SftpArg $Path)", 'pwd', 'ls -la') $script:D_Listing @{ W = $w; Push = $PushHistory }
}

function Show-Remote($w) {
    Clear-Selection
    $mode = $w.View
    $panel = if ($mode -eq 'list') { [Windows.Controls.StackPanel]::new() } else { [Windows.Controls.WrapPanel]::new() }
    $panel.Margin = [Windows.Thickness]::new(8)
    $w.Panel = $panel
    $w.Scroll.Content = $panel
    $show = [bool]$w.ShowHidden
    $key = switch ($script:SortKey) {
        'size' { { [long]$_.Size } }
        'date' { { if ($_.Date) { $_.Date } else { [datetime]::MinValue } } }
        'type' { { [IO.Path]::GetExtension($_.Name).ToLower() } }
        default { { $_.Name.ToLower() } }
    }
    $entries = @($w.Entries | Where-Object { $show -or -not $_.Name.StartsWith('.') } |
            Sort-Object -Property @({ -not $_.IsDir }, @{ Expression = $key; Descending = [bool]$script:SortDesc }, { $_.Name.ToLower() }))
    foreach ($e in $entries) {
        $item = @{ Kind = 'remote'; Name = $e.Name; IsDir = $e.IsDir; IsLink = [bool]$e.IsLink; Path = $(if ($e.FullPath) { $e.FullPath } else { Join-Remote $w.Cwd $e.Name }); Size = $e.Size; Date = $e.Date }
        [void]$w.Panel.Children.Add((New-Icon $item $w $mode))
    }
    $w.PathBox.Text = $w.Cwd
    $w.TitleText.Text = "Сервер — $($w.Cwd)"
    $w.WinStatus.Text = "Объектов: $($entries.Count)" + $(if (-not $entries.Count) { ' — папка пуста' } else { '' })
    if ($w.Search) {
        $w.TitleText.Text = "Поиск «$($w.Search.Query)» — $($w.Cwd)"
        $w.WinStatus.Text = "Найдено: $($entries.Count)" + $(if ($w.Search.Count -ge 500) { ' (показаны первые 500)' } elseif (-not $entries.Count) { ' — ничего (или на сервере нет GNU find)' } else { '' }) + '  ·  ⟳ — вернуться к папке'
    }
    Update-Taskbar
}

#endregion

#region Действия

function Get-VFolderPath($Item) {
    $parts = @()
    $cur = $Item
    while ($cur) { $parts = , $cur.Name + $parts; $cur = if ($cur.Parent) { Get-VItem $cur.Parent } else { $null } }
    return $parts -join ' › '
}

function Open-RemoteFile([string]$RemotePath, [string]$LeafName) {
    $dir = Join-Path $env:TEMP "ssh-desktop\$([IO.Path]::GetFileName($StorePath))"
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $local = Join-Path $dir $LeafName
    Set-Status "⏳ Скачиваю «$LeafName»…"
    Start-SftpOp @("get -p $(ConvertTo-SftpArg $RemotePath) $(ConvertTo-SftpArg ($local -replace '\\', '/'))") $script:D_OpenFile @{ Local = $local }
}

$script:Edits = [Collections.Generic.List[hashtable]]::new()

# Скачивает файл, открывает его в программе по умолчанию и следит за изменениями: после сохранения предлагает загрузить обратно.
function Edit-RemoteFile([string]$RemotePath, [string]$Leaf) {
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($RemotePath))).Replace('-', '').Substring(0, 8)
    $dir = Join-Path $env:TEMP "ssh-desktop\$([IO.Path]::GetFileName($StorePath))\edit-$hash"
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    $local = Join-Path $dir $Leaf
    Set-Status "⏳ Скачиваю «$Leaf» для правки…"
    Start-SftpOp @("get -p $(ConvertTo-SftpArg $RemotePath) $(ConvertTo-SftpArg ($local -replace '\\', '/'))") $script:D_EditReady @{ Local = $local; Remote = $RemotePath; Leaf = $Leaf }
}

function Test-EditChanges {
    foreach ($ed in @($script:Edits)) {
        if ($ed.Busy) { continue }
        try { $it = Get-Item -LiteralPath $ed.Local -ErrorAction Stop } catch { continue }
        if ($it.LastWriteTimeUtc -eq $ed.Stamp -and $it.Length -eq $ed.Len) { continue }
        $ed.Busy = $true
        $ed.Stamp = $it.LastWriteTimeUtc; $ed.Len = $it.Length
        $ans = [Windows.MessageBox]::Show($script:Main, "Файл «$($ed.Leaf)» изменён на этом ПК.`n`nЗагрузить НА СЕРВЕР, заменив файл:`n$($ed.Remote)", 'SSH — изменение сервера', 'YesNo', 'Warning')
        if ($ans -eq 'Yes') {
            Set-Status "⏳ Загружаю «$($ed.Leaf)» на сервер…"
            Start-SftpOp @("put -p $(ConvertTo-SftpArg ($ed.Local -replace '\\', '/')) $(ConvertTo-SftpArg $ed.Remote)") $script:D_EditSaved @{ Ed = $ed }
        }
        else { $ed.Busy = $false }
    }
}

function Start-RemoteSearch($w, [string]$Query) {
    if (-not $w.Cwd) { return }
    $q = if ($Query) { $Query } else { Read-Text 'Поиск на сервере' "Искать по имени в «$($w.Cwd)» и подпапках (можно маски * и ?):" '' }
    if (-not $q) { return }
    $pat = if ($q -match '[*?]') { $q } else { "*$q*" }
    $cmd = "find $(ConvertTo-ShellArg $w.Cwd) -iname $(ConvertTo-ShellArg $pat) -printf '%y\t%s\t%TY-%Tm-%Td %TH:%TM\t%p\n' 2>/dev/null | head -n 500"
    $w.WinStatus.Text = '⏳ Ищу на сервере…'
    Start-SshExec $cmd $script:D_Search @{ W = $w; Query = $q; Dir = $w.Cwd }
}

function Remove-RemoteItems($Items, $w) {
    $Items = @($Items)
    if (-not $Items.Count) { return }
    foreach ($i in $Items) {
        if (-not (Test-SafeRemotePath $i.Path)) { Show-Warn "Отказ: путь «$($i.Path)» слишком близко к корню — из программы его удалять нельзя."; return }
    }
    $dirs = @($Items | Where-Object { $_.IsDir -and -not $_.IsLink })
    $list = ($Items | Select-Object -First 12 | ForEach-Object { "  • $($_.Path)" }) -join "`n"
    if ($Items.Count -gt 12) { $list += "`n  … и ещё $($Items.Count - 12)" }
    if ($dirs.Count) {
        $typed = Read-Text 'Удаление на сервере' "ОПАСНО. БЕЗ КОРЗИНЫ будет удалено НА СЕРВЕРЕ, папки (всего $($dirs.Count)) — вместе со ВСЕМ содержимым:`n$list`n`nЧтобы подтвердить, введите слово УДАЛИТЬ:" ''
        if ($typed -ne 'УДАЛИТЬ') { Set-Status 'Удаление отменено'; return }
        $cmd = 'rm -rf -- ' + (($Items | ForEach-Object { ConvertTo-ShellArg $_.Path }) -join ' ')
        Set-Status '⏳ Удаляю на сервере…'
        Start-SshExec $cmd $script:D_Changed @{ W = $w; What = 'Удалено' }
    }
    else {
        if ([Windows.MessageBox]::Show($script:Main, "УДАЛИТЬ НА СЕРВЕРЕ без корзины:`n$list", 'SSH — изменение сервера', 'YesNo', 'Warning') -ne 'Yes') { return }
        Start-SftpOp @($Items | ForEach-Object { "rm $(ConvertTo-SftpArg $_.Path)" }) $script:D_Changed @{ W = $w; What = 'Удалено' }
    }
}

function Select-LocalFolder([string]$Description) {
    $dlg = [Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = $Description
    $dlg.SelectedPath = Join-Path $env:USERPROFILE 'Downloads'
    $wrap = [Win32Owner]::new()
    $wrap.Handle = [Windows.Interop.WindowInteropHelper]::new($script:Main).Handle
    if ($dlg.ShowDialog($wrap) -ne 'OK') { return $null }
    return $dlg.SelectedPath
}

function Open-Item($Tag) {
    $item = $Tag.Item
    switch ($item.Kind) {
        'vfolder' { Open-VirtualWindow $item }
        'link' { if ($item.IsDir) { Open-RemoteWindow $item.Path } else { Open-RemoteFile $item.Path ($item.Path -split '/')[-1] } }
        'remote' { if ($item.IsDir) { Update-Remote $Tag.Win $item.Path $true } else { Open-RemoteFile $item.Path ($item.Path -split '/')[-1] } }
    }
}

function Add-MenuItem($Menu, [string]$Header, $Tag, [scriptblock]$Handler) {
    if ($Header -eq '-') { [void]$Menu.Items.Add([Windows.Controls.Separator]::new()); return }
    $mi = [Windows.Controls.MenuItem]::new()
    $mi.Header = $Header
    $mi.Tag = $Tag
    if ($Handler) { $mi.Add_Click($Handler) }
    [void]$Menu.Items.Add($mi)
    return $mi
}

function Show-IconMenu($Tag) {
    $item = $Tag.Item
    $menu = New-Menu
    $tags = @(Get-SelTags)
    if ($tags.Count -gt 1) {
        $multi = @{ Tags = $tags; Win = $Tag.Win }
        $head = Add-MenuItem $menu "Выбрано объектов: $($tags.Count)" $null $null
        $head.IsEnabled = $false
        Add-MenuItem $menu '-'
        if (@($tags | Where-Object { $_.Item.Kind -eq 'remote' }).Count) {
            [void](Add-MenuItem $menu 'Закрепить на рабочем столе (ярлыки)' $multi $script:M_PinMany)
            [void](Add-MenuItem $menu 'Скопировать на ПК…' $multi $script:M_DownloadMany)
            Add-MenuItem $menu '-'
            [void](Add-MenuItem $menu '⚠ Удалить НА СЕРВЕРЕ…' $multi $script:M_DeleteMany)
        }
        else { [void](Add-MenuItem $menu 'Убрать выбранные (сервер не меняется)' $multi $script:M_VRemoveMany) }
        $menu.IsOpen = $true
        return
    }
    switch ($item.Kind) {
        'vfolder' {
            Add-MenuItem $menu 'Открыть' $Tag $script:M_Open | Out-Null
            Add-MenuItem $menu 'Переименовать…' $Tag $script:M_VRename | Out-Null
            Add-MenuItem $menu 'Цвет…' $Tag $script:M_VColor | Out-Null
            Add-MenuItem $menu '-' | Out-Null
            Add-MenuItem $menu 'Убрать с рабочего стола (сервер не меняется)' $Tag $script:M_VRemove | Out-Null
        }
        'link' {
            Add-MenuItem $menu 'Открыть' $Tag $script:M_Open | Out-Null
            if ($item.IsDir) { Add-MenuItem $menu 'Открыть в новом окне' $Tag { param($s, $e) Open-RemoteWindow $s.Tag.Item.Path } | Out-Null }
            if (-not $item.IsDir) { Add-MenuItem $menu 'Править (с загрузкой обратно на сервер)' $Tag $script:M_Edit | Out-Null }
            Add-MenuItem $menu 'Переименовать ярлык…' $Tag $script:M_VRename | Out-Null
            Add-MenuItem $menu '-' | Out-Null
            Add-MenuItem $menu 'Убрать ярлык (сервер не меняется)' $Tag $script:M_VRemove | Out-Null
        }
        'remote' {
            Add-MenuItem $menu 'Открыть' $Tag $script:M_Open | Out-Null
            Add-MenuItem $menu '-' | Out-Null
            Add-MenuItem $menu 'Закрепить на рабочем столе (ярлык)' $Tag $script:M_Pin | Out-Null
            $folders = @($script:Items | Where-Object { $_.Kind -eq 'vfolder' })
            if ($folders.Count) {
                $sub = [Windows.Controls.MenuItem]::new()
                $sub.Header = 'Закрепить в виртуальной папке'
                foreach ($f in $folders) {
                    $mi = [Windows.Controls.MenuItem]::new()
                    $mi.Header = Get-VFolderPath $f
                    $mi.Tag = @{ Item = $item; FolderId = $f.Id }
                    $mi.Add_Click($script:M_PinTo)
                    [void]$sub.Items.Add($mi)
                }
                [void]$menu.Items.Add($sub)
            }
            if (-not $item.IsDir) { Add-MenuItem $menu 'Править (с загрузкой обратно на сервер)' $Tag $script:M_Edit | Out-Null }
            Add-MenuItem $menu 'Скопировать на ПК…' $Tag $script:M_Download | Out-Null
            Add-MenuItem $menu '-' | Out-Null
            Add-MenuItem $menu '⚠ Переименовать НА СЕРВЕРЕ…' $Tag $script:M_RRename | Out-Null
            Add-MenuItem $menu $(if ($item.IsDir -and -not $item.IsLink) { '⚠ Удалить НА СЕРВЕРЕ вместе с содержимым…' } else { '⚠ Удалить НА СЕРВЕРЕ…' }) $Tag $script:M_RDelete | Out-Null
        }
    }
    $menu.IsOpen = $true
}

function Invoke-RemoteAfter($w, [string]$Done) {
    # После изменения на сервере — перечитать папку.
    Update-Remote $w $w.Cwd $false
    if ($Done) { $w.WinStatus.Text = "⏳ $Done" }
}

function Send-Files($w, [string[]]$Files) {
    if (-not $Files.Count -or -not $w.Cwd) { return }
    $names = ($Files | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
    $ans = [Windows.MessageBox]::Show($script:Main, "Загрузить НА СЕРВЕР в «$($w.Cwd)»:`n$names", 'SSH — изменение сервера', 'OKCancel', 'Question')
    if ($ans -ne 'OK') { return }
    $cmds = foreach ($f in $Files) {
        $flag = if (Test-Path -LiteralPath $f -PathType Container) { '-r ' } else { '' }
        "put -p $flag$(ConvertTo-SftpArg ($f -replace '\\', '/')) $(ConvertTo-SftpArg ($w.Cwd + '/'))"
    }
    $w.WinStatus.Text = '⏳ Загружаю на сервер…'
    Start-SftpOp @($cmds) $script:D_Changed @{ W = $w; What = 'Загружено' }
}

#endregion

#region Обработчики

# --- перетаскивание иконок ---
function Find-DropTarget($P, $ExcludeIcon) {
    $hit = [Windows.Media.VisualTreeHelper]::HitTest($script:Stage, $P)
    if (-not $hit) { return $null }
    $v = $hit.VisualHit
    while ($v) {
        if ($v -is [Windows.FrameworkElement] -and $v.Tag -is [hashtable]) {
            $tag = $v.Tag
            if ($tag.ContainsKey('Item') -and $tag.Icon -ne $ExcludeIcon -and $tag.Item.Kind -eq 'vfolder') { return @{ Type = 'folder'; Item = $tag.Item } }
            if ($tag.ContainsKey('Container')) { return @{ Type = 'container'; Info = $tag } }
        }
        $v = if ($v -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($v) } else { $null }
    }
    return $null
}

function Complete-Drop($Drag, $P) {
    $target = Find-DropTarget $P $Drag.Icon
    if (-not $target) { return }
    $src = $Drag.Tag.Item
    $tags = if ($script:Sel.Contains($Drag.Icon)) { @(Get-SelTags) } else { @($Drag.Tag) }
    $items = @($tags | ForEach-Object { $_.Item })
    $remoteItems = @($items | Where-Object { $_.Kind -eq 'remote' })
    $virtItems = @($items | Where-Object { $_.Kind -ne 'remote' })
    if ($target.Type -eq 'folder') {
        $dest = $target.Item
        foreach ($r in $remoteItems) { Add-Link $r $dest.Id $null -Quiet }
        foreach ($v in $virtItems) {
            if ($v.Id -ne $dest.Id -and -not (Test-Descendant $dest.Id $v.Id)) { $v.Parent = $dest.Id; $v.X = $null; $v.Y = $null }
        }
        Save-Store; Update-AllVirtual
        Set-Status "В «$($dest.Name)» перенесено объектов: $($items.Count) — виртуально, сервер не меняется"
        return
    }
    $info = $target.Info
    if ($info.Container -ne 'virtual') { return }
    $pt = $script:Stage.TransformToDescendant($info.Canvas).Transform($P)
    $pos = [Windows.Point]::new([Math]::Max(0, $pt.X - $Drag.Grab.X), [Math]::Max(0, $pt.Y - $Drag.Grab.Y))
    $ox = $src.X; $oy = $src.Y; $op = $src.Parent
    $i = 0
    foreach ($r in $remoteItems) {
        Add-Link $r $info.Id ([Windows.Point]::new($pos.X + ($i % 5) * 104, $pos.Y + [Math]::Floor($i / 5) * 112)) -Quiet
        $i++
    }
    foreach ($v in $virtItems) {
        if ($info.Id -and ($info.Id -eq $v.Id -or (Test-Descendant $info.Id $v.Id))) { continue }
        if ($null -ne $v.X -and $null -ne $ox -and $v.Parent -eq $op) { $dx = $v.X - $ox; $dy = $v.Y - $oy }
        else { $dx = ($i % 5) * 104; $dy = [Math]::Floor($i / 5) * 112; $i++ }
        $v.Parent = $info.Id
        $v.X = [Math]::Max(0, [Math]::Round(($pos.X + $dx) / 8) * 8)
        $v.Y = [Math]::Max(0, [Math]::Round(($pos.Y + $dy) / 8) * 8)
    }
    Save-Store
    Update-AllVirtual
}

$script:H_IconDown = {
    param($s, $e)
    $tag = $s.Tag
    $mods = [Windows.Input.Keyboard]::Modifiers
    if ($e.ClickCount -ge 2) { Select-Icon $s; $script:Drag = $null; Open-Item $tag; $e.Handled = $true; return }
    $collapse = $false
    if ($mods -band [Windows.Input.ModifierKeys]::Shift) { Select-IconRange $s }
    elseif ($mods -band [Windows.Input.ModifierKeys]::Control) { Switch-IconSelection $s }
    elseif (-not $script:Sel.Contains($s)) { Select-Icon $s }
    else { $collapse = $true }
    $script:Drag = @{ Icon = $s; Tag = $tag; Start = $e.GetPosition($script:Stage); Grab = $e.GetPosition($s); Active = $false; Ghost = $null; Collapse = $collapse }
    [void]$s.CaptureMouse()
    $e.Handled = $true
}

$script:H_IconMove = {
    param($s, $e)
    $d = $script:Drag
    if (-not $d -or $d.Icon -ne $s -or -not $s.IsMouseCaptured) { return }
    $p = $e.GetPosition($script:Stage)
    if (-not $d.Active) {
        if ([Math]::Abs($p.X - $d.Start.X) -lt 5 -and [Math]::Abs($p.Y - $d.Start.Y) -lt 5) { return }
        $g = [Windows.Shapes.Rectangle]::new()
        $g.Width = $s.ActualWidth; $g.Height = $s.ActualHeight
        $g.Fill = [Windows.Media.VisualBrush]::new($s)
        $g.Opacity = 0.85
        [void]$script:Overlay.Children.Add($g)
        $d.Ghost = $g; $d.Active = $true
        $s.Opacity = 0.35
    }
    [Windows.Controls.Canvas]::SetLeft($d.Ghost, $p.X - $d.Grab.X)
    [Windows.Controls.Canvas]::SetTop($d.Ghost, $p.Y - $d.Grab.Y)
}

$script:H_IconUp = {
    param($s, $e)
    $d = $script:Drag
    $script:Drag = $null
    if ($s.IsMouseCaptured) { $s.ReleaseMouseCapture() }
    if (-not $d) { return }
    if (-not $d.Active) { if ($d.Collapse) { Select-Icon $s }; return }
    $script:Overlay.Children.Remove($d.Ghost)
    $s.Opacity = 1
    try { Complete-Drop $d ($e.GetPosition($script:Stage)) }
    catch { Show-Warn $_.Exception.Message }
}

$script:H_IconMenu = {
    param($s, $e)
    if (-not $script:Sel.Contains($s)) { Select-Icon $s }
    Show-IconMenu $s.Tag
    $e.Handled = $true
}

# Рамка выделения: тянется с пустого места окна или рабочего стола.
$script:H_BgClick = {
    param($s, $e)
    if (-not ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)) { Clear-Selection }
    $rect = [Windows.Shapes.Rectangle]::new()
    $rect.Stroke = New-Brush $script:Accent 0xFF; $rect.StrokeThickness = 1; $rect.Fill = New-Brush $script:Accent 0x30
    $rect.Width = 0; $rect.Height = 0
    [void]$script:Overlay.Children.Add($rect)
    $script:Rub = @{ Elem = $s; Start = $e.GetPosition($script:Stage); Rect = $rect; Active = $false; Base = @($script:Sel) }
    [void]$s.CaptureMouse()
}
$script:H_BgMove = {
    param($s, $e)
    $r = $script:Rub
    if (-not $r -or $r.Elem -ne $s -or -not $s.IsMouseCaptured) { return }
    $p = $e.GetPosition($script:Stage)
    if (-not $r.Active) {
        if ([Math]::Abs($p.X - $r.Start.X) -lt 4 -and [Math]::Abs($p.Y - $r.Start.Y) -lt 4) { return }
        $r.Active = $true
    }
    $x = [Math]::Min($p.X, $r.Start.X); $y = [Math]::Min($p.Y, $r.Start.Y)
    $w = [Math]::Abs($p.X - $r.Start.X); $h = [Math]::Abs($p.Y - $r.Start.Y)
    [Windows.Controls.Canvas]::SetLeft($r.Rect, $x); [Windows.Controls.Canvas]::SetTop($r.Rect, $y)
    $r.Rect.Width = $w; $r.Rect.Height = $h
    $box = [Windows.Rect]::new($x, $y, $w, $h)
    $panel = if ($s -is [Windows.Controls.ScrollViewer]) { $s.Content } else { $s }
    Clear-Selection
    foreach ($b in $r.Base) { Add-ToSelection $b }
    foreach ($ic in @($panel.Children)) {
        $bounds = $ic.TransformToVisual($script:Stage).TransformBounds([Windows.Rect]::new(0, 0, $ic.ActualWidth, $ic.ActualHeight))
        if ($box.IntersectsWith($bounds)) { Add-ToSelection $ic }
    }
}
$script:H_BgUp = {
    param($s, $e)
    $r = $script:Rub
    if ($r -and $r.Elem -eq $s) {
        $script:Rub = $null
        $script:Overlay.Children.Remove($r.Rect)
        if ($s.IsMouseCaptured) { $s.ReleaseMouseCapture() }
    }
}

# --- плавающие окна ---
$script:H_WinFront = { param($s, $e) [Windows.Controls.Panel]::SetZIndex($s, ++$script:Z) }

$script:H_TitleDown = {
    param($s, $e)
    $w = $s.Tag
    if ($e.ClickCount -ge 2) { Switch-Maximize $w; return }
    if ($w.Restore) { return }
    $w.DragStart = $e.GetPosition($script:Stage)
    $w.DragOrigin = [Windows.Point]::new([Windows.Controls.Canvas]::GetLeft($w.Root), [Windows.Controls.Canvas]::GetTop($w.Root))
    [void]$s.CaptureMouse()
}
$script:H_TitleMove = {
    param($s, $e)
    if (-not $s.IsMouseCaptured) { return }
    $w = $s.Tag
    $p = $e.GetPosition($script:Stage)
    [Windows.Controls.Canvas]::SetLeft($w.Root, [Math]::Max(0, $w.DragOrigin.X + $p.X - $w.DragStart.X))
    [Windows.Controls.Canvas]::SetTop($w.Root, [Math]::Max(0, $w.DragOrigin.Y + $p.Y - $w.DragStart.Y))
}
$script:H_TitleUp = { param($s, $e) if ($s.IsMouseCaptured) { $s.ReleaseMouseCapture() } }
$script:H_Close = { param($s, $e) Close-FloatWindow $s.Tag }
$script:H_Min = { param($s, $e) $s.Tag.Root.Visibility = 'Collapsed'; Update-Taskbar }
$script:H_Max = { param($s, $e) Switch-Maximize $s.Tag }
$script:H_Grip = {
    param($s, $e)
    $w = $s.Tag
    if ($w.Restore) { return }
    $r = $w.Root
    $r.Width = [Math]::Max(380, $r.ActualWidth + $e.HorizontalChange)
    $r.Height = [Math]::Max(260, $r.ActualHeight + $e.VerticalChange)
}
$script:H_TaskClick = {
    param($s, $e)
    $w = $s.Tag
    $w.Root.Visibility = 'Visible'
    [Windows.Controls.Panel]::SetZIndex($w.Root, ++$script:Z)
    Update-Taskbar
}
$script:H_SideClick = { param($s, $e) Update-Remote $s.Tag.W $s.Tag.Path $true }

# --- режимы отображения ---
function Add-ViewMenu($Menu, $Target, [string]$Current, [switch]$Flat) {
    $host1 = $Menu
    if (-not $Flat) {
        $host1 = [Windows.Controls.MenuItem]::new()
        $host1.Header = 'Вид'
    }
    foreach ($k in $script:ViewNames.Keys) {
        $mi = [Windows.Controls.MenuItem]::new()
        $mi.Header = $script:ViewNames[$k]
        $mi.IsChecked = ($k -eq $Current)
        $mi.Tag = @{ Target = $Target; Mode = $k }
        $mi.Add_Click($script:M_SetView)
        [void]$host1.Items.Add($mi)
    }
    if (-not $Flat) { [void]$Menu.Items.Add($host1) }
}

$script:M_SetSort = {
    param($s, $e)
    if ($s.Tag.Key) { $script:SortKey = $s.Tag.Key } else { $script:SortDesc = -not $script:SortDesc }
    Save-Store
    foreach ($w in @($script:Windows | Where-Object { $_.Type -eq 'remote' -and $_.Cwd })) { Show-Remote $w }
}

$script:M_SetView = {
    param($s, $e)
    $t = $s.Tag.Target
    $mode = $s.Tag.Mode
    if ($t.Type -eq 'remote') {
        $t.W.View = $mode
        $script:RemoteView = $mode
        Save-Store
        if ($t.W.Cwd) { Show-Remote $t.W }
    }
    else {
        if ($t.Id) { (Get-VItem $t.Id).View = $mode } else { $script:DesktopView = $mode }
        Save-Store
        Update-AllVirtual
    }
    Set-Status "Вид: $($script:ViewNames[$mode])"
}

$script:H_ViewBtn = {
    param($s, $e)
    $w = $s.Tag
    $menu = New-Menu
    if ($w.Type -eq 'remote') { Add-ViewMenu $menu @{ Type = 'remote'; W = $w } $w.View -Flat }
    else { Add-ViewMenu $menu @{ Type = 'virtual'; Id = $w.Id } (Get-ContainerView $w.Id) -Flat }
    $menu.PlacementTarget = $s
    $menu.Placement = 'Bottom'
    $menu.IsOpen = $true
}

# --- окно сервера ---
$script:H_RBack = {
    param($s, $e)
    $w = $s.Tag
    if ($w.History.Count) {
        $prev = $w.History[$w.History.Count - 1]
        $w.History.RemoveAt($w.History.Count - 1)
        Update-Remote $w $prev $false
    }
}
$script:H_RUp = {
    param($s, $e)
    $w = $s.Tag
    if (-not $w.Cwd -or $w.Cwd -eq '/') { return }
    $parent = $w.Cwd -replace '/[^/]+/?$', ''
    Update-Remote $w $(if ($parent) { $parent } else { '/' }) $true
}
$script:H_RReload = { param($s, $e) Update-Remote $s.Tag $(if ($s.Tag.Cwd) { $s.Tag.Cwd } else { $s.Tag.Path }) $false }
$script:H_RPathKey = {
    param($s, $e)
    if ($s.Tag.Type -eq 'remote' -and $e.Key -eq 'Return' -and $s.Text.Trim()) { Update-Remote $s.Tag $s.Text.Trim() $true; $e.Handled = $true }
}

function Select-UploadFiles($w) {
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Multiselect = $true
    $dlg.Title = 'Что загрузить на сервер'
    if ($dlg.ShowDialog()) { Send-Files $w $dlg.FileNames }
}

function New-RemoteFolder($w) {
    if (-not $w.Cwd) { return }
    $name = Read-Text 'Новая папка на сервере' "Создать папку НА СЕРВЕРЕ в «$($w.Cwd)»:" 'Новая папка'
    if (-not $name) { return }
    Start-SftpOp @("mkdir $(ConvertTo-SftpArg (Join-Remote $w.Cwd $name))") $script:D_Changed @{ W = $w; What = 'Папка создана' }
}

$script:H_FileDragOver = {
    param($s, $e)
    $e.Effects = if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { [Windows.DragDropEffects]::Copy } else { [Windows.DragDropEffects]::None }
    $e.Handled = $true
}
$script:H_FileDrop = {
    param($s, $e)
    if ($e.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) { Send-Files $s.Tag.Win ([string[]]$e.Data.GetData([Windows.DataFormats]::FileDrop)) }
    $e.Handled = $true
}

# --- меню фона (вся навигация и действия — в контекстном меню) ---
$script:H_VirtualBgMenu = {
    param($s, $e)
    $info = $s.Tag
    $menu = New-Menu
    $tag = @{ Id = $info.Id; Pos = $e.GetPosition($s) }
    [void](Add-MenuItem $menu 'Новая виртуальная папка' $tag { param($m, $a) New-VirtualFolder $m.Tag.Id $m.Tag.Pos })
    [void](Add-MenuItem $menu 'Упорядочить значки' $tag { param($m, $a) Reset-Positions $m.Tag.Id })
    Add-ViewMenu $menu @{ Type = 'virtual'; Id = $info.Id } (Get-ContainerView $info.Id)
    if (-not $info.Id) {
        Add-MenuItem $menu '-'
        [void](Add-MenuItem $menu 'Открыть сервер' $null { param($m, $a) Open-RemoteWindow '.' })
        [void](Add-MenuItem $menu 'Найти…' $null $script:M_FindAll)
        [void](Add-MenuItem $menu 'Открыть терминал SSH' $null $script:M_Terminal)
        [void](Add-MenuItem $menu 'Обновить окна' $null $script:M_RefreshAll)
    }
    $menu.IsOpen = $true
    $e.Handled = $true
}
$script:H_RemoteBgMenu = {
    param($s, $e)
    $w = $s.Tag.Win
    $menu = New-Menu
    [void](Add-MenuItem $menu 'Обновить' $w { param($m, $a) Update-Remote $m.Tag $m.Tag.Cwd $false })
    Add-MenuItem $menu '-'
    [void](Add-MenuItem $menu 'Найти на сервере…' $w { param($m, $a) Start-RemoteSearch $m.Tag })
    [void](Add-MenuItem $menu 'Загрузить файлы на сервер…' $w { param($m, $a) Select-UploadFiles $m.Tag })
    [void](Add-MenuItem $menu 'Новая папка на сервере…' $w { param($m, $a) New-RemoteFolder $m.Tag })
    Add-MenuItem $menu '-'
    $hid = Add-MenuItem $menu 'Показывать скрытые файлы' $w { param($m, $a) $m.Tag.ShowHidden = -not $m.Tag.ShowHidden; if ($m.Tag.Cwd) { Show-Remote $m.Tag } }
    $hid.IsChecked = [bool]$w.ShowHidden
    Add-ViewMenu $menu @{ Type = 'remote'; W = $w } $w.View
    $sort = [Windows.Controls.MenuItem]::new()
    $sort.Header = 'Сортировка'
    foreach ($k in $script:SortNames.Keys) {
        $mi = [Windows.Controls.MenuItem]::new()
        $mi.Header = $script:SortNames[$k]; $mi.IsChecked = ($k -eq $script:SortKey); $mi.Tag = @{ W = $w; Key = $k }
        $mi.Add_Click($script:M_SetSort)
        [void]$sort.Items.Add($mi)
    }
    [void]$sort.Items.Add([Windows.Controls.Separator]::new())
    $desc = [Windows.Controls.MenuItem]::new()
    $desc.Header = 'В обратном порядке'; $desc.IsChecked = [bool]$script:SortDesc; $desc.Tag = @{ W = $w; Key = $null }
    $desc.Add_Click($script:M_SetSort)
    [void]$sort.Items.Add($desc)
    [void]$menu.Items.Add($sort)
    $menu.IsOpen = $true
    $e.Handled = $true
}

# Общий поиск: ярлыки и папки рабочего стола (подсвечиваются) + файлы на сервере (новое окно с результатами).
$script:M_FindAll = {
    $q = Read-Text 'Найти' 'Искать по имени на рабочем столе и на сервере (от домашней папки; можно маски * и ?):' ''
    if (-not $q) { return }
    $pat = if ($q -match '[*?]') { $q } else { "*$q*" }
    Update-AllVirtual
    $found = 0
    foreach ($ic in @($script:Desktop.Children)) {
        if ($ic.Tag -and $ic.Tag.Item -and $ic.Tag.Item.Name -like $pat) { Add-ToSelection $ic; $found++ }
    }
    $rw = Open-RemoteWindow '.' -NoLoad
    $rw.WinStatus.Text = '⏳ Ищу на сервере…'
    Set-Status "На рабочем столе найдено: $found (выделено). Ищу на сервере…"
    Start-RemoteSearch $rw $q
}

# --- меню «Пуск» на нижней панели ---
function New-WinShortcut {
    $c = $script:Conn
    $name = $c.Name -replace '[\\/:*?"<>|]', '_'
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "SSH Рабочий стол - $name.lnk"
    $argLine = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File `"$PSCommandPath`" -ConfigPath `"$ConfigPath`" -Name `"$($c.Name)`" -Address `"$($c.Address)`" -Port $($c.Port)"
    if ($c.Login) { $argLine += " -Login `"$($c.Login)`"" }
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
    $lnk.TargetPath = (Get-Command pwsh.exe).Source
    $lnk.Arguments = $argLine
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = (Get-Command pwsh.exe).Source + ',0'
    $lnk.Save()
    return $lnkPath
}
$script:M_Shortcut = {
    try { Set-Status "Ярлык создан: $(New-WinShortcut)" }
    catch { Set-Status "⚠ $($_.Exception.Message)" }
}
$script:M_Terminal = {
    try { Set-Status "Терминал SSH открыт ($(Start-TerminalSsh $script:Conn))" }
    catch { Set-Status "⚠ $($_.Exception.Message)" }
}
$script:M_RefreshAll = {
    foreach ($w in @($script:Windows | Where-Object { $_.Type -eq 'remote' -and $_.Cwd })) { Update-Remote $w $w.Cwd $false }
}
$script:H_StartClick = {
    param($s, $e)
    $menu = New-Menu
    $head = Add-MenuItem $menu "$($script:Conn.Name)  ·  $($script:Conn.Address):$($script:Conn.Port)" $null $null
    $head.IsEnabled = $false
    Add-MenuItem $menu '-'
    [void](Add-MenuItem $menu 'Сервер — домашняя папка' $null { param($m, $a) Open-RemoteWindow '.' })
    [void](Add-MenuItem $menu 'Сервер — корень /' $null { param($m, $a) Open-RemoteWindow '/' })
    [void](Add-MenuItem $menu 'Открыть терминал SSH' $null $script:M_Terminal)
    Add-MenuItem $menu '-'
    [void](Add-MenuItem $menu 'Новая виртуальная папка' $null { param($m, $a) New-VirtualFolder $null $null })
    [void](Add-MenuItem $menu 'Упорядочить значки' $null { param($m, $a) Reset-Positions $null })
    Add-ViewMenu $menu @{ Type = 'virtual'; Id = $null } $script:DesktopView
    [void](Add-MenuItem $menu 'Обновить окна' $null $script:M_RefreshAll)
    [void](Add-MenuItem $menu 'Создать ярлык на рабочем столе Windows' $null $script:M_Shortcut)
    Add-MenuItem $menu '-'
    [void](Add-MenuItem $menu 'Закрыть рабочий стол' $null { param($m, $a) $script:Main.Close() })
    $menu.PlacementTarget = $s
    $menu.Placement = 'Top'
    $menu.IsOpen = $true
    $e.Handled = $true
}

# --- пункты меню иконок ---
$script:M_Open = { param($s, $e) Open-Item $s.Tag }
$script:M_VRename = {
    param($s, $e)
    $item = $s.Tag.Item
    $name = Read-Text 'Переименовать' 'Новое имя (только на этом ПК — сервер не меняется):' $item.Name
    if ($name) { $item.Name = $name; Save-Store; Update-AllVirtual }
}
$script:M_VColor = {
    param($s, $e)
    $item = $s.Tag.Item
    $c = Select-ColorDialog $item.Color
    if ($c) { $item.Color = $c; Save-Store; Update-AllVirtual }
}
$script:M_VRemove = {
    param($s, $e)
    $item = $s.Tag.Item
    $inside = @($script:Items | Where-Object { $_.Parent -eq $item.Id }).Count
    $msg = if ($item.Kind -eq 'vfolder') { "Убрать виртуальную папку «$($item.Name)»" + $(if ($inside) { " вместе с ярлыками внутри ($inside)" } else { '' }) + "?`nФайлы на сервере не затрагиваются." }
    else { "Убрать ярлык «$($item.Name)»?`nФайл на сервере останется на месте." }
    if ([Windows.MessageBox]::Show($script:Main, $msg, 'SSH', 'YesNo', 'Question') -eq 'Yes') {
        Remove-VItem $item.Id
        Save-Store
        Update-AllVirtual
    }
}
$script:M_Pin = { param($s, $e) Add-Link $s.Tag.Item $null $null }
$script:M_PinTo = { param($s, $e) Add-Link $s.Tag.Item $s.Tag.FolderId $null }
$script:M_Download = {
    param($s, $e)
    $item = $s.Tag.Item
    $dlg = [Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = "Куда скопировать «$($item.Name)»"
    $dlg.SelectedPath = Join-Path $env:USERPROFILE 'Downloads'
    $wrap = [Win32Owner]::new()
    $wrap.Handle = [Windows.Interop.WindowInteropHelper]::new($script:Main).Handle
    if ($dlg.ShowDialog($wrap) -ne 'OK') { return }
    $dest = (Join-Path $dlg.SelectedPath $item.Name) -replace '\\', '/'
    $flag = if ($item.IsDir) { '-r ' } else { '' }
    Set-Status "⏳ Копирую «$($item.Name)» на ПК…"
    Start-SftpOp @("get -p $flag$(ConvertTo-SftpArg $item.Path) $(ConvertTo-SftpArg $dest)") $script:D_Copied @{ Name = $item.Name; Dest = $dlg.SelectedPath }
}
$script:M_RRename = {
    param($s, $e)
    $tag = $s.Tag
    $item = $tag.Item
    $name = Read-Text 'Переименовать на сервере' "ИЗМЕНИТЬ ИМЯ НА СЕРВЕРЕ:`n$($item.Path)" $item.Name
    if (-not $name -or $name -eq $item.Name) { return }
    $new = Join-Remote ($item.Path -replace '/[^/]+$', '') $name
    if ([Windows.MessageBox]::Show($script:Main, "Переименовать на сервере:`n$($item.Path)`n→ $new", 'SSH — изменение сервера', 'OKCancel', 'Warning') -ne 'OK') { return }
    Start-SftpOp @("rename $(ConvertTo-SftpArg $item.Path) $(ConvertTo-SftpArg $new)") $script:D_Changed @{ W = $tag.Win; What = 'Переименовано' }
}
$script:M_RDelete = { param($s, $e) Remove-RemoteItems @($s.Tag.Item) $s.Tag.Win }
$script:M_DeleteMany = { param($s, $e) Remove-RemoteItems @($s.Tag.Tags | ForEach-Object { $_.Item }) $s.Tag.Win }
$script:M_Edit = { param($s, $e) Edit-RemoteFile $s.Tag.Item.Path ($s.Tag.Item.Path -split '/')[-1] }
$script:M_PinMany = {
    param($s, $e)
    foreach ($t in $s.Tag.Tags) { Add-Link $t.Item $null $null -Quiet }
    Save-Store; Update-AllVirtual
    Set-Status "Закреплено ярлыков: $($s.Tag.Tags.Count) — на сервере ничего не изменилось"
}
$script:M_VRemoveMany = {
    param($s, $e)
    $tags = $s.Tag.Tags
    if ([Windows.MessageBox]::Show($script:Main, "Убрать выбранное ($($tags.Count))?`nФайлы на сервере не затрагиваются.", 'SSH', 'YesNo', 'Question') -ne 'Yes') { return }
    foreach ($t in $tags) { if (Get-VItem $t.Item.Id) { Remove-VItem $t.Item.Id } }
    Save-Store; Update-AllVirtual
}
$script:M_DownloadMany = {
    param($s, $e)
    $items = @($s.Tag.Tags | ForEach-Object { $_.Item })
    $dest = Select-LocalFolder "Куда скопировать выбранное ($($items.Count))"
    if (-not $dest) { return }
    $cmds = foreach ($i in $items) {
        $flag = if ($i.IsDir) { '-r ' } else { '' }
        "get -p $flag$(ConvertTo-SftpArg $i.Path) $(ConvertTo-SftpArg ((Join-Path $dest ($i.Path -split '/')[-1]) -replace '\\', '/'))"
    }
    Set-Status "⏳ Копирую на ПК: $($items.Count)…"
    Start-SftpOp @($cmds) $script:D_Copied @{ Name = "$($items.Count) объектов"; Dest = $dest }
}
# --- завершение операций sftp ---
$script:D_Listing = {
    param($res, $st)
    $w = $st.W
    if ($w.Closed) { return }
    $w.Loading = $false
    $err = Get-SftpError $res
    if ($err) { $w.WinStatus.Text = "⚠ $err"; return }
    $parsed = ConvertFrom-SftpLs $res.Out
    if (-not $parsed.Cwd) { $w.WinStatus.Text = '⚠ Не удалось прочитать каталог'; return }
    if ($st.Push -and $w.Cwd -and $w.Cwd -ne $parsed.Cwd) { $w.History.Add($w.Cwd) }
    $w.Search = $null
    $w.Cwd = $parsed.Cwd
    $w.Entries = $parsed.Entries
    Show-Remote $w
}
$script:D_OpenFile = {
    param($res, $st)
    $err = Get-SftpError $res
    if ($err) { Set-Status "⚠ $err"; return }
    Set-Status "Открыто: $($st.Local)"
    Start-Process -FilePath $st.Local
}
$script:D_EditReady = {
    param($res, $st)
    $err = Get-SftpError $res
    if ($err) { Set-Status "⚠ $err"; return }
    $it = Get-Item -LiteralPath $st.Local
    foreach ($old in @($script:Edits | Where-Object { $_.Local -eq $st.Local })) { [void]$script:Edits.Remove($old) }
    $script:Edits.Add(@{ Local = $st.Local; Remote = $st.Remote; Leaf = $st.Leaf; Stamp = $it.LastWriteTimeUtc; Len = $it.Length; Busy = $false })
    Start-Process -FilePath $st.Local
    Set-Status "Правьте «$($st.Leaf)»: после сохранения предложу загрузить файл обратно на сервер"
}
$script:D_EditSaved = {
    param($res, $st)
    $ed = $st.Ed
    $err = Get-SftpError $res
    if ($err) { Set-Status "⚠ $err" }
    else {
        Set-Status "«$($ed.Leaf)» загружен на сервер"
        try { $it = Get-Item -LiteralPath $ed.Local; $ed.Stamp = $it.LastWriteTimeUtc; $ed.Len = $it.Length } catch { }
    }
    $ed.Busy = $false
}
$script:D_Search = {
    param($res, $st)
    $w = $st.W
    if ($w.Closed) { return }
    $err = Get-SftpError $res
    if ($err -and -not $res.Out.Trim()) { $w.WinStatus.Text = "⚠ $err"; return }
    $dir = $st.Dir.TrimEnd('/')
    $entries = [Collections.Generic.List[hashtable]]::new()
    foreach ($line in $res.Out -split "`r?`n") {
        $f = $line -split "`t", 4
        if ($f.Count -lt 4 -or -not $f[3].StartsWith($dir)) { continue }
        $rel = $f[3].Substring($dir.Length).TrimStart('/')
        if (-not $rel) { continue }
        $date = $null
        try { $date = [datetime]::ParseExact($f[2], 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) } catch { }
        $entries.Add(@{ Name = $rel; IsDir = ($f[0] -eq 'd'); IsLink = ($f[0] -eq 'l'); Size = [long]$f[1]; Date = $date; FullPath = $f[3] })
    }
    $w.Entries = $entries
    $w.Search = @{ Query = $st.Query; Count = $entries.Count }
    Show-Remote $w
}
$script:D_Copied = {
    param($res, $st)
    $err = Get-SftpError $res
    if ($err) { Set-Status "⚠ $err" } else { Set-Status "Скопировано на ПК: $($st.Name) → $($st.Dest)" }
}
$script:D_Changed = {
    param($res, $st)
    $w = $st.W
    $err = Get-SftpError $res
    if ($err) { if (-not $w.Closed) { $w.WinStatus.Text = "⚠ $err" }; Set-Status "⚠ $err"; return }
    Set-Status "$($st.What) на сервере"
    if (-not $w.Closed) { Update-Remote $w $w.Cwd $false }
}

$script:H_Shot = {
    $script:ShotTimer.Stop()
    Save-Snapshot $script:Main.Content $script:ShotPath
    $script:Main.Close()
}

$script:TickN = 0
$script:H_Tick = {
    $script:TickN++
    if ($script:TickN % 8 -eq 0 -and $script:Edits.Count) { Test-EditChanges }
    $now = (Get-Date).ToString('HH:mm')
    if ($script:Clock.Text -ne $now) { $script:Clock.Text = $now }
    foreach ($op in @($script:Ops)) {
        if ($op.P.HasExited -and $op.Out.IsCompleted -and $op.Err.IsCompleted) {
            [void]$script:Ops.Remove($op)
            $res = @{ Out = $op.Out.Result; Err = $op.Err.Result; Code = $op.P.ExitCode }
            try { & $op.Done $res $op.State }
            catch { Set-Status "⚠ $($_.Exception.Message)" }
            Update-Busy
        }
    }
}

#endregion

#region Главное окно

Read-Store

$script:Main = Read-Xaml $mainXaml
$script:Main.Title = "Рабочий стол — $($script:Conn.Name)"
$script:Stage = $script:Main.FindName('Stage')
$script:Desktop = $script:Main.FindName('Desktop')
$script:Floating = $script:Main.FindName('Floating')
$script:Overlay = $script:Main.FindName('Overlay')
$script:StatusText = $script:Main.FindName('Status')
$script:Tasks = $script:Main.FindName('Tasks')
$script:Clock = $script:Main.FindName('Clock')
if ($TestView) { $script:DesktopView = $TestView; $script:RemoteView = $TestView }
$script:Main.FindName('Dot').Fill = New-Brush $script:GroupHex
$script:Main.FindName('Caption').Text = "$($script:Conn.Name)  ·  $($script:Conn.Address):$($script:Conn.Port)"

$glow = [Windows.Media.RadialGradientBrush]::new()
$glow.Center = [Windows.Point]::new(0.12, 0.05); $glow.GradientOrigin = $glow.Center; $glow.RadiusX = 1.0; $glow.RadiusY = 1.1
$rgb = ConvertFrom-Hex $script:GroupHex
[void]$glow.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color]::FromArgb(0x55, $rgb[0], $rgb[1], $rgb[2]), 0))
[void]$glow.GradientStops.Add([Windows.Media.GradientStop]::new([Windows.Media.Color]::FromArgb(0x00, $rgb[0], $rgb[1], $rgb[2]), 1))
$script:Main.FindName('Glow').Fill = $glow

$script:Desktop.Tag = @{ Container = 'virtual'; Id = $null; Canvas = $script:Desktop }
$script:Desktop.Add_MouseLeftButtonDown($script:H_BgClick); $script:Desktop.Add_MouseMove($script:H_BgMove); $script:Desktop.Add_MouseLeftButtonUp($script:H_BgUp)
$script:Desktop.Add_MouseRightButtonUp($script:H_VirtualBgMenu)

$script:Main.FindName('StartBtn').Add_MouseLeftButtonUp($script:H_StartClick)
if (-not $Screenshot) { $script:Main.WindowState = 'Maximized' }

$script:Timer = [Windows.Threading.DispatcherTimer]::new()
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:Timer.Add_Tick($script:H_Tick)
$script:Timer.Start()

$script:Main.Add_Closing({
        if (-not ($Screenshot -or $TestRemote -or $TestVirtual)) {
            try {
                $script:SavedWindows = @(foreach ($w in $script:Windows) {
                        $r = $w.Root
                        $g = if ($w.Restore) { $w.Restore } else { @{ L = [Windows.Controls.Canvas]::GetLeft($r); T = [Windows.Controls.Canvas]::GetTop($r); W = $r.ActualWidth; H = $r.ActualHeight } }
                        @{ Type = $w.Type; Id = $w.Id; Path = $(if ($w.Cwd) { $w.Cwd } else { $w.Path }); L = $g.L; T = $g.T; W = $g.W; H = $g.H; Min = ($r.Visibility -ne 'Visible') }
                    })
                Save-Store
            }
            catch { }
        }
        foreach ($op in $script:Ops) { try { if (-not $op.P.HasExited) { $op.P.Kill() } } catch { } }
    })

$script:Main.Add_ContentRendered({
        Update-AllVirtual
        if ($TestVirtual) { $v = Get-VItem $TestVirtual; if ($v) { Open-VirtualWindow $v } }
        if ($TestRemote) { Open-RemoteWindow $TestRemote }
        if (-not ($Screenshot -or $TestRemote -or $TestVirtual)) {
            foreach ($s in @($script:SavedWindows)) {
                try {
                    $before = $script:Windows.Count
                    if ($s.Type -eq 'virtual') { $v = Get-VItem ([string]$s.Id); if ($v) { Open-VirtualWindow $v } }
                    elseif ($s.Type -eq 'remote') { Open-RemoteWindow ([string]$(if ($s.Path) { $s.Path } else { '.' })) }
                    if ($script:Windows.Count -gt $before) {
                        $w = $script:Windows[$script:Windows.Count - 1]
                        [Windows.Controls.Canvas]::SetLeft($w.Root, [Math]::Max(0, [double]$s.L)); [Windows.Controls.Canvas]::SetTop($w.Root, [Math]::Max(0, [double]$s.T))
                        $w.Root.Width = [Math]::Max(380, [double]$s.W); $w.Root.Height = [Math]::Max(260, [double]$s.H)
                        if ($s.Min) { $w.Root.Visibility = 'Collapsed' }
                    }
                }
                catch { }
            }
            Update-Taskbar
        }
        if ($Screenshot) {
            $script:ShotPath = $Screenshot
            $script:ShotTimer = [Windows.Threading.DispatcherTimer]::new()
            $script:ShotTimer.Interval = [TimeSpan]::FromSeconds($(if ($TestRemote) { 7 } else { 1 }))
            $script:ShotTimer.Add_Tick($script:H_Shot)
            $script:ShotTimer.Start()
        }
    })

[void]$script:Main.ShowDialog()

#endregion
