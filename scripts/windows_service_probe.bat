@echo off
rem Windows hizmeti (SCM) sondası (2.3 madde 3.9). YÖNETİCİ olarak çalıştırın; bir hizmet KURAR ve sonunda KALDIRIR (sistem değişikliği: yalnızca kendi geliştirme makinenizde).
rem Hazırlık (Mac'ten): noxc build --target windows-x64 scripts\windows_service_probe.nox -o svc.exe ; svc.exe'yi bu betikle aynı klasöre koyun.
rem Beklenen: konsolda "service mode: False"; hizmet olarak: svc.log'da "service started", sc stop sonrası "stop requested ..." ve "reported stopped"; sc query durumu STOPPED.
setlocal
set DIR=C:\nox-win-probe
if not exist %DIR% mkdir %DIR%
copy /y "%~dp0svc.exe" %DIR%\svc.exe >nul
del %DIR%\svc.log 2>nul
echo --- konsol modu
%DIR%\svc.exe
echo --- hizmet kur + baslat
sc create NoxProbeSvc binPath= "%DIR%\svc.exe" start= demand >nul
sc start NoxProbeSvc
ping -n 3 127.0.0.1 >nul
sc query NoxProbeSvc | find "STATE"
echo --- durdur
sc stop NoxProbeSvc
ping -n 4 127.0.0.1 >nul
sc query NoxProbeSvc | find "STATE"
echo --- svc.log
type %DIR%\svc.log
echo --- hizmeti kaldir
sc delete NoxProbeSvc
endlocal
