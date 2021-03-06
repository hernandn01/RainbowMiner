﻿using module ..\Include.psm1

param(
    [PSCustomObject]$Pools,
    [PSCustomObject]$Stats,
    [PSCustomObject]$Config,
    [PSCustomObject]$Devices
)

$Path = ".\Bin\NVIDIA-TPruvotx64\ccminer-x64.exe"
$Uri = "https://github.com/tpruvot/ccminer/releases/download/2.3-tpruvot/ccminer-2.3-cuda9.7z"
$Port = "115{0:d2}"
$DevFee = 0.0

$Devices = $Devices.NVIDIA
if (-not $Devices -and -not $Config.InfoOnly) {return} # No NVIDIA present in system

$Commands = [PSCustomObject[]]@(
    #GPU - profitable 20/04/2018
    [PSCustomObject]@{MainAlgorithm = "allium"; Params = "-N 1"} #Allium
    #[PSCustomObject]@{MainAlgorithm = "bastion"; Params = ""} #bastion
    #[PSCustomObject]@{MainAlgorithm = "bitcore"; Params = ""} #Bitcore
    #[PSCustomObject]@{MainAlgorithm = "bmw"; Params = ""} #bmw
    #[PSCustomObject]@{MainAlgorithm = "c11/flax"; Params = ""} #C11
    [PSCustomObject]@{MainAlgorithm = "cryptolight"; Params = ""} # CryptoNight-Lite
    #[PSCustomObject]@{MainAlgorithm = "deep"; Params = ""} #deep
    #[PSCustomObject]@{MainAlgorithm = "dmd-gr"; Params = ""} #dmd-gr
    #[PSCustomObject]@{MainAlgorithm = "equihash"; Params = ""} #Equihash
    #[PSCustomObject]@{MainAlgorithm = "fresh"; Params = ""} #fresh
    #[PSCustomObject]@{MainAlgorithm = "fugue256"; Params = ""} #Fugue256
    [PSCustomObject]@{MainAlgorithm = "graft"; Params = ""} #CryptoNightV8
    #[PSCustomObject]@{MainAlgorithm = "groestl"; Params = ""} #Groestl
    [PSCustomObject]@{MainAlgorithm = "hmq1725"; Params = "-N 1"; FaultTolerance = 0.5} #HMQ1725
    #[PSCustomObject]@{MainAlgorithm = "jackpot"; Params = ""} #JHA
    [PSCustomObject]@{MainAlgorithm = "jha"; Params = "-N 1"} #JHA
    #[PSCustomObject]@{MainAlgorithm = "keccak"; Params = "-N 1"} #Keccak
    #[PSCustomObject]@{MainAlgorithm = "keccakc"; Params = "-N 1"} #keccakc
    #[PSCustomObject]@{MainAlgorithm = "luffa"; Params = ""} #Luffa
    #[PSCustomObject]@{MainAlgorithm = "lyra2"; Params = ""} #lyra2re
    #[PSCustomObject]@{MainAlgorithm = "lyra2v2"; Params = ""} #Lyra2RE2
    [PSCustomObject]@{MainAlgorithm = "lyra2z"; Params = "-N 1 --submit-stale"} #Lyra2z, ZCoin        
    [PSCustomObject]@{MainAlgorithm = "monero"; Params = "-N 1"} #CryptoNightV7
    #[PSCustomObject]@{MainAlgorithm = "neoscrypt"; Params = ""} #NeoScrypt
    #[PSCustomObject]@{MainAlgorithm = "penta"; Params = ""} #Pentablake
    #[PSCustomObject]@{MainAlgorithm = "phi1612"; Params = " -N 3"} #PHI spmod is faster
    #[PSCustomObject]@{MainAlgorithm = "phi2"; Params = " -N 3"}
    #[PSCustomObject]@{MainAlgorithm = "polytimos"; Params = ""} #Polytimos
    #[PSCustomObject]@{MainAlgorithm = "scrypt-jane"; Params = ""} #scryptjane:nf
    [PSCustomObject]@{MainAlgorithm = "sha256t"; Params = "-N 1"} #sha256t
    #[PSCustomObject]@{MainAlgorithm = "skein"; Params = ""} #Skein
    #[PSCustomObject]@{MainAlgorithm = "skein2"; Params = ""} #skein2
    #[PSCustomObject]@{MainAlgorithm = "skunk"; Params = ""} #Skunk
    [PSCustomObject]@{MainAlgorithm = "sonoa"; Params = "-N 1"} #SonoA
    [PSCustomObject]@{MainAlgorithm = "stellite"; Params = ""} # CryptoNightV3
    #[PSCustomObject]@{MainAlgorithm = "s3"; Params = ""} #S3
    [PSCustomObject]@{MainAlgorithm = "timetravel"; Params = "-N 1"} #Timetravel
    #[PSCustomObject]@{MainAlgorithm = "tribus"; Params = ""} #Tribus (enemyz 1.10 is faster)
    #[PSCustomObject]@{MainAlgorithm = "veltor"; Params = ""} #Veltor
    #[PSCustomObject]@{MainAlgorithm = "whirlpool"; Params = ""} #Whirlpool
    #[PSCustomObject]@{MainAlgorithm = "whirlpoolx"; Params = ""} #whirlpoolx
    #[PSCustomObject]@{MainAlgorithm = "wildkeccak"; Params = ""} #wildkeccak
    #[PSCustomObject]@{MainAlgorithm = "x11evo"; Params = ""} #X11evo
    #[PSCustomObject]@{MainAlgorithm = "x12"; Params = ""} #X12
    #[PSCustomObject]@{MainAlgorithm = "x16r"; Params = ""} #X16r
    #[PSCustomObject]@{MainAlgorithm = "X16s"; Params = ""} #X16s
    #[PSCustomObject]@{MainAlgorithm = "x17"; Params = ""} #x17
    #[PSCustomObject]@{MainAlgorithm = "zr5"; Params = ""} #zr5

    # ASIC - never profitable 20/04/2018
    #[PSCustomObject]@{MainAlgorithm = "blake"; Params = ""} #blake
    #[PSCustomObject]@{MainAlgorithm = "blakecoin"; Params = ""} #Blakecoin
    #[PSCustomObject]@{MainAlgorithm = "blake2s"; Params = ""} #Blake2s
    #[PSCustomObject]@{MainAlgorithm = "lbry"; Params = ""} #Lbry
    #[PSCustomObject]@{MainAlgorithm = "decred"; Params = ""} #Decred
    #[PSCustomObject]@{MainAlgorithm = "quark"; Params = ""} #Quark
    #[PSCustomObject]@{MainAlgorithm = "qubit"; Params = ""} #Qubit
    #[PSCustomObject]@{MainAlgorithm = "myr-gr"; Params = ""} #MyriadGroestl
    #[PSCustomObject]@{MainAlgorithm = "nist5"; Params = ""} #Nist5
    #[PSCustomObject]@{MainAlgorithm = "scrypt"; Params = ""} #Scrypt
    #[PSCustomObject]@{MainAlgorithm = "scrypt:N"; Params = ""} #scrypt:N
    #[PSCustomObject]@{MainAlgorithm = "sha256d"; Params = ""} #sha256d
    #[PSCustomObject]@{MainAlgorithm = "sia"; Params = ""} #SiaCoin
    #[PSCustomObject]@{MainAlgorithm = "sib"; Params = ""} #Sib
    #[PSCustomObject]@{MainAlgorithm = "vanilla"; Params = ""} #BlakeVanilla
    #[PSCustomObject]@{MainAlgorithm = "x11"; Params = ""} #X11
    #[PSCustomObject]@{MainAlgorithm = "x13"; Params = ""} #x13
    #[PSCustomObject]@{MainAlgorithm = "x14"; Params = ""} #x14
    #[PSCustomObject]@{MainAlgorithm = "x15"; Params = ""} #x15
)

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
    }
    return
}

