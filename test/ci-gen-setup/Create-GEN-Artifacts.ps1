#Requires -module AzureRM
#Requires -module pki

<#
Use this script to create the GEN artifacts needed by the pipeline to test templates.  The Crypto module is not supported on PS Core so this is using older modules.

Be sure to set the appropriate Context before running the script

#>

param(
    [string] $ResourceGroupName = 'ttk-gen-artifacts',
    [string] [Parameter(mandatory = $true)] $Location, #The location where resources will be deployed in the pipeline, in many cases they need to be in the same region.
    [string] $KeyVaultName = 'azbotvault',
    [string] $CertPass = $("cI#" + (New-Guid).ToString().Substring(0, 17)),
    [string] $CertDNSName = 'azbot-cert-dns',
    [string] $KeyVaultSelfSignedCertName = 'azbot-sscert',
    [string] $KeyVaultNotSecretName = 'notSecretPassword'

)

#Create the Resource Group only if it doesn't exist
if ((Get-AzureRMResourceGroup -Name $ResourceGroupName -Location $Location -Verbose -ErrorAction SilentlyContinue) -eq $null) {
    New-AzureRMResourceGroup -Name $ResourceGroupName -Location $Location -Verbose -Force
}

#Create the VNET
$subnet1 = New-AzureRMVirtualNetworkSubnetConfig -Name 'azbot-subnet-1' -AddressPrefix '10.0.1.0/24'
$vNet = New-AzureRMVirtualNetwork -ResourceGroupName $ResourceGroupName -Name 'azbot-vnet' -AddressPrefix '10.0.0.0/16' -Location $location -Subnet $subnet1 -Verbose -Force

$json = New-Object System.Collections.Specialized.OrderedDictionary #This keeps things in the order we entered them, instead of: New-Object -TypeName Hashtable
$json.Add("VNET-RESOURCEGROUP-NAME", $vNet.ResourceGroupName)
$json.Add("VNET-NAME", $vNet.Name)
$json.Add("VNET-SUBNET1-NAME", $vNet.Subnets[0].Name)

<#
Creat a KeyVault and add:
    1) Sample Password
    2) Service Fabric Cert
    3) Disk Encryption Key
    4) SSL Cert Secret
    5) Self-Signed Cert

#>
# Create the Vault
$vault = Get-AzureRMKeyVault -VaultName $KeyVaultName -verbose -ErrorAction SilentlyContinue
if($vault -eq $null) {
    $vault = New-AzureRMKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -Location $Location -EnabledForTemplateDeployment -EnabledForDiskEncryption -Verbose
}

# 1) Create a sample password
$SecretValue = ConvertTo-SecureString -String $CertPass -AsPlainText -Force
Set-AzureKeyVaultSecret -VaultName $KeyVaultName -Name $KeyVaultNotSecretName -SecretValue $SecretValue -Verbose

$json.Add("KEYVAULT-NAME", $vault.VaultName)
$json.Add("KEYVAULT-RESOURCEGROUP-NAME", $vault.ResourceGroupName)
$json.Add("KEYVAULT-PASSWORD-SECRET-NAME", $KeyVaultNotSecretName)
$json.Add("KEYVAULT-SUBSCRIPTION-ID", $vault.ResourceId.Split('/')[2])
$json.Add("KEYVAULT-RESOURCE-ID", $vault.ResourceId)


# 2) Create a sample cert for Service Fabric

$SecurePassword = ConvertTo-SecureString -String $CertPass -AsPlainText -Force
$CertFileFullPath = $(Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) "\$CertDNSName.pfx")

if($(Get-Module 'PKI') -eq $null){ Import-Module "PKI" -SkipEditionCheck -Verbose}
$NewCert = New-SelfSignedCertificate -CertStoreLocation Cert:\CurrentUser\My -DnsName $CertDNSName -NotAfter (Get-Date).AddYears(10)
Export-PfxCertificate -FilePath $CertFileFullPath -Password $SecurePassword -Cert $NewCert

$Bytes = [System.IO.File]::ReadAllBytes($CertFileFullPath)
$Base64 = [System.Convert]::ToBase64String($Bytes)

$JSONBlob = @{
    data = $Base64
    dataType = 'pfx'
    password = $CertPass
} | ConvertTo-Json

$ContentBytes = [System.Text.Encoding]::UTF8.GetBytes($JSONBlob)
$Content = [System.Convert]::ToBase64String($ContentBytes)

$SFSecretValue = ConvertTo-SecureString -String $Content -AsPlainText -Force
$NewSecret = Set-AzureKeyVaultSecret -VaultName $KeyVaultName -Name "azbot-sf-cert" -SecretValue $SFSecretValue -Verbose

$json.Add("SF-CERT-URL", $NewSecret.Id) #need to verify this one, it should be the secret uri
$json.Add("SF-CERT-THUMBPRINT", $NewCert.Thumbprint)

# 3) Create a disk encryption key
$key = Add-AzureKeyVaultKey -VaultName $keyVaultName -Name "azbot-diskkey" -Destination "Software"

$json.Add("KEYVAULT-ENCRYPTION-KEY", $key.Name)
$json.Add("KEYVAULT-ENCRYPTION-KEY-URI", $key.id)
$json.Add("KEYVAULT-ENCRYPTION-KEY-VERSION", $key.Version)


#3 ) SSL Cert (TODO not sure if this is making the correct cert, need to test it) 
#https://docs.microsoft.com/en-us/azure/virtual-machines/windows/tutorial-secure-web-server#generate-a-certificate-and-store-in-key-vault
#$policy = New-AzureKeyVaultCertificatePolicy -SubjectName "CN=www.contoso.com" -SecretContentType "application/x-pkcs12" -IssuerName Self -ValidityInMonths 120
#Add-AzureKeyVaultCertificate -VaultName $keyvaultName -Name "mycert" -CertificatePolicy $policy

# Use the same cert we generated for Service Fabric here
$pfxFileFullPath = $(Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) "\$CertDNSName.pfx")
$cerFileFullPath= $(Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) "\$CertDNSName.cer")

Export-PfxCertificate -Cert $NewCert -FilePath "$pfxFileFullPath" -Password $(ConvertTo-SecureString -String $CertPass -Force -AsPlainText)
Export-Certificate -Cert $NewCert -FilePath "$cerFileFullPath"

$kvCert = Import-AzureKeyVaultCertificate -VaultName $KeyVaultName -Name "azbot-ssl-cert" -FilePath $pfxFileFullPath -Password $(ConvertTo-SecureString -String $CertPass -Force -AsPlainText)

$json.Add("KEYVAULT-SSL-SECRET-NAME", $kvCert.Name)
$json.Add("KEYVAULT-SSL-SECRET-URI", $kvCert.Id)
$json.Add("SELFSIGNED-CERT-PFXDATA", [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes("$pfxFileFullPath")))
$json.Add("SELFSIGNED-CERT-CERDATA", [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes("$cerFileFullPath")))
$json.Add("SELFSIGNED-CERT-PASSWORD", $CertPass)
$json.Add("SELFSIGNED-CERT-THUMBPRINT", $kvCert.Thumbprint)
$json.Add("SELFSIGNED-CERT-DNSNAME", $CertDNSName)


#Output all the values needed for the config file
Write-Output $($json | ConvertTo-json)
