<#
.SYNOPSIS
    Bulk AD User Creation Tool with GUI
.DESCRIPTION
    Creates AD users from CSV with automatic group assignment, home folder creation,
    password display, and comprehensive logging.
#>

# ==========================================
# 1. REQUIREMENTS & ASSEMBLIES
# ==========================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.DirectoryServices.AccountManagement

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Active Directory module is not installed.`nPlease install RSAT-AD-PowerShell.",
        "Missing Dependency",
        "OK",
        "Error"
    )
    exit
}

Import-Module ActiveDirectory -ErrorAction Stop

# ==========================================
# 2. CONFIGURATION - CUSTOMIZE THESE VALUES
# ==========================================
$Script:Config = @{
    # Path where logs will be saved (can be network share or local path)
    LogPath          = "C:\Logs\Create-Users"  # CHANGE THIS
    
    # Default password prefix (number will be appended)
    DefaultPassword  = "Welcome"  # CHANGE THIS
    
    # Active Directory domain
    Domain           = "yourdomain.com"  # CHANGE THIS
    
    # Home folder drive letter
    HomeDrive        = "H"
    
    # Home folder root path (UNC path)
    HomeShare        = "\\fileserver\Home"  # CHANGE THIS
    
    # Maximum length for SAMAccountName (Windows limit is 20)
    MaxUsernameLength = 20
    
    # DEFAULT GROUPS - Applied to ALL users
    DefaultGroups    = @("Domain Users")  # CHANGE THIS
    
    # ROLE-BASED GROUPS - Applied based on Description field
    # Add or remove roles and groups as needed for your organization
    GroupMappings    = @{
        "Operator"          = @("Group-Operator")
        "Technician"        = @("Group-Technician", "Group-RedTeam")
        "Specialist"        = @("Group-Specialist", "Group-BlueTeam")
        "Manager"           = @("Group-Manager", "Group-AllTeams")
        # Add more role mappings as needed:
        # "RoleName"   = @("Group1", "Group2", "Group3")
    }
    
    # Keywords that trigger specific group assignments
    # Add or remove keywords as needed for your organization
    ManagerKeywords   = @("Manager", "Supervisor", "Leader", "Chief", "Architect")
}

# ==========================================
# 3. FUNCTIONS
# ==========================================

function Get-SafeString {
    param(
        [PSObject]$Object, 
        [string]$PropertyName, 
        [string]$DefaultValue = ""
    )
    try {
        $value = $Object.$PropertyName
        if ($null -ne $value -and $value.ToString().Trim() -ne "") {
            return $value.ToString().Trim()
        }
        
        foreach ($prop in $Object.PSObject.Properties) {
            if ($prop.Name -like $PropertyName) {
                $value = $prop.Value
                if ($null -ne $value -and $value.ToString().Trim() -ne "") {
                    return $value.ToString().Trim()
                }
            }
        }
        
        return $DefaultValue
    } catch {
        return $DefaultValue
    }
}

function New-Username {
    param(
        [string]$First, 
        [string]$Last,
        [int]$MaxLength = 20
    )
    
    $First = if ([string]::IsNullOrWhiteSpace($First)) { "user" } else { $First.Trim() }
    $Last = if ([string]::IsNullOrWhiteSpace($Last)) { "unknown" } else { $Last.Trim() }
    
    $First = $First -replace '[^a-zA-Z]', ''
    $Last = $Last -replace '[^a-zA-Z]', ''
    
    if ([string]::IsNullOrWhiteSpace($First)) { $First = "user" }
    if ([string]::IsNullOrWhiteSpace($Last)) { $Last = "unknown" }
    
    $base = "$First.$Last".ToLower()
    
    if ($base.Length -gt $MaxLength - 2) {
        $initial = $First.Substring(0, 1).ToLower()
        $base = "$initial.$Last".ToLower()
        Write-Host ("  [DEBUG] Username shortened: {0} -> {1}" -f "$First.$Last".ToLower(), $base) -ForegroundColor Gray
    }
    
    if ($base.Length -gt $MaxLength - 2) {
        $maxLastLen = $MaxLength - 2 - 1
        if ($maxLastLen -lt 1) { $maxLastLen = 1 }
        $truncatedLast = $Last.Substring(0, [Math]::Min($maxLastLen, $Last.Length)).ToLower()
        $base = "$initial.$truncatedLast".ToLower()
        Write-Host ("  [DEBUG] Username further truncated: {0}" -f $base) -ForegroundColor Gray
    }
    
    try {
        $existing = Get-ADUser -Filter "SamAccountName -eq '$base'" -ErrorAction SilentlyContinue
        if (-not $existing) {
            return $base
        }
    } catch {
        return $base
    }
    
    Write-Host ("  [DEBUG] Username {0} already exists, finding next available..." -f $base) -ForegroundColor Yellow
    $counter = 1
    do {
        $suffix = $counter.ToString()
        $maxBaseLen = $MaxLength - $suffix.Length
        if ($maxBaseLen -lt 1) { $maxBaseLen = 1 }
        
        $candidate = $base.Substring(0, [Math]::Min($maxBaseLen, $base.Length)) + $suffix
        
        try {
            $exists = Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue
            if (-not $exists) {
                Write-Host ("  [DEBUG] ✓ Found available username: {0}" -f $candidate) -ForegroundColor Green
                return $candidate
            }
        } catch {
            return $candidate
        }
        $counter++
    } while ($counter -lt 1000)
    
    $fallback = "$base$((Get-Random -Minimum 1000 -Maximum 9999))"
    Write-Host ("  [DEBUG] Using fallback username: {0}" -f $fallback) -ForegroundColor Yellow
    return $fallback
}

function Get-UserGroups {
    param([string]$Description)
    
    $allGroups = [System.Collections.ArrayList]::new($Script:Config.DefaultGroups)
    
    if ([string]::IsNullOrWhiteSpace($Description)) {
        return $allGroups.ToArray()
    }
    
    $descriptionLower = $Description.ToLower()
    
    foreach ($mapping in $Script:Config.GroupMappings.GetEnumerator()) {
        $keyword = $mapping.Key.ToLower()
        
        if ($keyword -eq "nurse") {
            $found = $false
            foreach ($kw in $Script:Config.NurseKeywords) {
                if ($descriptionLower -match $kw.ToLower()) { $found = $true; break }
            }
            if ($found) {
                foreach ($group in $mapping.Value) {
                    if ($group -notin $allGroups) { $allGroups.Add($group) | Out-Null }
                }
            }
        }
        elseif ($descriptionLower -match $keyword) {
            foreach ($group in $mapping.Value) {
                if ($group -notin $allGroups) { $allGroups.Add($group) | Out-Null }
            }
        }
    }
    
    return $allGroups.ToArray()
}

function New-UserAccount {
    param(
        [PSObject]$User,
        [string]$Password,
        [string]$ForcedOU,
        [bool]$ChangePasswordAtLogon = $true,
        [bool]$CreateHomeFolder = $true
    )
    
    $logEntry = @{ 
        Success = $false
        Message = ""
        OUUsed = ""
        HomePath = ""
        Username = ""
        Password = ""
        DisplayName = ""
        CN = ""
    }
    
    try {
        $firstName = $User.FirstName
        $lastName = $User.Surname
        $username = $User.Username
        $email = $User.Email
        $description = $User.Description
        $title = $User.Title
        $department = $User.Department
        $office = $User.Office
        $officePhone = $User.OfficePhone
        $mobilePhone = $User.MobilePhone
        
        $logEntry.Username = $username
        $logEntry.Password = $Password
        
        $displayName = "$($lastName.ToUpper()) $firstName"
        $logEntry.DisplayName = $displayName
        $logEntry.CN = $displayName
        
        Write-Host ("  [DEBUG] FirstName: '{0}'" -f $firstName) -ForegroundColor Gray
        Write-Host ("  [DEBUG] LastName: '{0}'" -f $lastName) -ForegroundColor Gray
        Write-Host ("  [DEBUG] Username: '{0}'" -f $username) -ForegroundColor Gray
        Write-Host ("  [DEBUG] DisplayName: '{0}'" -f $displayName) -ForegroundColor Gray
        
        if ([string]::IsNullOrWhiteSpace($firstName)) {
            $logEntry.Success = $false
            $logEntry.Message = "SKIPPED: First Name is empty or invalid"
            $logEntry.OUUsed = $ForcedOU
            return $logEntry
        }
        
        if ([string]::IsNullOrWhiteSpace($lastName)) {
            $logEntry.Success = $false
            $logEntry.Message = "SKIPPED: Surname is empty or invalid"
            $logEntry.OUUsed = $ForcedOU
            return $logEntry
        }
        
        if ([string]::IsNullOrWhiteSpace($username)) {
            $username = New-Username -First $firstName -Last $lastName
            $logEntry.Username = $username
        }
        
        $params = @{
            Name                   = $displayName
            GivenName              = $firstName
            Surname                = $lastName
            SamAccountName         = $username
            UserPrincipalName      = "$username@$($Script:Config.Domain)"
            DisplayName            = $displayName
            Path                   = $ForcedOU
            AccountPassword        = (ConvertTo-SecureString $Password -AsPlainText -Force)
            Enabled                = $true
            ChangePasswordAtLogon  = $ChangePasswordAtLogon
            ErrorAction            = "Stop"
        }
        
        if (-not [string]::IsNullOrWhiteSpace($email)) { $params.EmailAddress = $email }
        if (-not [string]::IsNullOrWhiteSpace($description)) { $params.Description = $description }
        if (-not [string]::IsNullOrWhiteSpace($title)) { $params.Title = $title }
        if (-not [string]::IsNullOrWhiteSpace($department)) { $params.Department = $department }
        if (-not [string]::IsNullOrWhiteSpace($officePhone)) { $params.OfficePhone = $officePhone }
        if (-not [string]::IsNullOrWhiteSpace($mobilePhone)) { $params.MobilePhone = $mobilePhone }
        if (-not [string]::IsNullOrWhiteSpace($office)) { $params.Office = $office }
        
        if ($CreateHomeFolder) {
            $firstLetter = $firstName.Substring(0, 1).ToLower()
            $homePath = "$($Script:Config.HomeShare)\Users_$firstLetter\$username"
            $params.HomeDrive = $Script:Config.HomeDrive
            $params.HomeDirectory = $homePath
            $logEntry.HomePath = $homePath
            Write-Host ("  [DEBUG] Home Path: {0}" -f $homePath) -ForegroundColor Gray
        }
        
        Write-Host ("  [DEBUG] Creating user: {0} (CN: {1})" -f $username, $displayName) -ForegroundColor Gray
        $newUser = New-ADUser @params
        Write-Host ("  [DEBUG] ✓ User created: {0}" -f $username) -ForegroundColor Green
        
        if ($User.Groups -and $User.Groups.Count -gt 0) {
            foreach ($group in $User.Groups) {
                if ([string]::IsNullOrWhiteSpace($group)) { continue }
                try {
                    $null = Get-ADGroup -Identity $group -ErrorAction Stop
                    Add-ADGroupMember -Identity $group -Members $username -ErrorAction Stop
                    Write-Host ("  [DEBUG] ✓ Added to group: {0}" -f $group) -ForegroundColor Green
                } catch {
                    Write-Host ("  [DEBUG] ⚠ Could not add to group: {0}" -f $group) -ForegroundColor Yellow
                }
            }
        }
        
        if ($CreateHomeFolder -and $homePath) {
            try {
                if (-not (Test-Path $homePath)) {
                    New-Item -Path $homePath -ItemType Directory -Force | Out-Null
                    Write-Host ("  [DEBUG] ✓ Home folder created: {0}" -f $homePath) -ForegroundColor Green
                    try {
                        $sid = (Get-ADUser -Identity $username).SID.Value
                        $aclResult = icacls $homePath /grant "*$sid`:(OI)(CI)M" 2>$null
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host ("  [DEBUG] ✓ Permissions set on home folder") -ForegroundColor Green
                        } else {
                            Write-Host ("  [DEBUG] ⚠ Permissions may need verification") -ForegroundColor Yellow
                        }
                    } catch {
                        Write-Host ("  [DEBUG] ⚠ Permission error: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                    }
                } else {
                    Write-Host ("  [DEBUG] ⚠ Home folder already exists: {0}" -f $homePath) -ForegroundColor Yellow
                }
            } catch {
                Write-Host ("  [DEBUG] ⚠ Home folder creation warning: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                $logEntry.Message += "Home folder warning; "
            }
        }
        
        $logEntry.Success = $true
        $logEntry.Message = "Created successfully"
        $logEntry.OUUsed = $ForcedOU
        
    } catch {
        $logEntry.Success = $false
        $logEntry.Message = "Error: $($_.Exception.Message)"
        $logEntry.OUUsed = $ForcedOU
        Write-Host ("  [DEBUG] ✗ FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    
    return $logEntry
}

# ==========================================
# 4. GUI
# ==========================================
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Bulk AD User Creator v3.3"
$Form.Size = New-Object System.Drawing.Size(1200, 800)
$Form.StartPosition = "CenterScreen"
$Form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$Form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)

