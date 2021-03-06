﻿Set-Location (Split-Path $MyInvocation.MyCommand.Path)

Add-Type -Path .\OpenCL\*.cs

function Get-Version {
    [CmdletBinding()]
    param($Version)
    # System.Version objects can be compared with -gt and -lt properly
    # This strips out anything that doens't belong in a version, eg. v at the beginning, or -preview1 at the end, and returns a version object
    Return [System.Version]($Version -Split '-' -Replace "[^0-9.]")[0]
}

function Confirm-Version {
    [CmdletBinding()]
    param($RBMVersion, [Switch]$Force = $false, [Switch]$Silent = $false)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $RBMVersion = $Version = Get-Version($RBMVersion)
    $Uri = ""

    $Name = "RainbowMiner"
    try {
        $ReposURI = "https://api.github.com/repos/rainbowminer/$Name/releases/latest"
        if ($Force) {
            $Request = Invoke-RestMethod $ReposURI -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        } else {
            $Request = Invoke-RestMethodAsync $ReposURI -cycletime 3600
        }
        $Version = ($Request.tag_name -replace '^v')
        $Uri = $Request.assets | Where-Object Name -EQ "$($Name)V$($Version).zip" | Select-Object -ExpandProperty browser_download_url

        $Version = Get-Version($Version)

        if (-not $Silent) {
            if ($Version -gt $RBMVersion) {
                Write-Log -Level Warn "$Name is out of date: lastest release version v$Version is available."
            } elseif ($Version -lt $RBMVersion) {
                Write-Log -Level Warn "You are running $Name prerelease v$RBMVersion. Use at your own risk."
            }
        }
    }
    catch {
        Write-Log -Level Warn "Github could not be reached. "
    }
    [PSCustomObject]@{
        Version = $RBMVersion
        RemoteVersion = $Version
        DownloadURI = $Uri
        ManualURI = "https://github.com/RainbowMiner/$Name/releases"
    }
}

function Get-PoolPayoutCurrencies {
    param($Pool)
    $Payout_Currencies = [PSCustomObject]@{}
    @($Pool.PSObject.Properties) | Where-Object Membertype -eq "NoteProperty" | Where-Object {$_.Value -is [string] -and $_.Value.Length -gt 10 -and @("API_Key","API_ID","User","Worker","DataWindow") -inotcontains $_.Name} | Select-Object Name,Value -Unique | Sort-Object Name,Value | Foreach-Object{$Payout_Currencies | Add-Member $_.Name $_.Value}
    $Payout_Currencies
}

function Get-Balance {
    [CmdletBinding()]
    param($Config, $NewRates, [Bool]$Refresh = $false, [Bool]$Details = $false)

    $Data = [PSCustomObject]@{}
    
    if (-not (Test-Path Variable:Script:CachedPoolBalances) -or $Refresh) {
        $NewBalances = @(Get-ChildItem "Balances" -File | Where-Object {$Config.Pools.$($_.BaseName) -and ($Config.ExcludePoolName -inotcontains $_.BaseName -or $Config.ShowPoolBalancesExcludedPools)} | ForEach-Object {
            Get-ChildItemContent "Balances\$($_.Name)" -Parameters @{Config = $Config}
        } | Foreach-Object {$_.Content | Add-Member Name $_.Name -PassThru -Force} | Group-Object -Property Caption | Foreach-Object {
            if ($_.Count -gt 1){foreach ($p in @("Balance","Pending","Total","Paid","Earned","Payouts")) {if (Get-Member -InputObject $_.Group[0] -Name $p) {if ($p -eq "Payouts") {$_.Group[0].$p = @($_.Group.$p | Select-Object)} else {$_.Group[0].$p = ($_.Group.$p | Measure-Object -Sum).Sum}}}}
            $_.Group[0]
        })
        $Script:CachedPoolBalances = @($NewBalances) + @(Compare-Object @($NewBalances.Caption | Select-Object -Unique) @($Script:CachedPoolBalances.Caption | Select-Object -Unique) | Where-Object SideIndicator -EQ "=>" | Select-Object -ExpandProperty InputObject | ForEach-Object {$Script:CachedPoolBalances | Where-Object Caption -EQ $_}) | Sort-Object Caption
    }

    $Balances = @($Script:CachedPoolBalances | Where-Object Name -ne '*Total*' | Foreach-Object {foreach ($p in @($_.PSObject.Properties.Name | Where-Object {$_ -match "^(Value in |Balance \()(\w+)"})) {$_.PSObject.Properties.Remove($p)};$_})

    if (-not $Balances) {return}

    #Get exchgange rates for all payout currencies
    $CurrenciesWithBalances = @(@($Balances.currency) | Select-Object -Unique | Sort-Object)
    $CurrenciesToExchange = @(@("BTC") + @($Config.Currency) | Select-Object -Unique | Sort-Object)
    try {
        $RatesAPI = Invoke-RestMethodAsync "https://min-api.cryptocompare.com/data/pricemulti?fsyms=$($CurrenciesWithBalances -join ",")&tsyms=$($CurrenciesToExchange -join ",")&extraParams=https://github.com/rainbowminer/RainbowMiner"
    }
    catch {
        $RatesAPI = [PSCustomObject]@{}
        $CurrenciesWithBalances | Foreach-Object {
            $Currency = $_
            if ($NewRates.ContainsKey($Currency) -and $NewRates.$Currency -match "^[\d+\.]+$") {
                $RatesAPI | Add-Member "$($Currency)" ([PSCustomObject]@{})
                $CurrenciesToExchange | Foreach-Object {
                    $RatesAPI.$Currency | Add-Member $_ ([double]$NewRates.$_/[double]$NewRates.$Currency)
                }
            }
        }
    }

    #Add total of totals
    $Totals = [PSCustomObject]@{
        Name    = "*Total*"
        Caption = "*Total*"
    }
    [hashtable]$Digits = @{}
    @($CurrenciesWithBalances)+@($Config.Currency) | Where-Object {$_} | Select-Object -Unique | Foreach-Object {
        if (-not $NewRates.ContainsKey($_) -and $RatesAPI.$_.BTC) {$v = 1/$RatesAPI.$_.BTC;$NewRates[$_] = [string][math]::round($v,[math]::max(0,[math]::truncate(8-[math]::log($v,10))))}
        $Digits[$_] = if ($NewRates.ContainsKey($_)) {($($NewRates.$_).ToString().Split(".")[1]).length} else {8}
    }

    $CurrenciesWithBalances | Sort-Object | ForEach-Object {
        $Currency = $_.ToUpper()
        $Balances | Where-Object Currency -eq $Currency | Foreach-Object {$_ | Add-Member "Balance ($Currency)" $_.Total -Force}
        if (($Balances."Balance ($Currency)" | Measure-Object -Sum).sum) {$Totals | Add-Member "Balance ($Currency)" ($Balances."Balance ($Currency)" | Measure-Object -Sum).sum -Force}
    }

    #Add converted values
    $Config.Currency | Sort-Object | ForEach-Object {
        $Currency = $_.ToUpper()
        $Balances | Foreach-Object {
            $Balance = $_
            $Balance | Add-Member "Value in $Currency" $(if ($RatesAPI.$($Balance.Currency).$Currency -ne $null) {$Balance.Total * $RatesAPI.$($Balance.Currency).$Currency}elseif($RatesAPI.$Currency.$($Balance.Currency)) {$Balance.Total / $RatesAPI.$Currency.$($Balance.Currency)}else{"-"}) -Force
        }
        if (($Balances."Value in $Currency" | Where-Object {$_ -ne "-"} | Measure-Object -Sum -ErrorAction Ignore).sum)  {$Totals | Add-Member "Value in $Currency" ($Balances."Value in $Currency" | Where-Object {$_ -ne "-"} | Measure-Object -Sum -ErrorAction Ignore).sum -Force}
    }

    if (-not $Details) {
        #consolidate result
        $Balances = $Balances | Group-Object -Property Name | Foreach-Object {
            $_.Group | Sort-Object @{Expression={$_.Currency -eq "BTC"};Descending=$true},Caption | Select-Object -First 1 | Foreach-Object {
                $Balance = $_
                if ($Balance.Name -ne "*Total*") {$Balance.Caption = "$($Balance.Name) ($($Balance.Currency))";$Balance.Currency = "BTC"}
                $Balance.PSObject.Properties.Name | Where-Object {$_ -match "^Value in"} | Foreach-Object {
                    $Field = $_
                    $Balance.$Field = ($Balances | Where-Object {$_.Name -eq $Balance.Name -and $_.$Field -and $_.$Field -ne "-"} | Measure-Object -Property $Field -Sum -ErrorAction Ignore).sum
                }
                $Balance
            }
        }
    }

    $Balances += $Totals

    $Balances | Foreach-Object {
        $Balance = $_
        $Balance.PSObject.Properties.Name | Where-Object {$_ -match "^(Value in |Balance \()(\w+)"} | Foreach-Object {if ($Balance.$_ -eq "" -or $Balance.$_ -eq $null) {$Balance.$_=0};$Balance.$_ = "{0:N$($Digits[$Matches[2]])}" -f $Balance.$_}
    }
    
    $Data | Add-Member Balances $Balances
    $Data | Add-Member Rates $RatesAPI

    Return $Data
}

function Get-CoinSymbol {
    [CmdletBinding()]
    param($CoinName = "Bitcoin",[Switch]$Silent)
    
    if (-not (Test-Path Variable:Global:GlobalCoinmarketCapList) -or -not $Global:GlobalCoinmarketCapList.Count) {
        $OldEAP = $ErrorActionPreference
        $ErrorActionPreference = "Stop"
        try {
            $Request = Invoke-RestMethod "https://api.coinmarketcap.com/v2/listings/" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        }
        catch {
            Write-Log -Level Warn "Coinmarketcap API (listings) has failed. "
        }
        $ErrorActionPreference = $OldEAP

        if ($Request.data -eq $null -or $Request.data.Count -le 100) {
            Write-Log -Level Warn "Coinmarketcap API (listings) returned nothing. "
            return
        }
        [hashtable]$Global:GlobalCoinmarketCapList = @{}
        [hashtable]$Global:GlobalCoinmarketCapCoins = @{}
        foreach ($data in $Request.data) {
            $Global:GlobalCoinmarketCapList[$data.symbol] = $data
            $Global:GlobalCoinmarketCapCoins[$data.name.ToLower() -replace "[^a-z0-9]+"] = $data.symbol
        }
        if (Test-Path "Data\Coins.json") {
            $NewCoins = Get-Content "Data\Coins.json" -Raw | ConvertFrom-Json
            $NewCoins.PSObject.Properties.Name | Foreach-Object {$name = $_.ToLower() -replace "[^a-z0-9]+";if (-not $Global:GlobalCoinmarketCapCoins.ContainsKey($name)) {$Global:GlobalCoinmarketCapCoins[$name] = $NewCoins.$_}}
        }        
    }

    if (-not $Silent) {$Global:GlobalCoinmarketCapCoins[$CoinName.ToLower() -replace "[^a-z0-9]+"]}
}

function Get-Ticker {
    [CmdletBinding()]
    param($Symbol, $Convert)

    if (-not $Convert) {$Convert="BTC"}
    $Convert = $Convert.ToUpper()

    try {
        $Symbol = ($Symbol -join ',').ToUpper()
        if ($Symbol -match ',') {
            $RatesAPI = Invoke-RestMethodAsync "https://min-api.cryptocompare.com/data/pricemulti?fsyms=$($Symbol)&tsyms=$($Convert)&extraParams=https://github.com/rainbowminer/RainbowMiner"
            if ($RatesAPI.Response -eq "Error") {
                Write-Log -Level Warn "Symbols $($Symbol) not found on Cryptocompare"
            } else {
                $RatesAPI
            }
        } else {
            $RatesAPI = Invoke-RestMethodAsync "https://min-api.cryptocompare.com/data/price?fsym=$($Symbol)&tsyms=$($Convert)&extraParams=https://github.com/rainbowminer/RainbowMiner"
            if ($RatesAPI.Response -eq "Error") {
                Write-Log -Level Warn "Symbol $($Symbol) not found on Cryptocompare"
            } else {
                [PSCustomObject]@{$Symbol = $RatesAPI}
            }
        }
    }
    catch {
        Write-Log -Level Warn "Cryptocompare API for $($Symbol) to $($Convert) has failed. "
    }
}

Function Write-Log {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)][ValidateNotNullOrEmpty()][Alias("LogContent")][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet("Error", "Warn", "Info", "Verbose", "Debug")][string]$Level = "Info"
    )
    
    Begin { }
    Process {
        # Inherit the same verbosity settings as the script importing this
        if (-not $PSBoundParameters.ContainsKey('InformationPreference')) { $InformationPreference = $PSCmdlet.GetVariableValue('InformationPreference') }
        if (-not $PSBoundParameters.ContainsKey('Verbose')) { $VerbosePreference = $PSCmdlet.GetVariableValue('VerbosePreference') }
        if (-not $PSBoundParameters.ContainsKey('Debug')) { $DebugPreference = $PSCmdlet.GetVariableValue('DebugPreference') }

        # Get mutex named MPMWriteLog. Mutexes are shared across all threads and processes.
        # This lets us ensure only one thread is trying to write to the file at a time.
        $mutex = New-Object System.Threading.Mutex($false, "MPMWriteLog")

        $filename = ".\Logs\RainbowMiner_$(Get-Date -Format "yyyy-MM-dd").txt"
        $date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        if (-not (Test-Path "Stats")) {New-Item "Stats" -ItemType "directory" > $null}
        if (-not (Test-Path "Stats\Pools")) {New-Item "Stats\Pools" -ItemType "directory" > $null}
        if (-not (Test-Path "Stats\Miners")) {New-Item "Stats\Miners" -ItemType "directory" > $null}

        switch ($Level) {
            'Error' {
                $LevelText = 'ERROR:'
                Write-Error -Message $Message
            }
            'Warn' {
                $LevelText = 'WARNING:'
                Write-Warning -Message $Message
            }
            'Info' {
                $LevelText = 'INFO:'
                Write-Information -MessageData $Message
            }
            'Verbose' {
                $LevelText = 'VERBOSE:'
                Write-Verbose -Message $Message
            }
            'Debug' {
                $LevelText = 'DEBUG:'
                Write-Debug -Message $Message
            }
        }

        # Attempt to aquire mutex, waiting up to 1 second if necessary.  If aquired, write to the log file and release mutex.  Otherwise, display an error.
        if ($mutex.WaitOne(1000)) {
            "$date $LevelText $Message" | Out-File -FilePath $filename -Append -Encoding utf8
            $mutex.ReleaseMutex()
        }
        else {
            Write-Error -Message "Log file is locked, unable to write message to $FileName."
        }
    }
    End {}
}

