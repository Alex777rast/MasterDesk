[CmdletBinding()]
param([string]$BuildScript=(Join-Path $PSScriptRoot 'Build-CustomWindows.ps1'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output=Join-Path $root ('artifacts/desktop-drop-patch-tests/'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $output | Out-Null
$scriptText=[IO.File]::ReadAllText($BuildScript).Replace("`r`n","`n")
# Independent minimal upstream 0.4.4 fixture: the three function boundaries
# and the original CF_HDROP block consumed by the build patch, not executed.
$fixture=@'
HRESULT DesktopDropTarget::DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
}
HRESULT DesktopDropTarget::DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
}
HRESULT DesktopDropTarget::Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {
                // we asked for the data as a HGLOBAL, so access it appropriately
                PVOID data = GlobalLock(stgmed.hGlobal);
                if (data != nullptr) {
                    auto files = DragQueryFile(reinterpret_cast<HDROP>(data), 0xFFFFFFFF, nullptr, 0);
                    for (unsigned int i = 0; i < files; ++i) {
                        TCHAR filename[MAX_PATH];
                        DragQueryFile(reinterpret_cast<HDROP>(data), i, filename, sizeof(TCHAR) * MAX_PATH);
                        std::wstring wide(filename);
                        std::string path = ws2s(wide);
                        std::cout << "done: " << path << std::endl;
                        list.push_back(flutter::EncodableValue(path));
                    }
                    GlobalUnlock(stgmed.hGlobal);
                }
}
'@
$fixture=$fixture.Replace("`r`n","`n")
$passed=0
foreach($scriptEnding in @("`n","`r`n")){
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($scriptText.Replace("`n",$scriptEnding),[ref]$tokens,[ref]$parseErrors)
    if($parseErrors){throw 'Build wrapper syntax error'}
    $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Initialize-DesktopDropWindowsPatch'},$false))
    if($functions.Count -ne 1){throw 'Patch function not uniquely found'}
    $functionText=$functions[0].Extent.Text
    foreach($pluginEnding in @("`n","`r`n")){
        $caseRoot=Join-Path $output ('case-'+$passed)
        $plugin=Join-Path $caseRoot 'plugin/windows/desktop_drop_plugin.cpp'
        $config=Join-Path $caseRoot 'flutter/.dart_tool/package_config.json'
        New-Item -ItemType Directory -Path (Split-Path $plugin),(Split-Path $config) | Out-Null
        [IO.File]::WriteAllText($plugin,$fixture.Replace("`n",$pluginEnding),[Text.UTF8Encoding]::new($false))
        @{packages=@(@{name='desktop_drop';rootUri=([Uri](Join-Path $caseRoot 'plugin/')).AbsoluteUri})}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $config -Encoding utf8
        & {
            param($ProjectRoot,$definition,$path,$ending)
            . ([ScriptBlock]::Create($definition))
            Initialize-DesktopDropWindowsPatch
            $first=[IO.File]::ReadAllText($path)
            if(([regex]::Matches($first,[regex]::Escape('(*pdwEffect & DROPEFFECT_COPY) != 0'))).Count -ne 3 -or
               $first.Contains('GlobalLock(stgmed.hGlobal)') -or
               -not $first.Contains('const auto drop = reinterpret_cast<HDROP>(stgmed.hGlobal);') -or
               $first.Contains("`r`r`n")){throw 'Patch content/newline regression'}
            if($ending -eq "`r`n" -and $first.Replace("`r`n",'').Contains("`n")){throw 'Mixed plugin newlines'}
            if($ending -eq "`n" -and $first.Contains("`r")){throw 'Plugin LF was not preserved'}
            $hash=(Get-FileHash -LiteralPath $path).Hash
            Initialize-DesktopDropWindowsPatch
            if((Get-FileHash -LiteralPath $path).Hash -cne $hash){throw 'Patch is not idempotent'}
            foreach($bad in @($first.Replace('const auto drop =','const auto changed ='),$fixture.Replace('HRESULT DesktopDropTarget::DragOver','HRESULT Changed::DragOver'))){
                [IO.File]::WriteAllText($path,$bad,[Text.UTF8Encoding]::new($false))
                $before=(Get-FileHash -LiteralPath $path).Hash
                $refused=$false
                try{Initialize-DesktopDropWindowsPatch}catch{$refused=$true}
                if(-not $refused -or (Get-FileHash -LiteralPath $path).Hash -cne $before){throw 'Unexpected upstream patch state was not refused without mutation'}
            }
        } $caseRoot $functionText $plugin $pluginEnding
        $passed++
    }
}
Write-Output ('PASS desktop_drop script/plugin LF-CRLF combinations='+$passed+'; idempotence and changed-upstream guards; evidence='+$output)