# -- TOP PANEL --
$PanelTop = New-Object System.Windows.Forms.Panel
$PanelTop.Dock = "Top"
$PanelTop.Height = 140
$PanelTop.BackColor = [System.Drawing.Color]::White
$PanelTop.Padding = New-Object System.Windows.Forms.Padding(10)

# CSV File
$LblCSV = New-Object System.Windows.Forms.Label
$LblCSV.Text = "CSV File:"
$LblCSV.Location = New-Object System.Drawing.Point(10, 15)
$LblCSV.AutoSize = $true
$PanelTop.Controls.Add($LblCSV)

$TxtCSV = New-Object System.Windows.Forms.TextBox
$TxtCSV.Location = New-Object System.Drawing.Point(80, 12)
$TxtCSV.Width = 600
$PanelTop.Controls.Add($TxtCSV)

$BtnBrowse = New-Object System.Windows.Forms.Button
$BtnBrowse.Text = "Browse..."
$BtnBrowse.Location = New-Object System.Drawing.Point(690, 10)
$BtnBrowse.Size = New-Object System.Drawing.Size(80, 25)
$PanelTop.Controls.Add($BtnBrowse)

$BtnLoad = New-Object System.Windows.Forms.Button
$BtnLoad.Text = "Load CSV"
$BtnLoad.Location = New-Object System.Drawing.Point(780, 10)
$BtnLoad.Size = New-Object System.Drawing.Size(100, 25)
$BtnLoad.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$BtnLoad.ForeColor = [System.Drawing.Color]::White
$BtnLoad.FlatStyle = "Flat"
$PanelTop.Controls.Add($BtnLoad)