function Set-Stat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$Name, 
        [Parameter(Mandatory = $true)]
        [Double]$Value, 
        [Parameter(Mandatory = $false)]
        [DateTime]$Updated = (Get-Date).ToUniversalTime(), 
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Duration, 
        [Parameter(Mandatory = $false)]
        [Bool]$FaultDetection = $false, 
        [Parameter(Mandatory = $false)]
        [Bool]$ChangeDetection = $false,
        [Parameter(Mandatory = $false)]
        [Double]$FaultTolerance = 0.1,
        [Parameter(Mandatory = $false)]
        [Double]$PowerDraw = 0,
        [Parameter(Mandatory = $false)]
        [String]$Sub = ""
    )

    $Updated = $Updated.ToUniversalTime()

    if ($Name -match '_Profit$') {$Path = "Stats\Pools"}
    elseif ($Name -match '_Hashrate$') {$Path = "Stats\Miners"}
    else {$Path = "Stats"}

    if ($Sub) {
        #legacy
        if (Test-Path ("$Path\$Name.txt")) {Move-Item "$Path\$Name.txt" "$Path\$Sub-$Name.txt" -Force}
        $Path = "$Path\$Sub-$Name.txt"
    } else {
        $Path = "$Path\$Name.txt"
    }

    $SmallestValue = 1E-20

    $Stat = Get-Content $Path -ErrorAction Ignore -Raw
   
    try {
        $Stat = $Stat | ConvertFrom-Json -ErrorAction Stop
        if ($Stat -and $PowerDraw -gt 0 -and $Stat.PowerDraw_Live -eq $null) {
            #backward compatibility
            $Stat | Add-Member -NotePropertyMembers ([PSCustomObject]@{PowerDraw_Live = $PowerDraw;PowerDraw_Average = $PowerDraw;PowerDraw_Fluctuation = 0})            
        }
        $Stat = [PSCustomObject]@{
            Live = [Double]$Stat.Live
            Minute = [Double]$Stat.Minute
            Minute_Fluctuation = [Double]$Stat.Minute_Fluctuation
            Minute_5 = [Double]$Stat.Minute_5
            Minute_5_Fluctuation = [Double]$Stat.Minute_5_Fluctuation
            Minute_10 = [Double]$Stat.Minute_10
            Minute_10_Fluctuation = [Double]$Stat.Minute_10_Fluctuation
            Hour = [Double]$Stat.Hour
            Hour_Fluctuation = [Double]$Stat.Hour_Fluctuation
            Day = [Double]$Stat.Day
            Day_Fluctuation = [Double]$Stat.Day_Fluctuation
            ThreeDay = [Double]$Stat.ThreeDay
            ThreeDay_Fluctuation = [Double]$Stat.ThreeDay_Fluctuation
            Week = [Double]$Stat.Week
            Week_Fluctuation = [Double]$Stat.Week_Fluctuation
            PowerDraw_Live = [Double]$Stat.PowerDraw_Live
            PowerDraw_Average = [Double]$Stat.PowerDraw_Average
            PowerDraw_Fluctuation = [Double]$Stat.PowerDraw_Fluctuation
            Duration = [TimeSpan]$Stat.Duration
            Updated = [DateTime]$Stat.Updated
        }
        if ($Stat.Day -and -not $Stat.ThreeDay) {$Stat.ThreeDay=($Stat.Day+$Stat.Week)/2;$Stat.ThreeDay_Fluctuation=($Stat.Day_Fluctuation+$Stat.Week_Fluctuation)/2} #backward compatibility

        $ToleranceMin = $Value
        $ToleranceMax = $Value

        if ($FaultDetection) {
            if ($FaultTolerance -eq $null) {$FaultTolerance = 0.1}
            $ToleranceMin = $Stat.Week * (1 - [Math]::Min([Math]::Max($Stat.Week_Fluctuation * 2, $FaultTolerance), 0.9))
            $ToleranceMax = $Stat.Week * (1 + [Math]::Min([Math]::Max($Stat.Week_Fluctuation * 2, $FaultTolerance +0.1), 0.9))
        }

        if ($ChangeDetection -and [Decimal]$Value -eq [Decimal]$Stat.Live) {$Updated = $Stat.updated}

        if ($Value -lt $ToleranceMin -or $Value -gt $ToleranceMax) {
            Write-Log -Level Warn "Stat file ($Name) was not updated because the value ($([Decimal]$Value)) is outside fault tolerance ($([Int]$ToleranceMin) to $([Int]$ToleranceMax)). "
        }
        else {
            $Span_Minute = [Math]::Min($Duration.TotalMinutes / [Math]::Min($Stat.Duration.TotalMinutes, 1), 1)
            $Span_Minute_5 = [Math]::Min(($Duration.TotalMinutes / 5) / [Math]::Min(($Stat.Duration.TotalMinutes / 5), 1), 1)
            $Span_Minute_10 = [Math]::Min(($Duration.TotalMinutes / 10) / [Math]::Min(($Stat.Duration.TotalMinutes / 10), 1), 1)
            $Span_Hour = [Math]::Min($Duration.TotalHours / [Math]::Min($Stat.Duration.TotalHours, 1), 1)
            $Span_Day = [Math]::Min($Duration.TotalDays / [Math]::Min($Stat.Duration.TotalDays, 1), 1)
            $Span_ThreeDay = [Math]::Min(($Duration.TotalDays / 3) / [Math]::Min(($Stat.Duration.TotalDays / 3), 1), 1)
            $Span_Week = [Math]::Min(($Duration.TotalDays / 7) / [Math]::Min(($Stat.Duration.TotalDays / 7), 1), 1)

            $Stat = [PSCustomObject]@{
                Live = $Value
                Minute = ((1 - $Span_Minute) * $Stat.Minute) + ($Span_Minute * $Value)
                Minute_Fluctuation = ((1 - $Span_Minute) * $Stat.Minute_Fluctuation) + 
                ($Span_Minute * ([Math]::Abs($Value - $Stat.Minute) / [Math]::Max([Math]::Abs($Stat.Minute), $SmallestValue)))
                Minute_5 = ((1 - $Span_Minute_5) * $Stat.Minute_5) + ($Span_Minute_5 * $Value)
                Minute_5_Fluctuation = ((1 - $Span_Minute_5) * $Stat.Minute_5_Fluctuation) + 
                ($Span_Minute_5 * ([Math]::Abs($Value - $Stat.Minute_5) / [Math]::Max([Math]::Abs($Stat.Minute_5), $SmallestValue)))
                Minute_10 = ((1 - $Span_Minute_10) * $Stat.Minute_10) + ($Span_Minute_10 * $Value)
                Minute_10_Fluctuation = ((1 - $Span_Minute_10) * $Stat.Minute_10_Fluctuation) + 
                ($Span_Minute_10 * ([Math]::Abs($Value - $Stat.Minute_10) / [Math]::Max([Math]::Abs($Stat.Minute_10), $SmallestValue)))
                Hour = ((1 - $Span_Hour) * $Stat.Hour) + ($Span_Hour * $Value)
                Hour_Fluctuation = ((1 - $Span_Hour) * $Stat.Hour_Fluctuation) + 
                ($Span_Hour * ([Math]::Abs($Value - $Stat.Hour) / [Math]::Max([Math]::Abs($Stat.Hour), $SmallestValue)))
                Day = ((1 - $Span_Day) * $Stat.Day) + ($Span_Day * $Value)
                Day_Fluctuation = ((1 - $Span_Day) * $Stat.Day_Fluctuation) + 
                ($Span_Day * ([Math]::Abs($Value - $Stat.Day) / [Math]::Max([Math]::Abs($Stat.Day), $SmallestValue)))
                ThreeDay = ((1 - $Span_ThreeDay) * $Stat.ThreeDay) + ($Span_ThreeDay * $Value)
                ThreeDay_Fluctuation = ((1 - $Span_ThreeDay) * $Stat.ThreeDay_Fluctuation) + 
                ($Span_ThreeDay * ([Math]::Abs($Value - $Stat.ThreeDay) / [Math]::Max([Math]::Abs($Stat.ThreeDay), $SmallestValue)))
                Week = ((1 - $Span_Week) * $Stat.Week) + ($Span_Week * $Value)
                Week_Fluctuation = ((1 - $Span_Week) * $Stat.Week_Fluctuation) + 
                ($Span_Week * ([Math]::Abs($Value - $Stat.Week) / [Math]::Max([Math]::Abs($Stat.Week), $SmallestValue)))
                PowerDraw_Live = $PowerDraw
                PowerDraw_Average = ((1 - $Span_Week) * $Stat.PowerDraw_Average) + ($Span_Week * $PowerDraw)
                PowerDraw_Fluctuation = ((1 - $Span_Week) * $Stat.PowerDraw_Fluctuation) + 
                ($Span_Week * ([Math]::Abs($PowerDraw - $Stat.PowerDraw_Average) / [Math]::Max([Math]::Abs($Stat.PowerDraw_Average), $SmallestValue)))
                Duration = $Stat.Duration + $Duration
                Updated = $Updated
            }
        }
    }
    catch {
        if ($Error.Count -gt 1){$Error.RemoveAt($Error.Count - 1)}else{$Error.Clear()}
        if (Test-Path $Path) {Write-Log -Level Warn "Stat file ($Name) is corrupt and will be reset. "}

        $Stat = [PSCustomObject]@{
            Live = $Value
            Minute = $Value
            Minute_Fluctuation = 0
            Minute_5 = $Value
            Minute_5_Fluctuation = 0
            Minute_10 = $Value
            Minute_10_Fluctuation = 0
            Hour = $Value
            Hour_Fluctuation = 0
            Day = $Value
            Day_Fluctuation = 0
            ThreeDay = $Value
            ThreeDay_Fluctuation = 0
            Week = $Value
            Week_Fluctuation = 0
            PowerDraw_Live = $PowerDraw
            PowerDraw_Average = $PowerDraw
            PowerDraw_Fluctuation = 0
            Duration = $Duration
            Updated = $Updated
        }
    }

    if (-not (Test-Path "Stats")) {New-Item "Stats" -ItemType "directory" > $null}
    if (-not (Test-Path "Stats\Miners")) {New-Item "Stats\Miners" -ItemType "directory" > $null}
    if (-not (Test-Path "Stats\Pools")) {New-Item "Stats\Pools" -ItemType "directory" > $null}

    if ($Stat.Duration -ne 0) {
        [PSCustomObject]@{
            Live = [Decimal]$Stat.Live
            Minute = [Decimal]$Stat.Minute
            Minute_Fluctuation = [Double]$Stat.Minute_Fluctuation
            Minute_5 = [Decimal]$Stat.Minute_5
            Minute_5_Fluctuation = [Double]$Stat.Minute_5_Fluctuation
            Minute_10 = [Decimal]$Stat.Minute_10
            Minute_10_Fluctuation = [Double]$Stat.Minute_10_Fluctuation
            Hour = [Decimal]$Stat.Hour
            Hour_Fluctuation = [Double]$Stat.Hour_Fluctuation
            Day = [Decimal]$Stat.Day
            Day_Fluctuation = [Double]$Stat.Day_Fluctuation
            ThreeDay = [Decimal]$Stat.ThreeDay
            ThreeDay_Fluctuation = [Double]$Stat.ThreeDay_Fluctuation
            Week = [Decimal]$Stat.Week
            Week_Fluctuation = [Double]$Stat.Week_Fluctuation
            PowerDraw_Live = [Decimal]$Stat.PowerDraw_Live
            PowerDraw_Average = [Decimal]$Stat.PowerDraw_Average
            PowerDraw_Fluctuation = [Double]$Stat.PowerDraw_Fluctuation
            Duration = [String]$Stat.Duration
            Updated = [DateTime]$Stat.Updated
        } | ConvertTo-Json | Set-Content $Path
    }

    $Stat
}

function Get-Stat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [String]$Name,
        [Parameter(Mandatory = $false)]
        [String]$Sub = ""
    )

    if (-not (Test-Path "Stats")) {New-Item "Stats" -ItemType "directory" > $null}
    if (-not (Test-Path "Stats\Miners")) {New-Item "Stats\Miners" -ItemType "directory" > $null}
    if (-not (Test-Path "Stats\Pools")) {New-Item "Stats\Pools" -ItemType "directory" > $null}

    if ($Name) {
        # Return single requested stat
        if ($Name -match '_Profit$') {$Path = "Stats\Pools"}
        elseif ($Name -match '_Hashrate$') {$Path = "Stats\Miners"}
        else {$Path = "Stats"}

        if ($Sub) {
            #legacy
            if (Test-Path ("$Path\$Name.txt")) {Move-Item "$Path\$Name.txt" "$Path\$Sub-$Name.txt" -Force}
            $Path = "$Path\$Sub-$Name.txt"
        } else {
            $Path = "$Path\$Name.txt"
        }
        if (Test-Path $Path) {ConvertFrom-Json (Get-Content $Path -ErrorAction Ignore -Raw) -ErrorAction Ignore}
    } else {
        # Return all stats
        [hashtable]$Stats = @{}

        foreach($p in (Get-ChildItem -Recurse "Stats" -File)) {
            $BaseName = $p.BaseName
            $FullName = $p.FullName
            try {
                $Stats[$BaseName -replace "^(AMD|CPU|NVIDIA)-"] = ConvertFrom-Json (Get-Content $FullName -ErrorAction Stop -Raw) -ErrorAction Stop
            }
            catch {
                #Remove broken stat file
                Write-Log -Level Warn "Stat file ($BaseName) is corrupt and will be removed. "
                if (Test-Path $FullName) {Remove-Item -Path  $FullName -Force -Confirm:$false}
            }
        }
        Return $Stats
    }
}

function Get-ChildItemContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$Path, 
        [Parameter(Mandatory = $false)]
        [Hashtable]$Parameters = @{},
        [Parameter(Mandatory = $false)]
        [Switch]$Force = $false
    )

    function Invoke-ExpressionRecursive ($Expression) {
        if ($Expression -is [String]) {
            if ($Expression -match '(\$|")') {
                try {$Expression = Invoke-Expression $Expression}
                catch {$Expression = Invoke-Expression "`"$Expression`""}
            }
        }
        elseif ($Expression -is [PSCustomObject]) {
            $Expression | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name | ForEach-Object {
                $Expression.$_ = Invoke-ExpressionRecursive $Expression.$_
            }
        }
        return $Expression
    }

    Get-ChildItem $Path -File -ErrorAction Ignore | ForEach-Object {
        $Name = $_.BaseName
        $Content = @()
        if ($_.Extension -eq ".ps1") {
            $Content = & {
                foreach ($k in $Parameters.Keys) {Set-Variable $k $Parameters.$k}
                & $_.FullName @Parameters
                foreach ($k in $Parameters.Keys) {Remove-Variable $k -ErrorAction Ignore}
            }
        }
        else {
            $Content = & {
                foreach ($k in $Parameters.Keys) {Set-Variable $k $Parameters.$k}                
                try {
                    ($_ | Get-Content | ConvertFrom-Json) | ForEach-Object {Invoke-ExpressionRecursive $_}
                }
                catch [ArgumentException] {
                    $null
                }
                foreach ($k in $Parameters.Keys) {Remove-Variable $k -ErrorAction Ignore}
            }
            if ($Content -eq $null) {$Content = $_ | Get-Content}
        }
        foreach ($c in $Content) {
            if ($c.Name) {
                [PSCustomObject]@{Name = $c.Name; BaseName = $Name; Content = $c}
            }
            else {
                [PSCustomObject]@{Name = $Name; BaseName = $Name; Content = $c}
            }
        }
        if ($Force) {
            foreach ($k in $Parameters.Keys) {
                if (-not (Get-Member -InputObject $Content -Name $k -Membertype Properties)) {
                    $Content | Add-Member $k $Parameters.$k -Force 
                }
            }
        }
    }
}

function Get-MinersContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Pools,
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$DevicesByTypes,
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Stats       
    )

    $MinerStats = [hashtable]@{}
    $Stats.PSObject.Properties.Name | Where-Object {$_ -match "^(.+?)-"} | Foreach-Object {
        if (-not $MinerStats[$matches[1]]) {$MinerStats[$matches[1]] = [PSCustomObject]@{}}
        $MinerStats[$matches[1]] | Add-Member $_ ($Stats.$_)
    }
 
    $Parameters = @{
        Config = $Config
        Devices = $DevicesByTypes
        Pools = $Pools
    }
    
    Get-ChildItem "Miners\*.ps1" -File -ErrorAction Ignore | ForEach-Object {
        $Miner = $_
        $Name = $Miner.BaseName
 
        $Parameters.Stats = $MinerStats[$Name]
                
        & $Miner.FullName @Parameters | ForEach-Object {
            $_ | Add-Member -NotePropertyMembers @{
                Name = if ($_.Name) {$_.Name} else {$Name}
                BaseName = $Name
                Algorithm = @($_.HashRates.PSObject.Properties.Name | Foreach-Object {$_ -replace '\-.*$'} | Select-Object)
                DeviceModel = if (@($DevicesByTypes.FullComboModels.PSObject.Properties.Name) -icontains $_.DeviceModel) {$DevicesByTypes.FullComboModels."$($_.DeviceModel)"} else {$_.DeviceModel}
            } -Force -PassThru
        }
    }
}


filter ConvertTo-Hash { 
    [CmdletBinding()]
    $Hash = $_
    switch ([math]::truncate([math]::log($Hash, 1000))) {
        "-Infinity" {"0  H"}
        0 {"{0:n2}  H" -f ($Hash / 1)}
        1 {"{0:n2} KH" -f ($Hash / 1000)}
        2 {"{0:n2} MH" -f ($Hash / 1000000)}
        3 {"{0:n2} GH" -f ($Hash / 1000000000)}
        4 {"{0:n2} TH" -f ($Hash / 1000000000000)}
        Default {"{0:n2} PH" -f ($Hash / 1000000000000000)}
    }
}

function ConvertTo-LocalCurrency { 
    [CmdletBinding()]
    # To get same numbering scheme regardless of value BTC value (size) to determine formatting
    # Use $Offset to add/remove decimal places

    param(
        [Parameter(Mandatory = $true)]
        [Double]$Number, 
        [Parameter(Mandatory = $true)]
        [Double]$BTCRate,
        [Parameter(Mandatory = $false)]
        [Int]$Offset = 2
    )

    ($Number * $BTCRate).ToString("N$([math]::max([math]::min([math]::truncate(10 - $Offset - [math]::log10($BTCRate)),9),0))")
}

function Get-Combination {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Array]$Value, 
        [Parameter(Mandatory = $false)]
        [Int]$SizeMax = $Value.Count, 
        [Parameter(Mandatory = $false)]
        [Int]$SizeMin = 1
    )

    $Combination = [PSCustomObject]@{}

    for ($i = 0; $i -lt $Value.Count; $i++) {
        $Combination | Add-Member @{[Math]::Pow(2, $i) = $Value[$i]}
    }

    $Combination_Keys = $Combination | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name

    for ($i = $SizeMin; $i -le $SizeMax; $i++) {
        $x = [Math]::Pow(2, $i) - 1

        while ($x -le [Math]::Pow(2, $Value.Count) - 1) {
            [PSCustomObject]@{Combination = $Combination_Keys | Where-Object {$_ -band $x} | ForEach-Object {$Combination.$_}}
            $smallest = ($x -band - $x)
            $ripple = $x + $smallest
            $new_smallest = ($ripple -band - $ripple)
            $ones = (($new_smallest / $smallest) -shr 1) - 1
            $x = $ripple -bor $ones
        }
    }
}

function Start-SubProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$FilePath, 
        [Parameter(Mandatory = $false)]
        [String]$ArgumentList = "", 
        [Parameter(Mandatory = $false)]
        [String]$LogPath = "", 
        [Parameter(Mandatory = $false)]
        [String]$WorkingDirectory = "", 
        [ValidateRange(-2, 3)]
        [Parameter(Mandatory = $false)]
        [Int]$Priority = 0,
        [Parameter(Mandatory = $false)]
        [String]$ProcessName = "",
        [Parameter(Mandatory = $false)]
        [Bool]$ShowMinerWindow = $false
    )

    if ( $ShowMinerWindow ) {
        Start-SubProcessInConsole -FilePath $FilePath -ArgumentList $ArgumentList -LogPath $LogPath -WorkingDirectory $WorkingDirectory -Priority $Priority -ProcessName $ProcessName
    } else {
        Start-SubProcessInBackground -FilePath $FilePath -ArgumentList $ArgumentList -LogPath $LogPath -WorkingDirectory $WorkingDirectory -Priority $Priority -ProcessName $ProcessName
    }
}

function Start-SubProcessInBackground {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$FilePath, 
        [Parameter(Mandatory = $false)]
        [String]$ArgumentList = "", 
        [Parameter(Mandatory = $false)]
        [String]$LogPath = "", 
        [Parameter(Mandatory = $false)]
        [String]$WorkingDirectory = "", 
        [ValidateRange(-2, 3)]
        [Parameter(Mandatory = $false)]
        [Int]$Priority = 0,
        [Parameter(Mandatory = $false)]
        [String]$ProcessName = ""
    )

    $ExecName = ([io.fileinfo]($FilePath | Split-Path -Leaf -ErrorAction Ignore)).BaseName
    if ($ProcessName -ne "" -and $ProcessName -ne $ExecName) {$ExecName = $ProcessName}
    $Running = @(Get-Process | Where-Object {$_.Name -eq $ExecName} | Select-Object -ExpandProperty Id)

    $ScriptBlock = "Set-Location '$WorkingDirectory'; (Get-Process -Id `$PID).PriorityClass = '$(@{-2 = "Idle"; -1 = "BelowNormal"; 0 = "Normal"; 1 = "AboveNormal"; 2 = "High"; 3 = "RealTime"}[$Priority])'; "
    $ScriptBlock += "& '$FilePath'"
    if ($ArgumentList) {$ScriptBlock += " $ArgumentList"}
    $ScriptBlock += " *>&1"
    $ScriptBlock += " | Write-Output"
    if ($LogPath) {$ScriptBlock += " | Tee-Object '$LogPath'"}

    $Job = Start-Job ([ScriptBlock]::Create($ScriptBlock))

    $wait_count = 0;
    do{
        Start-Sleep 1;
        $Process = Get-Process | Where-Object {$_.Name -eq $ExecName -and $Running -notcontains $_.Id} | Select-Object -First 1
        $wait_count++
    } while ($Process -eq $null -and $wait_count -le 5)

    if ($Process) {
        $Process.PriorityClass = @{-2 = "Idle"; -1 = "BelowNormal"; 0 = "Normal"; 1 = "AboveNormal"; 2 = "High"; 3 = "RealTime"}[$Priority]
        $Job | Add-Member MiningProcess $Process -Force -ErrorAction Ignore
    }
    $Job
}

function Start-SubProcessInConsole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$FilePath, 
        [Parameter(Mandatory = $false)]
        [String]$ArgumentList = "", 
        [Parameter(Mandatory = $false)]
        [String]$LogPath = "", 
        [Parameter(Mandatory = $false)]
        [String]$WorkingDirectory = "", 
        [ValidateRange(-2, 3)]
        [Parameter(Mandatory = $false)]
        [Int]$Priority = 0,
        [Parameter(Mandatory = $false)]
        [String]$ProcessName = ""
    )

    $ExecName = ([io.fileinfo]($FilePath | Split-Path -Leaf -ErrorAction Ignore)).BaseName
    if ( $ProcessName -eq $ExecName ) { $ProcessName = "" }

    $Job = Start-Job -ArgumentList $PID, $FilePath, $ArgumentList, $WorkingDirectory, $LogPath, $ProcessName {
        param($ControllerProcessID, $FilePath, $ArgumentList, $WorkingDirectory, $LogPath, $ProcessName)

        $ControllerProcess = Get-Process -Id $ControllerProcessID
        if ($ControllerProcess -eq $null) {return}

        if ($ProcessName -ne "") {
            $Running = @(Get-Process | Where-Object { $_.Name -eq $ProcessName } | Select-Object -ExpandProperty Id)
        }

        $ProcessParam = @{}
        $ProcessParam.Add("FilePath", $FilePath)
        $ProcessParam.Add("WindowStyle", 'Minimized')
        if ($ArgumentList -ne "") {$ProcessParam.Add("ArgumentList", $ArgumentList)}
        if ($WorkingDirectory -ne "") {$ProcessParam.Add("WorkingDirectory", $WorkingDirectory)}
        #if ($LogPath -ne "") {$ProcessParam.Add("RedirectStandardOutput", $LogPath);}

        $Process = Start-Process @ProcessParam -PassThru
        if ($Process -eq $null) {
            [PSCustomObject]@{ProcessId = $null}
            return        
        }

       if ( $ProcessName -ne "" ) {
            $wait_count = 0;
            do{
                Start-Sleep 1;
                $Process = Get-Process | Where-Object {$_.Name -eq $ProcessName -and $Running -notcontains $_.Id} | Select-Object -First 1
                $wait_count++;
            } while ($Process -eq $null -and $wait_count -le 5);
        }
        if ($Process -eq $null) {
            [PSCustomObject]@{ProcessId = $null}
            return        
        }

        [PSCustomObject]@{ProcessId = $Process.Id; ProcessHandle = $Process.Handle}

        $ControllerProcess.Handle > $null
        $Process.Handle > $null

        do {if ($ControllerProcess.WaitForExit(1000)) {$Process.CloseMainWindow() > $null}}
        while ($Process.HasExited -eq $false)
    }

    do {Start-Sleep 1; $JobOutput = Receive-Job $Job}
    while ($JobOutput -eq $null)

    $Process = Get-Process | Where-Object Id -eq $JobOutput.ProcessId

    if ($Process) {
        $Process.PriorityClass = @{-2 = "Idle"; -1 = "BelowNormal"; 0 = "Normal"; 1 = "AboveNormal"; 2 = "High"; 3 = "RealTime"}[$Priority]
        $Job | Add-Member MiningProcess $Process -Force -ErrorAction Ignore
    }

    $Job
}

