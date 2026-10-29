#Requires -Version 7.0
<#
.SYNOPSIS
    Оконная (WPF) версия ssh-menu: те же connections.yml, группы и цвета, но в обычном окне Windows.

.DESCRIPTION
    Подключение открывается в отдельном окне консоли, само меню остаётся открытым.
    Пароль передаётся в ssh через SSH_ASKPASS (askpass.cmd), в командной строке его не видно.

.EXAMPLE
    pwsh -STA -File ssh-menu-gui.ps1
    pwsh -File ssh-menu-gui.ps1 -CreateShortcut   # создать ssh-menu-gui.lnk
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'connections.yml'),
    [switch]$CreateShortcut,
    [string]$Screenshot,        # для проверки: сохранить снимок главного окна и выйти
    [string]$DialogScreenshot   # для проверки: открыть форму первого подключения, снять и выйти
)

$ErrorActionPreference = 'Stop'

if ($CreateShortcut) {
    $lnkPath = Join-Path $PSScriptRoot 'ssh-menu-gui.lnk'
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
    $lnk.TargetPath = (Get-Command pwsh.exe).Source
    $lnk.Arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    $lnk.WorkingDirectory = $PSScriptRoot
    $lnk.IconLocation = (Get-Command pwsh.exe).Source + ',0'
    $lnk.Save()
    Write-Host "Ярлык создан: $lnkPath"
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
if (-not ('Win32Owner' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
public class Win32Owner : System.Windows.Forms.IWin32Window {
    public System.IntPtr Handle { get; set; }
}
'@
}

# Хранилище, парсер адреса, DPAPI и цвета — из консольной версии.
. (Join-Path $PSScriptRoot 'ssh-menu.ps1') -ConfigPath $ConfigPath

#region XAML

$stylesXaml = @'
<Style TargetType="Button">
  <Setter Property="Foreground" Value="#E8E8EC"/>
  <Setter Property="Background" Value="#2C303A"/>
  <Setter Property="BorderBrush" Value="#3A3F4C"/>
  <Setter Property="Padding" Value="14,7"/>
  <Setter Property="Margin" Value="0,0,8,0"/>
  <Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>
<Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
  <Setter Property="Background" Value="#5B8DEF"/>
  <Setter Property="BorderBrush" Value="#5B8DEF"/>
  <Setter Property="Foreground" Value="White"/>
</Style>
<Style x:Key="Chip" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
  <Setter Property="Padding" Value="10,3"/>
  <Setter Property="Margin" Value="0,6,6,0"/>
  <Setter Property="FontSize" Value="13"/>
</Style>
<Style TargetType="TextBox">
  <Setter Property="Background" Value="#14161B"/>
  <Setter Property="Foreground" Value="#E8E8EC"/>
  <Setter Property="BorderBrush" Value="#3A3F4C"/>
  <Setter Property="CaretBrush" Value="#E8E8EC"/>
  <Setter Property="SelectionBrush" Value="#5B8DEF"/>
  <Setter Property="Padding" Value="8,6"/>
  <Setter Property="VerticalContentAlignment" Value="Center"/>
</Style>
<Style TargetType="PasswordBox">
  <Setter Property="Background" Value="#14161B"/>
  <Setter Property="Foreground" Value="#E8E8EC"/>
  <Setter Property="BorderBrush" Value="#3A3F4C"/>
  <Setter Property="CaretBrush" Value="#E8E8EC"/>
  <Setter Property="SelectionBrush" Value="#5B8DEF"/>
  <Setter Property="Padding" Value="8,6"/>
  <Setter Property="VerticalContentAlignment" Value="Center"/>
</Style>
<Style TargetType="CheckBox">
  <Setter Property="Foreground" Value="#B7BBC8"/>
  <Setter Property="Margin" Value="0,8,0,0"/>
</Style>
<Style x:Key="Lbl" TargetType="TextBlock">
  <Setter Property="Foreground" Value="#8B90A0"/>
  <Setter Property="FontSize" Value="12"/>
  <Setter Property="Margin" Value="0,12,0,4"/>
</Style>
'@

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SSH" Width="980" Height="680" MinWidth="680" MinHeight="420"
        WindowStartupLocation="CenterScreen" Background="#1B1D23" Foreground="#E8E8EC"
        FontFamily="Segoe UI" FontSize="14" UseLayoutRounding="True">
  <Window.Resources>
    <!--STYLES-->
    <Style x:Key="Row" TargetType="ListBoxItem">
      <Setter Property="Padding" Value="10,4"/>
      <Setter Property="Margin" Value="0,1"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="bd" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Background" Value="#262A34"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="bd" Property="Background" Value="#2F3A52"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="0,0,0,12">
      <TextBox x:Name="Search" FontSize="15" Padding="12,9"/>
      <TextBlock x:Name="SearchHint" Text="Поиск по названию, адресу, группе, логину…" Foreground="#6C7283"
                 Margin="14,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False" FontSize="15"/>
    </Grid>

    <Border Grid.Row="1" Background="#20232A" BorderBrush="#2E323D" BorderThickness="1" CornerRadius="8">
      <ListBox x:Name="List" Background="Transparent" BorderThickness="0" Foreground="#E8E8EC"
               ItemContainerStyle="{StaticResource Row}" Margin="6"
               ScrollViewer.HorizontalScrollBarVisibility="Disabled">
        <ListBox.GroupStyle>
          <GroupStyle>
            <GroupStyle.HeaderTemplate>
              <DataTemplate>
                <StackPanel Orientation="Horizontal" Margin="6,14,0,4">
                  <Rectangle Width="10" Height="10" RadiusX="2" RadiusY="2" Fill="{Binding Items[0].Brush}" VerticalAlignment="Center"/>
                  <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="15" Margin="8,0,0,0" Foreground="{Binding Items[0].Brush}"/>
                  <TextBlock Text="{Binding ItemCount}" Foreground="#6C7283" Margin="8,2,0,0"/>
                </StackPanel>
              </DataTemplate>
            </GroupStyle.HeaderTemplate>
          </GroupStyle>
        </ListBox.GroupStyle>
        <ListBox.ItemTemplate>
          <DataTemplate>
            <Grid MinHeight="28">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="2*"/>
                <ColumnDefinition Width="1.5*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <Rectangle Grid.Column="0" Width="3" Fill="{Binding Brush}" RadiusX="1.5" RadiusY="1.5" Margin="0,2,12,2"/>
              <TextBlock Grid.Column="1" Text="{Binding Name}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,0,12,0"/>
              <TextBlock Grid.Column="2" Text="{Binding Address}" VerticalAlignment="Center" Foreground="#9AA0B2" TextTrimming="CharacterEllipsis" Margin="0,0,12,0"/>
              <TextBlock Grid.Column="3" Text="{Binding Login}" VerticalAlignment="Center" Foreground="#9AA0B2" TextTrimming="CharacterEllipsis"/>
              <TextBlock Grid.Column="4" Text="{Binding Pw}" VerticalAlignment="Center" Foreground="#6C7283" FontSize="12" Margin="8,0,0,0"/>
            </Grid>
          </DataTemplate>
        </ListBox.ItemTemplate>
      </ListBox>
    </Border>

    <Grid Grid.Row="2" Margin="0,14,0,0">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="BtnConnect" Style="{StaticResource Primary}" Content="Подключить"/>
        <Button x:Name="BtnFiles" Content="🗂 Файлы"/>
        <Button x:Name="BtnNew" Content="+ Новое"/>
        <Button x:Name="BtnEdit" Content="Изменить"/>
        <Button x:Name="BtnColor" Content="Цвет группы…"/>
      </StackPanel>
      <Button x:Name="BtnDelete" Content="Удалить" HorizontalAlignment="Right" Margin="0" Foreground="#F08A8A"/>
    </Grid>

    <TextBlock x:Name="Status" Grid.Row="3" Margin="2,10,0,0" Foreground="#6C7283" FontSize="12"
               Text="Enter — подключить · F4 — файлы · Ins — новое · F2 — изменить · F3 — цвет группы · Del — удалить · двойной щелчок — подключить"/>
  </Grid>
</Window>
'@

$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="540" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="#1B1D23" Foreground="#E8E8EC"
        FontFamily="Segoe UI" FontSize="14" UseLayoutRounding="True">
  <Window.Resources>
    <!--STYLES-->
  </Window.Resources>
  <StackPanel Margin="22,10,22,20">
    <TextBlock Style="{StaticResource Lbl}" Text="Адрес  (host, user@host:port или вставьте целиком «ssh -l user -p 22 host»)"/>
    <TextBox x:Name="Address"/>

    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="130"/>
        <ColumnDefinition Width="14"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock Style="{StaticResource Lbl}" Text="Порт"/>
        <TextBox x:Name="Port"/>
      </StackPanel>
      <StackPanel Grid.Column="2">
        <TextBlock Style="{StaticResource Lbl}" Text="Логин (необязательно)"/>
        <TextBox x:Name="Login"/>
      </StackPanel>
    </Grid>

    <TextBlock x:Name="PassLabel" Style="{StaticResource Lbl}" Text="Пароль"/>
    <PasswordBox x:Name="Pass"/>
    <CheckBox x:Name="ClearPass" Content="Убрать сохранённый пароль" Visibility="Collapsed"/>

    <TextBlock Style="{StaticResource Lbl}" Text="Название"/>
    <TextBox x:Name="Name"/>

    <TextBlock Style="{StaticResource Lbl}" Text="Группа  (выберите из существующих или введите новую)"/>
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <TextBox x:Name="Group" Grid.Column="0"/>
      <StackPanel Grid.Column="1" Orientation="Horizontal" Margin="10,0,0,0">
        <Rectangle x:Name="Swatch" Width="30" Height="30" RadiusX="6" RadiusY="6" Stroke="#3A3F4C" Margin="0,0,8,0"/>
        <Button x:Name="PickColor" Content="Цвет…" Margin="0"/>
      </StackPanel>
    </Grid>
    <WrapPanel x:Name="Chips" Margin="0,0,0,0"/>

    <TextBlock x:Name="Err" Foreground="#F08A8A" Margin="0,14,0,0" TextWrapping="Wrap"/>

    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
      <Button x:Name="Cancel" Content="Отмена" IsCancel="True"/>
      <Button x:Name="Ok" Content="Сохранить" Style="{StaticResource Primary}" IsDefault="True" Margin="0"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

function New-Window([string]$Xaml) {
    [Windows.Markup.XamlReader]::Parse($Xaml.Replace('<!--STYLES-->', $stylesXaml))
}

#endregion

#region Помощники

function New-Brush([string]$Hex) {
    $rgb = ConvertFrom-Hex $Hex
    if (-not $rgb) { $rgb = 0x9A, 0xA0, 0xB2 }
    $brush = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb($rgb[0], $rgb[1], $rgb[2]))
    $brush.Freeze()
    return $brush
}

function Show-Error([string]$Text) {
    [void][Windows.MessageBox]::Show($Text, 'SSH', 'OK', 'Warning')
}

# Системный диалог выбора цвета Windows (полная палитра + свои цвета). Возвращает '#rrggbb' или $null.
function Select-ColorDialog([string]$Current, $Owner) {
    $rgb = ConvertFrom-Hex $Current
    if (-not $rgb) { $rgb = 0x5B, 0x8D, 0xEF }
    $dlg = [Windows.Forms.ColorDialog]::new()
    $dlg.AllowFullOpen = $true
    $dlg.FullOpen = $true
    $dlg.Color = [Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2])
    $wrap = [Win32Owner]::new()
    if ($Owner) { $wrap.Handle = [Windows.Interop.WindowInteropHelper]::new($Owner).Handle }
    $result = if ($Owner) { $dlg.ShowDialog($wrap) } else { $dlg.ShowDialog() }
    if ($result -ne 'OK') { return $null }
    return ConvertTo-Hex $dlg.Color.R $dlg.Color.G $dlg.Color.B
}