# OU Selection
$LblOU = New-Object System.Windows.Forms.Label
$LblOU.Text = "TARGET OU:"
$LblOU.Location = New-Object System.Drawing.Point(10, 50)
$LblOU.AutoSize = $true
$LblOU.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$LblOU.ForeColor = [System.Drawing.Color]::DarkRed
$PanelTop.Controls.Add($LblOU)

$TxtOU = New-Object System.Windows.Forms.TextBox
$TxtOU.Location = New-Object System.Drawing.Point(100, 47)
$TxtOU.Width = 480
$TxtOU.Text = "OU=Users,DC=yourdomain,DC=com"
$TxtOU.BackColor = [System.Drawing.Color]::LightYellow
$TxtOU.Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
$PanelTop.Controls.Add($TxtOU)

$BtnVerifyOU = New-Object System.Windows.Forms.Button
$BtnVerifyOU.Text = "Verify OU"
$BtnVerifyOU.Location = New-Object System.Drawing.Point(590, 45)
$BtnVerifyOU.Size = New-Object System.Drawing.Size(100, 25)
$BtnVerifyOU.BackColor = [System.Drawing.Color]::Orange
$BtnVerifyOU.FlatStyle = "Flat"
$PanelTop.Controls.Add($BtnVerifyOU)

$BtnFindOU = New-Object System.Windows.Forms.Button
$BtnFindOU.Text = "Find OUs"
$BtnFindOU.Location = New-Object System.Drawing.Point(700, 45)
$BtnFindOU.Size = New-Object System.Drawing.Size(100, 25)
$BtnFindOU.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$BtnFindOU.ForeColor = [System.Drawing.Color]::White
$BtnFindOU.FlatStyle = "Flat"
$PanelTop.Controls.Add($BtnFindOU)