function Expand-WebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$Uri, 
        [Parameter(Mandatory = $false)]
        [String]$Path = ""
    )

    # Set current path used by .net methods to the same as the script's path
    [Environment]::CurrentDirectory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation

    if (-not $Path) {$Path = Join-Path ".\Downloads" ([IO.FileInfo](Split-Path $Uri -Leaf)).BaseName}
    if (-not (Test-Path ".\Downloads")) {New-Item "Downloads" -ItemType "directory" > $null}
    $FileName = Join-Path ".\Downloads" (Split-Path $Uri -Leaf)

    if (Test-Path $FileName) {Remove-Item $FileName}
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest $Uri -OutFile $FileName -UseBasicParsing

    if (".msi", ".exe" -contains ([IO.FileInfo](Split-Path $Uri -Leaf)).Extension) {
        Start-Process $FileName "-qb" -Wait
    }
    else {
        $Path_Old = (Join-Path (Split-Path $Path) ([IO.FileInfo](Split-Path $Uri -Leaf)).BaseName)
        $Path_New = (Join-Path (Split-Path $Path) (Split-Path $Path -Leaf))

        if (Test-Path $Path_Old) {Remove-Item $Path_Old -Recurse -Force}
        Start-Process "7z" "x `"$([IO.Path]::GetFullPath($FileName))`" -o`"$([IO.Path]::GetFullPath($Path_Old))`" -y -spe" -Wait

        if (Test-Path $Path_New) {Remove-Item $Path_New -Recurse -Force}
        if (Get-ChildItem $Path_Old | Where-Object PSIsContainer -EQ $false) {
            Rename-Item $Path_Old (Split-Path $Path -Leaf)
        }
        else {
            Get-ChildItem $Path_Old | Where-Object PSIsContainer -EQ $true | ForEach-Object {Move-Item (Join-Path $Path_Old $_) $Path_New}
            Remove-Item $Path_Old
        }
    }
}

function Invoke-TcpRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$Server = "localhost", 
        [Parameter(Mandatory = $true)]
        [String]$Port, 
        [Parameter(Mandatory = $true)]
        [String]$Request, 
        [Parameter(Mandatory = $true)]
        [Int]$Timeout = 10, #seconds,
        [Parameter(Mandatory = $false)]
        [Switch]$DoNotSendNewline
    )
    $Response = $null
    if ($Server -eq "localhost") {$Server = "127.0.0.1"}
    #try {$ipaddress = [ipaddress]$Server} catch {$ipaddress = [system.Net.Dns]::GetHostByName($Server).AddressList | select-object -index 0}
    try {
        $Client = New-Object System.Net.Sockets.TcpClient $Server, $Port
        $Stream = $Client.GetStream()
        $Writer = New-Object System.IO.StreamWriter $Stream
        $Reader = New-Object System.IO.StreamReader $Stream
        $client.SendTimeout = $Timeout * 1000
        $client.ReceiveTimeout = $Timeout * 1000
        $Writer.AutoFlush = $true

        if ($DoNotSendNewline) {$Writer.Write($Request)} else {$Writer.WriteLine($Request)}
        $Response = $Reader.ReadLine()
    }
    finally {
        if ($Reader) {$Reader.Close()}
        if ($Writer) {$Writer.Close()}
        if ($Stream) {$Stream.Close()}
        if ($Client) {$Client.Close()}
    }

    $Response
}

function Invoke-TcpRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$Server = "localhost", 
        [Parameter(Mandatory = $true)]
        [String]$Port, 
        [Parameter(Mandatory = $true)]
        [Int]$Timeout = 10 #seconds
    )
    $Response = $null
    if ($Server -eq "localhost") {$Server = "127.0.0.1"}
    #try {$ipaddress = [ipaddress]$Server} catch {$ipaddress = [system.Net.Dns]::GetHostByName($Server).AddressList | select-object -index 0}
    try {
        $Client = New-Object System.Net.Sockets.TcpClient $Server, $Port
        $Stream = $Client.GetStream()
        $Reader = New-Object System.IO.StreamReader $Stream
        $client.SendTimeout = $Timeout * 1000
        $client.ReceiveTimeout = $Timeout * 1000
        $Response = $Reader.ReadToEnd()
    }
    finally {
        if ($Reader) {$Reader.Close()}
        if ($Stream) {$Stream.Close()}
        if ($Client) {$Client.Close()}
    }

    $Response
}

function Get-Device {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [String[]]$Name = @(),
        [Parameter(Mandatory = $false)]
        [Switch]$Refresh = $false
    )

    if ($Name) {
        if (-not (Test-Path Variable:Global:GlobalDataDeviceList) -or -not $Global:GlobalDataDeviceList) {$Global:GlobalDataDeviceList = Get-Content ".\Data\devices.json" -Raw | ConvertFrom-Json}        
        $Name_Devices = $Name | ForEach-Object {
            $Name_Split = $_ -split '#'
            $Name_Split = @($Name_Split | Select-Object -First 1) + @($Name_Split | Select-Object -Skip 1 | ForEach-Object {[Int]$_})
            $Name_Split += @("*") * (100 - $Name_Split.Count)

            $Name_Device = $Global:GlobalDataDeviceList.("{0}" -f $Name_Split) | Select-Object *
            $Name_Device | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | ForEach-Object {$Name_Device.$_ = $Name_Device.$_ -f $Name_Split}

            $Name_Device
        }
    }

    # Try to get cached devices first to improve performance
    if ((Test-Path Variable:Global:GlobalCachedDevices) -and -not $Refresh) {
        $Global:GlobalCachedDevices | Foreach-Object {
            $Device = $_
            if ((-not $Name) -or ($Name_Devices | Where-Object {($Device | Select-Object ($_ | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name)) -like ($_ | Select-Object ($_ | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name))}) -or ($Name | Where-Object {@($Device.Model,$Device.Model_Name) -like $_})) {
                $Device
            }
        }
        return
    }

    $Devices = @()
    $PlatformId = 0
    $Index = 0
    $PlatformId_Index = @{}
    $Type_PlatformId_Index = @{}
    $Vendor_Index = @{}
    $Type_Vendor_Index = @{}
    $Type_Index = @{}
    $Type_Mineable_Index = @{}
    $GPUVendorLists = @{}
    foreach ($GPUVendor in @("NVIDIA","AMD","INTEL")) {$GPUVendorLists | Add-Member $GPUVendor @(Get-GPUVendorList $GPUVendor)}

    try {
        [OpenCl.Platform]::GetPlatformIDs() | ForEach-Object {
            [OpenCl.Device]::GetDeviceIDs($_, [OpenCl.DeviceType]::All) | ForEach-Object {
                $Device_OpenCL = $_ | ConvertTo-Json | ConvertFrom-Json

                $Device_Name = [String]$Device_OpenCL.Name -replace '\(TM\)|\(R\)'
                $Vendor_Name = [String]$Device_OpenCL.Vendor

                if ($GPUVendorLists.NVIDIA -icontains $Vendor_Name) {
                    $Vendor_Name = "NVIDIA"
                } elseif ($GPUVendorLists.AMD -icontains $Vendor_Name) {
                    $Device_Name = $($Device_Name -replace 'ASUS|AMD|Series|Graphics' -replace "\s+", ' ').Trim()
                    $Device_Name = $Device_Name -replace '.*Radeon.*([4-5]\d0).*', 'Radeon RX $1'     # RX 400/500 series
                    $Device_Name = $Device_Name -replace '.*\s(Vega).*(56|64).*', 'Radeon Vega $2'    # Vega series
                    $Device_Name = $Device_Name -replace '.*\s(R\d)\s(\w+).*', 'Radeon $1 $2'         # R3/R5/R7/R9 series
                    $Device_Name = $Device_Name -replace '.*\s(HD)\s?(\w+).*', 'Radeon HD $2'         # HD series
                    $Vendor_Name = "AMD"
                } elseif ($GPUVendorLists.INTEL -icontains $Vendor_Name) {
                    $Vendor_Name = "INTEL"
                }

                $Device = [PSCustomObject]@{
                    Index = [Int]$Index
                    PlatformId = [Int]$PlatformId
                    PlatformId_Index = [Int]$PlatformId_Index."$($PlatformId)"
                    Type_PlatformId_Index = [Int]$Type_PlatformId_Index."$($Device_OpenCL.Type)"."$($PlatformId)"
                    Vendor = [String]$Vendor_Name
                    Vendor_Name = [String]$Device_OpenCL.Vendor                    
                    Vendor_Index = [Int]$Vendor_Index."$($Device_OpenCL.Vendor)"
                    Type_Vendor_Index = [Int]$Type_Vendor_Index."$($Device_OpenCL.Type)"."$($Device_OpenCL.Vendor)"
                    Type = [String]$Device_OpenCL.Type
                    Type_Index = [Int]$Type_Index."$($Device_OpenCL.Type)"
                    Type_Mineable_Index = [Int]$Type_Mineable_Index."$($Device_OpenCL.Type)"
                    OpenCL = $Device_OpenCL
                    Model = [String]$($Device_Name -replace "[^A-Za-z0-9]+" -replace "GeForce|Radeon|Intel")
                    Model_Name = [String]$Device_Name
                }

                if ($Device.Type -ne "Cpu" -and ((-not $Name) -or ($Name_Devices | Where-Object {($Device | Select-Object ($_ | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name)) -like ($_ | Select-Object ($_ | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name))}) -or ($Name | Where-Object {@($Device.Model,$Device.Model_Name) -like $_}))) {
                    $Devices += $Device | Add-Member Name ("{0}#{1:d2}" -f $Device.Type, $Device.Type_Index).ToUpper() -PassThru
                }

                if (-not $Type_PlatformId_Index."$($Device_OpenCL.Type)") {
                    $Type_PlatformId_Index."$($Device_OpenCL.Type)" = @{}
                }
                if (-not $Type_Vendor_Index."$($Device_OpenCL.Type)") {
                    $Type_Vendor_Index."$($Device_OpenCL.Type)" = @{}
                }

                $Index++
                $PlatformId_Index."$($PlatformId)"++
                $Type_PlatformId_Index."$($Device_OpenCL.Type)"."$($PlatformId)"++
                $Vendor_Index."$($Device_OpenCL.Vendor)"++
                $Type_Vendor_Index."$($Device_OpenCL.Type)"."$($Device_OpenCL.Vendor)"++
                $Type_Index."$($Device_OpenCL.Type)"++
                if (@("NVIDIA","AMD") -icontains $Vendor_Name) {$Type_Mineable_Index."$($Device_OpenCL.Type)"++}
            }

            $PlatformId++
        }
    }
    catch {
        Write-Log -Level Warn "OpenCL device detection has failed: $($_.Exception.Message)"
    }

    try {
        $CPUIndex = 0
        if (-not (Test-Path Variable:Global:GlobalGetDeviceCacheCIM)) {
            $Global:GlobalGetDeviceCacheCIM = Get-CimInstance -ClassName CIM_Processor
        }
        $Global:GlobalGetDeviceCacheCIM | Foreach-Object {
            # Vendor and type the same for all CPUs, so there is no need to actually track the extra indexes.  Include them only for compatibility.
            $CPUInfo = $_ | ConvertTo-Json | ConvertFrom-Json
            $Device = [PSCustomObject]@{
                Index = [Int]$Index
                Vendor = if ($GPUVendorLists.INTEL -icontains $CPUInfo.Manufacturer){"INTEL"}else{$CPUInfo.Manufacturer}
                Vendor_Name = $CPUInfo.Manufacturer
                Type_PlatformId_Index = $CPUIndex
                Type_Vendor_Index = $CPUIndex
                Type = "Cpu"
                Type_Index = $CPUIndex
                Type_Mineable_Index = $CPUIndex
                CIM = $CPUInfo
                Model = "CPU"
                Model_Name = $CPUInfo.Name
            }

            if ((-not $Name) -or ($Name_Devices | Where-Object {($Device | Select-Object ($_ | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name)) -like ($_ | Select-Object ($_ | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name))})) {
                $Devices += $Device | Add-Member Name ("{0}#{1:d2}" -f $Device.Type, $Device.Type_Index).ToUpper() -PassThru
            }

            $CPUIndex++
            $Index++
        }
    }
    catch {
        Write-Log -Level Warn "CIM CPU detection has failed. "
    }

    $Global:GlobalCachedDevices = $Devices
    $Devices
}

function Get-DevicePowerDraw {
    [cmdletbinding()]
    param(
        [Parameter(Mandatory = $false)]
        [String[]]$DeviceName = @()
    )
    (($Global:GlobalCachedDevices | Where-Object {-not $DeviceName -or $DeviceName -icontains $_.Name}).Data.PowerDraw | Measure-Object -Sum).Sum
}

function Start-Afterburner {
    try {
        Add-Type -Path ".\Includes\MSIAfterburner.NET.dll"
    } catch {
        Write-Log "Failed to load Afterburner interface library"
        $Script:abMonitor = $false
        $Script:abControl = $false
        return
    }
    
    try {
        $Script:abMonitor = New-Object MSI.Afterburner.HardwareMonitor
    } catch {
        Write-Log "Failed to create MSI Afterburner Monitor object. Falling back to standard monitoring."
        $Script:abMonitor = $false
    }
    try {
        $Script:abControl = New-Object MSI.Afterburner.ControlMemory
    } catch {
        Write-Log "Failed to create MSI Afterburner Control object. Overclocking non-NVIDIA devices will not be available."
        $Script:abControl = $false
    }

    if ($Script:abControl) {
        $Script:abControlBackup = @($Script:abControl.GpuEntries | Select-Object Index,PowerLimitCur,ThermalLimitCur,CoreClockBoostCur,MemoryClockBoostCur)
    }
}