$Devices | Select-Object Vendor, Model -Unique | ForEach-Object {
    $Miner_Device = $Devices | Where-Object Vendor -EQ $_.Vendor | Where-Object Model -EQ $_.Model
    $Miner_Port = $Port -f ($Miner_Device | Select-Object -First 1 -ExpandProperty Index)
    $Miner_Model = $_.Model
    $Miner_Name = (@($Name) + @($Miner_Device.Name | Sort-Object) | Select-Object) -join '-'
    $Miner_Port = Get-MinerPort -MinerName $Name -DeviceName @($Miner_Device.Name) -Port $Miner_Port

    $DeviceIDsAll = $Miner_Device.Type_Vendor_Index -join ','

    $Commands | ForEach-Object {

        $Algorithm_Norm = Get-Algorithm $_.MainAlgorithm

        if ($Pools.$Algorithm_Norm.Host -and $Miner_Device) {
            if ($Pools.$Algorithm_Norm.Name -notlike "Nicehash" -or $_.MainAlgorithm -ne "monero") {
                [PSCustomObject]@{
                    Name = $Miner_Name
                    DeviceName = $Miner_Device.Name
                    DeviceModel = $Miner_Model
                    Path = $Path
                    Arguments = "-R 1 -b $($Miner_Port) -d $($DeviceIDsAll) -a $($_.MainAlgorithm) -q -o $($Pools.$Algorithm_Norm.Protocol)://$($Pools.$Algorithm_Norm.Host):$($Pools.$Algorithm_Norm.Port) -u $($Pools.$Algorithm_Norm.User) -p $($Pools.$Algorithm_Norm.Pass) $($_.Params)"
                    HashRates = [PSCustomObject]@{$Algorithm_Norm = $Stats."$($Miner_Name)_$($Algorithm_Norm)_HashRate"."$(if ($_.HashrateDuration){$_.HashrateDuration}else{"Week"})"}
                    API = "Ccminer"
                    Port = $Miner_Port
                    Uri = $Uri
					DevFee = $DevFee
                    FaultTolerance = $_.FaultTolerance
                    ExtendInterval = $_.ExtendInterval
                    ManualUri = $ManualUri
                }
            }
        }
    }
}