# Options
$ChkDryRun = New-Object System.Windows.Forms.CheckBox
$ChkDryRun.Text = "Dry Run"
$ChkDryRun.Location = New-Object System.Drawing.Point(80, 80)
$ChkDryRun.AutoSize = $true
$ChkDryRun.Checked = $true
$PanelTop.Controls.Add($ChkDryRun)

$ChkChangePwd = New-Object System.Windows.Forms.CheckBox
$ChkChangePwd.Text = "Force password change"
$ChkChangePwd.Location = New-Object System.Drawing.Point(200, 80)
$ChkChangePwd.AutoSize = $true
$ChkChangePwd.Checked = $true
$PanelTop.Controls.Add($ChkChangePwd)

$ChkCreateHome = New-Object System.Windows.Forms.CheckBox
$ChkCreateHome.Text = "Create home folders"
$ChkCreateHome.Location = New-Object System.Drawing.Point(360, 80)
$ChkCreateHome.AutoSize = $true
$ChkCreateHome.Checked = $true
$PanelTop.Controls.Add($ChkCreateHome)

$ChkShowPasswords = New-Object System.Windows.Forms.CheckBox
$ChkShowPasswords.Text = "Show passwords in log"
$ChkShowPasswords.Location = New-Object System.Drawing.Point(530, 80)
$ChkShowPasswords.AutoSize = $true
$ChkShowPasswords.Checked = $true
$PanelTop.Controls.Add($ChkShowPasswords)

# Create Button
$BtnCreate = New-Object System.Windows.Forms.Button
$BtnCreate.Text = "CREATE USERS"
$BtnCreate.Location = New-Object System.Drawing.Point(780, 40)
$BtnCreate.Size = New-Object System.Drawing.Size(250, 80)
$BtnCreate.BackColor = [System.Drawing.Color]::FromArgb(0, 150, 50)
$BtnCreate.ForeColor = [System.Drawing.Color]::White
$BtnCreate.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$BtnCreate.Enabled = $false
$BtnCreate.FlatStyle = "Flat"
$PanelTop.Controls.Add($BtnCreate)

# Status
$LblCount = New-Object System.Windows.Forms.Label
$LblCount.Text = "Loaded: 0 users"
$LblCount.Location = New-Object System.Drawing.Point(80, 110)
$LblCount.AutoSize = $true
$LblCount.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$PanelTop.Controls.Add($LblCount)

# -- GRID --
$PanelGrid = New-Object System.Windows.Forms.Panel
$PanelGrid.Dock = "Fill"

$Grid = New-Object System.Windows.Forms.DataGridView
$Grid.Dock = "Fill"
$Grid.AllowUserToAddRows = $false
$Grid.AllowUserToDeleteRows = $false
$Grid.ReadOnly = $true
$Grid.SelectionMode = "FullRowSelect"
$Grid.AutoSizeColumnsMode = "Fill"
$Grid.BackgroundColor = [System.Drawing.Color]::White
$Grid.RowHeadersVisible = $false

$Grid.ColumnCount = 10
$Grid.Columns[0].Name = "First"
$Grid.Columns[1].Name = "Last"
$Grid.Columns[2].Name = "Username"
$Grid.Columns[3].Name = "DisplayName"
$Grid.Columns[4].Name = "Password"
$Grid.Columns[5].Name = "Email"
$Grid.Columns[6].Name = "Description"
$Grid.Columns[7].Name = "Groups"
$Grid.Columns[8].Name = "Status"
$Grid.Columns[9].Name = "Message"

$Grid.Columns[0].FillWeight = 8
$Grid.Columns[1].FillWeight = 8
$Grid.Columns[2].FillWeight = 12
$Grid.Columns[3].FillWeight = 15
$Grid.Columns[4].FillWeight = 10
$Grid.Columns[5].FillWeight = 12
$Grid.Columns[6].FillWeight = 12
$Grid.Columns[7].FillWeight = 12
$Grid.Columns[8].FillWeight = 6
$Grid.Columns[9].FillWeight = 10

$PanelGrid.Controls.Add($Grid)

# -- BOTTOM PANEL --
$PanelBottom = New-Object System.Windows.Forms.Panel
$PanelBottom.Dock = "Bottom"
$PanelBottom.Height = 40