function Save-Snapshot($Visual, [string]$Path) {
    $scale = [Windows.Media.VisualTreeHelper]::GetDpi($Visual).DpiScaleX
    $w = [int][Math]::Ceiling($Visual.ActualWidth * $scale)
    $h = [int][Math]::Ceiling($Visual.ActualHeight * $scale)
    $bmp = [Windows.Media.Imaging.RenderTargetBitmap]::new($w, $h, 96 * $scale, 96 * $scale, [Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($Visual)
    $enc = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}

# Запуск ssh в отдельном окне консоли. Пароль уходит в ssh через SSH_ASKPASS и переменные окружения
# дочернего процесса — в командной строке его нет.
function Start-GuiSsh($Conn) {
    $note = ''
    if ($Conn.Password) {
        try { [void](Unprotect-Password $Conn.Password) }
        catch { $note = ' (сохранённый пароль не расшифровать на этом ПК — ssh спросит его сам)' }
    }
    $where = Start-TerminalSsh $Conn
    return "Открыто ($where): $($Conn.Name)$note"
}

#endregion

#region Форма подключения

# Возвращает подключение или $null (отмена). Цвет группы записывается в $script:GroupColors.
function Show-EditDialog($Existing, [string]$DefaultGroup, [string]$ShotPath) {
    $dlg = New-Window $dialogXaml
    $dlg.Owner = $script:Window
    $dlg.Title = if ($Existing) { "Редактирование: $($Existing.Name)" } else { 'Новое подключение' }
    $ui = @{}
    foreach ($n in 'Address', 'Port', 'Login', 'Pass', 'ClearPass', 'PassLabel', 'Name', 'Group', 'Chips', 'Swatch', 'PickColor', 'Err', 'Ok') {
        $ui[$n] = $dlg.FindName($n)
    }

    $ui.Address.Text = if ($Existing) { $Existing.Address } else { '' }
    $ui.Port.Text = if ($Existing) { "$($Existing.Port)" } else { '22' }
    $ui.Login.Text = if ($Existing) { $Existing.Login } else { '' }
    $ui.Name.Text = if ($Existing) { $Existing.Name } else { '' }
    $ui.Group.Text = if ($Existing) { $Existing.Group } elseif ($DefaultGroup) { $DefaultGroup } else { 'Default' }
    if ($Existing.Password) {
        $ui.PassLabel.Text = 'Пароль  (пусто — оставить текущий)'
        $ui.ClearPass.Visibility = 'Visible'
    }

    $pending = @{}                 # группа -> цвет, выбранный в этой форме
    $randomColor = New-GroupColor  # для группы, которой ещё нет
    $currentColor = {
        $g = $ui.Group.Text.Trim()
        if ($pending.ContainsKey($g)) { $pending[$g] }
        elseif ($script:GroupColors.ContainsKey($g)) { $script:GroupColors[$g] }
        else { $randomColor }
    }
    $updateSwatch = { $ui.Swatch.Fill = New-Brush (& $currentColor) }

    foreach ($g in @($script:List.Group | Sort-Object -Unique)) {
        $chip = [Windows.Controls.Button]::new()
        $chip.Style = $dlg.Resources['Chip']
        $sp = [Windows.Controls.StackPanel]::new()
        $sp.Orientation = 'Horizontal'
        $dot = [Windows.Shapes.Rectangle]::new()
        $dot.Width = 9; $dot.Height = 9; $dot.RadiusX = 2; $dot.RadiusY = 2
        $dot.Fill = New-Brush $script:GroupColors[$g]
        $dot.VerticalAlignment = 'Center'
        $label = [Windows.Controls.TextBlock]::new()
        $label.Text = $g
        $label.Margin = [Windows.Thickness]::new(7, 0, 0, 0)
        [void]$sp.Children.Add($dot); [void]$sp.Children.Add($label)
        $chip.Content = $sp
        $chip.Tag = $g
        $chip.Add_Click({ param($s, $e) $ui.Group.Text = [string]$s.Tag })
        [void]$ui.Chips.Children.Add($chip)
    }

    # «user@host:port» или вставленная команда ssh раскладываются по полям.
    $splitAddress = {
        $text = $ui.Address.Text.Trim()
        if (-not $text) { return }
        $parsed = Split-SshTarget $text
        if ($parsed.Address) { $ui.Address.Text = $parsed.Address }
        if ($parsed.Port) { $ui.Port.Text = [string]$parsed.Port }
        if ($parsed.Login) { $ui.Login.Text = [string]$parsed.Login }
    }
    $ui.Address.Add_LostFocus({ & $splitAddress })
    $ui.Group.Add_TextChanged({ & $updateSwatch })
    $ui.PickColor.Add_Click({
            $picked = Select-ColorDialog (& $currentColor) $dlg
            if ($picked) {
                $pending[$ui.Group.Text.Trim()] = $picked
                & $updateSwatch
            }
        })

    $script:DlgResult = $null
    $ui.Ok.Add_Click({
            & $splitAddress
            $address = $ui.Address.Text.Trim()
            $group = $ui.Group.Text.Trim()
            $portText = $ui.Port.Text.Trim()
            if (-not $address) { $ui.Err.Text = 'Укажите адрес'; return }
            if (-not ($portText -match '^\d+$' -and [int]$portText -in 1..65535)) { $ui.Err.Text = 'Порт — число от 1 до 65535'; return }
            if (-not $group) { $ui.Err.Text = 'Укажите группу'; return }
            $name = $ui.Name.Text.Trim()
            if (-not $name) { $name = $address }

            $password = if ($ui.ClearPass.IsChecked) { $null }
            elseif ($ui.Pass.Password) { Protect-Password $ui.Pass.Password }
            elseif ($Existing) { $Existing.Password }
            else { $null }

            if ($pending.ContainsKey($group)) { $script:GroupColors[$group] = $pending[$group] }
            elseif (-not $script:GroupColors.ContainsKey($group)) { $script:GroupColors[$group] = $randomColor }

            $script:DlgResult = New-Connection @{
                name = $name; group = $group; address = $address
                port = [int]$portText; login = $ui.Login.Text.Trim(); password = $password
            }
            $dlg.DialogResult = $true
        })

    & $updateSwatch
    $dlg.Add_ContentRendered({
            $ui.Address.Focus()
            if ($ShotPath) {
                $dlg.Dispatcher.BeginInvoke([Action] { Save-Snapshot $dlg.Content $ShotPath; $dlg.Close() }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
            }
        })
    [void]$dlg.ShowDialog()
    return $script:DlgResult
}

#endregion

#region Главное окно

$script:List = Read-Connections
$needsSave = @($script:List.Group | Sort-Object -Unique | Where-Object { -not $script:GroupColors.ContainsKey($_) }).Count `
    -or @($script:List | Where-Object { $_.Password -and -not $_.Password.StartsWith($PassPrefix) }).Count
if ($needsSave) { Save-Connections $script:List }

$script:Window = New-Window $mainXaml
$searchBox = $script:Window.FindName('Search')
$searchHint = $script:Window.FindName('SearchHint')
$listBox = $script:Window.FindName('List')
$statusText = $script:Window.FindName('Status')
$defaultStatus = $statusText.Text

$items = [Collections.ObjectModel.ObservableCollection[object]]::new()
$view = [Windows.Data.CollectionViewSource]::GetDefaultView($items)
$view.GroupDescriptions.Add([Windows.Data.PropertyGroupDescription]::new('Group'))
$view.SortDescriptions.Add([ComponentModel.SortDescription]::new('Group', 'Ascending'))
$view.SortDescriptions.Add([ComponentModel.SortDescription]::new('Name', 'Ascending'))
$listBox.ItemsSource = $view
$script:Filter = ''
$view.Filter = [Predicate[object]] {
    param($o)
    foreach ($w in @($script:Filter -split '\s+' | Where-Object { $_ })) {
        if ("$($o.Name) $($o.Group) $($o.Address) $($o.Login)".IndexOf($w, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Update-Items($SelectConn) {
    $items.Clear()
    foreach ($c in $script:List) {
        $items.Add([pscustomobject]@{
                Name = $c.Name; Group = $c.Group; Address = "$($c.Address):$($c.Port)"; Login = $c.Login
                Pw = if ($c.Password) { '🔑' } else { '' }
                Brush = New-Brush $script:GroupColors[$c.Group]
                Conn = $c
            })
    }
    $view.Refresh()
    $target = if ($SelectConn) { $items | Where-Object { $_.Conn -eq $SelectConn } | Select-Object -First 1 }
    if ($target) { $listBox.SelectedItem = $target; $listBox.ScrollIntoView($target) }
    elseif ($listBox.Items.Count) { $listBox.SelectedIndex = 0 }
}

function Set-Status([string]$Text) { $statusText.Text = if ($Text) { $Text } else { $defaultStatus } }
function Get-Selected { $listBox.SelectedItem }

function Invoke-Safe([scriptblock]$Action) {
    try { & $Action }
    catch { Show-Error $_.Exception.Message }
}

function Invoke-Connect {
    $sel = Get-Selected
    if ($sel) { Invoke-Safe { Set-Status (Start-GuiSsh $sel.Conn) } }
}

# Рабочий стол сервера (файлы через sftp) — отдельное окно в своём процессе.
function Invoke-Files {
    $sel = Get-Selected
    if (-not $sel) { return }
    Invoke-Safe {
        $c = $sel.Conn
        $launchArgs = @('-NoLogo', '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-File', (Join-Path $PSScriptRoot 'ssh-desktop.ps1'),
            '-ConfigPath', $ConfigPath, '-Name', $c.Name, '-Address', $c.Address, '-Port', "$($c.Port)")
        if ($c.Login) { $launchArgs += '-Login', $c.Login }
        Start-Process -FilePath (Get-Command pwsh.exe).Source -ArgumentList $launchArgs | Out-Null
        Set-Status "Рабочий стол: $($c.Name)"
    }
}

function Invoke-New {
    Invoke-Safe {
        $sel = Get-Selected
        $c = Show-EditDialog $null $(if ($sel) { $sel.Group }) $null
        if ($c) {
            $script:List.Add($c)
            Save-Connections $script:List
            Update-Items $c
            Set-Status "Добавлено: $($c.Name)"
        }
    }
}

function Invoke-Edit {
    $sel = Get-Selected
    if (-not $sel) { return }
    Invoke-Safe {
        $c = Show-EditDialog $sel.Conn $null $null
        if ($c) {
            $script:List[$script:List.IndexOf($sel.Conn)] = $c
            Save-Connections $script:List
            Update-Items $c
            Set-Status "Сохранено: $($c.Name)"
        }
    }
}

function Invoke-GroupColor {
    $sel = Get-Selected
    if (-not $sel) { return }
    Invoke-Safe {
        $g = $sel.Group
        $picked = Select-ColorDialog $script:GroupColors[$g] $script:Window
        if ($picked) {
            $script:GroupColors[$g] = $picked
            Save-Connections $script:List
            Update-Items $sel.Conn
            Set-Status "Цвет группы «$g»: $picked"
        }
    }
}

function Invoke-Delete {
    $sel = Get-Selected
    if (-not $sel) { return }
    $answer = [Windows.MessageBox]::Show("Удалить «$($sel.Name)»?", 'SSH', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Invoke-Safe {
        $index = $listBox.SelectedIndex
        [void]$script:List.Remove($sel.Conn)
        Save-Connections $script:List
        Update-Items $null
        if ($listBox.Items.Count) { $listBox.SelectedIndex = [Math]::Min($index, $listBox.Items.Count - 1) }
        Set-Status "Удалено: $($sel.Name)"
    }
}

$script:Window.FindName('BtnConnect').Add_Click({ Invoke-Connect })
$script:Window.FindName('BtnFiles').Add_Click({ Invoke-Files })
$script:Window.FindName('BtnNew').Add_Click({ Invoke-New })
$script:Window.FindName('BtnEdit').Add_Click({ Invoke-Edit })
$script:Window.FindName('BtnColor').Add_Click({ Invoke-GroupColor })
$script:Window.FindName('BtnDelete').Add_Click({ Invoke-Delete })

$searchBox.Add_TextChanged({
        $script:Filter = $searchBox.Text
        $searchHint.Visibility = if ($searchBox.Text) { 'Collapsed' } else { 'Visible' }
        $view.Refresh()
        if ($listBox.Items.Count) { $listBox.SelectedIndex = 0 }
    })

# Печать при фокусе на списке уходит в поиск.
$listBox.Add_PreviewTextInput({
        param($s, $e)
        $searchBox.Focus()
        $searchBox.Text += $e.Text
        $searchBox.CaretIndex = $searchBox.Text.Length
        $e.Handled = $true
    })

$listBox.Add_MouseDoubleClick({
        param($s, $e)
        $src = $e.OriginalSource -as [Windows.DependencyObject]
        try { while ($src -and $src -isnot [Windows.Controls.ListBoxItem]) { $src = [Windows.Media.VisualTreeHelper]::GetParent($src) } }
        catch { $src = $null }
        if ($src) { Invoke-Connect }
    })

$script:Window.Add_PreviewKeyDown({
        param($s, $e)
        $ctrl = [bool]([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)
        $inSearch = $searchBox.IsKeyboardFocused
        switch ($e.Key) {
            'Return' { Invoke-Connect; $e.Handled = $true }
            'F2' { Invoke-Edit; $e.Handled = $true }
            'F3' { Invoke-GroupColor; $e.Handled = $true }
            'F4' { Invoke-Files; $e.Handled = $true }
            'Insert' { Invoke-New; $e.Handled = $true }
            'Delete' { if (-not $inSearch) { Invoke-Delete; $e.Handled = $true } }
            'Escape' {
                if ($searchBox.Text) { $searchBox.Clear() } else { $script:Window.Close() }
                $e.Handled = $true
            }
            'Down' {
                if ($inSearch -and $listBox.SelectedIndex -lt $listBox.Items.Count - 1) { $listBox.SelectedIndex++ ; $listBox.ScrollIntoView($listBox.SelectedItem); $e.Handled = $true }
            }
            'Up' {
                if ($inSearch -and $listBox.SelectedIndex -gt 0) { $listBox.SelectedIndex--; $listBox.ScrollIntoView($listBox.SelectedItem); $e.Handled = $true }
            }
            'N' { if ($ctrl) { Invoke-New; $e.Handled = $true } }
            'E' { if ($ctrl) { Invoke-Edit; $e.Handled = $true } }
            'K' { if ($ctrl) { Invoke-GroupColor; $e.Handled = $true } }
        }
    })

$script:Window.Add_ContentRendered({
        $searchBox.Focus()
        if ($Screenshot) {
            $script:Window.Dispatcher.BeginInvoke([Action] { Save-Snapshot $script:Window.Content $Screenshot; $script:Window.Close() }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
        }
        elseif ($DialogScreenshot) {
            $script:Window.Dispatcher.BeginInvoke([Action] { [void](Show-EditDialog $script:List[0] $null $DialogScreenshot); $script:Window.Close() }, [Windows.Threading.DispatcherPriority]::ApplicationIdle) | Out-Null
        }
    })

Update-Items $null
[void]$script:Window.ShowDialog()

#endregion
