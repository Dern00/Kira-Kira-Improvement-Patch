Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:Owner='KiraKiraImprovementPatch1'
$script:Names=@('data01000.arc','ipl._bp','KiraMono.ttf','Launch Kira Kira.cmd','KiraKira_Improvement_Launcher.ps1')
function Invoke-TestHook { param($Name) }
function Get-Sha($Path) {
    $stream=[IO.File]::OpenRead($Path);$sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose();$stream.Dispose() }
}
function Assert-PlainPath($Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while($cursor) {
        if(Test-Path -LiteralPath $cursor) {
            if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked folders or files are not supported. Select the actual game folder.' }
        }
        $parent=[IO.Directory]::GetParent($cursor)
        if($null -eq $parent) { break }; $cursor=$parent.FullName
    }
}
function Get-GameRoot($Path) {
    if(-not $Path) { throw 'No game folder selected.' }
    $root=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    Assert-PlainPath $root
    if(-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'The selected folder does not exist.' }
    if(-not (Test-Path -LiteralPath (Join-Path $root 'BGI.exe') -PathType Leaf)) { throw 'Select the Kira Kira folder containing BGI.exe.' }
    foreach($name in $script:Names) { Assert-PlainPath (Join-Path $root $name) }
    Assert-PlainPath (Join-Path $root 'KiraKira_Improvement_Backup')
    return $root
}
function Select-GameFolder {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog=New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description='Kira Kira Improvement Patch - select the English Standard Edition folder containing BGI.exe. Close the game first.'
    $dialog.ShowNewFolderButton=$false
    try { if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath } }
    finally { $dialog.Dispose() }
    return $null
}
function Assert-Closed($Root) {
    foreach($p in @(Get-Process -Name BGI -ErrorAction SilentlyContinue)) {
        try { $exe=$p.MainModule.FileName } catch { throw 'Close all BGI games before installing or uninstalling.' }
        if(-not $exe -or $exe -eq (Join-Path $Root 'BGI.exe')) { throw 'Close Kira Kira before installing or uninstalling.' }
    }
    foreach($name in @('data01000.arc','ipl._bp')) {
        $path=Join-Path $Root $name
        $stream=[IO.File]::Open($path,'Open','ReadWrite','None');$stream.Dispose()
    }
}
function Write-JsonAtomic($Path,$Value) {
    $temp=$Path+'.tmp'
    Assert-PlainPath $temp
    [IO.File]::WriteAllText($temp,($Value | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp,$Path,[NullString]::Value) } else { [IO.File]::Move($temp,$Path) }
}
function Set-FileAtomic($Source,$Target) {
    $temp=$Target+'.kip-'+[Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::Copy($Source,$temp,$false)
        if(Test-Path -LiteralPath $Target) { [IO.File]::Replace($temp,$Target,[NullString]::Value) } else { [IO.File]::Move($temp,$Target) }
    } finally { if(Test-Path -LiteralPath $temp) { [IO.File]::Delete($temp) } }
}
function Initialize-Delta {
    if('KiraPatchDelta' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
public static class KiraPatchDelta {
  static bool Match(byte[] hash,byte[] header,int offset) {
    for(int i=0;i<32;i++) if(hash[i]!=header[offset+i]) return false; return true;
  }
  public static byte[] Apply(byte[] original, byte[] patch) {
    if(patch.Length<76 || System.Text.Encoding.ASCII.GetString(patch,0,8)!="KKIP0001") throw new Exception("Invalid patch file.");
    int length=BitConverter.ToInt32(patch,8);
    if(length<1 || length>33554432) throw new Exception("Invalid patch length.");
    using(var sha=SHA256.Create()) {
      if(!Match(sha.ComputeHash(original),patch,12)) throw new Exception("This patch does not match the original game file.");
      byte[] result=new byte[length];
      using(var input=new MemoryStream(patch,76,patch.Length-76))
      using(var gzip=new GZipStream(input,CompressionMode.Decompress)) {
        int done=0;
        while(done<length) { int n=gzip.Read(result,done,length-done);if(n==0) throw new Exception("Incomplete patch data.");done+=n; }
        if(gzip.ReadByte()!=-1) throw new Exception("Unexpected patch data.");
      }
      for(int i=0;i<Math.Min(length,original.Length);i++) result[i]^=original[i];
      if(!Match(sha.ComputeHash(result),patch,44)) throw new Exception("The patched file failed verification.");
      return result;
    }
  }
}
'@
}
function Read-Package($Package) {
    $manifest=Get-Content -LiteralPath (Join-Path $Package 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if($manifest.owner -ne $script:Owner -or $manifest.version -ne '1.1') { throw 'Unsupported patch package.' }
    $names=@($manifest.files | ForEach-Object { $_.name })
    if($names.Count -ne $script:Names.Count -or @(Compare-Object $names $script:Names).Count -ne 0 -or @($names | Select-Object -Unique).Count -ne $names.Count) { throw 'Invalid patch file list.' }
    for($i=0;$i -lt $names.Count;$i++) { if($names[$i] -cne $script:Names[$i]) { throw 'Invalid patch file order.' } }
    foreach($f in $manifest.files) {
        $expected=if($f.name -in @('data01000.arc','ipl._bp')) { 'payload/'+$f.name+'.kkd' } else { 'payload/'+$f.name }
        if($f.payload -cne $expected -or $f.sha256 -notmatch '^[a-f0-9]{64}$' -or $f.payloadSha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid patch manifest.' }
        $path=Join-Path $Package $f.payload;Assert-PlainPath $path
        if((Get-Sha $path) -ne $f.payloadSha256) { throw ('Patch files are damaged. Extract the ZIP again: '+$f.name) }
        if($f.PSObject.Properties['previousPayload']) {
            if($f.name -cne 'ipl._bp' -or $f.previousPayload -cne 'payload/ipl._bp.v10.kkd' -or $f.previousSha256 -notmatch '^[a-f0-9]{64}$' -or $f.previousPayloadSha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid upgrade manifest.' }
            $upgrade=Join-Path $Package $f.previousPayload;Assert-PlainPath $upgrade
            if((Get-Sha $upgrade) -ne $f.previousPayloadSha256) { throw 'Upgrade patch files are damaged. Extract the ZIP again.' }
        }
    }
    return $manifest
}
function Read-Receipt($Root) {
    $backup=Join-Path $Root 'KiraKira_Improvement_Backup'
    $path=Join-Path $backup 'receipt.json'
    if(-not (Test-Path -LiteralPath $backup)) { return $null }
    Assert-PlainPath $path
    if(-not (Test-Path -LiteralPath $path)) { throw 'An unrecognized backup folder exists. Keep it safe and rename it before installing.' }
    $r=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if($r.owner -ne $script:Owner -or $r.id -notmatch '^[a-f0-9]{32}$' -or $r.game -ne $Root -or $r.files.Count -ne $script:Names.Count) { throw 'Unrecognized installation record. No files changed.' }
    for($i=0;$i -lt $script:Names.Count;$i++) {
        $f=$r.files[$i]
        if($f.name -cne $script:Names[$i] -or $f.after -notmatch '^[a-f0-9]{64}$' -or ($f.existed -and $f.before -notmatch '^[a-f0-9]{64}$')) { throw 'Invalid installation record.' }
        Assert-PlainPath (Join-Path $backup ($r.id+'/'+$i+'.before'))
    }
    return $r
}
function Restore-Receipt($Root,$Receipt) {
    $backup=Join-Path $Root 'KiraKira_Improvement_Backup'
    $receiptPath=Join-Path $backup 'receipt.json'
    # Verify the entire restore before touching any live file.
    for($i=0;$i -lt $Receipt.files.Count;$i++) {
        $f=$Receipt.files[$i];$target=Join-Path $Root $f.name
        if($f.existed) {
            $copy=Join-Path $backup ($Receipt.id+'/'+$i+'.before')
            if((Get-Sha $copy) -ne $f.before) { throw ('Backup verification failed: '+$f.name) }
        }
        if(Test-Path -LiteralPath $target) {
            $hash=Get-Sha $target
            if($hash -ne $f.after -and (-not $f.existed -or $hash -ne $f.before)) { throw ('A file has been changed since installation. It was left untouched: '+$f.name) }
        } elseif($f.existed) { throw ('A game file is missing. Restore was stopped: '+$f.name) }
    }
    $Receipt.state='restoring';Write-JsonAtomic $receiptPath $Receipt
    for($i=0;$i -lt $Receipt.files.Count;$i++) {
        $f=$Receipt.files[$i];$target=Join-Path $Root $f.name
        if($f.existed) { Set-FileAtomic (Join-Path $backup ($Receipt.id+'/'+$i+'.before')) $target }
        elseif(Test-Path -LiteralPath $target) { [IO.File]::Delete($target) }
    }
    $Receipt.state='restored';Write-JsonAtomic $receiptPath $Receipt
}
function Get-PatchedBytes($Root,$Package,$File) {
    $target=Join-Path $Root $File.name;$exists=Test-Path -LiteralPath $target -PathType Leaf
    $before=if($exists) { Get-Sha $target } else { $null }
    if($File.name -in @('data01000.arc','ipl._bp')) {
        if($before -eq $File.sha256) { return ,([IO.File]::ReadAllBytes($target)) }
        $delta=$null
        if($before -eq $File.baseSha256) { $delta=$File.payload }
        elseif($File.PSObject.Properties['previousSha256'] -and $before -eq $File.previousSha256) { $delta=$File.previousPayload }
        if(-not $delta) { throw ('Unsupported or modified game file: '+$File.name+'. Use the English Standard Edition.') }
        Initialize-Delta
        return ,([KiraPatchDelta]::Apply([IO.File]::ReadAllBytes($target),[IO.File]::ReadAllBytes((Join-Path $Package $delta))))
    }
    if($exists -and $before -ne $File.sha256) { throw ('A different file already uses this patch filename: '+$File.name) }
    return ,([IO.File]::ReadAllBytes((Join-Path $Package $File.payload)))
}
function Restore-Upgrade($Root,$Receipt) {
    $u=$Receipt.upgrade
    if($u.id -notmatch '^[a-f0-9]{32}$' -or $u.hashes.Count -ne $script:Names.Count) { throw 'Invalid upgrade recovery record.' }
    $backup=Join-Path $Root 'KiraKira_Improvement_Backup';$run=Join-Path $backup $u.id
    for($i=0;$i -lt $script:Names.Count;$i++) {
        $copy=Join-Path $run ($i.ToString()+'.previous');Assert-PlainPath $copy
        if($u.hashes[$i] -notmatch '^[a-f0-9]{64}$' -or (Get-Sha $copy) -ne $Receipt.files[$i].after) { throw 'Upgrade recovery backup verification failed.' }
        $current=Get-Sha (Join-Path $Root $script:Names[$i])
        if($current -ne $Receipt.files[$i].after -and $current -ne $u.hashes[$i]) { throw ('A file changed during upgrade; recovery stopped: '+$script:Names[$i]) }
    }
    for($i=0;$i -lt $script:Names.Count;$i++) { Set-FileAtomic (Join-Path $run ($i.ToString()+'.previous')) (Join-Path $Root $script:Names[$i]) }
    $Receipt.PSObject.Properties.Remove('upgrade');$Receipt.state='committed'
    Write-JsonAtomic (Join-Path $backup 'receipt.json') $Receipt
}
function Invoke-PatchUpgrade($Root,$Package,$Manifest,$Receipt) {
    $outputs=@()
    foreach($f in $Manifest.files) { $outputs+=,(Get-PatchedBytes $Root $Package $f) }
    $backup=Join-Path $Root 'KiraKira_Improvement_Backup';$id=[Guid]::NewGuid().ToString('N');$run=Join-Path $backup $id
    [void][IO.Directory]::CreateDirectory($run)
    for($i=0;$i -lt $script:Names.Count;$i++) {
        $copy=Join-Path $run ($i.ToString()+'.previous')
        [IO.File]::Copy((Join-Path $Root $script:Names[$i]),$copy,$false)
        if((Get-Sha $copy) -ne $Receipt.files[$i].after) { throw 'Upgrade backup failed. Game unchanged.' }
        $next=Join-Path $run ($i.ToString()+'.next');[IO.File]::WriteAllBytes($next,$outputs[$i])
        if((Get-Sha $next) -ne $Manifest.files[$i].sha256) { throw 'Upgrade output verification failed. Game unchanged.' }
    }
    $Receipt | Add-Member -NotePropertyName upgrade -NotePropertyValue @{id=$id;hashes=@($Manifest.files | ForEach-Object {$_.sha256})}
    $Receipt.state='upgrading';$receiptPath=Join-Path $backup 'receipt.json';Write-JsonAtomic $receiptPath $Receipt
    try {
        for($i=0;$i -lt $script:Names.Count;$i++) {
            Set-FileAtomic (Join-Path $run ($i.ToString()+'.next')) (Join-Path $Root $script:Names[$i])
            Invoke-TestHook ('UpgradeAfterReplace'+$i)
        }
        foreach($f in $Manifest.files) { if((Get-Sha (Join-Path $Root $f.name)) -ne $f.sha256) { throw 'Upgrade verification failed.' } }
        $done=$Receipt | ConvertTo-Json -Depth 12 | ConvertFrom-Json
        for($i=0;$i -lt $script:Names.Count;$i++) { $done.files[$i].after=$Manifest.files[$i].sha256 }
        $done.version=$Manifest.version;$done.state='committed';$done.PSObject.Properties.Remove('upgrade')
        Write-JsonAtomic $receiptPath $done
    } catch { $problem=$_;Restore-Upgrade $Root $Receipt;throw ('Upgrade failed and the previous patch was restored. '+$problem.Exception.Message) }
    Write-Output 'Updated successfully. Launch BGI.exe normally. Saves and original uninstall backups were preserved.'
}
function Invoke-PatchInstallCore($GamePath,$PackageRoot) {
    $root=Get-GameRoot $GamePath;Assert-Closed $root
    $package=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    if($root -eq $package -or $package.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Extract the patch outside the game folder, then run Install.cmd.' }
    $m=Read-Package $package
    if((Get-Sha (Join-Path $root 'BGI.exe')) -ne $m.engineSha256) { throw 'This game executable is not the supported English Standard Edition.' }
    $old=Read-Receipt $root
    if($null -ne $old -and $old.state -eq 'upgrading') { Restore-Upgrade $root $old;throw 'An interrupted upgrade was rolled back safely. Run Install.cmd again.' }
    if($null -ne $old -and $old.state -notin @('committed','restored')) {
        Restore-Receipt $root $old
        throw 'An interrupted installation was rolled back safely. Run Install.cmd again to install.'
    }
    if($null -ne $old -and $old.state -eq 'committed') {
        foreach($f in $old.files) { if((Get-Sha (Join-Path $root $f.name)) -ne $f.after) { throw ('An installed file has changed: '+$f.name+'. Uninstall or restore it before reinstalling.') } }
        $changed=$false
        for($i=0;$i -lt $script:Names.Count;$i++) { if($old.files[$i].after -ne $m.files[$i].sha256) { $changed=$true } }
        if($changed) { Invoke-PatchUpgrade $root $package $m $old;return }
        Write-Output 'Kira Kira Improvement Patch is already installed. Saves were not changed.';return
    }
    # Build every output in memory before creating backups or touching the game.
    $outputs=@();$records=@()
    foreach($f in $m.files) {
        $target=Join-Path $root $f.name;$exists=Test-Path -LiteralPath $target -PathType Leaf
        $before=if($exists) { Get-Sha $target } else { $null }
        $bytes=Get-PatchedBytes $root $package $f
        $outputs+=,[byte[]]$bytes
        $records+=@{name=$f.name;existed=[bool]$exists;before=$before;after=$f.sha256}
    }
    $id=[Guid]::NewGuid().ToString('N');$backup=Join-Path $root 'KiraKira_Improvement_Backup';$run=Join-Path $backup $id
    [void][IO.Directory]::CreateDirectory($run)
    $receipt=@{owner=$script:Owner;version=$m.version;game=$root;id=$id;state='prepared';files=$records}
    for($i=0;$i -lt $records.Count;$i++) {
        if($records[$i].existed) {
            [IO.File]::Copy((Join-Path $root $records[$i].name),(Join-Path $run ($i.ToString()+'.before')),$false)
            if((Get-Sha (Join-Path $run ($i.ToString()+'.before'))) -ne $records[$i].before) { throw 'Backup verification failed. The game was not changed.' }
        }
        [IO.File]::WriteAllBytes((Join-Path $run ($i.ToString()+'.after')),$outputs[$i])
        if((Get-Sha (Join-Path $run ($i.ToString()+'.after'))) -ne $records[$i].after) { throw 'Output verification failed. The game was not changed.' }
    }
    Write-JsonAtomic (Join-Path $backup 'receipt.json') $receipt
    try {
        Invoke-TestHook 'BeforeReplace'
        for($i=0;$i -lt $records.Count;$i++) {
            Set-FileAtomic (Join-Path $run ($i.ToString()+'.after')) (Join-Path $root $records[$i].name)
            Invoke-TestHook ('AfterReplace'+$i)
        }
        foreach($f in $records) { if((Get-Sha (Join-Path $root $f.name)) -ne $f.after) { throw 'Installed-file verification failed.' } }
        $receipt.state='committed';Write-JsonAtomic (Join-Path $backup 'receipt.json') $receipt
    } catch {
        $problem=$_
        Restore-Receipt $root $receipt
        throw ('Installation failed and was rolled back. '+$problem.Exception.Message)
    }
    Write-Output 'Installed successfully. Launch BGI.exe normally. Existing saves were left unchanged.'
}
function Invoke-PatchUninstallCore($GamePath) {
    $root=Get-GameRoot $GamePath;Assert-Closed $root;$r=Read-Receipt $root
    if($null -ne $r -and $r.state -eq 'upgrading') { Restore-Upgrade $root $r;$r=Read-Receipt $root }
    if($null -eq $r -or $r.state -eq 'restored') { Write-Output 'No active installation found. Nothing changed.';return }
    Restore-Receipt $root $r
    Write-Output 'Patch removed. Files from before installation were restored. Saves were left unchanged.'
}
function Invoke-WithGameLock($GamePath,$Action) {
    $root=Get-GameRoot $GamePath
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToUpperInvariant())))).Replace('-','') } finally { $sha.Dispose() }
    $mutex=[Threading.Mutex]::new($false,('Local\KiraKiraImprovement_'+$key));$locked=$false
    try {
        try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if(-not $locked) { throw 'Another installer is working on this game folder. Wait for it to finish.' }
        & $Action
    } finally { if($locked) { $mutex.ReleaseMutex() };$mutex.Dispose() }
}
function Invoke-PatchInstall($GamePath,$PackageRoot) {
    Invoke-WithGameLock $GamePath { Invoke-PatchInstallCore $GamePath $PackageRoot }
}
function Invoke-PatchUninstall($GamePath) {
    Invoke-WithGameLock $GamePath { Invoke-PatchUninstallCore $GamePath }
}

