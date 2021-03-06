﻿using module ..\Include.psm1

param(
    [PSCustomObject]$Pools,
    [PSCustomObject]$Stats,
    [PSCustomObject]$Config,
    [PSCustomObject]$Devices
)

$Path = ".\Bin\Equihash-BMiner\bminer.exe"
$URI = "https://www.bminercontent.com/releases/bminer-lite-v10.2.0-c698b5f-amd64.zip"
$ManualURI = "https://bminer.me"
$Port = "307{0:d2}"
$DevFee = 2.0

$Devices = $Devices.NVIDIA
if (-not $Devices -and -not $Config.InfoOnly) {return} # No NVIDIA present in system

$Commands = [PSCustomObject[]]@(
    [PSCustomObject]@{MainAlgorithm = "equihash"; SecondaryAlgorithm = ""; Params = ""; DevFee = 2.0} #" -nofee" #Equihash
    [PSCustomObject]@{MainAlgorithm = "equihash1445"; SecondaryAlgorithm = ""; Params = ""; DevFee = 2.0} #" -nofee" #Equihash 144,5
    [PSCustomObject]@{MainAlgorithm = "ethash"; SecondaryAlgorithm = ""; Params = ""; DevFee = 0.65} #Ethash (ethminer is faster and no dev fee)
    [PSCustomObject]@{MainAlgorithm = "tensority"; SecondaryAlgorithm = ""; Params = ""; DevFee = 2.0} #" -nofee" #Bytom
    #[PSCustomObject]@{MainAlgorithm = "zhash"; SecondaryAlgorithm = ""; Params = ""; DevFee = 2.0} #" -nofee" #Zhash
    #[PSCustomObject]@{MainAlgorithm = "ethash"; SecondaryAlgorithm = "blake2s"; Params = ""; DevFee = 1.3} #Ethash + Blake2s
    #[PSCustomObject]@{MainAlgorithm = "ethash"; SecondaryAlgorithm = "blake14r"; Params = ""; DevFee = 1.3} #Ethash + Decred
)

$Coins = [PSCustomObject]@{
    AION        = "--pers AION0PoW"
    BTG         = "--pers BgoldPoW"
    BTCZ        = "--pers BitcoinZ"
    SAFE        = "--pers Safecoin"
    XSG         = "--pers sngemPoW"
    ZEL         = "--pers ZelProof"
    ZER         = "--pers ZERO_PoW"
}

$Name = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName

if ($Config.InfoOnly) {
    [PSCustomObject]@{
        Type      = @("NVIDIA")
        Name      = $Name
        Path      = $Path
        Port      = $Miner_Port
        Uri       = $Uri
        DevFee    = $DevFee
        ManualUri = $ManualUri
        Commands  = $Commands
		Coins     = @($Coins.PSObject.Properties.Name)
    }
    return
}