$LblStatus = New-Object System.Windows.Forms.Label
$LblStatus.Text = "Ready. Load a CSV file to begin."
$LblStatus.Location = New-Object System.Drawing.Point(10, 12)
$LblStatus.Width = 600
$PanelBottom.Controls.Add($LblStatus)

$ProgressBar = New-Object System.Windows.Forms.ProgressBar
$ProgressBar.Location = New-Object System.Drawing.Point(620, 12)
$ProgressBar.Size = New-Object System.Drawing.Size(250, 18)
$ProgressBar.Style = "Continuous"
$PanelBottom.Controls.Add($ProgressBar)

$BtnExportLog = New-Object System.Windows.Forms.Button
$BtnExportLog.Text = "Export Log"
$BtnExportLog.Location = New-Object System.Drawing.Point(880, 8)
$BtnExportLog.Size = New-Object System.Drawing.Size(100, 25)
$BtnExportLog.Enabled = $false
$PanelBottom.Controls.Add($BtnExportLog)

$BtnExportPasswords = New-Object System.Windows.Forms.Button
$BtnExportPasswords.Text = "Export Passwords"
$BtnExportPasswords.Location = New-Object System.Drawing.Point(990, 8)
$BtnExportPasswords.Size = New-Object System.Drawing.Size(120, 25)
$BtnExportPasswords.Enabled = $false
$BtnExportPasswords.BackColor = [System.Drawing.Color]::LightYellow
$BtnExportPasswords.FlatStyle = "Flat"
$PanelBottom.Controls.Add($BtnExportPasswords)

# -- ASSEMBLE --
$PanelGrid.Controls.Add($Grid)
$Form.Controls.Add($PanelGrid)
$Form.Controls.Add($PanelTop)
$Form.Controls.Add($PanelBottom)

# ==========================================
# 5. EVENT HANDLERS
# ==========================================

$BtnVerifyOU.Add_Click({
    $ouToCheck = $TxtOU.Text
    if ([string]::IsNullOrWhiteSpace($ouToCheck)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter an OU path.")
        return
    }
    
    try {
        $ou = Get-ADOrganizationalUnit -Identity $ouToCheck -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            "OU exists and is accessible!`n`nOU: $($ou.DistinguishedName)",
            "OU Verified",
            "OK",
            "Information"
        )
        $TxtOU.BackColor = [System.Drawing.Color]::LightGreen
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "OU NOT FOUND or ACCESS DENIED!`n`nPath: $ouToCheck`n`nError: $($_.Exception.Message)",
            "OU Verification Failed",
            "OK",
            "Error"
        )
        $TxtOU.BackColor = [System.Drawing.Color]::LightCoral
    }
})

$BtnFindOU.Add_Click({
    try {
        $ous = Get-ADOrganizationalUnit -Filter * -ErrorAction SilentlyContinue
        if ($ous) {
            $ous | Select-Object -Property Name, DistinguishedName | Sort-Object Name | Out-GridView -Title "Available OUs - Select one to copy"
            
            [System.Windows.Forms.MessageBox]::Show(
                "OU list displayed in a separate grid window.`n`nYou can copy the DistinguishedName from there.",
                "OU List",
                "OK",
                "Information"
            )
        } else {
            [System.Windows.Forms.MessageBox]::Show("Could not list OUs.", "No OUs Found", "OK", "Warning")
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error listing OUs: $($_.Exception.Message)", "Error", "OK", "Error")
    }
})

$BtnBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "CSV Files (*.csv)|*.csv"
    if ($dialog.ShowDialog() -eq "OK") {
        $TxtCSV.Text = $dialog.FileName
    }
})

