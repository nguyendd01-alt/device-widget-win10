' Mo Device Widget (khong hien cua so PowerShell).
' Them tham so /hidden de chi chay nen o khay he thong (dung khi chay cung Windows).
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
extra = ""
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "/hidden" Then extra = " -Hidden"
End If
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "\DeviceWidget.ps1""" & extra, 0, False
