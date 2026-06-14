@echo off
cd /d "%~dp0"
"C:\Program Files\Eclipse Adoptium\jre-21.0.11.10-hotspot\bin\java.exe" -Xms1G -Xmx4G -jar server.jar nogui
pause