function Test-Afterburner {
    return $Script:abMonitor -and $Script:abControl
}

function Get-AfterburnerDevices ($Type) {
    if (-not $Script:abControl) {return}

    try {
        $Script:abControl.ReloadAll()
    } catch {        
        Write-Log -Level Warn "Failed to communicate with MSI Afterburner"
        return
    }

    if ($Type -in @('AMD', 'NVIDIA', 'INTEL')) {
        $Pattern = @{
            AMD    = "*Radeon*"
            NVIDIA = "*GeForce*"
            Intel  = "*Intel*"
        }
        @($Script:abMonitor.GpuEntries) | Where-Object Device -like $Pattern.$Type | ForEach-Object {
            $abIndex = $_.Index
            $Script:abMonitor.Entries | Where-Object {
                $_.GPU -eq $abIndex -and
                $_.SrcName -match "(GPU\d+ )?" -and
                $_.SrcName -notmatch "CPU"
            } | Format-Table
            @($Script:abControl.GpuEntries)[$abIndex]
        }
    } elseif ($Type -eq 'CPU') {
        $Script:abMonitor.Entries | Where-Object {
            $_.GPU -eq [uint32]"0xffffffff" -and
            $_.SrcName -match "CPU"
        } | Format-Table
    }
}

function Update-DeviceInformation {
    [cmdletbinding()]
    param(
        [Parameter(Mandatory = $false)]
        [String[]]$DeviceName = @(),
        [Parameter(Mandatory = $false)]
        [Bool]$UseAfterburner = $true        
    )
    
    $abReload = $true

    $Global:GlobalCachedDevices | Where-Object {$_.Type -eq "GPU" -and $DeviceName -icontains $_.Name} | Group-Object Vendor | Foreach-Object {
        $Devices = $_.Group
        $Vendor = $_.Name
        
        try { #AMD
            if ($UseAfterburner -and $Script:abMonitor -and $Vendor -eq "AMD") {
                if ($abReload) {
                    if ($Script:abMonitor) {$Script:abMonitor.ReloadAll()}
                    if ($Script:abControl) {$Script:abControl.ReloadAll()}
                    $abReload = $false
                }
                $DeviceId = 0
                $Pattern = @{
                    AMD    = '*Radeon*'
                    NVIDIA = '*GeForce*'
                    Intel  = '*Intel*'
                }
                @($Script:abMonitor.GpuEntries | Where-Object Device -like $Pattern.$Vendor) | ForEach-Object {
                    $CardData = $Script:abMonitor.Entries | Where-Object GPU -eq $_.Index
                    $AdapterId = $_.Index

                    $Devices | Where-Object {$_.Vendor -eq $Vendor -and $_.Type_Vendor_Index -eq $DeviceId} | Foreach-Object {
                        $_ | Add-Member Data ([PSCustomObject]@{
                                AdapterId         = [int]$AdapterId
                                Utilization       = [int]$($CardData | Where-Object SrcName -match "^(GPU\d* )?usage$").Data
                                UtilizationMem    = [int]$($mem = $CardData | Where-Object SrcName -match "^(GPU\d* )?memory usage$"; if ($mem.MaxLimit) {$mem.Data / $mem.MaxLimit * 100})
                                Clock             = [int]$($CardData | Where-Object SrcName -match "^(GPU\d* )?core clock$").Data
                                ClockMem          = [int]$($CardData | Where-Object SrcName -match "^(GPU\d* )?memory clock$").Data
                                FanSpeed          = [int]$($CardData | Where-Object SrcName -match "^(GPU\d* )?fan speed$").Data
                                Temperature       = [int]$($CardData | Where-Object SrcName -match "^(GPU\d* )?temperature$").Data
                                PowerDraw         = [int]$($CardData | Where-Object {$_.SrcName -match "^(GPU\d* )?power$" -and $_.SrcUnits -eq 'W'}).Data
                                PowerLimitPercent = [int]$($abControl.GpuEntries[$_.Index].PowerLimitCur)
                                #PCIBus            = [int]$($null = $_.GpuId -match "&BUS_(\d+)&"; $matches[1])
                            }) -Force
                    }
                    $DeviceId++
                }
            } else {

                if ($Vendor -eq 'AMD') {
                    #AMD
                    $DeviceId = 0
                    $Command = ".\Includes\OverdriveN.exe"
                    $AdlResult = & $Command | Where-Object {$_ -notlike "*&???" -and $_ -ne "ADL2_OverdriveN_Capabilities_Get is failed" -and $_ -ne "Failed to load ADL library"}
                    if (-not (Test-Path Variable:Script:AmdCardsTDP)) {$Script:AmdCardsTDP = Get-Content ".\Data\amd-cards-tdp.json" -Raw | ConvertFrom-Json}

                    if ($null -ne $AdlResult) {
                        $AdlResult | ForEach-Object {
                            [System.Collections.ArrayList]$AdlResultSplit = @('noid',0,1,0,0,100,0,0,'')
                            $i=0
                            foreach($v in @($_ -split ',')) {
                                if ($i -ge $AdlResultSplit.Count) {break}
                                if ($i -eq 0) {
                                    $AdlResultSplit[0] = $v
                                } elseif ($i -eq 8) {
                                    $AdlResultSplit[8] = $($v `
                                            -replace 'ASUS' `
                                            -replace 'AMD' `
                                            -replace '\(?TM\)?' `
                                            -replace 'Series' `
                                            -replace 'Graphics' `
                                            -replace "\s+", ' '
                                    ).Trim()

                                    $AdlResultSplit[8] = $AdlResultSplit[8] -replace '.*Radeon.*([4-5]\d0).*', 'Radeon RX $1'     # RX 400/500 series
                                    $AdlResultSplit[8] = $AdlResultSplit[8] -replace '.*\s(Vega).*(56|64).*', 'Radeon Vega $2'    # Vega series
                                    $AdlResultSplit[8] = $AdlResultSplit[8] -replace '.*\s(R\d)\s(\w+).*', 'Radeon $1 $2'         # R3/R5/R7/R9 series
                                    $AdlResultSplit[8] = $AdlResultSplit[8] -replace '.*\s(HD)\s?(\w+).*', 'Radeon HD $2'         # HD series
                                } elseif ($i -lt 8) {
                                    $v = $v -replace "[^\d\.]"
                                    if ($v -match "^(\d+|\.\d+|\d+\.\d+)$") {
                                        $ibak = $AdlResultSplit[$i]
                                        try {
                                            if ($i -eq 5 -or $i -eq 7){$AdlResultSplit[$i]=[double]$v}else{$AdlResultSplit[$i]=[int]$v}
                                        } catch {
                                            $AdlResultSplit[$i] = $ibak
                                        }
                                    }
                                }
                                $i++
                            }
                            if (-not $AdlResultSplit[2]) {$AdlResultSplit[1]=0;$AdlResultSplit[2]=1}
                            $Devices | Where-Object Type_Vendor_Index -eq $DeviceId | Foreach-Object {
                                $_ | Add-Member Data ([PSCustomObject]@{
                                        AdapterId         = $AdlResultSplit[0]
                                        FanSpeed          = [int]($AdlResultSplit[1] / $AdlResultSplit[2] * 100)
                                        Clock             = [int]($AdlResultSplit[3] / 100)
                                        ClockMem          = [int]($AdlResultSplit[4] / 100)
                                        Utilization       = [int]$AdlResultSplit[5]
                                        Temperature       = [int]$AdlResultSplit[6] / 1000
                                        PowerLimitPercent = 100 + [int]$AdlResultSplit[7]
                                        PowerDraw         = $Script:AmdCardsTDP."$(if ($AdlResultSplit[8]){$AdlResultSplit[8]}else{$_.Model_Name})" * ((100 + $AdlResultSplit[7]) / 100) * ($AdlResultSplit[5] / 100)                                
                                    }) -Force
                            }
                            $DeviceId++
                        }
                    }
                }
            }
        } catch {
            Write-Log -Level Warn "Could not read power data from AMD"
        }

        try { #NVIDIA        
            if ($Vendor -eq 'NVIDIA') {
                #NVIDIA
                $DeviceId = 0
                $Command = '.\includes\nvidia-smi.exe'
                $Arguments = @(
                    '--query-gpu=gpu_name,utilization.gpu,utilization.memory,temperature.gpu,power.draw,power.limit,fan.speed,pstate,clocks.current.graphics,clocks.current.memory,power.max_limit,power.default_limit'
                    '--format=csv,noheader'
                )
                if (-not (Test-Path Variable:Script:NvidiaCardsTDP)) {$Script:NvidiaCardsTDP = Get-Content ".\Data\nvidia-cards-tdp.json" -Raw | ConvertFrom-Json}
                & $Command $Arguments | ForEach-Object {
                    $SMIresultSplit = $_ -split ','
                    if ($SMIresultSplit.count -gt 10) {
                        for($i = 1; $i -lt $SMIresultSplit.count; $i++) {
                            $v = $SMIresultSplit[$i].Trim()
                            if ($v -match '(error|supported)') {$v = "-"}
                            elseif ($i -ne 7) {
                                $v = $v -replace "[^\d\.]"
                                if ($v -notmatch "^(\d+|\.\d+|\d+\.\d+)$") {$v = "-"}
                            }
                            $SMIresultSplit[$i] = $v                        
                        }
                        $Devices | Where-Object Type_Vendor_Index -eq $DeviceId | Foreach-Object {
                            $Data = [PSCustomObject]@{
                                Utilization       = if ($SMIresultSplit[1] -eq "-") {100} else {[int]$SMIresultSplit[1]} #If we dont have real Utilization, at least make the watchdog happy
                                UtilizationMem    = if ($SMIresultSplit[2] -eq "-") {$null} else {[int]$SMIresultSplit[2]}
                                Temperature       = if ($SMIresultSplit[3] -eq "-") {$null} else {[int]$SMIresultSplit[3]}
                                PowerDraw         = if ($SMIresultSplit[4] -eq "-") {$null} else {[int]$SMIresultSplit[4]}
                                PowerLimit        = if ($SMIresultSplit[5] -eq "-") {$null} else {[int]$SMIresultSplit[5]}
                                FanSpeed          = if ($SMIresultSplit[6] -eq "-") {$null} else {[int]$SMIresultSplit[6]}
                                Pstate            = $SMIresultSplit[7]
                                Clock             = if ($SMIresultSplit[8] -eq "-") {$null} else {[int]$SMIresultSplit[8]}
                                ClockMem          = if ($SMIresultSplit[9] -eq "-") {$null} else {[int]$SMIresultSplit[9]}
                                PowerMaxLimit     = if ($SMIresultSplit[10] -eq "-") {$null} else {[int]$SMIresultSplit[10]}
                                PowerDefaultLimit = if ($SMIresultSplit[11] -eq "-") {$null} else {[int]$SMIresultSplit[11]}
                            }
                            if ($Data.PowerDefaultLimit -gt 0) {$Data | Add-Member PowerLimitPercent ([math]::Floor(($Data.PowerLimit * 100) / $Data.PowerDefaultLimit))}
                            if (-not $Data.PowerDraw -and $Script:NvidiaCardsTDP."$($_.Model_Name)") {$Data.PowerDraw = $Script:NvidiaCardsTDP."$($_.Model_Name)" * ([double]$Data.PowerLimitPercent / 100) * ([double]$Data.Utilization / 100)}
                            $_ | Add-Member Data $Data -Force
                        }
                        $DeviceId++
                    }
                }
            }
        } catch {
            Write-Log -Level Warn "Could not read power data from NVIDIA"
        }
    }

    try { #CPU
        if (-not $DeviceName -or $DeviceName -like "CPU*") {
            $CPU_count = ($Global:GlobalCachedDevices | Where-Object {$_.Type -eq "CPU"} | Measure-Object).Count
            if ($CPU_count -gt 0) {$Global:GlobalGetDeviceCacheCIM = Get-CimInstance -ClassName CIM_Processor}
            $Global:GlobalCachedDevices | Where-Object {$_.Type -eq "CPU"} | Foreach-Object {
                $Device = $_
                $Global:GlobalGetDeviceCacheCIM | Where-Object {$_.DeviceID -eq $Device.CIM.DeviceID} | ForEach-Object {
                    if ($UseAfterburner -and $Script:abMonitor -and $CPU_count -eq 1) {
                        $CpuData = @{
                            Clock       = $($Script:abMonitor.Entries | Where-Object SrcName -match '^(CPU\d* )clock' | Measure-Object -Property Data -Maximum).Maximum
                            Utilization = $($Script:abMonitor.Entries | Where-Object SrcName -match '^(CPU\d* )usage'| Measure-Object -Property Data -Average).Average
                            PowerDraw   = $($Script:abMonitor.Entries | Where-Object SrcName -eq 'CPU power').Data
                            Temperature = $($Script:abMonitor.Entries | Where-Object SrcName -match "^(CPU\d* )temperature" | Measure-Object -Property Data -Maximum).Maximum
                        }
                    } else {
                        $CpuData = @{}
                    }
                
                    if (-not $CpuData.Utilization) {
                        $CpuData.Utilization = $_.LoadPercentage
                    }
                    if (-not $CpuData.PowerDraw) {
                        if (-not (Test-Path Variable:Script:CpuTDP)) {$Script:CpuTDP = Get-Content ".\Data\cpu-tdp.json" -Raw | ConvertFrom-Json}
                        if (-not ($CPU_tdp = $Script:CpuTDP.($_.Name.Trim()))) {$CPU_tdp = ($Script:CpuTDP.PSObject.Properties.Value | Measure-Object -Average).Average}                    
                        $CpuData.PowerDraw = $CPU_tdp * $CpuData.Utilization / 100
                    }
                    if (-not $CpuData.Clock) {$CpuData.Clock = $_.MaxClockSpeed}

                    $Device | Add-Member Data ([PSCustomObject]@{
                        Cores       = [int]$_.NumberOfCores
                        Threads     = [int]$_.NumberOfLogicalProcessors
                        CacheL3     = [int]($_.L3CacheSize / 1024)
                        Clock       = [int]$CpuData.Clock
                        Utilization = [int]$CpuData.Utilization
                        PowerDraw   = [int]$CpuData.PowerDraw
                        Temperature = [int]$CpuData.Temperature
                    }) -Force
                }
            }
        }
    } catch {
        Write-Log -Level Warn "Could not read power data from CPU"
    }
}

function Get-CoinName {
    [CmdletBinding()]
    param(
        [Parameter(
            Position = 0,   
            ParameterSetName = '',   
            ValueFromPipeline = $True,
            Mandatory = $false)]
        [String]$CoinName = ""
    )
    if ($CoinName -match "[,;]") {@($CoinName -split "\s*[,;]+\s*") | Foreach-Object {Get-CoinName $_}}
    else {
        ((Get-Culture).TextInfo.ToTitleCase($CoinName -replace "[^`$a-z0-9\s\-]+")).Trim()        
    }
}

function Get-Algorithm {
    [CmdletBinding()]
    param(
        [Parameter(
            Position = 0,   
            ParameterSetName = '',   
            ValueFromPipeline = $True,
            Mandatory = $false)]
        [String]$Algorithm = ""
    )
    if ($Algorithm -eq '*') {$Algorithm}
    elseif ($Algorithm -match "[,;]") {@($Algorithm -split "\s*[,;]+\s*") | Foreach-Object {Get-Algorithm $_}}
    else {
        if (-not (Test-Path Variable:Global:GlobalAlgorithms) -or (Get-ChildItem "Data\algorithms.json").LastWriteTime.ToUniversalTime() -gt $Global:GlobalAlgorithmsTimeStamp) {Get-Algorithms -Silent}
        $Algorithm = (Get-Culture).TextInfo.ToTitleCase(($Algorithm -replace "[^a-z0-9]+", " ")) -replace " "
        if ($Global:GlobalAlgorithms.ContainsKey($Algorithm)) {$Global:GlobalAlgorithms[$Algorithm]} else {$Algorithm}
    }
}

function Get-Region {
    [CmdletBinding()]
    param(
        [Parameter(
            Position = 0,   
            ParameterSetName = '',   
            ValueFromPipeline = $True,
            Mandatory = $false)]
        [String]$Region = ""
    )
    if (-not (Test-Path Variable:Global:GlobalRegions)) {Get-Regions -Silent}
    $Region = (Get-Culture).TextInfo.ToTitleCase(($Region -replace "-", " " -replace "_", " ")) -replace " "
    if ($Global:GlobalRegions.ContainsKey($Region)) {$Global:GlobalRegions[$Region]} else {foreach($r in @($Global:GlobalRegions.Keys)) {if ($Region -match "^$($r)") {$Global:GlobalRegions[$r];return}};$Region}
}

function Get-Algorithms {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [Switch]$Silent = $false
    )
    if (-not (Test-Path Variable:Global:GlobalAlgorithms) -or (Get-ChildItem "Data\algorithms.json").LastWriteTime.ToUniversalTime() -gt $Global:GlobalAlgorithmsTimeStamp) {
        [hashtable]$Global:GlobalAlgorithms = @{}
        (Get-Content "Data\algorithms.json" -Raw | ConvertFrom-Json).PSObject.Properties | %{$Global:GlobalAlgorithms[$_.Name]=$_.Value}
        $Global:GlobalAlgorithmsTimeStamp = (Get-ChildItem "Data\algorithms.json").LastWriteTime.ToUniversalTime()
    }
    if (-not $Silent) {$Global:GlobalAlgorithms.Keys}
}

function Get-Regions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [Switch]$Silent = $false
    )
    if (-not (Test-Path Variable:Global:GlobalRegions)) {
        [hashtable]$Global:GlobalRegions = @{}
        (Get-Content "Data\regions.json" -Raw | ConvertFrom-Json).PSObject.Properties | %{$Global:GlobalRegions[$_.Name]=$_.Value}
    }
    if (-not $Silent) {$Global:GlobalRegions.Keys}
}

enum MinerStatus {
    Running
    Idle
    Failed
}

