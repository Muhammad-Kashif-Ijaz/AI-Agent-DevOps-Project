Option Explicit

Dim action, scriptName, shell, files, root, scriptPath, command

If WScript.Arguments.Count = 0 Then
    action = "start"
Else
    action = LCase(WScript.Arguments(0))
End If

If action = "validate" Then WScript.Quit 0

Select Case action
    Case "start"
        scriptName = "start.ps1"
    Case "stop"
        scriptName = "stop.ps1"
    Case Else
        MsgBox "Unknown KEIVO launcher action.", vbExclamation, "KEIVO"
        WScript.Quit 1
End Select

Set files = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
root = files.GetParentFolderName(WScript.ScriptFullName)
scriptPath = files.BuildPath(root, scriptName)

If Not files.FileExists(scriptPath) Then
    MsgBox "The KEIVO installation is incomplete.", vbCritical, "KEIVO"
    WScript.Quit 1
End If

command = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34)
On Error Resume Next
shell.Run command, 0, False
If Err.Number <> 0 Then
    MsgBox "KEIVO could not launch its local service.", vbCritical, "KEIVO"
    WScript.Quit 1
End If

WScript.Quit 0
