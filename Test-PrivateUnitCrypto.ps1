param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('private-unit-crypto-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$checks=@();$key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$plain=[Text.Encoding]::UTF8.GetBytes('synthetic-input-no-application-source')
$red='1'*40;$green='2'*40
$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($plain)).ToLowerInvariant()
$aad="leadya-private-unit-source/v1|$red|$sha"
$nonce=[Security.Cryptography.RandomNumberGenerator]::GetBytes(12);$tag=[byte[]]::new(16);$cipher=[byte[]]::new($plain.Length)
$aes=[Security.Cryptography.AesGcm]::new($key,16)
try{
 $aes.Encrypt($nonce,$plain,$cipher,$tag,[Text.Encoding]::UTF8.GetBytes($aad))
 [IO.File]::WriteAllBytes((Join-Path $root 'source.cipher'),$cipher)
 $envelope=@{format='leadya-private-unit-source/v1';red_tree=$red;plaintext_sha256=$sha;aad_utf8=$aad;nonce_base64=[Convert]::ToBase64String($nonce);tag_base64=[Convert]::ToBase64String($tag);cipher_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cipher)).ToLowerInvariant()}
 $envelope | ConvertTo-Json | Set-Content (Join-Path $root 'source-envelope.json')
 $env:DEVUNIT_SOURCE_KEY=[Convert]::ToBase64String($key)
 & (Join-Path $PSScriptRoot 'private_unit_crypto.ps1') -Action decrypt -InputDirectory $root -OutputPath (Join-Path $root 'good.zip') -RedTree $red -GreenTree $green -ZipSha256 $sha
 if([IO.File]::ReadAllText((Join-Path $root 'good.zip')) -cne 'synthetic-input-no-application-source'){throw 'Decrypt roundtrip failed'}
 $checks+='authenticated-roundtrip'
 foreach($kind in @('cipher','tag','aad')){
  $bad=@{};foreach($name in $envelope.Keys){$bad[$name]=$envelope[$name]}
  $badCipher=[byte[]]$cipher.Clone()
  if($kind -eq 'cipher'){$badCipher[0]=$badCipher[0] -bxor 1}
  if($kind -eq 'tag'){$bad.tag_base64=[Convert]::ToBase64String([byte[]]::new(16))}
  if($kind -eq 'aad'){$bad.aad_utf8+='tampered'}
  $bad | ConvertTo-Json | Set-Content (Join-Path $root 'source-envelope.json')
  [IO.File]::WriteAllBytes((Join-Path $root 'source.cipher'),$badCipher)
  $env:DEVUNIT_SOURCE_KEY=[Convert]::ToBase64String($key)
  $out=Join-Path $root ($kind+'.zip');$refused=$false
  try{& (Join-Path $PSScriptRoot 'private_unit_crypto.ps1') -Action decrypt -InputDirectory $root -OutputPath $out -RedTree $red -GreenTree $green -ZipSha256 $sha}catch{$refused=$true}
  if(-not $refused -or (Test-Path -LiteralPath $out)){throw 'Tampered input accepted'}
  $checks+='tampered-'+$kind+'-refused-before-plaintext'
 }
 @{status='PASS';checks=$checks} | ConvertTo-Json | Set-Content -LiteralPath $Output
}finally{
 $aes.Dispose();[Array]::Clear($key,0,$key.Length);Remove-Item Env:DEVUNIT_SOURCE_KEY -ErrorAction SilentlyContinue
 if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force}
}
