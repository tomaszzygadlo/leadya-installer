param([Parameter(Mandatory=$true)][string]$ResultDirectory,
      [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
if (-not (Test-Path -LiteralPath $ResultDirectory -PathType Container)) {throw 'No result directory'}
$allowed=@('build.log','bootstrap.log','unit-tests.log','source-verification.log','input-provenance.json','admission-check.json','release.json','identity.json','ci-sdk.json','final-assets.json','build-status.json','authenticode.json')
$domains=@('LEADYA_APP','LEADYA_PRO','TURBOT_PRO','TURBO_BOT_APP','HOTFIX_LEADYA_APP','HOTFIX_LEADYA_PRO','HOTFIX_TURBOT_PRO','HOTFIX_TURBO_BOT_APP','TESTOWY_LEADYA_APP','TESTOWY_LEADYA_PRO','TESTOWY_TURBOT_PRO','TESTOWY_TURBO_BOT_APP')
foreach($domain in $domains){$allowed+=@("installers/LeadyaInstaller-$domain.exe","installers/LeadyaVpsInstaller-$domain.exe","installers/LeadyaVpsInstaller-$domain.manifest","installers/LeadyaVpsInstaller-$domain.txt")}
$allowed+='installers/LeadyaInstaller-HOTFIX_TURBOT_PRO.manifest.json'
$root=(Resolve-Path -LiteralPath $ResultDirectory).Path
foreach($entry in Get-ChildItem -LiteralPath $root -Recurse -Force){
 if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Aliased result refused'}
 if(-not $entry.PSIsContainer){$relative=$entry.FullName.Substring($root.Length+1).Replace('\','/');if($relative -notin $allowed){throw 'Unexpected result file refused'}}
}
New-Item -ItemType Directory -Path $OutputDirectory -ErrorAction Stop|Out-Null
$zip=Join-Path $env:RUNNER_TEMP 'leadya-result-private.zip'
if(Test-Path -LiteralPath $zip){throw 'Existing plaintext transport refused'}
Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip -CompressionLevel Optimal
$key=[Convert]::FromBase64String($env:LEADYA_RESULT_KEY)
if($key.Length -ne 32){throw 'Expected 256-bit result key'}
$plain=[IO.File]::ReadAllBytes($zip);$nonce=[Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
$cipher=[byte[]]::new($plain.Length);$tag=[byte[]]::new(16)
$aad=[Text.Encoding]::UTF8.GetBytes("leadya-installer-build/v1|$env:LEADYA_SOURCE_COMMIT|$env:LEADYA_ARCHIVE_SHA256|$env:GITHUB_SHA|$env:GITHUB_RUN_ID")
$aes=[Security.Cryptography.AesGcm]::new($key,16)
try{$aes.Encrypt($nonce,$plain,$cipher,$tag,$aad)}finally{$aes.Dispose();[Array]::Clear($key,0,$key.Length)}
$output=Join-Path $OutputDirectory 'result.cipher'
[IO.File]::WriteAllBytes($output,$cipher)
[ordered]@{format='leadya-installer-build/v1';nonce_base64=[Convert]::ToBase64String($nonce);tag_base64=[Convert]::ToBase64String($tag);aad_utf8=[Text.Encoding]::UTF8.GetString($aad);cipher_sha256=(Get-FileHash -LiteralPath $output).Hash.ToLowerInvariant();plaintext_sha256=(Get-FileHash -LiteralPath $zip).Hash.ToLowerInvariant();source_commit=$env:LEADYA_SOURCE_COMMIT;source_archive_sha256=$env:LEADYA_ARCHIVE_SHA256;workflow_commit=$env:GITHUB_SHA;workflow_run_id=$env:GITHUB_RUN_ID} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'result-envelope.json') -Encoding utf8
[Array]::Clear($plain,0,$plain.Length)
Write-Output 'Encrypted result prepared; no plaintext asset is uploaded.'