class Miner {
    $Name
    $Path
    $Arguments
    $API
    $Port
    $Type
    [string[]]$Algorithm = @()
    [string[]]$BaseAlgorithm = @()
    $DeviceName
    $DeviceModel
    $Profit
    $Profit_Comparison
    $Profit_MarginOfError
    $Profit_Bias
    $Profit_Unbias
    $Profit_Cost
    $PowerDraw
    $Speed
    $Speed_Live
    $Best
    $Best_Comparison
    $New
    $Benchmarked
    $LogFile
    $Pool
    [Bool]$ShowMinerWindow = $false
    $MSIAprofile
    $OCprofile
    $DevFee
    $BaseName = $null
    $ExecName = $null
    $FaultTolerance = 0.1
    $ExtendInterval = 0
    $Penalty = 0
    $ManualUri
    [String]$EthPillEnable = "disable"
    hidden [System.Management.Automation.Job]$Process = $null
    hidden [TimeSpan]$Active = [TimeSpan]::Zero
    hidden [Int]$Activated = 0
    hidden [MinerStatus]$Status = [MinerStatus]::Idle
    hidden [Array]$Data = @()
    hidden [Bool]$HasOwnMinerWindow = $false
    hidden $EthPill = $null
    hidden [System.Collections.ArrayList]$OCprofileBackup = @()

    [String[]]GetProcessNames() {
        return @(([IO.FileInfo]($this.Path | Split-Path -Leaf -ErrorAction Ignore)).BaseName)
    }

    [String[]]GetExecNames() {
        return @($this.ExecName)
    }

    [String]GetArguments() {
        return $this.Arguments
    }

    [String]GetMinerDeviceName() {
        return "$($this.BaseName)-$(($this.DeviceName | Sort-Object) -join '-')"
    }

    hidden StartMining() {
        $this.StopMining();

        $this.Status = [MinerStatus]::Failed

        $this.New = $true
        $this.Activated++

        if (-not $this.Process) {
            if ($this.BaseAlgorithm -icontains "Ethash" -and $this.EthPillEnable -ne "disable") {
                $Prescription_Device = @(Get-Device $this.DeviceName) | Where-Object Model -in @("GTX1080","GTX1080Ti","TITANXP")
                $Prescription = ""
                switch ($this.EthPillEnable) {
                    "RevA" {$Prescription = "revA"}
                    "RevB" {$Prescription = "revB"}
                }
                if ($Prescription -ne "" -and $Prescription_Device) {
                    Write-Log "Starting OhGodAnETHlargementPill $($Prescription) on $($Prescription_Device.Name -join ',')"
                    $this.EthPill = Start-Process -FilePath ".\Includes\OhGodAnETHlargementPill-r2.exe" -passthru -Verb RunAs -ArgumentList "--$($Prescription) $($Prescription_Device.Type_Vendor_Index -join ',')"
                    Sleep -Milliseconds 250 #wait 1/4 second
                }
            }

            $this.LogFile = $Global:ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(".\Logs\$($this.Name)-$($this.Port)_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").txt")
            $this.Process = Start-SubProcess -FilePath $this.Path -ArgumentList $this.GetArguments() -LogPath $this.LogFile -WorkingDirectory (Split-Path $this.Path) -Priority ($this.DeviceName | ForEach-Object {if ($_ -like "CPU*") {-2}else {-1}} | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum) -ShowMinerWindow $this.ShowMinerWindow -ProcessName $this.ExecName
            $this.HasOwnMinerWindow = $this.ShowMinerWindow

            if ($this.Process | Get-Job -ErrorAction Ignore) {
                $this.Status = [MinerStatus]::Running
            }
        }
    }

    hidden StopMining() {
        $this.Status = [MinerStatus]::Failed

        $this.Data = @()

        if ($this.Process) {
            if ($this.HasOwnMinerWindow -and $this.Process.MiningProcess) {
                $this.Process.MiningProcess.CloseMainWindow() > $null
                # Wait up to 10 seconds for the miner to close gracefully
                $closedgracefully = $this.Process.MiningProcess.WaitForExit(10000)
                if($closedgracefully) { 
                    Write-Log "$($this.Type) miner $($this.Name) closed gracefully" 
                } else {
                    Write-Log -Level Warn "$($this.Type) miner $($this.Name) failed to close within 10 seconds"
                    if(!$this.Process.MiningProcess.HasExited) {
                        Write-Log -Level Warn "Attempting to kill $($this.Type) miner $($this.Name) PID $($this.Process.Id)"
                        $this.Process.MiningProcess.Kill()
                    }
                }
            }
            if ($this.Process | Get-Job -ErrorAction Ignore) {
                $this.Process | Remove-Job -Force
            }

            if (-not ($this.Process | Get-Job -ErrorAction Ignore)) {
                $this.Active = $this.GetActiveTime();
                $this.Process = $null
                $this.Status = [MinerStatus]::Idle
            }
            if ($this.EthPill -ne $null) {
                Write-Log "Stopping OhGodAnETHlargementPill"
                $this.EthPill.CloseMainWindow() > $null
                if(-not $this.EthPill.WaitForExit(1000)) {if(-not $this.EthPill.HasExited) {$this.EthPill.Kill()}}
                $this.EthPill = $null
                Sleep -Milliseconds 250 #Sleep for 1/4 second
            }
        }    
    }

    hidden StartMiningPreProcess() { }

    hidden StartMiningPostProcess() { }

    hidden StopMiningPreProcess() { }

    hidden StopMiningPostProcess() {
        Sleep -Milliseconds 500
        $this.ResetOCprofile() #reset all overclocking
        Sleep -Milliseconds 500
    }

    cleanup() { }

    [DateTime]GetActiveStart() {
        $Begin = if ($this.Process.MiningProcess) {$this.Process.MiningProcess.StartTime} else {$this.Process.PSBeginTime}

        if ($Begin) {
            return $Begin
        }
        else {
            return [DateTime]::MinValue
        }
    }

    [DateTime]GetActiveLast() {
        $Begin = if ($this.Process.MiningProcess) {$this.Process.MiningProcess.StartTime} else {$this.Process.PSBeginTime}
        $End   = if ($this.Process.MiningProcess) {$this.Process.MiningProcess.ExitTime} else {$this.Process.PSEndTime}

        if ($Begin -and $End) {
            return $End
        }
        elseif ($Begin) {
            return Get-Date
        }
        else {
            return [DateTime]::MinValue
        }
    }

    [TimeSpan]GetActiveTime() {
        $Begin = if ($this.Process.MiningProcess) {$this.Process.MiningProcess.StartTime} else {$this.Process.PSBeginTime}
        $End   = if ($this.Process.MiningProcess) {$this.Process.MiningProcess.ExitTime} else {$this.Process.PSEndTime}
        
        if ($Begin -and $End) {
            return $this.Active + ($End - $Begin)
        }
        elseif ($Begin) {
            return $this.Active + ((Get-Date) - $Begin)
        }
        else {
            return $this.Active
        }
    }

    [Int]GetActivateCount() {
        return $this.Activated
    }

    [MinerStatus]GetStatus() {
        if ((-not $this.Process.MiningProcess -and $this.Process.State -eq "Running") -or ($this.Process.MiningProcess -and -not $this.Process.MiningProcess.HasExited) ) {
            return [MinerStatus]::Running
        }
        elseif ($this.Status -eq [MinerStatus]::Running) {
            return [MinerStatus]::Failed
        }
        else {
            return $this.Status
        }
    }

    [Int]GetProcessId() {
        if ( $this.Process.MiningProcess ) {
            return $this.Process.MiningProcess.Id;
        } else {
            return 0;
        }
    }

    SetStatus([MinerStatus]$Status) {
        if ($Status -eq $this.GetStatus()) {return}

        switch ($Status) {
            Running {
                $this.StartMiningPreProcess()
                $this.StartMining()
                $this.StartMiningPostProcess()
            }
            Idle {
                $this.StopMiningPreProcess()
                $this.StopMining()
                $this.StopMiningPostProcess()
            }
            Default {
                $this.StopMiningPreProcess()
                $this.StopMining()
                $this.StopMiningPostProcess()
                $this.Status = [MinerStatus]$Status
            }
        }
    }

    [String[]]UpdateMinerData () {
        $Lines = @()

        if ($this.Process.HasMoreData) {
            $Date = (Get-Date).ToUniversalTime()

            $this.Process | Receive-Job | ForEach-Object {
                $Line = $_ -replace "`n|`r", ""
                $Line_Simple = $Line -replace "\x1B\[[0-?]*[ -/]*[@-~]", ""

                if ($Line_Simple) {
                    $HashRates = @()
                    $Devices = @()

                    if ($Line_Simple -match "/s") {
                        $Words = $Line_Simple -split " "

                        $Words -match "/s$" | ForEach-Object {
                            if (($Words | Select-Object -Index $Words.IndexOf($_)) -match "^((?:\d*\.)?\d+)(.*)$") {
                                $HashRate = ($matches | Select-Object -Index 1) -as [Decimal]
                                $HashRate_Unit = ($matches | Select-Object -Index 2)
                            }
                            else {
                                $HashRate = ($Words | Select-Object -Index ($Words.IndexOf($_) - 1)) -as [Decimal]
                                $HashRate_Unit = ($Words | Select-Object -Index $Words.IndexOf($_))
                            }

                            switch -wildcard ($HashRate_Unit) {
                                "kh/s*" {$HashRate *= 1E+3}
                                "mh/s*" {$HashRate *= 1E+6}
                                "gh/s*" {$HashRate *= 1E+9}
                                "th/s*" {$HashRate *= 1E+12}
                                "ph/s*" {$HashRate *= 1E+15}
                            }

                            $HashRates += $HashRate
                        }
                    }

                    if (($HashRates | Measure-Object -Sum).Sum -gt 0) {
                        if ($Line_Simple -match "\b(gpu|cpu|device)([^s]|\b)") {
                            $Words = $Line_Simple -replace "#", "" -replace ":", "" -split " "

                            $Words -match "^(gpu|cpu|device)([^s]|$)" | ForEach-Object {
                                if (($Words | Select-Object -Index $Words.IndexOf($_)) -match "^(.*)((?:\d*\.)?\d+)$") {
                                    $Device = ($matches | Select-Object -Index 2) -as [Int]
                                    $Device_Type = ($matches | Select-Object -Index 1)
                                }
                                else {
                                    $Device = ($Words | Select-Object -Index ($Words.IndexOf($_) + 1)) -as [Int]
                                    $Device_Type = ($Words | Select-Object -Index $Words.IndexOf($_))
                                }

                                $Devices += "{0}#{1:d2}" -f $Device_Type, $Device
                            }
                        }

                        $this.Data += [PSCustomObject]@{
                            Date = $Date
                            Raw = $Line_Simple
                            HashRate = [PSCustomObject]@{[String]$this.Algorithm = $HashRates} 
                            PowerDraw = Get-DevicePowerDraw -DeviceName $this.DeviceName                           
                            Device = $Devices
                        }
                    }

                    $Lines += $Line
                }
            }

            $this.Data = @($this.Data | Select-Object -Last 10000)
        }

        return $Lines
    }

    [Int64]GetHashRate([String]$Algorithm = [String]$this.Algorithm, [Int]$Seconds = 60, [Boolean]$Safe = $this.New) {
        $HashRates_Devices = @($this.Data | Where-Object Device | Select-Object -ExpandProperty Device -Unique)
        if (-not $HashRates_Devices) {$HashRates_Devices = @("Device")}

        $HashRates_Counts = @{}
        $HashRates_Averages = @{}
        $HashRates_Variances = @{}

        $this.Data | Where-Object HashRate | Where-Object Date -GE (Get-Date).ToUniversalTime().AddSeconds( - $Seconds) | ForEach-Object {
            $Data_Devices = $_.Device
            if (-not $Data_Devices) {$Data_Devices = $HashRates_Devices}

            $Data_HashRates = $_.HashRate.$Algorithm
            if (-not $Data_HashRates -and $Algorithm -match "-") {$Data_HashRates = $_.HashRate."$($Algorithm -replace '\-.*$')"}

            $Data_Devices | ForEach-Object {$HashRates_Counts.$_++}
            $Data_Devices | ForEach-Object {$HashRates_Averages.$_ += @(($Data_HashRates | Measure-Object -Sum | Select-Object -ExpandProperty Sum) / $Data_Devices.Count)}
            $HashRates_Variances."$($Data_Devices | ConvertTo-Json)" += @($Data_HashRates | Measure-Object -Sum | Select-Object -ExpandProperty Sum)
        }

        $HashRates_Count = $HashRates_Counts.Values | ForEach-Object {$_} | Measure-Object -Minimum | Select-Object -ExpandProperty Minimum
        $HashRates_Average = ($HashRates_Averages.Values | ForEach-Object {$_} | Measure-Object -Average | Select-Object -ExpandProperty Average) * $HashRates_Averages.Keys.Count
        $HashRates_Variance = $HashRates_Variances.Keys | ForEach-Object {$_} | ForEach-Object {$HashRates_Variances.$_ | Measure-Object -Average -Minimum -Maximum} | ForEach-Object {if ($_.Average) {($_.Maximum - $_.Minimum) / $_.Average}} | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum

        if ($Safe) {
            if ($HashRates_Count -lt 3 -or $HashRates_Variance -gt 0.05) {
                return 0
            }
            else {
                return $HashRates_Average * (1 + ($HashRates_Variance / 2))
            }
        }
        else {
            return $HashRates_Average
        }
    }

    [Int64]GetPowerDraw([Int]$Seconds = 60) {
        return ($this.Data | Where-Object PowerDraw | Where-Object Date -GE (Get-Date).ToUniversalTime().AddSeconds( - $Seconds) | Select-Object -ExpandProperty PowerDraw | Measure-Object -Average).Average
    }

    [bool]HasDevFees() {
        return $this.DevFee -and ($this.Algorithm.PSObject.Properties.Value | Measure-Object -Sum).Sum
    }

    [array]GetDevFees() {
        return @($this.HashRates.PSObject.Properties.Name | Foreach-Object {$this.DevFee.$_})
    }

    ResetOCprofile() {
        if ($this.OCprofile.Count -eq 0 -or $this.OCprofileBackup.Count -eq 0) {return}

        try {
            $Script:abMonitor.ReloadAll()
            $Script:abControl.ReloadAll()
        } catch {        
            Write-Log -Level Warn "Failed to communicate with MSI Afterburner"
            return
        }
        foreach($Profile in $this.OCprofileBackup) {foreach($Name in $Profile.Keys) {if ($Name -ne "Index") {$Script:abControl.GpuEntries[$Profile.Index].$Name = $Profile.$Name}}}
        $Script:abControl.CommitChanges()
        $this.OCprofileBackup.Clear()
        Write-Log "OC reset for $($this.BaseName)"
    }

