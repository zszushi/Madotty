param(
    [Parameter(Mandatory)][string]$ExePath,
    [Parameter(Mandatory)][string]$ResourcesPath,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('opaque','transparent','light','drag','split-drag','progress','all')][string]$Case='all'
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$nativeReferences=@('System.Drawing.Common','System.Drawing.Primitives','System.Private.Windows.Core','System.Runtime.InteropServices','System.ComponentModel.Primitives','System.Collections')
if(Test-Path (Join-Path $PSHOME 'System.Private.Windows.GdiPlus.dll')){$nativeReferences+='System.Private.Windows.GdiPlus'}
Add-Type -ReferencedAssemblies $nativeReferences -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
public static class TabBarTestNative {
    public static int ProcessId;
    [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;public int Width {get{return Right-Left;}}}
    [StructLayout(LayoutKind.Sequential)] public struct Point {public int X,Y;public Point(int x,int y){X=x;Y=y;}}
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo {public int Size;public Rect Bounds,Work;public uint Flags;}
    delegate bool EnumProc(IntPtr hwnd,IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback,IntPtr parameter);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent,EnumProc callback,IntPtr parameter);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd,StringBuilder name,int count);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd,int index);
    [DllImport("user32.dll",SetLastError=true)] static extern bool PostMessage(IntPtr hwnd,uint message,IntPtr wparam,IntPtr lparam);
    [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint message,IntPtr wparam,IntPtr lparam,uint flags,uint timeout,out IntPtr result);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd,out Rect rect);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd,IntPtr dc,uint flags);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hwnd,IntPtr after,int x,int y,int width,int height,uint flags);
    [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr hwnd,ref Point point);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hwnd,ref Point point);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd,uint flags);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor,ref MonitorInfo info);
    public static IntPtr Check(IntPtr hwnd){uint owner;if(hwnd==IntPtr.Zero||GetWindowThreadProcessId(hwnd,out owner)==0||owner!=(uint)ProcessId)throw new Exception("Refusing a window not owned by the test process");return hwnd;}
    public static IntPtr[] Find(string cls,IntPtr parent,bool visible){
        var found=new List<IntPtr>();
        EnumProc callback=(hwnd,parameter)=>{uint owner;GetWindowThreadProcessId(hwnd,out owner);var name=new StringBuilder(256);GetClassName(hwnd,name,256);bool live=cls!="GhosttyTerminal"||GetWindowLongPtr(hwnd,-21)!=IntPtr.Zero;if(owner==(uint)ProcessId&&live&&name.ToString()==cls&&(!visible||IsWindowVisible(hwnd)))found.Add(hwnd);return true;};
        if(parent==IntPtr.Zero)EnumWindows(callback,IntPtr.Zero);else EnumChildWindows(Check(parent),callback,IntPtr.Zero);
        return found.ToArray();
    }
    public static long Message(IntPtr hwnd,uint message,long wparam,IntPtr lparam){IntPtr result;if(SendMessageTimeout(Check(hwnd),message,new IntPtr(wparam),lparam,3,2000,out result)==IntPtr.Zero)throw new TimeoutException("Owned window did not respond to message "+message);return result.ToInt64();}
    public static void Post(IntPtr hwnd,uint message,long wparam,long lparam){if(!PostMessage(Check(hwnd),message,new IntPtr(wparam),new IntPtr(lparam)))throw new Exception("PostMessage failed");}
    public static void Key(IntPtr hwnd,int key){Post(hwnd,0x100,key,1);Post(hwnd,0x101,key,0xC0000001);}
    public static void SelectPane(IntPtr pane){Click(pane,8,8);}
    public static string Text(IntPtr hwnd){var buffer=Marshal.AllocHGlobal(2048);try{long length=Message(hwnd,0x000D,1024,buffer);return Marshal.PtrToStringUni(buffer,(int)length);}finally{Marshal.FreeHGlobal(buffer);}}
    public static void SetText(IntPtr hwnd,string text){var buffer=Marshal.StringToHGlobalUni(text);try{Message(hwnd,0x000C,0,buffer);}finally{Marshal.FreeHGlobal(buffer);}}
    public static void Position(IntPtr top){SetThreadDpiAwarenessContext(new IntPtr(-4));if(!SetWindowPos(Check(top),IntPtr.Zero,30,30,900,680,0x54))throw new Exception("Positioning owned window failed");}
    public static Rect WindowBounds(IntPtr top){Rect rect;if(!GetWindowRect(Check(top),out rect))throw new Exception("GetWindowRect failed");return rect;}
    static Rect Client(IntPtr top){Rect rect;if(!GetClientRect(Check(top),out rect))throw new Exception("GetClientRect failed");return rect;}
    static long Coordinates(int x,int y){return unchecked((uint)((x&0xffff)|((y&0xffff)<<16)));}
    static void Click(IntPtr top,int x,int y){long point=Coordinates(x,y);Post(top,0x200,0,point);Post(top,0x201,1,point);Post(top,0x202,0,point);}
    public static void TabClick(IntPtr top,int index,int count){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;double width=(rect.Width-Math.Round(36*scale))/count;Click(top,(int)Math.Round((index+.5)*width),(int)Math.Round(16*scale));}
    public static void PlusClick(IntPtr top){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;Click(top,rect.Right-(int)Math.Round(18*scale),(int)Math.Round(16*scale));}
    public static void CloseTab(IntPtr top,int index,int count){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;double width=(rect.Width-Math.Round(36*scale))/count;Click(top,(int)Math.Round((index+1)*width-16*scale),(int)Math.Round(16*scale));}
    public static void RenameTab(IntPtr top,int index,int count){var rect=Client(top);double scale=GetDpiForWindow(Check(top))/96.0;double width=(rect.Width-Math.Round(36*scale))/count;int x=(int)Math.Round((index+.5)*width),y=(int)Math.Round(16*scale);Click(top,x,y);Post(top,0x203,1,Coordinates(x,y));Post(top,0x202,0,Coordinates(x,y));}
    static Point TabPoint(IntPtr top,int index,int count,double fraction){
        var rect=Client(top);
        double scale=GetDpiForWindow(Check(top))/96.0;
        double width=(rect.Width-2*Math.Round(32*scale))/count;
        return new Point((int)Math.Round((index+fraction)*width),(int)Math.Round(16*scale));
    }
    public static void Reorder(IntPtr top,int from,int to,int count){
        var start=TabPoint(top,from,count,0.5);
        var end=TabPoint(top,to,count,0.7);
        Post(top,0x201,1,Coordinates(start.X,start.Y));
        Post(top,0x200,1,Coordinates(end.X,end.Y));
        Post(top,0x202,0,Coordinates(end.X,end.Y));
    }
    public static Point TabScreenPoint(IntPtr top) {
        var point=TabPoint(top,0,1,0.25);
        if(!ClientToScreen(Check(top),ref point))throw new Exception("ClientToScreen failed");
        return point;
    }
    public static void HoldTab(IntPtr top) {
        var start=TabPoint(top,0,2,0.5);
        var next=TabPoint(top,0,2,0.9);
        Message(top,0x201,1,new IntPtr(Coordinates(start.X,start.Y)));
        Message(top,0x200,1,new IntPtr(Coordinates(next.X,next.Y)));
    }
    public static Point PositionForDrag(IntPtr top){
        SetThreadDpiAwarenessContext(new IntPtr(-4));
        var info=new MonitorInfo{Size=Marshal.SizeOf(typeof(MonitorInfo))};
        if(!GetMonitorInfo(MonitorFromWindow(Check(top),2),ref info))throw new Exception("GetMonitorInfo failed");
        var work=info.Work;
        int height=work.Bottom-work.Top;
        if(!SetWindowPos(Check(top),IntPtr.Zero,work.Left+24,work.Top+24,work.Width/2,height/2,0x14))
            throw new Exception("Positioning owned drag source failed");
        return new Point(work.Left+work.Width*3/4,work.Top+height/3);
    }
    public static void HoldOver(IntPtr top,int index,int count,Point screen){
        var start=TabPoint(top,index,count,0.5);
        if(!ScreenToClient(Check(top),ref screen))throw new Exception("ScreenToClient failed");
        Post(top,0x201,1,Coordinates(start.X,start.Y));
        Post(top,0x200,1,Coordinates(screen.X,screen.Y));
    }
    public static Point TabCenterOnScreen(IntPtr top,int index,int count){
        var point=TabPoint(top,index,count,0.5);
        if(!ClientToScreen(Check(top),ref point))throw new Exception("ClientToScreen failed");
        return point;
    }
    public static void DragAt(IntPtr top,Point screen,bool release){
        if(!ScreenToClient(Check(top),ref screen))throw new Exception("ScreenToClient failed");
        long point=Coordinates(screen.X,screen.Y);
        Message(top,release?0x202u:0x200u,release?0:1,new IntPtr(point));
    }
    public static void DropTab(IntPtr top,int index,int count,Point screen,bool cancel){
        HoldOver(top,index,count,screen);
        if(!ScreenToClient(Check(top),ref screen))throw new Exception("ScreenToClient failed");
        if(cancel)Post(top,0x001f,0,0);
        Post(top,0x202,0,Coordinates(screen.X,screen.Y));
    }
    public static void Capture(IntPtr top,string path){
        Rect rect;if(!GetWindowRect(Check(top),out rect))throw new Exception("GetWindowRect failed");
        using(var bitmap=new Bitmap(rect.Width,rect.Bottom-rect.Top)){
            PaintToBitmap(top,bitmap);
            bitmap.Save(path,ImageFormat.Png);
        }
    }
    static void PaintToBitmap(IntPtr top,Bitmap bitmap){
        using(var graphics=Graphics.FromImage(bitmap)){
            var dc=graphics.GetHdc();
            try{if(!PrintWindow(Check(top),dc,2))throw new Exception("PrintWindow failed");}
            finally{graphics.ReleaseHdc(dc);}
        }
    }
    public sealed class ProgressSample {
        public int Green {get;set;}
        public int GreenSegments {get;set;}
        public int Red {get;set;}
        public int Yellow {get;set;}
    }
    public static ProgressSample[] SampleProgress(IntPtr top,int count){
        var outer=WindowBounds(top);
        var origin=new Point(0,0);
        if(!ClientToScreen(Check(top),ref origin))throw new Exception("ClientToScreen failed");
        var result=new ProgressSample[count];
        int halfWidth=Scaled(top,40);
        int topY=origin.Y-outer.Top+Scaled(top,22);
        int bottomY=origin.Y-outer.Top+Scaled(top,31);
        using(var bitmap=new Bitmap(outer.Width,outer.Bottom-outer.Top)){
            PaintToBitmap(top,bitmap);
            for(int tab=0;tab<count;tab++){
                var sample=new ProgressSample();
                int center=origin.X-outer.Left+TabPoint(top,tab,count,0.5).X;
                for(int y=topY;y<bottomY;y++){
                    int green=0,red=0,yellow=0,segments=0,previous=0;
                    for(int x=center-halfWidth;x<center+halfWidth;x++){
                        int color=bitmap.GetPixel(x,y).ToArgb()&0xffffff;
                        if(color==0x00f560){green++;if(previous!=color)segments++;}
                        else if(color==0xff4364){red++;}
                        else if(color==0xffd063){yellow++;}
                        previous=color;
                    }
                    if(green>sample.Green){sample.Green=green;sample.GreenSegments=segments;}
                    sample.Red=Math.Max(sample.Red,red);
                    sample.Yellow=Math.Max(sample.Yellow,yellow);
                }
                result[tab]=sample;
            }
        }
        return result;
    }
    public static int Scaled(IntPtr top,double units){return (int)Math.Round(units*GetDpiForWindow(Check(top))/96.0);}
}
'@
New-Item -ItemType Directory -Force $OutputDirectory|Out-Null
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$work=Join-Path $env:TEMP ('ghostty-tab-bar-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work|Out-Null
# Stage a matching portable payload locally even when this script is called
# from a WSL checkout. UNC execution can trigger Windows security prompts.
$stagedExecutable=Join-Path $work 'ghostty-tab-bar-test.exe'
$stagedShare=Join-Path $work 'share'
try{
    $binaryDirectory=Split-Path -Parent ([IO.Path]::GetFullPath($ExePath))
    Copy-Item -LiteralPath $ExePath -Destination $stagedExecutable
    foreach($runtime in @('conpty.dll','OpenConsole.exe')){
        Copy-Item -LiteralPath (Join-Path $binaryDirectory $runtime) -Destination $work
    }
    # Compiled terminfo contains Unix symlinks that cannot be followed from
    # Windows. Match portable packaging and copy only the plain-text sentinel.
    foreach($relativePath in @('ghostty\themes','ghostty\shell-integration','terminfo\ghostty.terminfo','licenses\conpty\LICENSE.txt')){
        $destination=Join-Path $stagedShare $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force|Out-Null
        Copy-Item -LiteralPath (Join-Path $ResourcesPath $relativePath) -Destination $destination -Recurse
    }
}catch{
    Remove-Item -LiteralPath $work -Recurse -Force
    throw
}
$fixture=Join-Path $work 'terminal.ps1'
@'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new()
$keys=[Collections.Generic.List[string]]::new()
$statePath = Join-Path $env:GHOSTTY_TAB_TEST_STATE "$PID"
function Save-State {
    $json = @{Pid=$PID; Keys=$keys.ToArray()} | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText("$statePath.pending", $json)
    # Publish each snapshot once. A polling reader can keep the previous one open.
    [IO.File]::Move("$statePath.pending", ('{0}.{1:D10}.json' -f $statePath, $keys.Count))
}
function Update-Progress {
    if (-not [IO.File]::Exists($progressFile)) { return }
    $value = [IO.File]::ReadAllText($progressFile)
    [IO.File]::Delete($progressFile)
    [Console]::Write(([string][char]27) + ']9;4;' + $value + [char]7)
    [Console]::Out.Flush()
}
[Console]::Write("`e]2;tab-probe-$PID`a`e[2J`e[Htab-probe-$PID`r`n")
Save-State
$progressFile = Join-Path $env:GHOSTTY_TAB_TEST_STATE "$PID.progress"
while($true){
    if($env:GHOSTTY_TAB_TEST_PROGRESS){Update-Progress}
    if([Console]::KeyAvailable){$key=[Console]::ReadKey($true);if([int]$key.KeyChar -ge 32){$keys.Add($key.KeyChar.ToString());[Console]::Write("`r`nkeys: "+($keys -join ','));Save-State}}
    Start-Sleep -Milliseconds 20
}
'@|Set-Content -Encoding utf8 $fixture
$record=[ordered]@{Case=$Case;Status='failed';Executable=[IO.Path]::GetFullPath($ExePath);Runs=@();Checks=@();Captures=@();Errors=@()}
$runs=[Collections.Generic.List[object]]::new()
$current=$null
function Check($condition,$name,$metrics){$record.Checks+=@{Name=$name;Passed=[bool]$condition;Metrics=$metrics};if(-not $condition){throw $name}}
function Wait-For($run,[string]$name,[scriptblock]$condition){
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    do{
        if($run.Process.HasExited){throw "$name : process exited with code $($run.Process.ExitCode)"}
        try{if(& $condition){return}}catch{if($_.Exception.InnerException -isnot [TimeoutException]){throw}}
        Start-Sleep -Milliseconds 50
    }while([DateTime]::UtcNow -lt $deadline)
    throw "$name : timed out"
}
function Children($run,[bool]$visible=$true){return @([TabBarTestNative]::Find('GhosttyTerminal',$run.Top,$visible))}
function Shell-Pid($run){$title=[TabBarTestNative]::Text($run.Top);if($title -match '^tab-probe-(\d+)$'){return [int]$Matches[1]};return 0}
function State($run,[int]$pidValue){
    $latest = Get-ChildItem -LiteralPath $run.State -Filter "$pidValue.*.json" | Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { return [IO.File]::ReadAllText($latest.FullName) | ConvertFrom-Json }
}
function Screenshot($run,[string]$name){$path=Join-Path $OutputDirectory ($run.Name+'-'+$name+'.png');[TabBarTestNative]::Capture($run.Top,$path);$record.Captures+=@{Name=$name;Mode=$run.Name;Path=$path}}
function Start-Run([double]$opacity,[string]$name){
    $run=@{Name=$name;State=(Join-Path $work $name);Config=(Join-Path $work ($name+'.ghostty'))};New-Item -ItemType Directory $run.State|Out-Null
    $background=if($name -eq 'light'){'#ffffff'}else{'#1e1e2e'}
    $foreground=if($name -eq 'light'){'#1e1e2e'}else{'#ffffff'}
    @(('command = pwsh.exe -NoLogo -NoProfile -File "'+$fixture+'"'),('background-opacity = '+$opacity.ToString([Globalization.CultureInfo]::InvariantCulture)),('background = '+$background),('foreground = '+$foreground),'background-blur = false','font-family = Consolas','font-size = 14','window-show-tab-bar = always','shell-integration = none','confirm-close-surface = false','cursor-style-blink = false','auto-update = off','keybind = f9=new_tab','keybind = f4=next_tab','keybind = f8=new_split:right')|Set-Content -Encoding utf8 $run.Config
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$stagedExecutable;$start.WorkingDirectory=$work;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.Environment['GHOSTTY_RESOURCES_DIR']=Join-Path $stagedShare 'ghostty';$start.Environment['GHOSTTY_TAB_TEST_STATE']=$run.State
    if($name -eq 'progress'){
        @('progress-style = true','palette = 1=#ff4364','palette = 2=#00f560','palette = 3=#ffd063',
          'palette = 9=#ff4364','palette = 10=#00f560','palette = 11=#ffd063') | Add-Content -Encoding utf8 -LiteralPath $run.Config
        $start.Environment['GHOSTTY_TAB_TEST_PROGRESS']='1'
    }
    $start.ArgumentList.Add('--config-default-files=false');$start.ArgumentList.Add('--config-file='+$run.Config)
    $run.Process=[Diagnostics.Process]::Start($start);$runs.Add($run);$run.Stdout=$run.Process.StandardOutput.ReadToEndAsync();$run.Stderr=$run.Process.StandardError.ReadToEndAsync()
    [TabBarTestNative]::ProcessId=$run.Process.Id
    Wait-For $run 'initial native window' {$tops=@([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true));if($tops.Count -eq 1){$run.Top=$tops[0];return @(Children $run).Count -eq 1};return $false}
    [TabBarTestNative]::Position($run.Top)
    Wait-For $run 'initial terminal fixture' {(Shell-Pid $run) -ne 0}
    return $run
}

function Test-TabDrag($run){
    $first=@(Children $run)[0]
    $firstPid=Shell-Pid $run
    $drop=[TabBarTestNative]::PositionForDrag($run.Top)
    [TabBarTestNative]::Key($first,0x78)
    Wait-For $run 'second tab ready' {@(Children $run $false).Count -eq 2 -and (Shell-Pid $run) -notin 0,$firstPid}
    $second=@(Children $run)[0]
    $secondPid=Shell-Pid $run

    [TabBarTestNative]::HoldTab($run.Top)
    Screenshot $run 'held-tab'
    [void][TabBarTestNative]::Message($run.Top,0x001f,0,[IntPtr]::Zero)
    [TabBarTestNative]::Reorder($run.Top,0,1,2)
    [TabBarTestNative]::TabClick($run.Top,0,2)
    Wait-For $run 'other tab is now in first slot' {(Shell-Pid $run) -eq $secondPid}
    [TabBarTestNative]::TabClick($run.Top,1,2)
    Wait-For $run 'dragged tab is now in second slot' {(Shell-Pid $run) -eq $firstPid -and @(Children $run)[0] -eq $first}
    Check $true 'horizontal mouse drag reorders existing tab HWNDs' @{FirstShell=$firstPid;SecondShell=$secondPid}

    [TabBarTestNative]::HoldOver($run.Top,1,2,$drop)
    Wait-For $run 'detached drag preview shows the held tab title' {
        $labels=@([TabBarTestNative]::Find('Static',[IntPtr]::Zero,$true) | Where-Object {[TabBarTestNative]::Text($_) -eq [TabBarTestNative]::Text($run.Top)})
        return $labels.Count -eq 1
    }
    [TabBarTestNative]::Post($run.Top,0x001f,0,0)
    [TabBarTestNative]::TabClick($run.Top,0,2)
    Wait-For $run 'source still owns both tabs after cancelling drag' {(Shell-Pid $run) -eq $secondPid -and @(Children $run $false).Count -eq 2}
    [TabBarTestNative]::TabClick($run.Top,1,2)
    Wait-For $run 'dragged tab ready for split' {(Shell-Pid $run) -eq $firstPid}
    [TabBarTestNative]::Key($first,0x77)
    Wait-For $run 'split terminal fixture ready' {@(Children $run).Count -eq 2 -and (Shell-Pid $run) -notin 0,$firstPid,$secondPid}
    $split=@(Children $run)|Where-Object {$_ -ne $first}|Select-Object -First 1
    $splitPid=Shell-Pid $run

    [TabBarTestNative]::DropTab($run.Top,1,2,$drop,$false)
    Wait-For $run 'split tab moved into positioned second window' {
        $other=@([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true)|Where-Object {$_ -ne $run.Top})
        if($other.Count -ne 1){return $false}
        $run.Destination=$other[0]
        $destinationPanes=@(Children @{Top=$run.Destination})
        return $destinationPanes.Count -eq 2 -and $first -in $destinationPanes -and $split -in $destinationPanes -and
            @(Children $run).Count -eq 1 -and @(Children $run)[0] -eq $second
    }
    $bounds=[TabBarTestNative]::WindowBounds($run.Destination)
    Check ($bounds.Left -eq $drop.X -and $bounds.Top -eq $drop.Y) 'detached window starts at the drop position' @{X=$bounds.Left;Y=$bounds.Top;Requested=$drop}
    foreach($probe in @(
        @{Window=$first;Shell=$firstPid;Key=0x41;Text='a'},
        @{Window=$split;Shell=$splitPid;Key=0x42;Text='b'},
        @{Window=$second;Shell=$secondPid;Key=0x43;Text='c'}
    )){
        [TabBarTestNative]::SelectPane($probe.Window)
        [TabBarTestNative]::Key($probe.Window,$probe.Key)
        try {
            Wait-For $run "original PTY $($probe.Shell) receives '$($probe.Text)' after detach" {
                return (@((State $run $probe.Shell).Keys) -join ',') -eq $probe.Text
            }
        } catch {
            $record.Errors+=@{
                First=State $run $firstPid
                Split=State $run $splitPid
                Second=State $run $secondPid
            }|ConvertTo-Json -Compress
            throw
        }
    }
    Check (@(Get-ChildItem -LiteralPath $run.State -Filter '*.0000000000.json').Count -eq 3) 'detach preserves native HWNDs and original shell PIDs' @{FirstShell=$firstPid;SecondShell=$secondPid;SplitShell=$splitPid}
    $target=[TabBarTestNative]::TabScreenPoint($run.Top)
    [TabBarTestNative]::DropTab($run.Destination,0,1,$target,$false)
    Wait-For $run 'split tab merged back into original window' {
        $panes=@(Children $run)
        return @([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true)).Count -eq 1 -and
            $panes.Count -eq 2 -and $first -in $panes -and $split -in $panes
    }
    Screenshot $run 'merged-tab'
    [TabBarTestNative]::TabClick($run.Top,1,2)
    Wait-For $run 'merge inserted before existing tab and preserved its session' {(Shell-Pid $run) -eq $secondPid}
    [TabBarTestNative]::Post($run.Top,0x10,0,0)
    Check ($run.Process.WaitForExit(20000) -and $run.Process.ExitCode -eq 0) 'both windows close cleanly' @{}
}

function Test-TabSplitDrag($run){
    $first=@(Children $run)[0]
    $firstPid=Shell-Pid $run
    $outside=[TabBarTestNative]::PositionForDrag($run.Top)
    [TabBarTestNative]::Key($first,0x78)
    Wait-For $run 'second session opens' { (Shell-Pid $run) -notin 0,$firstPid }
    $second=@(Children $run)[0]
    $secondPid=Shell-Pid $run
    foreach($cancel in $true,$false){
        $destPane=if($cancel){$first}else{$second}
        if($cancel){
            $otherTab=[TabBarTestNative]::TabCenterOnScreen($run.Top,0,2)
            [TabBarTestNative]::HoldOver($run.Top,1,2,$otherTab)
            Wait-For $run 'hovering another tab exposes its terminal' {
                (Shell-Pid $run) -eq $firstPid -and @(Children $run)[0] -eq $first
            }
        }
        $bounds=[TabBarTestNative]::WindowBounds($destPane)
        $right=[TabBarTestNative+Point]::new($bounds.Right-12,($bounds.Top+$bounds.Bottom)/2)
        if(!$cancel){[TabBarTestNative]::HoldOver($run.Top,0,2,$right)}
        [TabBarTestNative]::DragAt($run.Top,$right,$false)
        Wait-For $run 'right half preview covers the target area' {
            $preview=@([TabBarTestNative]::Find('Static',[IntPtr]::Zero,$true) | Where-Object {
                $r=[TabBarTestNative]::WindowBounds($_)
                [Math]::Abs($r.Right-$bounds.Right) -lt 6 -and [Math]::Abs(2*$r.Width-$bounds.Width) -lt 12
            })
            $preview.Count -eq 1
        }
        if($cancel){
            [void][TabBarTestNative]::Message($run.Top,0x001f,0,[IntPtr]::Zero)
            Wait-For $run 'cancelling restores the source tab and both sessions' {
                (Shell-Pid $run) -eq $secondPid -and @(Children $run).Count -eq 1 -and @(Children $run $false).Count -eq 2
            }
        }else{
            [TabBarTestNative]::DragAt($run.Top,$right,$true)
        }
    }
    Wait-For $run 'both original panes share one tab' {
        $panes=@(Children $run)
        $panes.Count -eq 2 -and $first -in $panes -and $second -in $panes
    }
    $leftBounds=[TabBarTestNative]::WindowBounds($second)
    $rightBounds=[TabBarTestNative]::WindowBounds($first)
    Check ($leftBounds.Right -le $rightBounds.Left -and $leftBounds.Top -eq $rightBounds.Top) 'same-window drop places the source to the right' @{}
    Screenshot $run 'right'

    # Detach the complete two-pane tab, then return it to the bottom of a
    # separate session. The three child windows and shell PIDs must survive.
    [TabBarTestNative]::Key($first,0x78)
    Wait-For $run 'third session opens' { (Shell-Pid $run) -notin 0,$firstPid,$secondPid }
    $third=@(Children $run)[0]
    $thirdPid=Shell-Pid $run
    [TabBarTestNative]::DropTab($run.Top,0,2,$outside,$false)
    Wait-For $run 'two-pane tab is in a separate window' {
        $other=@([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true)|Where-Object {$_ -ne $run.Top})
        if($other.Count -ne 1){return $false}
        $run.Destination=$other[0]
        @(Children @{Top=$run.Destination}).Count -eq 2 -and @(Children $run)[0] -eq $third
    }
    $target=[TabBarTestNative]::WindowBounds($third)
    $bottom=[TabBarTestNative+Point]::new(($target.Left+$target.Right)/2,$target.Bottom-12)
    [TabBarTestNative]::DropTab($run.Destination,0,1,$bottom,$false)
    Wait-For $run 'cross-window split preserves all three child windows' {
        $panes=@(Children $run)
        @([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true)).Count -eq 1 -and
            $panes.Count -eq 3 -and $first -in $panes -and $second -in $panes -and $third -in $panes
    }
    $a=[TabBarTestNative]::WindowBounds($first)
    $b=[TabBarTestNative]::WindowBounds($second)
    $c=[TabBarTestNative]::WindowBounds($third)
    Check ($c.Bottom -le $a.Top -and $a.Top -eq $b.Top -and $b.Right -le $a.Left) 'source subtree and destination occupy their expected halves' @{}
    foreach($probe in @(@($first,$firstPid),@($second,$secondPid),@($third,$thirdPid))){
        [TabBarTestNative]::SelectPane($probe[0])
        [TabBarTestNative]::Key($probe[0],0x4b)
        Wait-For $run 'original shell accepts input after the split' { 'k' -in (State $run $probe[1]).Keys }
    }
    Screenshot $run 'nested'
    [TabBarTestNative]::Post($run.Top,0x10,0,0)
    Check ($run.Process.WaitForExit(20000) -and $run.Process.ExitCode -eq 0) 'merged session shuts down cleanly' @{}
}

function Send-Progress($run,[int]$shell,[string]$request){
    $target=Join-Path $run.State "$shell.progress"
    $pending=$target+'.pending'
    [IO.File]::WriteAllText($pending,$request)
    [IO.File]::Move($pending,$target)
}

function Has-ProgressWidth($top,[int]$pixels,[int]$percent){
    $expected=[TabBarTestNative]::Scaled($top,64)*$percent/100
    return [Math]::Abs($pixels-$expected) -le 2
}

function Test-TabProgress($run){
    $first=@(Children $run)[0]
    $firstPid=Shell-Pid $run
    Send-Progress $run $firstPid '1;25'
    Wait-For $run 'normal 25 percent paints green' {
        $stripe=[TabBarTestNative]::SampleProgress($run.Top,1)[0]
        return Has-ProgressWidth $run.Top $stripe.Green 25
    }
    $quarter=[TabBarTestNative]::SampleProgress($run.Top,1)[0].Green
    Send-Progress $run $firstPid '1;75'
    Wait-For $run 'normal 75 percent paints a longer indicator' {
        $stripe=[TabBarTestNative]::SampleProgress($run.Top,1)[0]
        return Has-ProgressWidth $run.Top $stripe.Green 75
    }
    $threeQuarters=[TabBarTestNative]::SampleProgress($run.Top,1)[0].Green
    Check ([Math]::Abs($threeQuarters-3*$quarter) -le 4) 'normal progress renders proportional 25 and 75 percent lengths' @{QuarterPixels=$quarter;ThreeQuarterPixels=$threeQuarters}

    [TabBarTestNative]::Key($first,0x78)
    Wait-For $run 'second tab ready for independent progress' {
        return @(Children $run $false).Count -eq 2 -and (Shell-Pid $run) -notin 0,$firstPid
    }
    $second=@(Children $run)[0]
    $secondPid=Shell-Pid $run
    Send-Progress $run $secondPid '2;50'
    Wait-For $run 'foreground error and inactive normal stripes coexist' {
        $stripes=[TabBarTestNative]::SampleProgress($run.Top,2)
        return (Has-ProgressWidth $run.Top $stripes[0].Green 75) -and (Has-ProgressWidth $run.Top $stripes[1].Red 50)
    }
    Check $true 'inactive tab preserves its progress while another reports an error' @{Stripes=[TabBarTestNative]::SampleProgress($run.Top,2)}

    [TabBarTestNative]::TabClick($run.Top,0,2)
    Wait-For $run 'the first tab is active again' {(Shell-Pid $run) -eq $firstPid}
    Send-Progress $run $secondPid '4;60'
    Wait-For $run 'background tab changes from error to pause' {
        $stripes=[TabBarTestNative]::SampleProgress($run.Top,2)
        return (Has-ProgressWidth $run.Top $stripes[0].Green 75) -and (Has-ProgressWidth $run.Top $stripes[1].Yellow 60) -and $stripes[1].Red -eq 0
    }
    Check $true 'a background report updates only its own tab indicator' @{Stripes=[TabBarTestNative]::SampleProgress($run.Top,2)}

    Send-Progress $run $firstPid '3'
    Wait-For $run 'indeterminate progress renders a segmented indicator' {
        $stripes=[TabBarTestNative]::SampleProgress($run.Top,2)
        return $stripes[0].GreenSegments -eq 3 -and (Has-ProgressWidth $run.Top $stripes[1].Yellow 60)
    }
    Check $true 'indeterminate and paused indicators coexist' @{Stripes=[TabBarTestNative]::SampleProgress($run.Top,2)}

    Send-Progress $run $firstPid '0'
    Wait-For $run 'removing first progress preserves the paused sibling' {
        $stripes=[TabBarTestNative]::SampleProgress($run.Top,2)
        return $stripes[0].Green -eq 0 -and $stripes[0].Red -eq 0 -and $stripes[0].Yellow -eq 0 -and
            (Has-ProgressWidth $run.Top $stripes[1].Yellow 60)
    }
    Check $true 'removing one tab indicator preserves the other' @{Stripes=[TabBarTestNative]::SampleProgress($run.Top,2)}

    Send-Progress $run $firstPid '1;40'
    Wait-For $run 'remaining tab has its own normal progress before detach' {
        $stripes=[TabBarTestNative]::SampleProgress($run.Top,2)
        return Has-ProgressWidth $run.Top $stripes[0].Green 40
    }
    $drop=[TabBarTestNative]::PositionForDrag($run.Top)
    [TabBarTestNative]::DropTab($run.Top,1,2,$drop,$false)
    Wait-For $run 'detached tab retains paused progress on its new window' {
        $dest=@([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true)|Where-Object {$_ -ne $run.Top})
        if($dest.Count -ne 1 -or $second -notin @(Children @{Top=$dest[0]})){return $false}
        $run.Destination=$dest[0]
        $sourceStripe=[TabBarTestNative]::SampleProgress($run.Top,1)[0]
        $destStripe=[TabBarTestNative]::SampleProgress($run.Destination,1)[0]
        return (Has-ProgressWidth $run.Top $sourceStripe.Green 40) -and (Has-ProgressWidth $run.Destination $destStripe.Yellow 60)
    }
    [TabBarTestNative]::Post($run.Destination,0x10,0,0)
    Wait-For $run 'closing detached tab preserves progress on the original window' {
        if(@([TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$true)).Count -ne 1){return $false}
        $stripe=[TabBarTestNative]::SampleProgress($run.Top,1)[0]
        return Has-ProgressWidth $run.Top $stripe.Green 40
    }
    Check $true 'progress stays with the moved tab and closing it preserves the other window' @{SourceStripe=[TabBarTestNative]::SampleProgress($run.Top,1)[0]}
    [TabBarTestNative]::Post($run.Top,0x10,0,0)
    Check ($run.Process.WaitForExit(20000) -and $run.Process.ExitCode -eq 0) 'progress fixture windows close cleanly' @{}
}

try{
    $modes=if($Case -eq 'all'){@(@{Name='opaque';Opacity=1.0},@{Name='transparent';Opacity=0.8},@{Name='light';Opacity=1.0})}elseif($Case -eq 'transparent'){@(@{Name='transparent';Opacity=0.8})}else{@(@{Name=$Case;Opacity=1.0})}
    foreach($mode in $modes){
        $current=Start-Run $mode.Opacity $mode.Name
        $record.Runs+=@{Mode=$mode.Name;Pid=$current.Process.Id;ConfiguredOpacity=$mode.Opacity}
        if($mode.Name -eq 'drag') { Test-TabDrag $current; continue }
        if($mode.Name -eq 'split-drag') { Test-TabSplitDrag $current; continue }
        if($mode.Name -eq 'progress') { Test-TabProgress $current; continue }
        $first=@(Children $current)[0];$firstPid=Shell-Pid $current
        Screenshot $current 'initial'
        [TabBarTestNative]::Key($first,0x78)
        Wait-For $current 'new-tab binding activates second session' {$visible=@(Children $current);$title=Shell-Pid $current;return @(Children $current $false).Count -eq 2 -and $visible.Count -eq 1 -and $visible[0] -ne $first -and $title -ne 0 -and $title -ne $firstPid}
        $second=@(Children $current)[0];$secondPid=Shell-Pid $current
        Check ($first -ne $second) "$($mode.Name): creating a tab selects a distinct session" @{FirstShell=$firstPid;SecondShell=$secondPid}
        [TabBarTestNative]::Key($second,0x58)
        Wait-For $current 'second session receives x' {$state=State $current $secondPid;return $state -and (@($state.Keys) -join ',') -eq 'x'}
        $firstState=State $current $firstPid
        Check ($firstState -and (@($firstState.Keys) -join ',') -eq '') "$($mode.Name): original session receives no new-tab input" @{FirstShell=$firstPid;SecondShell=$secondPid}
        [TabBarTestNative]::Key($second,0x73)
        Wait-For $current 'next-tab selects first session' {$visible=@(Children $current);return $visible.Count -eq 1 -and $visible[0] -eq $first -and (Shell-Pid $current) -eq $firstPid}
        [TabBarTestNative]::Key($first,0x43)
        Wait-For $current 'first session receives c' {$state=State $current $firstPid;return $state -and (@($state.Keys) -join ',') -eq 'c'}
        Check ((@(State $current $secondPid).Keys -join ',') -eq 'x') "$($mode.Name): switching preserves independent PTY input" @{FirstShell=$firstPid;SecondShell=$secondPid}
        [TabBarTestNative]::Key($first,0x73)
        Wait-For $current 'next-tab returns to second session' {$visible=@(Children $current);return $visible.Count -eq 1 -and $visible[0] -eq $second}
        [TabBarTestNative]::Key($second,0x78)
        Wait-For $current 'third session becomes active' {$visible=@(Children $current);$title=Shell-Pid $current;return @(Children $current $false).Count -eq 3 -and $visible.Count -eq 1 -and $visible[0] -ne $first -and $visible[0] -ne $second -and $title -ne 0 -and $title -ne $firstPid -and $title -ne $secondPid}
        $third=@(Children $current)[0]
        Screenshot $current 'three-tabs'
        [TabBarTestNative]::CloseTab($current.Top,2,3)
        Wait-For $current 'right-side close removes third session' {$visible=@(Children $current);return $visible.Count -eq 1 -and $visible[0] -eq $second -and (Shell-Pid $current) -eq $secondPid}
        [TabBarTestNative]::TabClick($current.Top,2,3)
        Wait-For $current 'closed position cannot select retired session' {$visible=@(Children $current);return $visible.Count -eq 1 -and $visible[0] -eq $second}
        Check (((@(State $current $firstPid).Keys -join ',') -eq 'c') -and ((@(State $current $secondPid).Keys -join ',') -eq 'x')) "$($mode.Name): right close preserves surviving sessions" @{FirstShell=$firstPid;SecondShell=$secondPid}
        [TabBarTestNative]::TabClick($current.Top,0,2)
        Wait-For $current 'fitted first tab selects original session' {(Shell-Pid $current) -eq $firstPid}
        [TabBarTestNative]::PlusClick($current.Top)
        Wait-For $current 'right-edge plus creates a fresh session' {$visible=@(Children $current);$title=Shell-Pid $current;return $visible.Count -eq 1 -and $visible[0] -ne $first -and $visible[0] -ne $second -and $visible[0] -ne $third -and $title -ne 0 -and $title -ne $firstPid -and $title -ne $secondPid}
        Screenshot $current 'right-edge-plus'
        [TabBarTestNative]::RenameTab($current.Top,1,3)
        Wait-For $current 'double click opens title editor' {$editors=@([TabBarTestNative]::Find('Edit',$current.Top,$true));if($editors.Count -eq 1){$script:titleEdit=$editors[0];return $true};return $false}
        [TabBarTestNative]::SetText($titleEdit,'renamed')
        [TabBarTestNative]::Key($titleEdit,0x0D)
        Wait-For $current 'title commit updates selected tab' {[TabBarTestNative]::Text($current.Top) -eq 'renamed' -and @([TabBarTestNative]::Find('Edit',$current.Top,$true)).Count -eq 0}
        [TabBarTestNative]::TabClick($current.Top,0,3)
        Wait-For $current 'other tab keeps original title' {(Shell-Pid $current) -eq $firstPid}
        [TabBarTestNative]::TabClick($current.Top,1,3)
        Wait-For $current 'renamed title survives reselection' {[TabBarTestNative]::Text($current.Top) -eq 'renamed'}
        Check ([TabBarTestNative]::Text($current.Top) -eq 'renamed') "$($mode.Name): edited title persists only on its selected tab" @{Title='renamed';OriginalShell=$firstPid}
        Screenshot $current 'renamed-tab'
        [TabBarTestNative]::Post($current.Top,0x10,0,0)
        Check ($current.Process.WaitForExit(20000)) "$($mode.Name): closing the test window exits without forced termination" @{}
        Check ($current.Process.ExitCode -eq 0) "$($mode.Name): app exit succeeds" @{ExitCode=$current.Process.ExitCode}
    }
    $record.Status='passed'
}catch{
    $record.Errors+=$_.Exception.ToString();$record.Errors+=$_.ScriptStackTrace
    if($current -and -not $current.Process.HasExited -and $current.Top){try{Screenshot $current 'failure'}catch{$record.Errors+='Capture: '+$_.Exception.Message}}
}finally{
    foreach($run in $runs){
        [TabBarTestNative]::ProcessId=$run.Process.Id
        if(-not $run.Process.HasExited){
            foreach($top in [TabBarTestNative]::Find('GhosttyWindow',[IntPtr]::Zero,$false)){
                try{[TabBarTestNative]::Post($top,0x10,0,0)}catch{}
            }
            if(-not $run.Process.WaitForExit(5000)){$run.Process.Kill($true);$run.Process.WaitForExit()}
        }
        [IO.File]::WriteAllText((Join-Path $OutputDirectory ($run.Name+'.stdout.log')),$run.Stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText((Join-Path $OutputDirectory ($run.Name+'.stderr.log')),$run.Stderr.GetAwaiter().GetResult())
    }
    $record|ConvertTo-Json -Depth 10|Set-Content (Join-Path $OutputDirectory 'tab-bar-results.json')
    Remove-Item -LiteralPath $work -Recurse -Force
}
Write-Host "Native tab bar: $($record.Status); evidence: $OutputDirectory"
if($record.Status -ne 'passed'){exit 1}
