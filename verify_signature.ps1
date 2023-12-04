[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [Alias("sf")]
    [string] $signature_folder,

    [Parameter(Mandatory=$false)]
    [Alias("cf")]
    [string] $cosign_folder
)

if (-not (Test-Path $signature_folder)) {
    throw "$signature_folder not found. Download it from https://downloads.zenid.cz/"
}

$cosign_url = "https://github.com/sigstore/cosign/releases/download/v2.2.1/cosign-windows-amd64.exe"

$working_folder = [System.IO.Path]::GetTempPath() + [System.IO.Path]::GetRandomFileName()

New-Item -ItemType Directory -Path $working_folder\ | out-null

try {
    # Download cosign
    if ([string]::IsNullOrEmpty($cosign_folder)) {
        $cosign_folder = $working_folder
        Write-Host -ForegroundColor Blue "Cosign will be downloaded to a temp folder which will be deleted after this script run ends. If you want to skip this step in the future supply a path to a folder you would like the cosign to be downloaded to the next time you would run this script and always use this path as parameter when running the script. Use -cf for the cosign path and -sf for the path you dowloaded the .zip files to." 
    }

    $cosign_path = "$cosign_folder/cosign.exe"
    if (-not (Test-Path $cosign_path)) {
        Write-Host "Downloading $cosign_url..."
        Invoke-WebRequest -Uri $cosign_url -OutFile "$cosign_path" -UseBasicParsing
    }    

    # Unzip signatures.txt
    Get-ChildItem $signature_folder -Filter *.signature.zip | Expand-Archive -DestinationPath $working_folder -Force
    #Expand-Archive -Path $SignatureZip -DestinationPath $working_folder

    $checksums_path =  Get-ChildItem $working_folder -recurse -Filter checksums.txt | % { $_.FullName }
    $unzipped_signature_path = Split-Path $checksums_path -Parent
    $checksumsContent = Get-Content $checksums_path

    # Parse the text file and verify the checksums.
    [Environment]::NewLine
    Write-Host "Verifying checksums..."
    
    $checksum_outputs = @()

    $checksumsContent | ForEach-Object {
        $line = $_
        $checksum = $line.Split(" ")[0]
        $file = $line.Split(" ")[2] # The file is separated from the checksum by two spaces

        $file_path = Get-ChildItem $signature_folder -recurse -Filter $file | % { $_.FullName }        

        $message = ''

        if (-not (Test-Path $file_path)) {
            $message = "File $file expected but not found. Download it from https://downloads.zenid.cz/"
        }

        $file_checksum = (Get-FileHash -Path $file_path -Algorithm SHA256).Hash        
        
        $color = "Red"
        #Write-Host "$file     "  -NoNewline
        if ($file_checksum -ne $checksum) {
            $message = "Checksum mismatch" 
        } else {
            $message = "Checksum OK" 
            $color = "Green"
        }
        
        $checksum_outputs += [pscustomobject]@{File=$file;Result=$message;Color=$color}
    }

    Foreach ($item in $checksum_outputs) { 
        $f = $item.File + ' ' * (30 - $item.File.Length);
        Write-Host  $f -NoNewline
        Write-Host $item.Result -ForegroundColor $item.Color
    }
   
   [Environment]::NewLine

    # Verify the cosign binary
    Write-Host "Verifying cosign...           "  -NoNewline
    $repository = "ZenIDTeam/ZenID"
    $workflow_name = "Release SDKs"
    $workflow_ref = "refs/heads/rc"

    if ($file.StartsWith('zenid')) {
        $workflow_name = "Release ZenID" #"Test ZenID pull request"
        $workflow_ref = "refs/heads/live" #"refs/pull/7320/merge"
    }
    
    $cosign_output = "$working_folder/cosign_output.txt"
    # Set the COSIGN_EXPERIMENTAL env variable to enable the experimental features
    $env:COSIGN_EXPERIMENTAL = 1
          
    & $cosign_path verify-blob $checksums_path --signature "$unzipped_signature_path/checksums.sig" --certificate "$unzipped_signature_path/checksums.pem" --certificate-identity-regexp=https://github.com/ZenIDTeam/ZenID/ --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-github-workflow-name "$workflow_name" --certificate-github-workflow-ref "$workflow_ref"  *> $cosign_output
    
    Get-Content $cosign_output -Tail 1 | ForEach-Object { 
        $color = "Red"
        If ($_.Trim() -eq 'Verified OK') { 
            $color = "Green"
        }      
        Write-Host "$_`n" -ForegroundColor $color
    }  
}
finally {
    # Remove the temp folder and all contents
    Remove-Item -Path $working_folder -Recurse
}