    SetOCprofile($Config) {        
        if ($this.OCprofile.Count -eq 0 -or $this.DeviceModel -like 'CPU*') {return}

        [System.Collections.ArrayList]$applied = @()
        [System.Collections.ArrayList]$NvCmd = @()

        $this.OCprofileBackup.Clear()
        $Vendor = $Global:GlobalCachedDevices | Where-Object {@($this.OCprofile.PSObject.Properties.Name) -icontains $_.Model} | Select-Object -ExpandProperty Vendor -Unique

        if ($Vendor -ne "NVIDIA") {
            try {
                $Script:abMonitor.ReloadAll()
                $Script:abControl.ReloadAll()
            } catch {        
                Write-Log -Level Warn "Failed to communicate with MSI Afterburner"
                return
            }
        }

        $Pattern = @{
            AMD    = "*Radeon*"
            NVIDIA = "*GeForce*"
            Intel  = "*Intel*"
        }

        foreach ($DeviceModel in @($this.OCprofile.PSObject.Properties.Name)) {
            if ($Config.OCprofiles."$($this.OCprofile.$DeviceModel)" -ne $null) {
                $DeviceIds = @($Global:GlobalCachedDevices | Where-Object Model -eq $DeviceModel | Select-Object -ExpandProperty Type_Vendor_Index)
                $Profile = $Config.OCprofiles."$($this.OCprofile.$DeviceModel)"
                $Profile.CoreClockBoost   = $Profile.CoreClockBoost -replace '[^0-9\-]+'
                $Profile.MemoryClockBoost = $Profile.MemoryClockBoost -replace '[^0-9\-]+'
                $Profile.LockVoltagePoint = $Profile.LockVoltagePoint -replace '[^0-9]+'
                if (-not $Config.EnableOCVoltage) {$Profile.LockVoltagePoint = ''}

                $applied_any = $false

                if ($Vendor -eq "NVIDIA") {
                    foreach($DeviceId in $DeviceIds) {
                        if ($Profile.PowerLimit -gt 0) {$NvCmd.Add("-setPowerTarget:$($DeviceId),$([math]::max([math]::min($Profile.PowerLimit,200),20))") >$null;$applied_any=$true}
                        if ($Profile.ThermalLimit -gt 0) {$NvCmd.Add("-setTempTarget:$($DeviceId),0,$([math]::max([math]::min($Profile.ThermalLimit,95),50))") >$null;$applied_any=$true}
                        if ($Profile.LockVoltagePoint-match '^\-*[0-9]+$')  {$NvCmd.Add("-lockVoltagePoint:$($DeviceId),$([int]([Convert]::ToInt32($Profile.LockVoltagePoint)/12500)*12500)") >$null;$applied_any=$true}
                        if ($Profile.CoreClockBoost -match '^\-*[0-9]+$') {$NvCmd.Add("-setBaseClockOffset:$($DeviceId),0,$([Convert]::ToInt32($Profile.CoreClockBoost))") >$null;$applied_any=$true}
                        if ($Profile.MemoryClockBoost -match '^\-*[0-9]+$') {$NvCmd.Add("-setMemoryClockOffset:$($DeviceId),0,$([Convert]::ToInt32($Profile.MemoryClockBoost))") >$null;$applied_any=$true}
                    }
                } elseif ($Pattern.$Vendor -ne $null) {
                    $DeviceId = 0
                    $Script:abMonitor.GpuEntries | Where-Object Device -like $Pattern.$Vendor | Select-Object -ExpandProperty Index | Foreach-Object {
                        if ($DeviceId -in $DeviceIds) {
                            $GpuEntry = $Script:abControl.GpuEntries[$_]
                            $ProfileBackup = [hashtable]@{}
                            try {if (-not ($GpuEntry.PowerLimitMin -eq 0 -and $GpuEntry.PowerLimitMax -eq 0) -and $Profile.PowerLimit -gt 0) {$ProfileBackup.PowerLimitCur = $GpuEntry.PowerLimitCur;$Script:abControl.GpuEntries[$_].PowerLimitCur = [math]::max([math]::min($Profile.PowerLimit,$GpuEntry.PowerLimitMax),$GpuEntry.PowerLimitMin)}} catch {Write-Log -Level Warn $_.Exception.Message}
                            try {if (-not ($GpuEntry.ThermalLimitMin -eq 0 -and $GpuEntry.ThermalLimitMax -eq 0) -and $Profile.ThermalLimit -gt 0) {$ProfileBackup.ThermalLimitCur = $GpuEntry.ThermalLimitCur;$Script:abControl.GpuEntries[$_].ThermalLimitCur = [math]::max([math]::min($Profile.ThermalLimit,$GpuEntry.ThermalLimitMax),$GpuEntry.ThermalLimitMin)}} catch {Write-Log -Level Warn $_.Exception.Message}
                            try {if (-not ($GpuEntry.CoreClockBoostMin -eq 0 -and $GpuEntry.CoreClockBoostMax -eq 0) -and $Profile.CoreClockBoost -match '^\-*[0-9]+$') {$ProfileBackup.CoreClockBoostCur = $GpuEntry.CoreClockBoostCur;$Script:abControl.GpuEntries[$_].CoreClockBoostCur = [math]::max([math]::min([convert]::ToInt32($Profile.CoreClockBoost) * 1000,$GpuEntry.CoreClockBoostMax),$GpuEntry.CoreClockBoostMin)}} catch {Write-Log -Level Warn $_.Exception.Message}
                            try {if (-not ($GpuEntry.MemoryClockBoostMin -eq 0 -and $GpuEntry.MemoryClockBoostMax -eq 0) -and $Profile.MemoryClockBoost -match '^\-*[0-9]+$') {$ProfileBackup.MemoryClockBoostCur = $GpuEntry.MemoryClockBoostCur;$Script:abControl.GpuEntries[$_].MemoryClockBoostCur = [math]::max([math]::min([convert]::ToInt32($Profile.MemoryClockBoost) * 1000,$GpuEntry.MemoryClockBoostMax),$GpuEntry.MemoryClockBoostMin)}} catch {Write-Log -Level Warn $_.Exception.Message}
                            if ($Profile.LockVoltagePoint-match '^\-*[0-9]+$') {Write-Log -Level Warn "$DeviceModel does not support LockVoltagePoint overclocking"}
                            if ($ProfileBackup.Count) {$ProfileBackup.Index = $_;$this.OCprofileBackup.Add($ProfileBackup) > $null;$applied_any=$true}
                        }
                        $DeviceId++
                    }                 
                }
                if ($applied_any) {$applied.Add("OC set for $($this.BaseName)-$($DeviceModel)-$($this.BaseAlgorithm -join '-'): PL=$(if ($Profile.PowerLimit) {"$($Profile.PowerLimit)%"} else {"-"}), TL=$(if ($Profile.ThermalLimit) {"$($Profile.ThermalLimit)°C"} else {"-"}), MEM=$(if ($Profile.MemoryClockBoost -ne '') {"$($Profile.MemoryClockBoost)"} else {"-"}), CORE=$(if ($Profile.CoreClockBoost -ne '') {"$($Profile.CoreClockBoost)"} else {"-"}), LVP=$(if ($Profile.LockVoltagePoint -ne '') {"$($Profile.LockVoltagePoint)µV"} else {"-"})") > $null}
            }
        }

        if ($applied.Count) {
            if ($Vendor -eq "NVIDIA") {& ".\Includes\NvidiaInspector\nvidiaInspector.exe" $NvCmd} else {$Script:abControl.CommitChanges()}
            $applied.GetEnumerator() | Foreach-Object {Write-Log $_}
        }
    }
}

function Get-GPUVendorList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $False)]
        [Array]$Type = @() #AMD/NVIDIA
    )
    if (-not $Type.Count) {$Type = "AMD","NVIDIA"}
    $Type | Foreach-Object {if ($_ -like "*AMD*" -or $_ -like "*Advanced Micro*"){"AMD","Advanced Micro Devices","Advanced Micro Devices, Inc."}elseif($_ -like "*NVIDIA*" ){"NVIDIA","NVIDIA Corporation"}elseif($_ -like "*INTEL*"){"INTEL","Intel(R) Corporation","GenuineIntel"}else{$_}} | Select-Object -Unique
}

function Get-GPUplatformID {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$Type = "" #AMD/NVIDIA
    )
    $Types = Get-GPUVendorList $Type
    $IxFound = -1
    $Ix = -1
    [OpenCl.Platform]::GetPlatformIDs() | ForEach-Object {$Ix++; if ((Compare-Object $_.Vendor $Types -IncludeEqual -ExcludeDifferent | Measure-Object).Count -gt 0) {$IxFound = $Ix}}
    $IxFound
}

function Select-Device {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $False)]
        [Array]$Devices = @(),
        [Parameter(Mandatory = $False)]
        [Array]$Type = @(), #CPU/AMD/NVIDIA
        [Parameter(Mandatory = $False)]
        [Long]$MinMemSize = 0
    )
    $Devices | Where-Object {($_.Type -eq "CPU" -and $Type -contains "CPU") -or ($_.Type -eq "GPU" -and $_.OpenCL.GlobalMemsize -ge $MinMemSize -and $Type -icontains $_.Vendor)}
}

function Get-DeviceModelName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [PSCustomObject]$Device,
        [Parameter(Mandatory = $False)]
        [Array]$Name = @(),
        [Parameter(Mandatory = $False)]
        [Switch]$Short
    )
    $Device | Where-Object {$Name.Count -eq 0 -or $Name -icontains $_.Name} | Select-Object -ExpandProperty Model_Name -Unique | Foreach-Object {if ($Short){($_ -replace "geforce|radeon|intel|\(r\)","").Trim()}else {$_}}
}

function Get-GPUIDs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [PSCustomObject[]]$Devices,
        [Parameter(Mandatory = $False)]
        [Int]$Offset = 0,
        [Parameter(Mandatory = $False)]
        [Switch]$ToHex = $False,
        [Parameter(Mandatory = $False)]
        [String]$Join
    )
    $GPUIDs = $Devices | Select -ExpandProperty Type_PlatformId_Index -ErrorAction Ignore | Foreach-Object {if ($ToHex) {[Convert]::ToString($_ + $Offset,16)} else {$_ + $Offset}}
    if ($PSBoundParameters.ContainsKey("Join")) {$GPUIDs -join $Join} else {$GPUIDs}    
}

function Test-GPU {
    #$VideoCardsAvail = Get-GPUs
    $GPUfail = 0
    #Get-GPUobjects | Foreach-Object { if ( $VideoCardsAvail.DeviceID -notcontains $_.DeviceID ) { $GPUfail++ } }
    if ($GPUfail -ge 1) {
        Write-Log -Level Error "$($GPUfail) failing GPU(s)! PC will reboot in 5 seconds"
        Start-Sleep 5
        $reboot = @("-r", "-f", "-t", 0)
        & shutdown $reboot        
    }
}

function Test-TimeSync {

    try {
        if ((Get-Service -Name W32Time).Status -ne 'Running')
        {
            Get-CimInstance -ClassName Win32_Service | Where-Object { $_.Name -eq "W32Time" -and $_.Status -ne "Running" } | Set-Service -StartupType Manual -Status Running
            Write-Log 'Start service W32Time (Windows Time)'
        }
    }
    catch {
        Write-Log -Level Warn "[Test-TimeSync] W32Time Service is not running and could not be started!"
        return
    }


    try {
        $configuredNtpServerNameRegistryPolicy = $null
        if (Test-Path -Path HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters -PathType Container)
        {
            $configuredNtpServerNameRegistryPolicy = Get-ItemProperty `
                -Path HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters `
                -Name 'NtpServer' -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty NtpServer
        }

        if ($configuredNtpServerNameRegistryPolicy)
        {
            # Policy override
            $ConfiguredNTPServerNameRaw = $configuredNtpServerNameRegistryPolicy.Trim()
        }
        else
        {
            # Exception if not exists
            $ConfiguredNTPServerNameRaw = ((Get-ItemProperty `
                -Path HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters -Name 'NtpServer').NtpServer).Trim()
        }

        if ($ConfiguredNTPServerNameRaw)
        {
            $ConfiguredNTPServerNames = $ConfiguredNTPServerNameRaw.Split(' ') -replace ',.+$'
        }
        else {
            $ConfiguredNTPServerNames = @("pool.ntp.org","time.windows.com")
        }
    }
    catch {
        Write-Log -Level Warn "[Test-TimeSync] No configured nameservers found in registry"
        return
    }


    try {
        if ( (w32tm /stripchart /computer:$($ConfiguredNTPServerNames[0]) /dataonly /samples:1 | Select-Object -Last 1 | Out-String).Split(",")[1] -match '([\d\.\-\+]+)' ) {
            $b = [double]$matches[1]
            if ( $b*$b -gt 4.0 ) {
                Write-Log -Level Warn "[Test-TimeSync] Time is out of sync by $($b.ToString('f3'))s! $((get-date).ToString('HH:mm:ss')) - syncing now with $($ConfiguredNTPServerNames[0])"
                $s = w32tm /resync /update | Select-Object -Last 1 | Out-String                
                Write-Log "[Test-TimeSync] $($s)"
            }
        } else {
            Write-Log -Level Warn "[Test-TimeSync] Could not read w32tm statistics from $($w32tmSource)"
        }
    }
    catch { 
        Write-Log -Level Warn "[Test-TimeSync] Something went wrong"
    }

}

function Get-Yes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        $Argument
    )
    if ($Argument -is [bool]) {$Argument} else {[Bool](0,$false,"no","n","not","niet","non","nein","never","0" -inotcontains $Argument)}
}

function Read-HostString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$Prompt,
        [Parameter(Mandatory = $False)]
        [String]$Default = '',
        [Parameter(Mandatory = $False)]
        [Switch]$Mandatory = $False,
        [Parameter(Mandatory = $False)]
        [String]$Characters = "A-Z0-9",
        [Parameter(Mandatory = $False)]
        [Array]$Valid = @(),
        [Parameter(Mandatory = $False)]
        [Int]$MinLength = 0,
        [Parameter(Mandatory = $False)]
        [Int]$MaxLength = 0,
        [Parameter(Mandatory = $False)]
        [Int]$Length = 0
    )
    if ($Valid.Count -eq 1 -and $Valid[0] -match "[,;:]") {[Array]$Valid = [regex]::split($Valid[0].Trim(),"\s*[,;:]+\s*")}
    do{
        $Repeat = $false
        $Result = if (([String]$Result=(Read-Host "$($Prompt)$(if ($Default){" [default=$($Default)]"})$(if ($Mandatory){"*"})").Trim()) -eq ''){$Default}else{$Result.Trim()}
        if ("exit","cancel","back","<" -icontains $Result){$Result;return}
        if ("del","delete","dele","clr","cls","clear","cl" -icontains $Result){$Result=''}                
        if ("help","list" -icontains $Result) {
            if ($Valid.Count -gt 0) {Write-Host "Valid inputs are from the following list:";Write-Host $($Valid -join ",");Write-Host " "}
            else {Write-Host "Every input will be valid. So, take care :)";Write-Host " "}
            $Repeat = $true
        }
        else {
            if ($Characters -ne $null -and $Characters -ne $false -and $Characters.Length) {[String]$Result = $Result -replace "[^$($Characters)]+",""}
            if ($Mandatory -or $Result.Length -gt 0) {
                if ($Length -gt 0 -and $Result.Length -ne $Length) {Write-Host "The input must be exactly $($Length) characters long";Write-Host " ";$Repeat = $true}
                if ($MinLength -gt 0 -and $Result.Length -lt $MinLength) {Write-Host "The input is shorter than the minimum of $($MinLength) characters";Write-Host " ";$Repeat = $true}
                if ($MaxLength -gt 0 -and $Result.Length -gt $MaxLength) {Write-Host "The input is longer than the maximum of $($MaxLength) characters";Write-Host " ";$Repeat = $true}
                if ($Valid.Count -gt 0) {
                    if ($Valid -inotcontains $Result) {
                        Write-Host "Invalid input (type `"list`" to show all valid)";
                        Write-Host " ";
                        $Repeat = $true
                    } else {
                        [String]$Result = Compare-Object $Valid @($Result) -IncludeEqual -ExcludeDifferent | Select-Object -ExpandProperty InputObject | Select-Object -Index 0
                    }
                }
            }
        }
    } until (-not $Repeat -and ($Result.Length -gt 0 -or -not $Mandatory))
    $Result
}

function Read-HostDouble {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$Prompt,
        [Parameter(Mandatory = $False)]
        $Default = $null,
        [Parameter(Mandatory = $False)]
        [Switch]$Mandatory = $False,
        [Parameter(Mandatory = $False)]
        $Min = $null,
        [Parameter(Mandatory = $False)]
        $Max = $null
    )        
    do{
        $Repeat = $false
        $Result = if (([String]$Result=(Read-Host "$($Prompt)$(if ($Default -ne $null){" [default=$($Default)]"})$(if ($Mandatory){"*"})").Trim()) -eq ''){$Default}else{$Result.Trim()}
        if ("exit","cancel","back","<" -icontains $Result){$Result;return}
        [Double]$Result = $Result -replace "[^0-9\.,\-]","" -replace ",","."
        if ($Mandatory -or $Result) {            
            if ($Min -ne $null -and $Result -lt $Min) {Write-Host "The input is lower than the minimum of $($Min)";Write-Host " ";$Repeat = $true}
            if ($Max -ne $null -and $Result -gt $Max) {Write-Host "The input is higher than the maximum of $($Max)";Write-Host " ";$Repeat = $true}
        }
    } until (-not $Repeat -and ($Result -or -not $Mandatory))
    $Result
}

function Read-HostInt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$Prompt,
        [Parameter(Mandatory = $False)]
        $Default = $null,
        [Parameter(Mandatory = $False)]
        [Switch]$Mandatory = $False,
        [Parameter(Mandatory = $False)]
        $Min = $null,
        [Parameter(Mandatory = $False)]
        $Max = $null
    )    
    do{
        $Repeat = $false
        $Result = if (([String]$Result=(Read-Host "$($Prompt)$(if ($Default -ne $null){" [default=$($Default)]"})$(if ($Mandatory){"*"})").Trim()) -eq ''){$Default}else{$Result.Trim()}
        if ("exit","cancel","back","<" -icontains $Result){$Result;return}
        [Int]$Result = $Result -replace "[^0-9\-]",""
        if ($Mandatory -or $Result) {            
            if ($Min -ne $null -and $Result -lt $Min) {Write-Host "The input is lower than the minimum of $($Min)";Write-Host " ";$Repeat = $true}
            if ($Max -ne $null -and $Result -gt $Max) {Write-Host "The input is higher than the maximum of $($Max)";Write-Host " ";$Repeat = $true}
        }
    } until (-not $Repeat -and ($Result -or -not $Mandatory))
    $Result
}