$BtnLoad.Add_Click({
    if ([string]::IsNullOrWhiteSpace($TxtCSV.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please select a CSV file first.")
        return
    }
    
    if (-not (Test-Path $TxtCSV.Text)) {
        [System.Windows.Forms.MessageBox]::Show("File not found.")
        return
    }
    
    try {
        $data = Import-Csv -Path $TxtCSV.Text -ErrorAction Stop
        
        if ($data.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("CSV file is empty.")
            return
        }
        
        Write-Host "`n============================================================" -ForegroundColor Cyan
        Write-Host "  CSV COLUMNS DETECTED" -ForegroundColor Cyan
        Write-Host "============================================================" -ForegroundColor Cyan
        $data[0].PSObject.Properties.Name | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Gray }
        Write-Host "============================================================" -ForegroundColor Cyan
        
        $Grid.Rows.Clear()
        $gridData = @()
        $rowNumber = 0
        $skippedCount = 0
        
        foreach ($row in $data) {
            $rowNumber++
            
            $firstName = Get-SafeString -Object $row -PropertyName "First Name" -DefaultValue ""
            if ([string]::IsNullOrWhiteSpace($firstName)) {
                $firstName = Get-SafeString -Object $row -PropertyName "FirstName" -DefaultValue ""
            }
            if ([string]::IsNullOrWhiteSpace($firstName)) {
                $firstName = Get-SafeString -Object $row -PropertyName "GivenName" -DefaultValue ""
            }
            if ([string]::IsNullOrWhiteSpace($firstName)) {
                $firstName = Get-SafeString -Object $row -PropertyName "Forename" -DefaultValue ""
            }
            
            $surname = Get-SafeString -Object $row -PropertyName "Surname" -DefaultValue ""
            if ([string]::IsNullOrWhiteSpace($surname)) {
                $surname = Get-SafeString -Object $row -PropertyName "LastName" -DefaultValue ""
            }
            if ([string]::IsNullOrWhiteSpace($surname)) {
                $surname = Get-SafeString -Object $row -PropertyName "FamilyName" -DefaultValue ""
            }
            if ([string]::IsNullOrWhiteSpace($surname)) {
                $surname = Get-SafeString -Object $row -PropertyName "Last Name" -DefaultValue ""
            }
            
            $email = Get-SafeString -Object $row -PropertyName "Email" -DefaultValue ""
            if ([string]::IsNullOrWhiteSpace($email)) {
                $email = Get-SafeString -Object $row -PropertyName "EmailAddress" -DefaultValue ""
            }
            
            $description = Get-SafeString -Object $row -PropertyName "Description" -DefaultValue ""
            $title = Get-SafeString -Object $row -PropertyName "Title" -DefaultValue ""
            $department = Get-SafeString -Object $row -PropertyName "Department" -DefaultValue ""
            $office = Get-SafeString -Object $row -PropertyName "Office" -DefaultValue ""
            $officePhone = Get-SafeString -Object $row -PropertyName "Office Phone" -DefaultValue ""
            $mobilePhone = Get-SafeString -Object $row -PropertyName "Mobile Phone" -DefaultValue ""
            
            if ([string]::IsNullOrWhiteSpace($firstName) -or [string]::IsNullOrWhiteSpace($surname)) {
                Write-Host ("  ⚠ Skipping row {0}: First='{1}' Last='{2}'" -f $rowNumber, $firstName, $surname) -ForegroundColor Yellow
                $skippedCount++
                continue
            }
            
            $username = New-Username -First $firstName -Last $surname -MaxLength $Script:Config.MaxUsernameLength
            $groups = Get-UserGroups -Description $description
            $password = "$($Script:Config.DefaultPassword)$(Get-Random -Minimum 100 -Maximum 999)"
            
            $displayName = "$($surname.ToUpper()) $firstName"
            
            Write-Host ("  ✓ Row {0}: {1} {2} -> {3} (DisplayName: {4})" -f $rowNumber, $firstName, $surname, $username, $displayName) -ForegroundColor Green
            
            $gridRow = $Grid.Rows.Add(
                $firstName,
                $surname,
                $username,
                $displayName,
                $password,
                $email,
                $description,
                ($groups -join ", "),
                "Pending",
                ""
            )
            
            $userObject = [PSCustomObject]@{
                FirstName   = $firstName
                Surname     = $surname
                Username    = $username
                DisplayName = $displayName
                Password    = $password
                Email       = $email
                Description = $description
                Groups      = $groups
                Title       = $title
                Department  = $department
                Office      = $office
                OfficePhone = $officePhone
                MobilePhone = $mobilePhone
                RowIndex    = $gridRow
            }
            
            $gridData += $userObject
        }
        
        Write-Host ("`nLoaded: {0} users, Skipped: {1} rows" -f $gridData.Count, $skippedCount) -ForegroundColor Cyan
        
        $LblCount.Text = "Loaded: $($gridData.Count) users (Skipped: $skippedCount)"
        $BtnCreate.Enabled = ($gridData.Count -gt 0)
        $LblStatus.Text = "Loaded $($gridData.Count) users. Target OU: $($TxtOU.Text)"
        $Script:UserData = $gridData
        
        try {
            $testOU = Get-ADOrganizationalUnit -Identity $TxtOU.Text -ErrorAction Stop
            $TxtOU.BackColor = [System.Drawing.Color]::LightGreen
        } catch {
            $TxtOU.BackColor = [System.Drawing.Color]::LightCoral
            $LblStatus.Text = "WARNING: OU may not exist! Click 'Verify OU' to check."
        }
        
        if ($gridData.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "No valid users were loaded from the CSV.`n`nCheck the console output for details.",
                "No Users Loaded",
                "OK",
                "Warning"
            )
        }
        
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error loading CSV: $($_.Exception.Message)")
    }
})

