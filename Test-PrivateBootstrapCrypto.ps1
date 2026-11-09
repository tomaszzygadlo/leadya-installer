param([Parameter(Mandatory)][string]$Archive,
      [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $OutputDirectory){throw 'Existing test output refused'}
$digest='1e7b512be3f640563cd3a08854793dfa01da3f5213ad13cef6bc6c665e51d0c9'
if((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest){throw 'Expected original pinned bootstrap'}
$root=(New-Item -ItemType Directory -Path $OutputDirectory).FullName
$inputDir=(New-Item -ItemType Directory -Path (Join-Path $root 'input')).FullName
$key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$plain=[IO.File]::ReadAllBytes($Archive)
$red='4f2ea6ca180a9c5b15e989dba1cb18b58166f8fe'
$green='3a6aed45056493a4a9f7741aaa581f9287c79eee'
$zip='27cafa3f0728fad79454083fa0e92d9f55dd6ee5d09096684cc62e5b0f519836'
$commit='709c62ba7c1dc27588b1608ef1fc3fed5ec2c232'
$tree='55e52f37023f971a89ae32fb876a369fe379da15'
$aad="leadya-private-unit-bootstrap/v1|$commit|$tree|$digest|$red|$green|$zip"
$nonce=[Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
$cipher=[byte[]]::new($plain.Length);$tag=[byte[]]::new(16)
$aes=[Security.Cryptography.AesGcm]::new($key,16)
try{$aes.Encrypt($nonce,$plain,$cipher,$tag,[Text.Encoding]::UTF8.GetBytes($aad))}finally{$aes.Dispose()}
$base=@{format='leadya-private-unit-bootstrap/v1';bootstrap_commit=$commit;bootstrap_tree=$tree;red_tree=$red;plaintext_sha256=$digest;aad_utf8=$aad;nonce_base64=[Convert]::ToBase64String($nonce);tag_base64=[Convert]::ToBase64String($tag);cipher_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cipher)).ToLowerInvariant()}
$results=[Collections.Generic.List[string]]::new()
try{
 foreach($case in @('valid','wrong-key','wrong-tag','wrong-aad','wrong-commit','wrong-tree','wrong-digest','oversize')){
  $e=$base.Clone();$bytes=[byte[]]$cipher.Clone();$env:DEVUNIT_BOOTSTRAP_KEY=[Convert]::ToBase64String($key)
  switch($case){
   'wrong-key' {$env:DEVUNIT_BOOTSTRAP_KEY=[Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))}
   'wrong-tag' {$e.tag_base64=[Convert]::ToBase64String([byte[]]::new(16))}
   'wrong-aad' {$e.aad_utf8+='-wrong'}
   'wrong-commit' {$e.bootstrap_commit='0'*40}
   'wrong-tree' {$e.bootstrap_tree='0'*40}
   'wrong-digest' {$e.plaintext_sha256='0'*64}
   'oversize' {$bytes=[byte[]]::new(4194305)}
  }
  [IO.File]::WriteAllBytes((Join-Path $inputDir 'bootstrap.cipher'),$bytes)
  $e | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $inputDir 'bootstrap-envelope.json') -Encoding utf8
  $output=Join-Path $root ($case+'.tar.xz');$failed=$false
  try{ & (Join-Path $PSScriptRoot 'private_unit_crypto.ps1') -Action bootstrap -InputDirectory $inputDir -OutputPath $output -RedTree $red -GreenTree $green -ZipSha256 $zip }catch{$failed=$true}
  if($case -eq 'valid'){
   if($failed -or (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest){throw 'Positive authenticated bootstrap failed'}
  }elseif(-not $failed -or (Test-Path -LiteralPath $output)){throw ('Invalid input produced plaintext: '+$case)}
  if(Test-Path Env:DEVUNIT_BOOTSTRAP_KEY){throw 'Bootstrap key retained in environment'}
  $results.Add($case)
 }
 @{passed=$results.ToArray();failed=0;application_tests='NOT_RUN'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'crypto-guards.json') -Encoding utf8
}finally{
 Remove-Item Env:DEVUNIT_BOOTSTRAP_KEY -ErrorAction SilentlyContinue
 [Array]::Clear($key,0,$key.Length);[Array]::Clear($plain,0,$plain.Length)
}
