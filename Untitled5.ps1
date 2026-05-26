Get-ChildItem -Recurse -Include *.kt,*.java | 
Sort-Object LastWriteTime -Descending | 
Select-Object -First 30 FullName, LastWriteTime