$BtnCreate.Add_Click({
    if (-not $Script:UserData -or $Script:UserData.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No users loaded.")
        return
    }
    
    $targetOU = $TxtOU.Text
    
    if ([string]::IsNullOrWhiteSpace($targetOU)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter a Target OU.")
        return
    }
    
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host ("  TARGET OU: {0}" -f $targetOU) -ForegroundColor Yellow
    Write-Host ("  Total Users: {0}" -f $Script:UserData.Count) -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan
    
    try {
        $testOU = Get-ADOrganizationalUnit -Identity $targetOU -ErrorAction Stop
        Write-Host ("OU verified: {0}" -f $testOU.DistinguishedName) -ForegroundColor Green
    } catch {
        Write-Host ("OU NOT FOUND: {0}" -f $targetOU) -ForegroundColor Red
        [System.Windows.Forms.MessageBox]::Show(
            "The Target OU does not exist:`n`n$targetOU`n`nClick 'Find OUs' to see available OUs.",
            "Invalid OU",
            "OK",
            "Error"
        )
        return
    }
    
    $result = [System.Windows.Forms.MessageBox]::Show(
        "Create $($Script:UserData.Count) users in:`n`n$targetOU`n`nDry Run: $($ChkDryRun.Checked)`n`nPasswords will be shown in the grid and logged.",
        "Confirm Creation",
        "YesNo",
        "Question"
    )
    
    if ($result -eq "No") { return }
    
    $BtnCreate.Enabled = $false
    $BtnLoad.Enabled = $false
    $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $ProgressBar.Maximum = $Script:UserData.Count
    $ProgressBar.Value = 0
    
    $successCount = 0
    $failCount = 0
    $skippedCount = 0
    $logLines = @()
    $passwordLog = @()
    $passwordLogLines = @()
    
    $passwordLogLines += "===== USER PASSWORDS - $(Get-Date) ====="
    $passwordLogLines += "Username`tDisplayName`tPassword`tHomeFolder`tOU"
    $passwordLogLines += "============================================================"
    
    $logLines += "=== Bulk User Import Started $(Get-Date) ==="
    $logLines += "Total Users: $($Script:UserData.Count)"
    $logLines += "Dry Run: $($ChkDryRun.Checked)"
    $logLines += "Force Change Password: $($ChkChangePwd.Checked)"
    $logLines += "Create Home Folders: $($ChkCreateHome.Checked)"
    $logLines += "TARGET OU: $targetOU"
    $logLines += "Max Username Length: $($Script:Config.MaxUsernameLength)"
    $logLines += ""
    
    for ($i = 0; $i -lt $Script:UserData.Count; $i++) {
        $user = $Script:UserData[$i]
        $gridRow = $Grid.Rows[$user.RowIndex]
        $userNumber = $i + 1
        
        $gridRow.Cells["Status"].Value = if ($ChkDryRun.Checked) { "Preview" } else { "Creating..." }
        $gridRow.Cells["Message"].Value = ""
        $gridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightYellow
        $Form.Refresh()
        
        Write-Host ("`n--- User {0}: {1} ---" -f $userNumber, $user.Username) -ForegroundColor Yellow
        
        if ($ChkDryRun.Checked) {
            $gridRow.Cells["Status"].Value = "Preview (OK)"
            $gridRow.Cells["Message"].Value = "Would create in: $targetOU"
            $gridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightBlue
            $successCount++
            Write-Host ("  DRY RUN: Would create {0} (CN: {1}) in {2}" -f $user.Username, $user.DisplayName, $targetOU) -ForegroundColor Gray
            
            $passwordLogLines += "$($user.Username)`t$($user.DisplayName)`t$($user.Password)`t(DRY RUN)`t$targetOU"
            
        } else {
            $result = New-UserAccount -User $user -Password $user.Password -ForcedOU $targetOU -ChangePasswordAtLogon $ChkChangePwd.Checked -CreateHomeFolder $ChkCreateHome.Checked
            
            if ($result.Success) {
                $gridRow.Cells["Status"].Value = "Success"
                $gridRow.Cells["Message"].Value = $result.Message
                $gridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightGreen
                $successCount++
                
                $passwordLogLines += "$($user.Username)`t$($user.DisplayName)`t$($user.Password)`t$($result.HomePath)`t$targetOU"
                
                Write-Host ("  ✓ SUCCESS: {0}" -f $user.Username) -ForegroundColor Green
                Write-Host ("    DisplayName: {0}" -f $user.DisplayName) -ForegroundColor Gray
                Write-Host ("    Password: {0}" -f $user.Password) -ForegroundColor Yellow
                Write-Host ("    Home: {0}" -f $result.HomePath) -ForegroundColor Gray
                
            } else {
                if ($result.Message -match "SKIPPED") {
                    $gridRow.Cells["Status"].Value = "Skipped"
                    $gridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightGray
                    $skippedCount++
                    Write-Host ("  ⚠ SKIPPED: {0}" -f $result.Message) -ForegroundColor Yellow
                } else {
                    $gridRow.Cells["Status"].Value = "Failed"
                    $gridRow.Cells["Message"].Value = $result.Message
                    $gridRow.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightCoral
                    $failCount++
                    Write-Host ("  ✗ FAILED: {0} - {1}" -f $user.Username, $result.Message) -ForegroundColor Red
                }
            }
        }
        
        $ProgressBar.Value = $i + 1
        $LblStatus.Text = "$($i + 1)/$($Script:UserData.Count) - Success: $successCount, Failed: $failCount, Skipped: $skippedCount"
        $Form.Refresh()
        Start-Sleep -Milliseconds 50
    }
    
    $Form.Cursor = [System.Windows.Forms.Cursors]::Default
    
    $logLines += ""
    $logLines += "=== SUMMARY ==="
    $logLines += "Success: $successCount"
    $logLines += "Failed: $failCount"
    $logLines += "Skipped: $skippedCount"
    $logLines += "OU Used: $targetOU"
    
    $passwordLogLines += ""
    $passwordLogLines += "=== SUMMARY ==="
    $passwordLogLines += "Success: $successCount"
    $passwordLogLines += "Failed: $failCount"
    $passwordLogLines += "Skipped: $skippedCount"
    
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host ("SUMMARY: Success={0} Failed={1} Skipped={2}" -f $successCount, $failCount, $skippedCount) -ForegroundColor Yellow
    Write-Host ("OU Used: {0}" -f $targetOU) -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan
    
    if (-not $ChkDryRun.Checked) {
        $timestamp = Get-Date -Format 'yyyyMMdd.HHmm'
        $logFile = "$($Script:Config.LogPath)\BulkUserImport_$timestamp.log"
        $passwordFile = "$($Script:Config.LogPath)\BulkUserImport_NewPasswords_$timestamp.log"
        
        $logDir = Split-Path $logFile -Parent
        if (-not (Test-Path $logDir)) { 
            try {
                New-Item -Path $logDir -ItemType Directory -Force | Out-Null
            } catch {
                $logFile = "$env:TEMP\BulkUserImport_$timestamp.log"
                $passwordFile = "$env:TEMP\BulkUserImport_NewPasswords_$timestamp.log"
                Write-Host ("  ⚠ Could not write to network log, using local temp") -ForegroundColor Yellow
            }
        }
        
        $logLines | Out-File -FilePath $logFile -Encoding UTF8
        $passwordLogLines | Out-File -FilePath $passwordFile -Encoding UTF8
        
        $BtnExportLog.Enabled = $true
        $BtnExportLog.Tag = $logFile
        
        $BtnExportPasswords.Enabled = $true
        $BtnExportPasswords.Tag = $passwordFile
        
        $LblStatus.Text = "Complete! Created: $successCount, Failed: $failCount, Skipped: $skippedCount"
        
        if ($successCount -gt 0 -and $ChkShowPasswords.Checked) {
            $passwordMsg = "Users created successfully!`n`n"
            $passwordMsg += "DisplayName format: LASTNAME Firstname`n"
            $passwordMsg += "Usernames shortened if over $($Script:Config.MaxUsernameLength) characters`n`n"
            $passwordMsg += "Passwords saved to:`n$passwordFile`n`n"
            $passwordMsg += "First 5 users (for reference):`n`n"
            
            $displayCount = [Math]::Min(5, $successCount)
            $shown = 0
            foreach ($line in $passwordLogLines) {
                if ($line -match "^\w+\.\w+`t") {
                    $parts = $line -split "`t"
                    if ($parts.Count -ge 3) {
                        $passwordMsg += "  $($parts[0]) : $($parts[2])`n"
                        $shown++
                        if ($shown -ge $displayCount) { break }
                    }
                }
            }
            
            if ($successCount -gt 5) {
                $passwordMsg += "`n... and $($successCount - 5) more users (see log file)"
            }
            
            [System.Windows.Forms.MessageBox]::Show($passwordMsg, "Passwords Created", "OK", "Information")
        }
        
    } else {
        $LblStatus.Text = "Dry run complete! Would create: $successCount users in $targetOU"
    }
    
    $BtnCreate.Enabled = $true
    $BtnLoad.Enabled = $true
    
    $summaryMsg = "Complete!`n`nSuccess: $successCount`nFailed: $failCount`nSkipped: $skippedCount`n`nOU Used: $targetOU"
    
    if (-not $ChkDryRun.Checked) {
        $summaryMsg += "`n`nPassword log saved to:`n$passwordFile"
    }
    
    [System.Windows.Forms.MessageBox]::Show($summaryMsg, "Done", "OK", "Information")
})