$Devices | Select-Object Vendor, Model -Unique | ForEach-Object {
    $Miner_Device = $Devices | Where-Object Vendor -EQ $_.Vendor | Where-Object Model -EQ $_.Model
    $Miner_Port = $Port -f ($Miner_Device | Select-Object -First 1 -ExpandProperty Index)
    $Miner_Port = Get-MinerPort -MinerName $Name -DeviceName @($Miner_Device.Name) -Port $Miner_Port
    $Miner_Model = $_.Model

    $DeviceIDsAll = $Miner_Device.Type_Vendor_Index -join ','

    $Commands | ForEach-Object {
        $MainAlgorithm = $_.MainAlgorithm
        $MainAlgorithm_Norm = Get-Algorithm $MainAlgorithm

        if ($Pools.$MainAlgorithm_Norm.Host -and $Miner_Device) {

            $SecondAlgorithm = $_.SecondaryAlgorithm
            if ($SecondAlgorithm -ne '') {
                $SecondAlgorithm_Norm = Get-Algorithm $SecondAlgorithm
            }

            switch ($MainAlgorithm) {
                "equihash" {$Stratum = if ($Pools.$MainAlgorithm_Norm.SSL) {'stratum+ssl'}else {'stratum'}}
                "equihash1445" {$Stratum = if ($Pools.$MainAlgorithm_Norm.SSL) {'equihash1445+ssl'}else {'equihash1445'}}
                "ethash" {$Stratum = if ($Pools.$MainAlgorithm_Norm.SSL) {'ethash+ssl'}else {'ethstratum'}}
                "tensority" {$Stratum = if ($Pools.$MainAlgorithm_Norm.SSL) {'tensority+ssl'}else {'tensority'}}
                "zhash" {$Stratum = if ($Pools.$MainAlgorithm_Norm.SSL) {'zhash+ssl'}else {'zhash'}}
            }

            if ($SecondAlgorithm -eq '') {
                $Miner_Name = (@($Name) + @($Miner_Device.Name | Sort-Object) | Select-Object) -join '-'

                if ($MainAlgorithm -eq "equihash1445") {
                    @($Coins.PSObject.Properties.Name) | Foreach-Object {
                        $Miner_Coin = $_
                        $Algorithm_Norm = "$MainAlgorithm_Norm-$Miner_Coin"
                        [PSCustomObject]@{
                            Name = $Miner_Name
                            DeviceName = $Miner_Device.Name
                            DeviceModel = $Miner_Model
                            Path = $Path
                            Arguments = "-devices $($DeviceIDsAll) -api 127.0.0.1:$($Miner_Port) -uri $($Stratum)://$([System.Web.HttpUtility]::UrlEncode($Pools.$Algorithm_Norm.User)):$([System.Web.HttpUtility]::UrlEncode($Pools.$Algorithm_Norm.Pass))@$($Pools.$Algorithm_Norm.Host):$($Pools.$Algorithm_Norm.Port) $($Coins.$Miner_Coin) -watchdog=false -no-runtime-info -gpucheck=0 $($_.Params)"
                            HashRates = [PSCustomObject]@{$Algorithm_Norm = $Stats."$($Miner_Name)_$($Algorithm_Norm -replace '\-.*$')_HashRate".Week}
                            API = "Bminer"
                            Port = $Miner_Port
                            Uri = $Uri
                            DevFee = $_.DevFee
                            ManualUri = $ManualUri
                        }
                    }
                } else {               
                    [PSCustomObject]@{
                        Name = $Miner_Name
                        DeviceName = $Miner_Device.Name
                        DeviceModel = $Miner_Model
                        Path = $Path
                        Arguments = "-devices $($DeviceIDsAll) -api 127.0.0.1:$($Miner_Port) -uri $($Stratum)://$([System.Web.HttpUtility]::UrlEncode($Pools.$MainAlgorithm_Norm.User)):$([System.Web.HttpUtility]::UrlEncode($Pools.$MainAlgorithm_Norm.Pass))@$($Pools.$MainAlgorithm_Norm.Host):$($Pools.$MainAlgorithm_Norm.Port) -watchdog=false -no-runtime-info -gpucheck=0 $($_.Params)"
                        HashRates = [PSCustomObject]@{$MainAlgorithm_Norm = $Stats."$($Miner_Name)_$($MainAlgorithm_Norm)_HashRate".Week}
                        API = "Bminer"
                        Port = $Miner_Port
                        Uri = $Uri
                        DevFee = $_.DevFee
                        ManualUri = $ManualUri
                    }
                }
            } else {
                $Miner_Name = (@($Name) + @($MainAlgorithm_Norm) + @($SecondAlgorithm_Norm) + @($Miner_Device.Name | Sort-Object) | Select-Object) -join '-'
                [PSCustomObject]@{
                    Name = $Miner_Name
                    DeviceName = $Miner_Device.Name
                    DeviceModel = $Miner_Model
                    Path = $Path
                    Arguments = "-devices $($DeviceIDsAll) -api 127.0.0.1:$($Miner_Port) -uri $($Stratum)://$([System.Web.HttpUtility]::UrlEncode($Pools.$MainAlgorithm_Norm.User)):$([System.Web.HttpUtility]::UrlEncode($Pools.$MainAlgorithm_Norm.Pass))@$($Pools.$MainAlgorithm_Norm.Host):$($Pools.$MainAlgorithm_Norm.Port) -uri2 $($SecondAlgorithm)://$([System.Web.HttpUtility]::UrlEncode($Pools.$SecondAlgorithm_Norm.User)):$([System.Web.HttpUtility]::UrlEncode($Pools.$SecondAlgorithm_Norm.Pass))@$($Pools.$SecondAlgorithm_Norm.Host):$($Pools.$SecondAlgorithm_Norm.Port) -watchdog=false -no-runtime-info -gpucheck=0 $($_.Params)"
                    HashRates = [PSCustomObject]@{
                        $MainAlgorithm_Norm = $($Stats."$($MinerName)_$($MainAlgorithm_Norm)_HashRate".Week)
                        $SecondAlgorithm_Norm = $($Stats."$($MinerName)_$($SecondAlgorithm_Norm)_HashRate".Week)
                    }
                    API = "Bminer"
                    Port = $Miner_Port
                    Uri = $Uri
                    DevFee = [PSCustomObject]@{
                        ($MainAlgorithm_Norm) = $_.DevFee
                        ($SecondAlgorithm_Norm) = 0
                    }
                    ManualUri = $ManualUri
                }
            }
        }
    }
}