param([Parameter(Mandatory)][ValidateSet('decrypt','bootstrap','seal')][string]$Action,
      [Parameter(Mandatory)][string]$InputDirectory,
      [Parameter(Mandatory)][string]$OutputPath,
      [Parameter(Mandatory)][string]$RedTree,
      [Parameter(Mandatory)][string]$GreenTree,
      [Parameter(Mandatory)][string]$ZipSha256)
$ErrorActionPreference='Stop'
if($RedTree -cnotmatch '^[0-9a-f]{40}$' -or $GreenTree -cnotmatch '^[0-9a-f]{40}$' -or $ZipSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid unit identity'}
function HashBytes([byte[]]$Bytes){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
function NoAlias([string]$Path){
 $item=Get-Item -LiteralPath $Path -Force
 while($null -ne $item){if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Aliased input refused'};$item=$item.Parent}
}
NoAlias $InputDirectory
if(Test-Path -LiteralPath $OutputPath){throw 'Existing crypto output refused'}
NoAlias (Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath)))
$key=$null;$plain=$null;$aes=$null
try{
 if($Action -in @('decrypt','bootstrap')){
  $bootstrap=$Action -eq 'bootstrap'
  if($bootstrap){
   $key=[Convert]::FromBase64String($env:DEVUNIT_BOOTSTRAP_KEY)
   Remove-Item Env:DEVUNIT_BOOTSTRAP_KEY
  }else{
   $key=[Convert]::FromBase64String($env:DEVUNIT_SOURCE_KEY)
   Remove-Item Env:DEVUNIT_SOURCE_KEY
  }
  if($key.Length -ne 32){throw 'Invalid source key'}
  $stem=if($bootstrap){'bootstrap'}else{'source'}
  $cipherPath=Join-Path $InputDirectory ($stem+'.cipher');$envelopePath=Join-Path $InputDirectory ($stem+'-envelope.json')
  NoAlias $cipherPath;NoAlias $envelopePath
  if((Get-Item -LiteralPath $cipherPath).Length -gt 134217728 -or (Get-Item -LiteralPath $envelopePath).Length -gt 8192){throw 'Input transport limit'}
  $e=Get-Content -LiteralPath $envelopePath -Raw | ConvertFrom-Json
  if($bootstrap){
   $commit='709c62ba7c1dc27588b1608ef1fc3fed5ec2c232'
   $tree='55e52f37023f971a89ae32fb876a369fe379da15'
   $digest='1e7b512be3f640563cd3a08854793dfa01da3f5213ad13cef6bc6c665e51d0c9'
   $format='leadya-private-unit-bootstrap/v1'
   $aad="$format|$commit|$tree|$digest|$RedTree|$GreenTree|$ZipSha256"
   if($e.bootstrap_commit -cne $commit -or $e.bootstrap_tree -cne $tree -or (Get-Item -LiteralPath $cipherPath).Length -gt 4194304){throw 'Bootstrap identity or size mismatch'}
  }else{
   $digest=$ZipSha256;$format='leadya-private-unit-source/v1'
   $aad="$format|$RedTree|$ZipSha256"
  }
  if($e.format -cne $format -or $e.aad_utf8 -cne $aad -or $e.red_tree -cne $RedTree -or $e.plaintext_sha256 -cne $digest){throw 'Input envelope identity mismatch'}
  $cipher=[IO.File]::ReadAllBytes($cipherPath)
  if((HashBytes $cipher) -cne $e.cipher_sha256){throw 'Input cipher digest mismatch'}
  $nonce=[Convert]::FromBase64String($e.nonce_base64);$tag=[Convert]::FromBase64String($e.tag_base64)
  if($nonce.Length -ne 12 -or $tag.Length -ne 16){throw 'Invalid GCM parameters'}
  $plain=[byte[]]::new($cipher.Length);$aes=[Security.Cryptography.AesGcm]::new($key,16)
  $aes.Decrypt($nonce,$cipher,$tag,$plain,[Text.Encoding]::UTF8.GetBytes($aad))
  if((HashBytes $plain) -cne $digest){throw 'Plaintext source digest mismatch'}
  [IO.File]::WriteAllBytes($OutputPath,$plain)
 }else{
  $key=[Convert]::FromBase64String($env:LEADYA_RESULT_KEY)
  Remove-Item Env:LEADYA_RESULT_KEY
  if($key.Length -ne 32){throw 'Invalid result key'}
  if($env:GITHUB_SHA -cnotmatch '^[0-9a-f]{40}$' -or $env:GITHUB_RUN_ID -notmatch '^\d+$'){throw 'Missing immutable run identity'}
  $allowed=@('.json','.log','.xml','.txt')
  $root=(Resolve-Path -LiteralPath $InputDirectory).Path;$total=0L;$count=0
  foreach($file in Get-ChildItem -LiteralPath $root -Recurse -Force){
   NoAlias $file.FullName
   if(-not $file.PSIsContainer){$count++;$total+=$file.Length;if($file.Extension -notin $allowed -or $file.Length -gt 67108864 -or $total -gt 268435456 -or $count -gt 1500){throw 'Result closure limit'}}
  }
  $zip=Join-Path $env:RUNNER_TEMP 'leadya-unit-result-private.zip'
  if(Test-Path -LiteralPath $zip){throw 'Existing result zip refused'}
  Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip -CompressionLevel Optimal
  $plain=[IO.File]::ReadAllBytes($zip);$nonce=[Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
  $cipher=[byte[]]::new($plain.Length);$tag=[byte[]]::new(16)
  $aad="leadya-private-unit-result/v1|$RedTree|$GreenTree|$ZipSha256|$env:GITHUB_SHA|$env:GITHUB_RUN_ID"
  $aes=[Security.Cryptography.AesGcm]::new($key,16);$aes.Encrypt($nonce,$plain,$cipher,$tag,[Text.Encoding]::UTF8.GetBytes($aad))
  New-Item -ItemType Directory -Path $OutputPath | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $OutputPath 'result.cipher'),$cipher)
  [ordered]@{format='leadya-private-unit-result/v1';nonce_base64=[Convert]::ToBase64String($nonce);tag_base64=[Convert]::ToBase64String($tag);aad_utf8=$aad;cipher_sha256=(HashBytes $cipher);plaintext_sha256=(HashBytes $plain);red_tree=$RedTree;green_tree=$GreenTree;source_zip_sha256=$ZipSha256;workflow_commit=$env:GITHUB_SHA;workflow_run_id=$env:GITHUB_RUN_ID} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputPath 'result-envelope.json') -Encoding utf8
 }
}finally{
 if($null -ne $aes){$aes.Dispose()}
 if($null -ne $key){[Array]::Clear($key,0,$key.Length)}
 if($null -ne $plain){[Array]::Clear($plain,0,$plain.Length)}
}