function Read-HostArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$Prompt,
        [Parameter(Mandatory = $False)]
        [Array]$Default = @(),
        [Parameter(Mandatory = $False)]
        [Switch]$Mandatory = $False,
        [Parameter(Mandatory = $False)]
        [String]$Characters = "A-Z0-9",
        [Parameter(Mandatory = $False)]
        [Array]$Valid = @(),
        [Parameter(Mandatory = $False)]
        [Switch]$AllowDuplicates = $False
    )
    if ($Default.Count -eq 1 -and $Default[0] -match "[,;:]") {[Array]$Default = [regex]::split($Default[0].Trim(),"\s*[,;:]+\s*")}
    if ($Valid.Count -eq 1 -and $Valid[0] -match "[,;:]") {[Array]$Valid = [regex]::split($Valid[0].Trim(),"\s*[,;:]+\s*")}
    do{
        $Repeat = $false
        $Result = if (([String]$Result=(Read-Host "$($Prompt)$(if ($Default){" [default=$($Default -join ",")]"})$(if ($Mandatory){"*"})").Trim()) -eq ''){$Default -join ","}else{$Result.Trim()}
        if ("exit","cancel","back","<" -icontains $Result){$Result;return}
        if ("del","delete","dele","clr","cls","clear","cl" -icontains $Result){$Result=''}        
        if ("help","list" -icontains $Result) {
            if ($Valid.Count -gt 0) {Write-Host "Valid inputs are from the following list:";Write-Host $($Valid -join ",")}
            else {Write-Host "Every input will be valid. So, take care :)";Write-Host " "}
            $Repeat = $true
        } else {
            $Mode = "v";
            if ($Result -match "^([\-\+])(.+)$") {
                $Mode = $Matches[1]
                $Result = $Matches[2]
            }
            if ($Characters -eq $null -or $Characters -eq $false) {[String]$Characters=''}
            [Array]$Result = $Result -replace "[^$($Characters),;:]+","" -split "\s*[,;:]+\s*"
            Switch ($Mode) {
                "+" {$Result = @($Default | Select-Object) + @($Result | Select-Object); break}
                "-" {$Result = @($Default | Where-Object {$Result -inotcontains $_}); break}
            }
            if (-not $AllowDuplicates) {$Result = $Result | Select-Object -Unique}
            if ($Valid.Count -gt 0) {
                if ($Invalid = Compare-Object @($Result | Select-Object -Unique) @($Valid | Select-Object -Unique) | Where-Object SideIndicator -eq "<=" | Select-Object -ExpandProperty InputObject) {
                    Write-Host "The following entries are invalid (type `"list`" to show all valid):"
                    Write-Host $($Invalid -join ",")
                    Write-Host " "
                    $Repeat = $true
                }
            }
        }
    } until (-not $Repeat -and ($Result.Count -gt 0 -or -not $Mandatory))
    $Result
}

function Read-HostBool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$Prompt,
        [Parameter(Mandatory = $False)]
        $Default = $false
    )
    $Default = if (Get-Yes $Default){"yes"}else{"no"}
    $Result = if (([String]$Result=(Read-Host "$($Prompt) (yes/no) [default=$($Default)]").Trim()) -eq ''){$Default}else{$Result.Trim()}
    if ("exit","cancel","back","<" -icontains $Result){$Result;return}
    Get-Yes $Result
}

function Read-HostKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$Prompt
    )    
    if ($psISE)
    {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("$Prompt")
    }
    else
    {
        Write-Host "$Prompt" -ForegroundColor Yellow
        [void]($Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown'))
    }
}

function Get-ContentDataMD5hash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $False)]
        $Data
    )
    if ($Data -eq $null) {$Data = ''}
    Get-MD5Hash ($Data | ConvertTo-Json -Compress)
}

function Set-ContentJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$PathToFile,
        [Parameter(Mandatory = $True)]
        $Data,
        [Parameter(Mandatory = $False)]
        $MD5hash = ''
    )
    $retry = 3
    do {
        try {
            if (Test-Path $PathToFile) {[io.file]::OpenWrite($PathToFile).close()}
            if ($MD5hash -eq '' -or ($MD5hash -ne (Get-ContentDataMD5hash($Data)))) {
                $Data | ConvertTo-Json | Set-Content $PathToFile -Encoding utf8
            } else {
                Write-Log -Level Verbose "No changes in $PathToFile"
            }
            return $true
        } catch { }
        $retry--
        Sleep -Seconds 1
    } until ($retry -le 0)
    Write-Log -Level Warn "Unable to write to file $PathToFile"
    return $false
}

function Set-MinersConfigDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$PathToFile,
        [Parameter(Mandatory = $False)]
        [Switch]$Force = $false,
        [Parameter(Mandatory = $False)]
        [Switch]$UseDefaultParams = $false
    )
    $PathToFileCpu = "$(([IO.FileInfo]$PathToFile).DirectoryName)\cpu.$(([IO.FileInfo]$PathToFile).Name)"
    if ($Force -or -not (Test-Path $PathToFile) -or (Get-ChildItem $PathToFile).LastWriteTime.ToUniversalTime() -lt (Get-ChildItem ".\Data\MinersConfigDefault.ps1").LastWriteTime.ToUniversalTime()) {
        try {
            $Algo = [hashtable]@{}
            $Done = [PSCustomObject]@{}
            $ChangeTag = $null
            if (Test-Path $PathToFile) {
                $PresetTmp = Get-Content $PathToFile -Raw | ConvertFrom-Json
                $ChangeTag = Get-ContentDataMD5hash($PresetTmp)
                #cleanup duplicates in algorithm lists
                $Preset = [PSCustomObject]@{}
                foreach($Name in @($PresetTmp.PSObject.Properties.Name)) {
                    if (Get-Member -inputobject $Preset -name $Name -Membertype Properties) {continue}
                    $Preset | Add-Member $Name @(
                        [System.Collections.ArrayList]$MinerCheck = @()
                        foreach($cmd in $PresetTmp.$Name) {
                            $m = $(if (-not $Algo[$cmd.MainAlgorithm]) {$Algo[$cmd.MainAlgorithm]=Get-Algorithm $cmd.MainAlgorithm};$Algo[$cmd.MainAlgorithm])
                            $s = $(if ($cmd.SecondaryAlgorithm) {if (-not $Algo[$cmd.SecondaryAlgorithm]) {$Algo[$cmd.SecondaryAlgorithm]=Get-Algorithm $cmd.SecondaryAlgorithm};$Algo[$cmd.SecondaryAlgorithm]}else{""})
                            $k = "$m-$s"
                            if (-not $MinerCheck.Contains($k)) {$cmd.MainAlgorithm=$m;$cmd.SecondaryAlgorithm=$s;$cmd;$MinerCheck.Add($k)>$null}
                        }) -Force
                }
            }
            if ($Preset -is [string] -or -not $Preset.PSObject.Properties.Name) {$Preset = $null}
            if (-not (Test-Path ".\nopresets.txt")) {$Setup = Get-ChildItemContent ".\Data\MinersConfigDefault.ps1" | Select-Object -ExpandProperty Content}
            $AllDevices = Get-Device "cpu","gpu"
            $AllMiners = if (Test-Path "Miners") {@(Get-ChildItemContent "Miners" -Parameters @{Pools = @{}; Stats = @{}; Config = @{InfoOnly=$true}; Devices = @{}} | Select-Object -ExpandProperty Content)}
            foreach ($a in @("CPU","NVIDIA","AMD")) {
                if ($a -eq "CPU") {[System.Collections.ArrayList]$SetupDevices = @("CPU")}
                else {
                    $Devices = @($AllDevices | Where-Object {$_.Vendor -eq $a} | Select-Object Model,Model_Name,Name)
                    [System.Collections.ArrayList]$SetupDevices = @($Devices | Select-Object -ExpandProperty Model -Unique)
                    if ($SetupDevices.Count -gt 1) {Get-DeviceSubsets $Devices | Foreach-Object {$SetupDevices.Add($_.Model -join '-') > $null}}
                }
                
                [System.Collections.ArrayList]$Miners = @($AllMiners | Where-Object Type -icontains $a)
                [System.Collections.ArrayList]$MinerNames = @($Miners | Select-Object -ExpandProperty Name -Unique)                
                foreach ($Miner in $Miners) {
                    foreach ($SetupDevice in $SetupDevices) {                        
                        $Done | Add-Member "$($Miner.Name)-$($SetupDevice)" @(
                            [System.Collections.ArrayList]$MinerCheck = @()
                            foreach($cmd in $Miner.Commands) {
                                $m = $(if (-not $Algo[$cmd.MainAlgorithm]) {$Algo[$cmd.MainAlgorithm]=Get-Algorithm $cmd.MainAlgorithm};$Algo[$cmd.MainAlgorithm])
                                $s = $(if ($cmd.SecondaryAlgorithm) {if (-not $Algo[$cmd.SecondaryAlgorithm]) {$Algo[$cmd.SecondaryAlgorithm]=Get-Algorithm $cmd.SecondaryAlgorithm};$Algo[$cmd.SecondaryAlgorithm]}else{""})
                                $k = "$m-$s"                                
                                if (-not $MinerCheck.Contains($k)) {[PSCustomObject]@{MainAlgorithm=$m;SecondaryAlgorithm=$s;Params = "";MSIAprofile = "";OCprofile = ""};$MinerCheck.Add($k)>$null}
                            }
                        )
                    }
                }

                if ($Setup) {
                    foreach ($Name in @($Setup.PSObject.Properties.Name)) {
                        if ($MinerNames.Contains($Name)) {
                            [System.Collections.ArrayList]$Value = @(foreach ($v in $Setup.$Name) {if (-not $UseDefaultParams) {$v.Params = ''};if ($v.MainAlgorithm -ne '*') {$v.MainAlgorithm=$(if (-not $Algo[$v.MainAlgorithm]) {$Algo[$v.MainAlgorithm]=Get-Algorithm $v.MainAlgorithm};$Algo[$v.MainAlgorithm]);$v.SecondaryAlgorithm=$(if ($v.SecondaryAlgorithm) {if (-not $Algo[$v.SecondaryAlgorithm]) {$Algo[$v.SecondaryAlgorithm]=Get-Algorithm $v.SecondaryAlgorithm};$Algo[$v.SecondaryAlgorithm]}else{""})};$v})
                            foreach ($SetupDevice in $SetupDevices) {
                                $NameKey = "$($Name)-$($SetupDevice)"
                                [System.Collections.ArrayList]$ValueTmp = $Value.Clone()
                                if (Get-Member -inputobject $Done -name $NameKey -Membertype Properties) {
                                    [System.Collections.ArrayList]$NewValues = @(Compare-Object @($Done.$NameKey) @($Setup.$Name) -Property MainAlgorithm,SecondaryAlgorithm | Where-Object SideIndicator -eq '<=' | Foreach-Object {$m=$_.MainAlgorithm;$s=$_.SecondaryAlgorithm;$Done.$NameKey | Where-Object {$_.MainAlgorithm -eq $m -and $_.SecondaryAlgorithm -eq $s}} | Select-Object)
                                    if ($NewValues.count) {$ValueTmp.AddRange($NewValues) > $null}
                                    $Done | Add-Member $NameKey $ValueTmp -Force
                                }
                            }
                        }
                    }
                }
            }

            if ($Preset) {
                foreach ($Name in @($Preset.PSObject.Properties.Name)) {
                    [System.Collections.ArrayList]$Value = @(foreach ($v in $Preset.$Name) {if ($v.MainAlgorithm -ne '*') {$v.MainAlgorithm=$(if (-not $Algo[$v.MainAlgorithm]) {$Algo[$v.MainAlgorithm]=Get-Algorithm $v.MainAlgorithm};$Algo[$v.MainAlgorithm]);$v.SecondaryAlgorithm=$(if ($v.SecondaryAlgorithm) {if (-not $Algo[$v.SecondaryAlgorithm]) {$Algo[$v.SecondaryAlgorithm]=Get-Algorithm $v.SecondaryAlgorithm};$Algo[$v.SecondaryAlgorithm]}else{""})};$v})
                    if (Get-Member -inputobject $Done -name $Name -Membertype Properties) {
                        [System.Collections.ArrayList]$NewValues = @(Compare-Object $Done.$Name $Preset.$Name -Property MainAlgorithm,SecondaryAlgorithm | Where-Object SideIndicator -eq '<=' | Foreach-Object {$m=$_.MainAlgorithm;$s=$_.SecondaryAlgorithm;$Done.$Name | Where-Object {$_.MainAlgorithm -eq $m -and $_.SecondaryAlgorithm -eq $s}} | Select-Object)
                        if ($NewValues.Count) {$Value.AddRange($NewValues) > $null}
                    }
                    $Done | Add-Member $Name $Value.ToArray() -Force
                }
            }

            $DoneSave = [PSCustomObject]@{}
            $Done.PSObject.Properties.Name | Sort-Object | Foreach-Object {if ($Done.$_.Count) {$DoneSave | Add-Member $_ @($Done.$_ | Sort-Object MainAlgorithm,SecondaryAlgorithm)}}
            Set-ContentJson -PathToFile $PathToFile -Data $DoneSave -MD5hash $ChangeTag > $null
        }
        catch{
            Write-Log -Level Error "Could not create $($PathToFile): $($_.Exception.Message) "
        }
    }
}

function Set-DevicesConfigDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$PathToFile,
        [Parameter(Mandatory = $False)]
        [Switch]$Force = $false
    )
    if ($Force -or -not (Test-Path $PathToFile) -or (Get-ChildItem $PathToFile).LastWriteTime.ToUniversalTime() -lt (Get-ChildItem ".\Data\DevicesConfigDefault.ps1").LastWriteTime.ToUniversalTime()) {
        try {
            if (Test-Path $PathToFile) {$Preset = Get-Content $PathToFile -Raw | ConvertFrom-Json}
            if ($Preset -is [string] -or -not $Preset.PSObject.Properties.Name) {$Preset = [PSCustomObject]@{}}
            $ChangeTag = Get-ContentDataMD5hash($Preset)
            $SetupNames = @("Algorithm","ExcludeAlgorithm","MinerName","ExcludeMinerName","DisableDualMining","DefaultOCprofile")
            $Setup = Get-ChildItemContent ".\Data\DevicesConfigDefault.ps1" | Select-Object -ExpandProperty Content
            $AllDevices = Get-Device "cpu","nvidia","amd" | Select-Object -ExpandProperty Model -Unique
            foreach ($DeviceModel in $AllDevices) {
                if (-not $Preset.$DeviceModel) {
                    if ($Setup.$DeviceModel) {
                        $Preset | Add-Member $DeviceModel $Setup.$DeviceModel
                    } else {
                        $Preset | Add-Member $DeviceModel ([PSCustomObject]@{Algorithm="";ExcludeAlgorithm="";MinerName="";ExcludeMinerName="";DisableDualMining="";DefaultOCprofile=""})
                    }
                }
                foreach($SetupName in $SetupNames) {if ($Preset.$DeviceModel.$SetupName -eq $null){$Preset.$DeviceModel | Add-Member $SetupName "" -Force}}
            }
            Set-ContentJson -PathToFile $PathToFile -Data $Preset -MD5hash $ChangeTag > $null
        }
        catch{
            Write-Log -Level Error "Could not create $($PathToFile) "
        }
    }
}


function Set-PoolsConfigDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$PathToFile,
        [Parameter(Mandatory = $False)]
        [Switch]$Force = $false
    )
    if ($Force -or -not (Test-Path $PathToFile) -or (Get-ChildItem $PathToFile).LastWriteTime.ToUniversalTime() -lt (Get-ChildItem ".\Data\PoolsConfigDefault.ps1").LastWriteTime.ToUniversalTime()) {
        try {
            if (Test-Path $PathToFile) {$Preset = Get-Content $PathToFile -Raw | ConvertFrom-Json}
            if ($Preset -is [string] -or -not $Preset.PSObject.Properties.Name) {$Preset = $null}
            $ChangeTag = Get-ContentDataMD5hash($Preset)
            $Done = [PSCustomObject]@{}
            $Setup = Get-ChildItemContent ".\Data\PoolsConfigDefault.ps1" | Select-Object -ExpandProperty Content
            $Pools = @(Get-ChildItem ".\Pools\*.ps1" -ErrorAction Ignore | Select-Object -ExpandProperty BaseName)
            if ($Pools.Count -gt 0) {
                $Pools | Foreach-Object {        
                    if ($Preset -and $Preset.PSObject.Properties.Name -icontains $_) {
                        $Setup_Content = $Preset.$_
                    } else {
                        $Setup_Content = [PSCustomObject]@{}
                        $Setup_Currencies = @("BTC")
                        if ($Setup.$_) {
                            if ($Setup.$_.Fields) {$Setup_Content = $Setup.$_.Fields}
                            $Setup_Currencies = @($Setup.$_.Currencies)            
                        }
                        $Setup_Currencies | Foreach-Object {$Setup_Content | Add-Member $_ "$(if ($_ -eq "BTC"){"`$Wallet"})" -Force}
                    }
                    if ($Setup_Content.PSObject.Properties.Name -inotcontains "Worker") {$Setup_Content | Add-Member Worker "`$WorkerName" -Force}
                    if ($Setup_Content.PSObject.Properties.Name -inotcontains "Penalty") {$Setup_Content | Add-Member Penalty 0 -Force}
                    if ($Setup_Content.PSObject.Properties.Name -inotcontains "Algorithm") {$Setup_Content | Add-Member Algorithm "" -Force}
                    if ($Setup_Content.PSObject.Properties.Name -inotcontains "ExcludeAlgorithm") {$Setup_Content | Add-Member ExcludeAlgorithm "" -Force}            
                    if ($Setup_Content.PSObject.Properties.Name -inotcontains "CoinName") {$Setup_Content | Add-Member CoinName "" -Force}
                    if ($Setup_Content.PSObject.Properties.Name -inotcontains "ExcludeCoin") {$Setup_Content | Add-Member ExcludeCoin "" -Force}
                    if ($Setup_Content.PSObject.Properties.Name -inotcontains "CoinSymbol") {$Setup_Content | Add-Member CoinSymbol "" -Force}
                    if ($Setup_Content.PSObject.Properties.Name -inotcontains "ExcludeCoinSymbol") {$Setup_Content | Add-Member ExcludeCoinSymbol "" -Force}
                    $Done | Add-Member $_ $Setup_Content
                }
                Set-ContentJson -PathToFile $PathToFile -Data $Done -MD5hash $ChangeTag > $null
            } else {
                Write-Log -Level Error "No pools found!"
            }
        }
        catch{
            Write-Log -Level Error "Could not create $($PathToFile) "
        }
    }
}

function Set-OCProfilesConfigDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [String]$PathToFile,
        [Parameter(Mandatory = $False)]
        [Switch]$Force = $false
    )
    if ($Force -or -not (Test-Path $PathToFile) -or (Get-ChildItem $PathToFile).LastWriteTime.ToUniversalTime() -lt (Get-ChildItem ".\Data\OCProfilesConfigDefault.ps1").LastWriteTime.ToUniversalTime()) {
        try {
            if (Test-Path $PathToFile) {$Preset = Get-Content $PathToFile -Raw | ConvertFrom-Json}
            if ($Preset -is [string] -or -not $Preset.PSObject.Properties.Name) {$Preset = [PSCustomObject]@{}}
            $ChangeTag = Get-ContentDataMD5hash($Preset)
            $Setup = Get-ChildItemContent ".\Data\OCProfilesConfigDefault.ps1" | Select-Object -ExpandProperty Content
            $Setup.PSObject.Properties.Name | Where-Object {-not $Preset.$_} | Foreach-Object {$Preset | Add-Member $_ $Setup.$_}
            Set-ContentJson -PathToFile $PathToFile -Data $Preset -MD5hash $ChangeTag > $null
        }
        catch{
            Write-Log -Level Error "Could not create $($PathToFile) "
        }
    }
    
}

function Get-YiiMPDataWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $False)]
        [String]$DataWindow = ''
    )
    Switch ($DataWindow -replace "[^A-Za-z0-9]+") {
        {"1","e1","e","ec","ecurrent","current","default","estimatecurrent" -icontains $_} {"estimate_current"}
        {"2","e2","e24","e24h","last24","estimate24h","24h","estimatelast24h" -icontains $_} {"estimate_last24h"}
        {"3","a2","a","a24","a24h","actual","actual24h","actuallast24h" -icontains $_} {"actual_last24h"}                
        {"4","min","min2","minimum","minimum2" -icontains $_} {"minimum-2"}
        {"5","max","max2","maximum","maximum2" -icontains $_} {"maximum-2"}
        {"6","avg","avg2","average","average2" -icontains $_} {"average-2"}
        {"7","min3","minimum3","minall","minimumall" -icontains $_} {"minimum-3"}
        {"8","max3","maximum3","maxall","maximumall" -icontains $_} {"maximum-3"}
        {"9","avg3","average3","avgall","averageall" -icontains $_} {"average-3"}
        {"10","mine","min2e","minimume","minimum2e" -icontains $_} {"minimum-2e"}
        {"11","maxe","max2e","maximume","maximum2e" -icontains $_} {"maximum-2e"}
        {"12","avge","avg2e","averagee","average2e" -icontains $_} {"average-2e"}
        {"13","minh","min2h","minimumh","minimum2h" -icontains $_} {"minimum-2h"}
        {"14","maxh","max2h","maximumh","maximum2h" -icontains $_} {"maximum-2h"}
        {"15","avgh","avg2h","averageh","average2h" -icontains $_} {"average-2h"}
        default {"average-2e"}
    }
}