$BtnExportLog.Add_Click({
    if ($BtnExportLog.Tag) {
        $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $saveDialog.Filter = "Log Files (*.log)|*.log|All Files (*.*)|*.*"
        $saveDialog.FileName = Split-Path $BtnExportLog.Tag -Leaf
        
        if ($saveDialog.ShowDialog() -eq "OK") {
            Copy-Item -Path $BtnExportLog.Tag -Destination $saveDialog.FileName -Force
            [System.Windows.Forms.MessageBox]::Show("Log exported to $($saveDialog.FileName)")
        }
    }
})

$BtnExportPasswords.Add_Click({
    if ($BtnExportPasswords.Tag) {
        $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $saveDialog.Filter = "Password Files (*.log)|*.log|CSV Files (*.csv)|*.csv|All Files (*.*)|*.*"
        $saveDialog.FileName = Split-Path $BtnExportPasswords.Tag -Leaf
        
        if ($saveDialog.ShowDialog() -eq "OK") {
            Copy-Item -Path $BtnExportPasswords.Tag -Destination $saveDialog.FileName -Force
            [System.Windows.Forms.MessageBox]::Show("Password file exported to $($saveDialog.FileName)")
        }
    }
})

# ==========================================
# 6. LAUNCH
# ==========================================
$Form.Add_Shown({ 
    $Form.Activate()
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  Bulk AD User Creator v3.3" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "FEATURES:" -ForegroundColor Yellow
    Write-Host "  - DisplayName/CN format: LASTNAME Firstname (surname in ALL CAPS)" -ForegroundColor Gray
    Write-Host "  - Usernames auto-shortened to first initial if > 20 characters" -ForegroundColor Gray
    Write-Host "  - Configurable max username length" -ForegroundColor Gray
    Write-Host "  - Role-based group assignment" -ForegroundColor Gray
    Write-Host "  - Home folder creation with permissions" -ForegroundColor Gray
    Write-Host "  - Password display and logging" -ForegroundColor Gray
    Write-Host "  - Dry run mode for testing" -ForegroundColor Gray
    Write-Host ""
})

$Form.ShowDialog() | Out-Null