function Get-YiiMPValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $True)]
        [PSCustomObject]$Request,
        [Parameter(Mandatory = $False)]
        [String]$DataWindow = '',
        [Parameter(Mandatory = $False)]
        [Switch]$CheckDataWindow = $false
    )    
    [Double]$Value = 0
    [hashtable]$div = @{"actual_last24h"=1000}
    if ($CheckDataWindow) {$DataWindow = Get-YiiMPDataWindow $DataWindow}
    if ($DataWindow -match '^(.+)-(.+)$') {
        Switch ($Matches[2]) {
            "2"  {[System.Collections.ArrayList]$fields = @("actual_last24h","estimate_current")}
            "2e" {[System.Collections.ArrayList]$fields = @("estimate_last24h","estimate_current")}
            "2h" {[System.Collections.ArrayList]$fields = @("actual_last24h","estimate_last24h")}
            "3"  {[System.Collections.ArrayList]$fields = @("actual_last24h","estimate_current","estimate_last24h")}
        }
        Switch ($Matches[1]) {
            "minimum" {
                $set = $true
                foreach ($field in $fields) {
                    if($Request.$field -eq $null) {continue}
                    $v = [Double]$Request.$field
                    if ($div[$field]) {$v /= $div[$field]}
                    if ($set -or $v -lt $Value) {$Value = $v;$set=$false}
                }
            }
            "maximum" {
                $set = $true
                foreach ($field in $fields) {
                    if($Request.$field -eq $null) {continue}
                    $v = [Double]$Request.$field
                    if ($div[$field]) {$v /= $div[$field]}
                    if ($set -or $v -gt $Value) {$Value = $v;$set=$false}
                }
            }
            "average" {
                $c=0
                foreach ($field in $fields) {                
                    if($Request.$field -eq $null) {continue}
                    $v = [Double]$Request.$field
                    if ($div[$field]) {$v /= $div[$field]}
                    $Value+=$v
                    $c++
                }
                if ($c) {$Value/=$c}
            }
        }
    } else {
        if (-not $DataWindow) {foreach ($field in [System.Collections.ArrayList]@("estimate_current","estimate_last24h","actual_last24h")) {if ($Request.$field -ne $null) {$DataWindow = $field;break}}}
        if ($DataWindow -and $Request.$DataWindow -ne $null) {
            $Value = $Request.$DataWindow
            if ($div[$DataWindow]) {$Value /= $div[$DataWindow]}
        }
    }
    $Value
}

function Get-DeviceSubsets($Device) {
    $Models = @($Device | Select-Object Model,Model_Name -Unique)
    if ($Models.Count) {
        $a = @();0..$($Models.Count-1) | Foreach-Object {$a+=$_}
        @(Get-Subsets $a | Where-Object {$_.Length -gt 1} | Foreach-Object{
            [PSCustomObject[]]$x = @($_.ToCharArray() | Foreach-Object {$Models[[string]$_/1]}) | Sort-Object -Property Model
            [PSCustomObject]@{
                Model = @($x.Model)
                Model_Name = @($x.Model_Name)
                Name = @($Device | Where-Object {$x.Model -icontains $_.Model} | Select-Object -ExpandProperty Name -Unique | Sort-Object)
            }
        })
    }
}

function Get-Subsets($a){
    #uncomment following to ensure only unique inputs are parsed
    #e.g. 'B','C','D','E','E' would become 'B','C','D','E'
    $a = $a | Select-Object -Unique
    #create an array to store output
    $l = @()
    #for any set of length n the maximum number of subsets is 2^n
    for ($i = 0; $i -lt [Math]::Pow(2,$a.Length); $i++)
    { 
        #temporary array to hold output
        [string[]]$out = New-Object string[] $a.length
        #iterate through each element
        for ($j = 0; $j -lt $a.Length; $j++)
        { 
            #start at the end of the array take elements, work your way towards the front
            if (($i -band (1 -shl ($a.Length - $j - 1))) -ne 0)
            {
                #store the subset in a temp array
                $out[$j] = $a[$j]
            }
        }
        #stick subset into an array
        $l += -join $out
    }
    #group the subsets by length, iterate through them and sort
    $l | Group-Object -Property Length | %{$_.Group | sort}
}

function Set-ActiveMinerPorts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $False)]
        $RunningMiners
    )
    if (-not (Test-Path Variable:Global:GlobalActiveMinerPorts) -or $Global:GlobalActiveMinerPorts -eq $null) {[hashtable]$Global:GlobalActiveMinerPorts = @{}}
    $Global:GlobalActiveMinerPorts.Clear()
    if ($RunningMiners) {foreach($m in $RunningMiners) {$Global:GlobalActiveMinerPorts[$m.GetMinerDeviceName()] = $m.Port}}
}

function Set-ActiveTcpPorts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $False)]
        [Switch]$Disable = $false
    )
    if ($Disable) {$Global:GlobalActiveTcpPorts=$null;return}
    if (-not (Test-Path Variable:Global:GlobalActiveTcpPorts) -or $Global:GlobalActiveTcpPorts -eq $null) {[System.Collections.ArrayList]$Global:GlobalActiveTcpPorts = @()}
    $Global:GlobalActiveTcpPorts.Clear()
    try {
        $NewPorts = @(([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()).GetActiveTcpListeners() | Select-Object -ExpandProperty Port -Unique)
        if ($NewPorts.Count -gt 0 ) {$Global:GlobalActiveTcpPorts.AddRange($NewPorts)>$null}
        $NewPorts = $null
    } catch {$Global:GlobalActiveTcpPorts=$null}
}

function Get-MinerPort{
    [cmdletbinding()]
    Param(   
        [Parameter(Mandatory = $True)]
        [string]$MinerName,
        [Parameter(Mandatory = $False)]
        [string[]]$DeviceName = @(),
        [Parameter(Mandatory = $False)]
        $Port = 30000
    )
    if (-not (Test-Path Variable:Global:GlobalActiveTcpPorts) -or $Global:GlobalActiveTcpPorts -eq $null) {return $Port}

    if ($DeviceName -and $DeviceName.Count) {$MinerName = "$($MinerName)-$(($DeviceName | Sort-Object) -join '-')"}
    if ($Global:GlobalActiveMinerPorts -and $Global:GlobalActiveMinerPorts.ContainsKey($MinerName)) {return $Global:GlobalActiveMinerPorts[$MinerName]}
    if (-not (Test-Path Variable:Global:GlobalMinerPorts)) {[hashtable]$Global:GlobalMinerPorts = @{};$API.MinerPorts = $Global:GlobalMinerPorts}
    $Port = [int]($Port -replace "[^\d]")
    $portin  = [int]$Port
    if ($Global:GlobalActiveTcpPorts.Contains($portin)) {
        $portmax = [math]::min($portin+9999,65535)
        do {$portin+=20} until ($portin -gt $portmax -or -not $Global:GlobalActiveTcpPorts.Contains($portin))
        if ($portin -gt $portmax) {$portin=[int]$Port}
    }
    if (-not $Global:GlobalMinerPorts.ContainsKey($MinerName) -or $portin -ne $Global:GlobalMinerPorts[$MinerName]) {Write-Log "Assigning port $portin to $MinerName"}
    $Global:GlobalMinerPorts[$MinerName]=$portin
    $portin
}

function Get-ComputerStats {
    [PSCustomObject]@{
        CpuLoad = Get-CimInstance win32_processor | Measure-Object -property LoadPercentage -Average | ForEach-Object {$_.Average}
        MemoryUsage = Get-CimInstance win32_operatingsystem | ForEach-Object {"{0:N2}" -f ((($_.TotalVisibleMemorySize - $_.FreePhysicalMemory) * 100) / $_.TotalVisibleMemorySize)}
        VirtualMemoryUsage = Get-CimInstance win32_operatingsystem | ForEach-Object {"{0:N2}" -f ((($_.TotalVirtualMemorySize - $_.FreeVirtualMemory) * 100) / $_.TotalVirtualMemorySize)}
        DriveFree = Get-CimInstance Win32_Volume -Filter "DriveLetter = '$($PWD.Drive.Name):'" | ForEach-Object {"{0:N2}" -f (($_.FreeSpace / $_.Capacity) * 100)}
        Processes = (Get-Process).count
        Connections = if (Get-Command "Get-NetTCPConnection" -ErrorAction Ignore) {(Get-NetTCPConnection).count}
    }
}

function Get-MD5Hash {
[cmdletbinding(   
    DefaultParameterSetName = '',   
    ConfirmImpact = 'low'   
)]   
Param(   
    [Parameter(
        Mandatory = $True,   
        Position = 0,   
        ParameterSetName = '',   
        ValueFromPipeline = $True)]   
        [string]$value
)
    $md5 = new-object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider
    $utf8 = new-object -TypeName System.Text.UTF8Encoding
    [System.BitConverter]::ToString($md5.ComputeHash($utf8.GetBytes($value))).ToUpper() -replace '-'
}

function Invoke-RestMethodAsync {
[cmdletbinding(   
    DefaultParameterSetName = '',   
    ConfirmImpact = 'low'   
)]   
Param(   
    [Parameter(   
        Mandatory = $True,   
        Position = 0,   
        ParameterSetName = '',   
        ValueFromPipeline = $True)]   
        [string]$url,
    [Parameter(Mandatory = $False)]   
        [int]$cycletime = 60,
    [Parameter(Mandatory = $False)]
        [int]$retry = 0,
    [Parameter(Mandatory = $False)]
        [int]$retrywait = 250
)
    Invoke-GetUrlAsync $url -method "REST" -cycletime $cycletime -retry $retry -retrywait $retrywait
}

function Invoke-WebRequestAsync {
[cmdletbinding(   
    DefaultParameterSetName = '',   
    ConfirmImpact = 'low'   
)]   
Param(   
    [Parameter(   
        Mandatory = $True,   
        Position = 0,   
        ParameterSetName = '',   
        ValueFromPipeline = $True)]   
        [string]$url,
    [Parameter(Mandatory = $False)]   
        [int]$cycletime = 60,
    [Parameter(Mandatory = $False)]
        [int]$retry = 0,
    [Parameter(Mandatory = $False)]
        [int]$retrywait = 250
)
    Invoke-GetUrlAsync $url -method "WEB" -cycletime $cycletime -retry $retry -retrywait $retrywait
}

function Invoke-GetUrlAsync {
[cmdletbinding(   
    DefaultParameterSetName = '',   
    ConfirmImpact = 'low'   
)]   
Param(   
    [Parameter(   
        Mandatory = $True,   
        Position = 0,   
        ParameterSetName = '',   
        ValueFromPipeline = $True)]   
        [string]$url,
    [Parameter(Mandatory = $False)]   
        [string]$method = "REST",
    [Parameter(Mandatory = $False)]   
        [switch]$force = $false,
    [Parameter(Mandatory = $False)]   
        [switch]$quiet = $false,
    [Parameter(Mandatory = $False)]   
        [int]$cycletime = 60,
    [Parameter(Mandatory = $False)]
        [int]$retry = 0,
    [Parameter(Mandatory = $False)]
        [int]$retrywait = 250
)
    $Jobkey = Get-MD5Hash $url

    if ($force -or
        -not $AsyncLoader.Jobs.$Jobkey -or (
            -not $AsyncLoader.Jobs.$Jobkey.Running -and (
                $AsyncLoader.Jobs.$Jobkey.CycleTime -ne $cycletime -or
                $AsyncLoader.Jobs.$Jobkey.Retry -ne $retry -or
                $AsyncLoader.Jobs.$Jobkey.RetryWait -ne $retrywait
            )
        )
    ) {
        if (-not $AsyncLoader.Jobs.$Jobkey) {
            $AsyncLoader.Jobs.$Jobkey = [PSCustomObject]@{Url=$url;Request='';Error=$null;Running=$true;Method=$method;LastRequest=(Get-Date).ToUniversalTime();CycleTime=$cycletime;Retry=$retry;RetryWait=$retrywait}
        } else {
            $AsyncLoader.Jobs.$Jobkey.Running=$true
            $AsyncLoader.Jobs.$Jobkey.LastRequest=(Get-Date).ToUniversalTime()
            $AsyncLoader.Jobs.$Jobkey.CycleTime = $cycletime
            $AsyncLoader.Jobs.$Jobkey.Retry = $retry
            $AsyncLoader.Jobs.$Jobkey.RetryWait = $retrywait
        }        
                
        $retry++

        $OldEAP = $ErrorActionPreference
        $ErrorActionPreference = "Stop"
        do {
            $Request = $RequestError = $null
            $RequestUrl = $url -replace "{timestamp}",(Get-Date -Format "yyyy-MM-dd_HH-mm-ss")
            try {    
                if ($method -eq "REST") {
                    $Request = Invoke-RestMethod $RequestUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                } else {
                    $Request = Invoke-WebRequest -UseBasicParsing $RequestUrl -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/66.0.3359.181 Safari/537.36" -TimeoutSec 10 -ErrorAction Stop
                }
            }
            catch {
                $RequestError = $_.Exception    
            }

            $retry--
            if ($retry) {
                if (-not $RequestError -and $Request -and ($Request -isnot [string] -or $Request.trim().Length)) {$retry = 0}
                else {Sleep -Milliseconds $retrywait}
            }
        } until ($retry -le 0)
        $ErrorActionPreference = $OldEAP

        $AsyncLoader.Jobs.$Jobkey.Request = $Request
        $AsyncLoader.Jobs.$Jobkey.Error = $RequestError
        $AsyncLoader.Jobs.$Jobkey.Running = $false
    }
    if (-not $quiet) {
        if ($AsyncLoader.Jobs.$Jobkey.Error) {throw $AsyncLoader.Jobs.$Jobkey.Error}
        $AsyncLoader.Jobs.$Jobkey.Request
    }
}

function Start-AsyncLoader {
    $Global:AsyncLoader = [hashtable]::Synchronized(@{})

     # Setup runspace to launch the AsyncLoader in a separate thread
    $newRunspace = [runspacefactory]::CreateRunspace()
    $newRunspace.Open()
    $newRunspace.SessionStateProxy.SetVariable("AsyncLoader", $AsyncLoader)
    $newRunspace.SessionStateProxy.Path.SetLocation($(pwd)) > $null

    $AsyncLoader.Loader = [PowerShell]::Create().AddScript({
        
        Import-Module ".\Include.psm1"

        $AsyncLoader.Stop = $false
        $AsyncLoader.Cycle = -1
        [hashtable]$AsyncLoader.Jobs = @{}
        [System.Collections.ArrayList]$AsyncLoader.Errors = @()
        $AsyncLoader.CycleTime = 10

        while (-not $AsyncLoader.Stop) {
            $Start = (Get-Date).ToUniversalTime()
            $AsyncLoader.Cycle++
            if (-not ($AsyncLoader.Cycle % 6)) {
                $AsyncLoader.ComputerStats = Get-ComputerStats
            }
            try {
                $AsyncLoader.Jobs.GetEnumerator() | Where-Object {$_.Value.LastRequest -le (Get-Date).ToUniversalTime().AddSeconds(-$_.Value.CycleTime) -and -not $_.Value.Running} | Foreach-Object {Invoke-GetUrlAsync -url $_.Value.Url -method $_.Value.Method -cycletime $_.Value.CycleTime -retry $_.Value.Retry -retrywait $_.Value.RetryWait -force -quiet}
            }
            catch {
                $AsyncLoader.Errors.Add($_.Exception.Message) > $null                
                if ($AsyncLoader.Errors.Count -gt 50) {$AsyncLoader.Errors.RemoveRange(0,[math]::max(1,$AsyncLoader.Errors.Count - 50))}
            }
            $Delta = $AsyncLoader.CycleTime-((Get-Date).ToUniversalTime() - $Start).TotalSeconds
            if ($Delta -gt 0) {Sleep -Milliseconds ($Delta*1000)}
            if ($Error.Count) {$Error | Out-File "Logs\errors_$(Get-Date -Format "yyyy-MM-dd").asyncloader.txt" -Append}
            $Error.Clear()
        }
    });

    $AsyncLoader.Loader.Runspace = $newRunspace
    $AsyncLoader.Handle = $AsyncLoader.Loader.BeginInvoke()
}

function Stop-AsyncLoader {
    $Global:AsyncLoader.Stop = $true
    $Global:AsyncLoader.Loader.dispose()
    $Global:AsyncLoader = [hashtable]::Synchronized(@{})
}

function Write-HostSetupHints {
[cmdletbinding()]   
Param(   
    [Parameter(Mandatory = $False)]   
    [string]$Color = "Yellow"
)

    Write-Host " "
    Write-Host "Hints:" -ForegroundColor $Color
    Write-Host "- press Return to accept the defaults" -ForegroundColor $Color
    Write-Host "- fields marked with * are mandatory" -ForegroundColor $Color
    Write-Host "- use comma `",`" to separate list entries" -ForegroundColor $Color
    Write-Host "- add new entries to a list, by adding a `"+`" in front of your input" -ForegroundColor $Color
    Write-Host "- remove entries from a list, by adding a `"-`" in front of your input" -ForegroundColor $Color
    Write-Host "- enter `"list`" or `"help`" to show a list of all valid entries" -ForegroundColor $Color
    Write-Host "- enter `"back`" or `"<`" to repeat the last input" -ForegroundColor $Color
    Write-Host "- enter `"delete`" to clear a non-mandatory entry" -ForegroundColor $Color
    Write-Host "- enter `"exit`" or `"cancel`" to abort without any changes to the configuration" -ForegroundColor $Color
    Write-Host " "
}